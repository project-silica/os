//! TCP measured from the host against a guest's HTTP server: M4's gates of
//! spec/TESTING.md section 4.2, taken the same way of both systems (Silica's
//! `httpd`, the Linux baseline's server in bench/linux/init.c), so that the
//! instrument is the host's and not either guest's.
//!
//! `tcpbench <address:port> ready <seconds>`
//!
//! Asks `GET /1` until it is answered, at most `<seconds>`; prints
//! `ready <time>`, the first answer's arrival by the host's realtime clock in
//! seconds (what `qemu.sh --stamp` writes), for boot to a network-ready
//! server.
//!
//! `tcpbench <address:port> http <connections> <rate> <seconds>`
//!
//! Opens `<connections>` kept-alive connections, then asks `GET /1024` at
//! `<rate>` a second in all for `<seconds>`, open loop: request k is due at
//! k / rate on connection k mod connections, and its latency runs from when
//! it was due to its answer's last byte. An answer late enough to hold up
//! the next request on its connection counts against that one too, as a
//! client of a slow server would see it, not only against itself.
//! Prints `BENCH http_p50 <ns> ns` and `BENCH http_p99 <ns> ns`.
//!
//! `tcpbench <address:port> bulk <MiB> <MB/s> <qemu pid>`
//!
//! One connection reads `<MiB>` in answers of 16 MiB, its reads paced to
//! `<MB/s>` (the fixed rate: a system that could go faster does the same
//! work as one that could not). The guest's processors' time over it is the
//! time on a host processor of the QEMU process's virtual processor threads
//! (`/proc/<pid>/task/*/schedstat`, nanoseconds), so what the guest spends
//! is counted whatever it is doing, polling included. KVM's halt polling
//! would add the host's own spinning after each halt: the caller turns it
//! off (`halt_poll_ns` 0). Prints `BENCH tcp_cpu_gb <ms> ms`, milliseconds
//! of guest processor per GiB.
//!
//! Every body is checked (byte i is i % 251, the length Content-Length's);
//! a failure prints `ERROR: tcpbench: ...` and exits 1.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::process::exit;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const TIMEOUT: Duration = Duration::from_secs(30);
/// Bytes of each answer in `bulk`.
const ANSWER: u64 = 16 << 20;

fn fail(why: String) -> ! {
    println!("ERROR: tcpbench: {why}");
    exit(1)
}

fn connect(addr: SocketAddr) -> Result<BufReader<TcpStream>, String> {
    let s = TcpStream::connect_timeout(&addr, TIMEOUT).map_err(|e| format!("connect: {e}"))?;
    s.set_read_timeout(Some(TIMEOUT))
        .and_then(|_| s.set_write_timeout(Some(TIMEOUT)))
        .and_then(|_| s.set_nodelay(true))
        .map_err(|e| e.to_string())?;
    Ok(BufReader::with_capacity(1 << 16, s))
}

fn ask(s: &mut BufReader<TcpStream>, n: u64) -> Result<(), String> {
    s.get_mut()
        .write_all(format!("GET /{n} HTTP/1.1\r\nHost: guest\r\n\r\n").as_bytes())
        .map_err(|e| format!("sending a request: {e}"))
}

/// Read one answer of `n` bytes, checking its head and every byte of its
/// body. `pace`: called with the bytes read so far after each read.
fn answer(s: &mut BufReader<TcpStream>, n: u64, mut pace: impl FnMut(u64)) -> Result<(), String> {
    let mut line = String::new();
    let mut length = None;
    let mut first = true;
    loop {
        line.clear();
        s.read_line(&mut line).map_err(|e| format!("reading the head: {e}"))?;
        if line.is_empty() {
            return Err("the connection ended in the head".into());
        }
        if first && !line.starts_with("HTTP/1.1 200 ") {
            return Err(format!("answered {}", line.trim_end()));
        }
        first = false;
        if line == "\r\n" {
            break;
        }
        if let Some(v) = line.strip_prefix("Content-Length: ") {
            length = v.trim().parse::<u64>().ok();
        }
    }
    if length != Some(n) {
        return Err(format!("Content-Length {length:?}, not {n}"));
    }
    let mut at = 0u64;
    let mut buf = vec![0u8; 1 << 16];
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
        pace(at);
    }
    Ok(())
}

fn ready(addr: SocketAddr, seconds: u64) {
    let end = Instant::now() + Duration::from_secs(seconds);
    loop {
        let tried = TcpStream::connect_timeout(&addr, Duration::from_millis(100))
            .map_err(|e| e.to_string())
            .and_then(|s| {
                s.set_read_timeout(Some(Duration::from_secs(1)))
                    .map_err(|e| e.to_string())?;
                let mut s = BufReader::new(s);
                ask(&mut s, 1)?;
                answer(&mut s, 1, |_| {})
            });
        if tried.is_ok() {
            let t = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
            println!("ready {}.{:06}", t.as_secs(), t.subsec_micros());
            return;
        }
        if Instant::now() > end {
            fail(format!("no answer from {addr} in {seconds} s"));
        }
        std::thread::sleep(Duration::from_millis(1));
    }
}

