//! TCP interop between the host's Linux stack and a guest's (M4: "interop
//! suite green against the host Linux stack"):
//!
//! `tcpinterop <guest address> <phase> [<case>]` (`quit` as the phase: ask the
//! server to end)
//!
//! Runs every case against the guest's httpd on port 80 (`GET /<n>`
//! answers n bytes whose byte i is i % 251) through the host's own TCP, and
//! prints `interop: <phase>/<case>: ok (<what it exercised>)` per case, or
//! `ERROR: interop: <phase>/<case>: <why>`; exits 1 if any failed. The
//! phase only names the conditions the harness made on the path (a route
//! that advertises a small MSS and window, a lossy, reordering link); the
//! cases are the same in each:
//!
//! - `basic`: one request, one answer.
//! - `large`: 16 MiB on one connection (windows, many segments in flight).
//! - `slow_reader`: 2 MiB read in pauses, so the host's window closes and
//!   the guest must wait for it to open (zero window, its probes).
//! - `pipelined`: ten requests in one write, ten answers in order.
//! - `byte_at_a_time`: a request sent a byte a segment (no Nagle): the
//!   guest reassembles it.
//! - `half_close`: the host ends its sending after the request; the answer
//!   still comes whole.
//! - `reset`: the host resets a connection in the middle of a 4 MiB answer;
//!   the guest goes on serving (the next connection is answered).
//! - `many`: 64 connections at once, 256 KiB each.

#![feature(tcp_linger)]

use std::io::{Read, Write};
use std::net::{Shutdown, SocketAddr, TcpStream};
use std::process::exit;
use std::time::{Duration, Instant};

const PORT: u16 = 80;

fn connect(addr: SocketAddr) -> Result<TcpStream, String> {
    let s = TcpStream::connect_timeout(&addr, Duration::from_secs(10)).map_err(|e| format!("connect: {e}"))?;
    s.set_read_timeout(Some(Duration::from_secs(60)))
        .map_err(|e| e.to_string())?;
    s.set_write_timeout(Some(Duration::from_secs(60)))
        .map_err(|e| e.to_string())?;
    Ok(s)
}

fn request(n: u64, close: bool) -> String {
    format!(
        "GET /{n} HTTP/1.1\r\nHost: guest\r\n{}\r\n",
        if close { "Connection: close\r\n" } else { "" }
    )
}

/// Read one answer of `n` bytes from `s`, checking its head and every byte
/// of its body; `pause` after every 64 KiB read.
fn answer(s: &mut TcpStream, n: u64, pause: Duration) -> Result<(), String> {
    let mut head = Vec::new();
    let mut b = [0u8; 1];
    while !head.ends_with(b"\r\n\r\n") {
        s.read_exact(&mut b).map_err(|e| format!("reading the head: {e}"))?;
        head.push(b[0]);
        if head.len() > 4096 {
            return Err("a head longer than 4 KiB".into());
        }
    }
    let head = String::from_utf8_lossy(&head);
    if !head.starts_with("HTTP/1.1 200 ") {
        return Err(format!("answered {}", head.lines().next().unwrap_or("")));
    }
    let length = head
        .lines()
        .find_map(|l| l.strip_prefix("Content-Length: "))
        .and_then(|v| v.trim().parse::<u64>().ok())
        .ok_or("no Content-Length")?;
    if length != n {
        return Err(format!("Content-Length {length}, not {n}"));
    }
    let mut at = 0u64;
    let mut buf = vec![0u8; 65536];
    while at < n {
        let want = ((n - at) as usize).min(buf.len());
        let got = s
            .read(&mut buf[..want])
            .map_err(|e| format!("reading the body at byte {at}: {e}"))?;
        if got == 0 {
            return Err(format!("the connection ended at byte {at} of {n}"));
        }
        if let Some(k) = buf[..got]
            .iter()
            .enumerate()
            .position(|(k, v)| *v != ((at + k as u64) % 251) as u8)
        {
            return Err(format!("byte {} is wrong", at + k as u64));
        }
        at += got as u64;
        if !pause.is_zero() && at % 65536 < got as u64 {
            std::thread::sleep(pause);
        }
    }
    Ok(())
}

fn get(addr: SocketAddr, n: u64) -> Result<(), String> {
    let mut s = connect(addr)?;
    s.write_all(request(n, true).as_bytes()).map_err(|e| e.to_string())?;
    answer(&mut s, n, Duration::ZERO)
}

