//! A time server for a test: `sntpd <port> <seconds ahead>`.
//!
//! Answers every SNTP question on the host's loopback with the host's time
//! plus `<seconds ahead>` (so that a client that takes it is seen to have
//! taken it), as a synchronized stratum-1 server, echoing the question's
//! transmit time as the origin. Prints one line per answer.

use std::net::UdpSocket;
use std::process::exit;
use std::time::{SystemTime, UNIX_EPOCH};

/// Seconds from 1900 (NTP's era 0) to 1970.
const EPOCH: u64 = 2_208_988_800;

/// The host's time plus `ahead` seconds, as an NTP timestamp.
fn now(ahead: f64) -> u64 {
    let t = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("the host's clock is before 1970")
        .as_secs_f64()
        + ahead;
    let secs = t.floor();
    let frac = ((t - secs) * 4_294_967_296.0) as u64;
    ((secs as u64 + EPOCH) & 0xFFFF_FFFF) << 32 | frac
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let (Some(port), Some(ahead)) = (
        args.get(1).and_then(|p| p.parse::<u16>().ok()),
        args.get(2).and_then(|a| a.parse::<f64>().ok()),
    ) else {
        eprintln!("usage: sntpd <port> <seconds ahead>");
        exit(2);
    };
    let socket = UdpSocket::bind(("127.0.0.1", port)).unwrap_or_else(|e| {
        eprintln!("sntpd: cannot listen on 127.0.0.1:{port}: {e}");
        exit(1);
    });
    let mut q = [0u8; 512];
    loop {
        let (n, peer) = match socket.recv_from(&mut q) {
            Ok(r) => r,
            Err(e) => {
                eprintln!("sntpd: {e}");
                exit(1);
            }
        };
        let received = now(ahead);
        // A client's question (mode 3) of at least the 48-byte header.
        if n < 48 || q[0] & 7 != 3 {
            continue;
        }
        let mut reply = [0u8; 48];
        reply[0] = 4 << 3 | 4; // no leap warning, version 4, server
        reply[1] = 1; // stratum 1
        reply[2] = 6; // poll 2^6 s
        reply[3] = -20i8 as u8; // precision 2^-20 s
        reply[12..16].copy_from_slice(b"TEST"); // reference identifier
        reply[24..32].copy_from_slice(&q[40..48]); // origin: the question's transmit time
        reply[32..40].copy_from_slice(&received.to_be_bytes());
        reply[40..48].copy_from_slice(&now(ahead).to_be_bytes());
        if let Err(e) = socket.send_to(&reply, peer) {
            eprintln!("sntpd: cannot answer {peer}: {e}");
            continue;
        }
        println!("sntpd: answered {peer}");
    }
}