fn http(addr: SocketAddr, connections: usize, rate: u64, seconds: u64) {
    // Each connection through its first answer before the clock starts.
    let mut conns = Vec::new();
    for _ in 0..connections {
        let mut c = connect(addr).unwrap_or_else(|e| fail(e));
        ask(&mut c, 1024)
            .and_then(|_| answer(&mut c, 1024, |_| {}))
            .unwrap_or_else(|e| fail(e));
        conns.push(c);
    }
    let total = rate * seconds;
    let start = Instant::now() + Duration::from_millis(10);
    let threads: Vec<_> = conns
        .into_iter()
        .enumerate()
        .map(|(i, mut c)| {
            std::thread::spawn(move || -> Result<Vec<u64>, String> {
                let mut latencies = Vec::new();
                let mut k = i as u64;
                while k < total {
                    let due = start + Duration::from_nanos(k * 1_000_000_000 / rate);
                    if let Some(wait) = due.checked_duration_since(Instant::now()) {
                        std::thread::sleep(wait);
                    }
                    ask(&mut c, 1024)?;
                    answer(&mut c, 1024, |_| {})?;
                    latencies.push(due.elapsed().as_nanos() as u64);
                    k += connections as u64;
                }
                Ok(latencies)
            })
        })
        .collect();
    let mut all = Vec::new();
    for t in threads {
        match t.join() {
            Ok(Ok(l)) => all.extend(l),
            Ok(Err(e)) => fail(e),
            Err(_) => fail("a connection's thread panicked".into()),
        }
    }
    let took = start.elapsed().as_secs_f64();
    all.sort_unstable();
    let at = |q: usize| all[(all.len() * q / 1000).min(all.len() - 1)];
    println!(
        "tcpbench: {} answers in {took:.2} s ({:.0} a second asked); max {} ns",
        all.len(),
        rate,
        all[all.len() - 1]
    );
    println!("BENCH http_p50 {} ns", at(500));
    println!("BENCH http_p99 {} ns", at(990));
}

/// Nanoseconds the virtual processor threads of QEMU process `pid` have run.
fn vcpu_ns(pid: u32) -> u64 {
    let tasks =
        std::fs::read_dir(format!("/proc/{pid}/task")).unwrap_or_else(|e| fail(format!("QEMU process {pid}: {e}")));
    let mut ns = 0;
    let mut vcpus = 0;
    for t in tasks.flatten() {
        let comm = std::fs::read_to_string(t.path().join("comm")).unwrap_or_default();
        if !comm.starts_with("CPU ") {
            continue;
        }
        let stat = std::fs::read_to_string(t.path().join("schedstat")).unwrap_or_default();
        ns += stat
            .split_whitespace()
            .next()
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(0);
        vcpus += 1;
    }
    if vcpus == 0 {
        fail(format!(
            "process {pid} has no virtual processor threads (named \"CPU n/KVM\")"
        ));
    }
    ns
}

fn bulk(addr: SocketAddr, mib: u64, mb_per_s: u64, pid: u32) {
    let bytes = mib << 20;
    let mut c = connect(addr).unwrap_or_else(|e| fail(e));
    let before = vcpu_ns(pid);
    let start = Instant::now();
    let mut done = 0u64;
    while done < bytes {
        let n = ANSWER.min(bytes - done);
        ask(&mut c, n).unwrap_or_else(|e| fail(e));
        let base = done;
        answer(&mut c, n, |at| {
            // Read no faster than the fixed rate: sleep until the bytes
            // read so far are due.
            let due = start + Duration::from_nanos((base + at) * 1000 / mb_per_s);
            if let Some(wait) = due.checked_duration_since(Instant::now()) {
                std::thread::sleep(wait);
            }
        })
        .unwrap_or_else(|e| fail(e));
        done += n;
    }
    let took = start.elapsed().as_secs_f64();
    let cpu = vcpu_ns(pid) - before;
    let rate = bytes as f64 / took / 1e6;
    if rate < mb_per_s as f64 * 0.95 {
        fail(format!(
            "{mib} MiB took {took:.2} s: {rate:.0} MB/s, short of the {mb_per_s} MB/s asked"
        ));
    }
    println!(
        "tcpbench: {mib} MiB in {took:.2} s ({rate:.0} MB/s), the guest's processors {:.3} s",
        cpu as f64 / 1e9
    );
    println!(
        "BENCH tcp_cpu_gb {:.3} ms",
        cpu as f64 / 1e6 * (1u64 << 30) as f64 / bytes as f64
    );
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let usage = || -> ! {
        eprintln!(
            "usage: tcpbench <address:port> ready <seconds> | http <connections> <rate> <seconds> | bulk <MiB> <MB/s> <qemu pid>"
        );
        exit(2)
    };
    let addr: SocketAddr = args.get(1).and_then(|a| a.parse().ok()).unwrap_or_else(|| usage());
    let n = |i: usize| -> u64 { args.get(i).and_then(|v| v.parse().ok()).unwrap_or_else(|| usage()) };
    match args.get(2).map(String::as_str) {
        Some("ready") => ready(addr, n(3)),
        Some("http") => http(addr, n(3) as usize, n(4), n(5)),
        Some("bulk") => bulk(addr, n(3), n(4), n(5) as u32),
        _ => usage(),
    }
}