fn case(addr: SocketAddr, name: &str) -> Result<String, String> {
    match name {
        "basic" => get(addr, 1000).map(|_| "1,000 bytes".into()),
        "large" => {
            let t = Instant::now();
            get(addr, 16 << 20)?;
            Ok(format!("16 MiB in {} ms", t.elapsed().as_millis()))
        }
        "slow_reader" => {
            let mut s = connect(addr)?;
            s.write_all(request(2 << 20, true).as_bytes())
                .map_err(|e| e.to_string())?;
            let t = Instant::now();
            answer(&mut s, 2 << 20, Duration::from_millis(40))?;
            Ok(format!("2 MiB read in pauses over {} ms", t.elapsed().as_millis()))
        }
        "pipelined" => {
            let mut s = connect(addr)?;
            let sizes: Vec<u64> = (0..10).map(|k| 1 + k * 7919).collect();
            let all: String = sizes.iter().map(|n| request(*n, false)).collect();
            s.write_all(all.as_bytes()).map_err(|e| e.to_string())?;
            for n in &sizes {
                answer(&mut s, *n, Duration::ZERO).map_err(|e| format!("answer of {n} bytes: {e}"))?;
            }
            Ok("ten requests in one write, ten answers in order".into())
        }
        "byte_at_a_time" => {
            let mut s = connect(addr)?;
            s.set_nodelay(true).map_err(|e| e.to_string())?;
            let r = request(4096, true);
            for b in r.as_bytes() {
                s.write_all(&[*b]).map_err(|e| e.to_string())?;
                std::thread::sleep(Duration::from_micros(200));
            }
            answer(&mut s, 4096, Duration::ZERO)?;
            Ok(format!("a request of {} bytes sent a byte a segment", r.len()))
        }
        "half_close" => {
            let mut s = connect(addr)?;
            s.write_all(request(300_000, false).as_bytes())
                .map_err(|e| e.to_string())?;
            s.shutdown(Shutdown::Write).map_err(|e| e.to_string())?;
            answer(&mut s, 300_000, Duration::ZERO)?;
            let mut rest = [0u8; 16];
            match s.read(&mut rest) {
                Ok(0) => Ok("the answer whole after the host's FIN, then the guest's".into()),
                Ok(_) => Err("bytes after the answer".into()),
                Err(e) => Err(format!("after the answer: {e}")),
            }
        }
        "reset" => {
            let mut s = connect(addr)?;
            s.write_all(request(4 << 20, true).as_bytes())
                .map_err(|e| e.to_string())?;
            let mut part = vec![0u8; 100_000];
            s.read_exact(&mut part).map_err(|e| format!("before the reset: {e}"))?;
            s.set_linger(Some(Duration::ZERO)).map_err(|e| e.to_string())?;
            drop(s);
            get(addr, 50_000).map_err(|e| format!("after a reset: {e}"))?;
            Ok("reset 100 KB into 4 MiB; the next connection answered".into())
        }
        "many" => {
            let threads: Vec<_> = (0..64)
                .map(|_| std::thread::spawn(move || get(addr, 256 << 10)))
                .collect();
            let mut failed = Vec::new();
            for (k, t) in threads.into_iter().enumerate() {
                if let Err(e) = t.join().unwrap_or_else(|_| Err("panicked".into())) {
                    failed.push(format!("connection {k}: {e}"));
                }
            }
            if failed.is_empty() {
                Ok("64 connections at once, 256 KiB each".into())
            } else {
                Err(failed.join("; "))
            }
        }
        _ => Err("no such case".into()),
    }
}

const CASES: [&str; 8] = [
    "basic",
    "large",
    "slow_reader",
    "pipelined",
    "byte_at_a_time",
    "half_close",
    "reset",
    "many",
];

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (Some(guest), Some(phase)) = (
        args.first().and_then(|a| a.parse::<std::net::Ipv4Addr>().ok()),
        args.get(1),
    ) else {
        eprintln!("usage: tcpinterop <guest address> <phase>");
        exit(2);
    };
    let addr = SocketAddr::from((guest, PORT));
    if phase == "quit" {
        // The server ends once this answer is taken.
        let r = connect(addr).and_then(|mut s| {
            s.write_all(b"GET /quit HTTP/1.1\r\nHost: guest\r\n\r\n")
                .map_err(|e| e.to_string())?;
            answer(&mut s, 0, Duration::ZERO)
        });
        if let Err(e) = r {
            println!("ERROR: interop: quit: {e}");
            exit(1);
        }
        return;
    }
    let mut failed = 0;
    let only = args.get(2);
    for name in CASES.iter().copied().filter(|c| only.is_none_or(|o| o == c)) {
        let t = Instant::now();
        match case(addr, name) {
            Ok(what) => println!("interop: {phase}/{name}: ok ({what}; {} ms)", t.elapsed().as_millis()),
            Err(why) => {
                println!("ERROR: interop: {phase}/{name}: {why}");
                failed += 1;
            }
        }
    }
    exit(if failed == 0 { 0 } else { 1 });
}
