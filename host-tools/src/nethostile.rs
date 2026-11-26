//! A hostile host on the guest's link, for the interop test:
//! `nethostile <relay> <guest address> <host address> <arp|synflood|timewait>`.
//!
//! The host is the guest's router on a tap interface of the test's own.
//! This program forges frames for that link and hands each to `<relay>`, a
//! UDP address where the test runs `socat -u UDP-RECV:<port> INTERFACE:<tap>`
//! as root (one datagram, one frame on the tap: no raw socket here). Then it
//! asks the guest's httpd for an answer the ordinary way, from the host's
//! own stack: the guest must still answer the host.
//!
//! - `arp`: an unsolicited ARP reply, a request and a gratuitous ARP, each
//!   saying the host's address (the guest's router) is at another hardware
//!   address. A guest that believed one sends its answers to that address,
//!   where nobody takes them: the host's connection times out.
//! - `synflood`: 300 SYNs to port 80 from addresses on the link that do not
//!   exist (they never answer the SYN-ACK; addresses off the link would be
//!   forwarded by the host). A guest that keeps every unfinished handshake
//!   until its backlog is full refuses the host's connection.
//!
//! - `timewait`: 400 short connections in a row, each answered and closed
//!   by the guest first, so each stays in TIME-WAIT there for a minute. A
//!   guest whose TIME-WAIT holds places in its table of live connections
//!   refuses the host once they are full.
//!
//! Prints `nethostile: <case>: ok` or `ERROR: nethostile: <case>: <why>`
//! and exits 0 or 1.

use std::io::{Read, Write};
use std::net::{Ipv4Addr, SocketAddr, TcpStream, UdpSocket};
use std::process::exit;
use std::time::{Duration, Instant};

/// Frames go to the relay, which puts each on the link.
struct Link(UdpSocket, SocketAddr);

impl Link {
    fn open(relay: &str) -> Result<Link, String> {
        let to: SocketAddr = relay
            .parse()
            .map_err(|_| format!("the relay {relay} is not an address:port"))?;
        let s = UdpSocket::bind("127.0.0.1:0").map_err(|e| format!("no UDP socket: {e}"))?;
        Ok(Link(s, to))
    }

    fn send(&self, frame: &[u8]) {
        if let Err(e) = self.0.send_to(frame, self.1) {
            eprintln!("nethostile: a frame was not sent: {e}");
        }
        // The relay reads one datagram at a time.
        std::thread::sleep(Duration::from_micros(200));
    }
}

type Mac = [u8; 6];

/// The hardware address of `ip` in the host's neighbour table.
fn neighbour(ip: Ipv4Addr) -> Option<Mac> {
    let table = std::fs::read_to_string("/proc/net/arp").ok()?;
    let line = table
        .lines()
        .find(|l| l.split_whitespace().next() == Some(&ip.to_string()))?;
    mac(line.split_whitespace().nth(3)?)
}

fn mac(s: &str) -> Option<Mac> {
    let v: Vec<u8> = s
        .trim()
        .split(':')
        .filter_map(|b| u8::from_str_radix(b, 16).ok())
        .collect();
    v.try_into().ok().filter(|m: &Mac| *m != [0; 6])
}

fn ether(dst: Mac, src: Mac, ty: u16, payload: &[u8]) -> Vec<u8> {
    let mut f = Vec::with_capacity(14 + payload.len());
    f.extend_from_slice(&dst);
    f.extend_from_slice(&src);
    f.extend_from_slice(&ty.to_be_bytes());
    f.extend_from_slice(payload);
    f.resize(f.len().max(60), 0);
    f
}

fn arp(op: u16, sender_mac: Mac, sender_ip: Ipv4Addr, target_mac: Mac, target_ip: Ipv4Addr) -> Vec<u8> {
    let mut p = vec![0, 1, 8, 0, 6, 4];
    p.extend_from_slice(&op.to_be_bytes());
    p.extend_from_slice(&sender_mac);
    p.extend_from_slice(&sender_ip.octets());
    p.extend_from_slice(&target_mac);
    p.extend_from_slice(&target_ip.octets());
    p
}

fn sum(data: &[u8], mut acc: u32) -> u32 {
    for c in data.chunks(2) {
        acc += u32::from(c[0]) << 8 | u32::from(*c.get(1).unwrap_or(&0));
    }
    acc
}

fn fold(mut acc: u32) -> u16 {
    while acc > 0xFFFF {
        acc = (acc & 0xFFFF) + (acc >> 16);
    }
    !(acc as u16)
}

