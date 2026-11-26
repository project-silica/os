//! A time server for a test: `sntpd <port> <seconds ahead> [bad=<n>]`.
//!
//! Answers every SNTP question on the host's loopback with the host's time
//! plus `<seconds ahead>` (so that a client that takes it is seen to have
//! taken it), as a synchronized stratum-1 server, echoing the question's
//! transmit time as the origin. Prints one line per answer.
//!
//! With `bad=<n>`, its first `n` answers are ones a client must not believe,
//! in turn: one that left 1.5 s after the question arrived while saying it
//! left at once (a round trip too long to trust), and one that says it was
//! sent a second before it was received (times that cannot be). A client
//! that sets its clock from any of them is wrong; the test that runs this
//! looks for the client saying it did not. With the first of them goes a
//! forged answer, at once, whose origin is not the question's and whose time
//! is ten years ahead: what a blind spoofer sends.
//!
//! For every question it says which port it came from and whether the
//! number the question carries for its answer to echo is the client's
//! clock (within a minute of the host's): a number anyone can guess.

use std::net::UdpSocket;
use std::process::exit;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

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
        eprintln!("usage: sntpd <port> <seconds ahead> [bad=<n>]");
        exit(2);
    };
    let mut bad = match args
        .get(3)
        .map(|a| a.strip_prefix("bad=").and_then(|n| n.parse::<u32>().ok()))
    {
        None => 0,
        Some(Some(n)) => n,
        Some(None) => {
            eprintln!("usage: sntpd <port> <seconds ahead> [bad=<n>]");
            exit(2);
        }
    };
    let socket = UdpSocket::bind(("127.0.0.1", port)).unwrap_or_else(|e| {
        eprintln!("sntpd: cannot listen on 127.0.0.1:{port}: {e}");
        exit(1);
    });
    let mut q = [0u8; 512];
    let mut answered = 0u32;
    loop {
        let (n, peer) = match socket.recv_from(&mut q) {
            Ok(r) => r,
            Err(e) => {
                eprintln!("sntpd: {e}");
                exit(1);
            }
        };
        let mut received = now(ahead);
        // A client's question (mode 3) of at least the 48-byte header.
        if n < 48 || q[0] & 7 != 3 {
            continue;
        }
        // Whether the question carries the client's clock where its nonce
        // goes (within a minute of the host's, ahead or not): a number
        // anyone can guess, where a random one belongs (RFC 9109).
        let carried = u64::from_be_bytes(q[40..48].try_into().expect("eight bytes"));
        let host = now(0.0) >> 32;
        let clock = (carried >> 32).abs_diff(host) < 60 || (carried >> 32).abs_diff(now(ahead) >> 32) < 60;
        println!(
            "sntpd: a question from port {} carries {}",
            peer.port(),
            if clock {
                "the clock"
            } else {
                "a number that is not the clock"
            }
        );
        let mut what = "answered";
        let mut transmit = now(ahead);
        if bad > 0 {
            bad -= 1;
            if answered.is_multiple_of(2) {
                // First, at once, what a blind spoofer sends: an answer whose
                // origin is not the question's, ten years ahead.
                let mut forged = [0u8; 48];
                forged[0] = 4 << 3 | 4;
                forged[1] = 1;
                forged[24..32].copy_from_slice(&(carried ^ 0x5A5A_5A5A).to_be_bytes());
                let decade = now(ahead + 10.0 * 365.0 * 86_400.0);
                forged[32..40].copy_from_slice(&decade.to_be_bytes());
                forged[40..48].copy_from_slice(&decade.to_be_bytes());
                let _ = socket.send_to(&forged, peer);
                println!("sntpd: forged an answer with another origin, ten years ahead");
                // Then late, saying it left as it arrived.
                std::thread::sleep(Duration::from_millis(1500));
                received = now(ahead);
                transmit = received;
                what = "answered late (1.5 s, a bad answer)";
            } else {
                // Sent a second before it was received.
                transmit = received - (1 << 32);
                what = "answered with times that cannot be (a bad answer)";
            }
        }
        let mut reply = [0u8; 48];
        reply[0] = 4 << 3 | 4; // no leap warning, version 4, server
        reply[1] = 1; // stratum 1
        reply[2] = 6; // poll 2^6 s
        reply[3] = -20i8 as u8; // precision 2^-20 s
        reply[12..16].copy_from_slice(b"TEST"); // reference identifier
        reply[24..32].copy_from_slice(&q[40..48]); // origin: the question's transmit time
        reply[32..40].copy_from_slice(&received.to_be_bytes());
        reply[40..48].copy_from_slice(&transmit.to_be_bytes());
        if let Err(e) = socket.send_to(&reply, peer) {
            eprintln!("sntpd: cannot answer {peer}: {e}");
            continue;
        }
        answered += 1;
        println!("sntpd: {what} {peer}");
    }
}