/// An IPv4 packet carrying a TCP SYN from `src`:`sport` to `dst`:`dport`.
fn syn(src: Ipv4Addr, sport: u16, dst: Ipv4Addr, dport: u16, seq: u32) -> Vec<u8> {
    let mut t = Vec::new();
    t.extend_from_slice(&sport.to_be_bytes());
    t.extend_from_slice(&dport.to_be_bytes());
    t.extend_from_slice(&seq.to_be_bytes());
    t.extend_from_slice(&0u32.to_be_bytes());
    t.extend_from_slice(&[6 << 4, 0x02]); // 24-byte header, SYN
    t.extend_from_slice(&65535u16.to_be_bytes());
    t.extend_from_slice(&[0, 0, 0, 0]); // checksum, urgent
    t.extend_from_slice(&[2, 4, 0x05, 0xB4]); // MSS 1460
    let mut pseudo = Vec::new();
    pseudo.extend_from_slice(&src.octets());
    pseudo.extend_from_slice(&dst.octets());
    pseudo.extend_from_slice(&[0, 6]);
    pseudo.extend_from_slice(&(t.len() as u16).to_be_bytes());
    let c = fold(sum(&t, sum(&pseudo, 0)));
    t[16..18].copy_from_slice(&c.to_be_bytes());
    let mut ip = vec![0x45, 0];
    ip.extend_from_slice(&((20 + t.len()) as u16).to_be_bytes());
    ip.extend_from_slice(&[0, 0, 0x40, 0, 64, 6, 0, 0]);
    ip.extend_from_slice(&src.octets());
    ip.extend_from_slice(&dst.octets());
    let c = fold(sum(&ip, 0));
    ip[10..12].copy_from_slice(&c.to_be_bytes());
    ip.extend_from_slice(&t);
    ip
}

/// One HTTP answer from the guest, asked the ordinary way within `within`.
fn answer(guest: Ipv4Addr, within: Duration) -> Result<(), String> {
    let deadline = Instant::now() + within;
    let mut last = String::new();
    while Instant::now() < deadline {
        let left = deadline
            .saturating_duration_since(Instant::now())
            .max(Duration::from_millis(100));
        match TcpStream::connect_timeout(&SocketAddr::from((guest, 80)), left.min(Duration::from_secs(2))) {
            Ok(mut s) => {
                let _ = s.set_read_timeout(Some(Duration::from_secs(2)));
                let _ = s.write_all(b"GET /16 HTTP/1.1\r\nHost: guest\r\nConnection: close\r\n\r\n");
                let mut got = Vec::new();
                let _ = s.read_to_end(&mut got);
                if got.starts_with(b"HTTP/1.1 200") {
                    return Ok(());
                }
                last = format!(
                    "an answer that is not 200: {:?}",
                    String::from_utf8_lossy(&got[..got.len().min(40)])
                );
            }
            Err(e) => last = e.to_string(),
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    Err(last)
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let (Some(relay), Some(guest), Some(host), Some(case)) = (
        a.get(1),
        a.get(2).and_then(|g| g.parse().ok()),
        a.get(3).and_then(|h| h.parse::<Ipv4Addr>().ok()),
        a.get(4),
    ) else {
        eprintln!("usage: nethostile <relay address:port> <guest address> <host address> <arp|synflood|timewait>");
        exit(2);
    };
    let fail = |why: String| -> ! {
        println!("ERROR: nethostile: {case}: {why}");
        exit(1)
    };
    let link = Link::open(relay).unwrap_or_else(|e| fail(e));
    if let Err(e) = answer(guest, Duration::from_secs(5)) {
        fail(format!("the guest did not answer before anything was forged: {e}"));
    }
    let guest_mac =
        neighbour(guest).unwrap_or_else(|| fail(format!("the host does not know {guest}'s hardware address")));
    let forged: Mac = [0x02, 0xde, 0xad, 0xbe, 0xef, 0x01];
    match case.as_str() {
        "arp" => {
            for _ in 0..3 {
                // An unsolicited reply to the guest, a request to it, and a
                // gratuitous ARP, each with the host's address at `forged`.
                link.send(&ether(
                    guest_mac,
                    forged,
                    0x0806,
                    &arp(2, forged, host, guest_mac, guest),
                ));
                link.send(&ether([0xFF; 6], forged, 0x0806, &arp(1, forged, host, [0; 6], guest)));
                link.send(&ether([0xFF; 6], forged, 0x0806, &arp(1, forged, host, [0; 6], host)));
                std::thread::sleep(Duration::from_millis(20));
            }
            if let Err(e) = answer(guest, Duration::from_secs(5)) {
                fail(format!(
                    "after forged ARP packets naming the host at {forged:02x?} the guest no longer answers it: {e}"
                ));
            }
        }
        "synflood" => {
            let [a0, a1, a2, _] = host.octets();
            for i in 0..300u32 {
                let src = Ipv4Addr::new(a0, a1, a2, 100 + (i % 150) as u8);
                let src_mac: Mac = [0x02, 0x5f, 0, 0, (i >> 8) as u8, i as u8];
                let packet = syn(src, 20_000 + i as u16, guest, 80, i.wrapping_mul(2_654_435_761));
                link.send(&ether(guest_mac, src_mac, 0x0800, &packet));
            }
            std::thread::sleep(Duration::from_millis(100));
            if let Err(e) = answer(guest, Duration::from_secs(5)) {
                fail(format!(
                    "after 300 SYNs from addresses that never answer, the guest does not take the host's connection: {e}"
                ));
            }
        }
        "timewait" => {
            // Short connections the guest closes first (its answer says
            // `Connection: close`), one after another: each leaves one in
            // TIME-WAIT on the guest for a minute.
            for i in 0..400 {
                if let Err(e) = answer(guest, Duration::from_secs(3)) {
                    fail(format!(
                        "connection {i} of 400 short ones the guest closed first was not answered: {e}"
                    ));
                }
            }
        }
        _ => fail("no such case (arp, synflood, timewait)".into()),
    }
    println!("nethostile: {case}: ok");
}
