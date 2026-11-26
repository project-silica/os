//! `remoteprobe`: what someone who is not, or is not only, an owner does to
//! a machine's remote management service, for the remote test
//! (os/tools/lib/tests.sh, `run_remote`) to check that it gets nothing.
//!
//! ```text
//! remoteprobe -i <owner key> -m <machine key> <host>:<port> replay <n> <seconds>
//!     records an owner's first handshake message (as anyone on the path
//!     can), then opens <n> connections that each send it again and then a
//!     frame that never ends, a byte a second; succeeds if the machine
//!     closed every one of them within <seconds>
//! remoteprobe -i <owner key> -m <machine key> <host>:<port> old-first <seconds>
//!     sends one owner's first handshake message made <seconds> ago (as one
//!     recorded then and sent now); succeeds if the machine closes the
//!     connection without answering it
//! remoteprobe -i <owner key> -m <machine key> <host>:<port> silent <n> <seconds>
//!     opens <n> connections that send nothing; succeeds if the machine
//!     closed every one of them within <seconds>
//! remoteprobe -i <owner key> -m <machine key> <host>:<port> trickle-session <seconds>
//!     as an owner, opens a session and makes one call, then starts a frame
//!     that never ends, a byte a second; succeeds if the machine closed the
//!     session within <seconds> (bytes are not messages)
//! remoteprobe -i <owner key> -m <machine key> <host>:<port> stage-hold <seconds>
//!     as an owner, sends a piece of a program the service manager refuses
//!     (`stage` past the largest program), then keeps the session, idle,
//!     for <seconds>; succeeds if the piece was refused
//! ```
//!
//! Exit status: 0 the machine held, 1 it did not (said on stderr), 2 usage.

use std::cell::RefCell;
use std::io::{ErrorKind, Read, Write};
use std::net::TcpStream;
use std::rc::Rc;
use std::time::{Duration, Instant};

#[path = "remote_session.rs"]
#[allow(dead_code)]
mod wire;
use wire::{Channel, Conn, NoCap, fail, now_ns, random, read_key, write_frame};

use silica_crypto::noise::{self, Initiator, Keypair};
use silica_idl_rt::CallError;
use silica_protocols::remote::session;
use silica_protocols::system::manager;
use silica_remote::{Frames, MAX_FRAME, PROLOGUE, STAMP, stamp};

fn usage() -> ! {
    eprintln!(
        "usage: remoteprobe -i <owner key> -m <machine key> <host>:<port> replay <n> <seconds> | old-first <seconds> | silent <n> <seconds> | trickle-session <seconds> | stage-hold <seconds>"
    );
    std::process::exit(2)
}

fn main() {
    let a: Vec<String> = std::env::args().skip(1).collect();
    if a.len() < 6 || a[0] != "-i" || a[2] != "-m" {
        usage();
    }
    let owner = Keypair::new(read_key(&a[1]));
    let machine = silica_remote::parse_key(&a[3]).unwrap_or_else(|| read_key(&a[3]));
    let host = a[4].as_str();
    let num = |i: usize| a.get(i).and_then(|s| s.parse::<u64>().ok()).unwrap_or_else(|| usage());
    match a[5].as_str() {
        "replay" => replay(host, &owner, &machine, num(6) as usize, num(7)),
        "stage-hold" => stage_hold(host, &owner, &machine, num(6)),
        "old-first" => old_first(host, &owner, &machine, num(6)),
        "silent" => silent(host, num(6) as usize, num(7)),
        "trickle-session" => trickle_session(host, &owner, &machine, num(6)),
        _ => usage(),
    }
}

/// See the module's documentation.
fn old_first(host: &str, owner: &Keypair, machine: &[u8; 32], ago: u64) {
    let mut e = [0u8; 32];
    random(&mut e);
    let mut first = [0u8; noise::FIRST + STAMP];
    let made = now_ns().saturating_sub(ago.saturating_mul(1_000_000_000));
    let (_, len) = Initiator::start(PROLOGUE, owner, machine, e, &stamp(made), &mut first)
        .unwrap_or_else(|e| fail(format!("handshake: {e:?}")));
    let mut tcp = TcpStream::connect(host).unwrap_or_else(|e| fail(format!("{host}: {e}")));
    write_frame(&mut tcp, &first[..len]).unwrap_or_else(|e| fail(format!("{host}: {e}")));
    tcp.set_read_timeout(Some(Duration::from_secs(10))).ok();
    let mut len2 = [0u8; 2];
    match tcp.read_exact(&mut len2) {
        Ok(()) => {
            eprintln!("the machine answered a first message made {ago} s ago");
            std::process::exit(1)
        }
        Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof || e.kind() == std::io::ErrorKind::ConnectionReset => {}
        Err(e) => {
            eprintln!("the machine neither answered nor closed: {e}");
            std::process::exit(1)
        }
    }
}

/// See the module's documentation.
fn replay(host: &str, owner: &Keypair, machine: &[u8; 32], n: usize, seconds: u64) {
    // The owner's first message, as it crosses the network: sent once and
    // answered, so it is one the machine takes.
    let mut e = [0u8; 32];
    random(&mut e);
    let mut first = [0u8; noise::FIRST + STAMP];
    let (_, len) = Initiator::start(PROLOGUE, owner, machine, e, &stamp(now_ns()), &mut first)
        .unwrap_or_else(|e| fail(format!("handshake: {e:?}")));
    let recorded = first[..len].to_vec();
    let mut tcp = TcpStream::connect(host).unwrap_or_else(|e| fail(format!("{host}: {e}")));
    write_frame(&mut tcp, &recorded).unwrap_or_else(|e| fail(format!("{host}: {e}")));
    let mut len2 = [0u8; 2];
    tcp.set_read_timeout(Some(Duration::from_secs(10))).ok();
    tcp.read_exact(&mut len2)
        .unwrap_or_else(|_| fail("the machine did not answer the owner's first message"));
    drop(tcp);
    // Replayed on `n` connections, each then starting a frame of the largest
    // length and sending it a byte a second, which never ends.
    let conns = (0..n)
        .map(|_| {
            let mut t = TcpStream::connect(host).unwrap_or_else(|e| fail(format!("{host}: {e}")));
            write_frame(&mut t, &recorded).unwrap_or_else(|e| fail(format!("{host}: {e}")));
            let _ = t.write_all(&Frames::length(MAX_FRAME));
            t
        })
        .collect();
    hold(conns, seconds, "replayed handshakes", true);
}

/// See the module's documentation.
fn silent(host: &str, n: usize, seconds: u64) {
    let conns = (0..n)
        .map(|_| TcpStream::connect(host).unwrap_or_else(|e| fail(format!("{host}: {e}"))))
        .collect();
    hold(conns, seconds, "silent connections", false);
}

/// See the module's documentation.
fn trickle_session(host: &str, owner: &Keypair, machine: &[u8; 32], seconds: u64) {
    let conn = Rc::new(RefCell::new(Conn::connect(host, owner, machine)));
    {
        // One whole message: the session is the owner's, proven.
        let mut s = session::Client::<Channel, NoCap>::from(Channel {
            conn: conn.clone(),
            channel: silica_remote::SESSION,
        });
        if let Err(e) = s.protocols() {
            fail(format!("protocols: {e:?}"));
        }
    }
    let tcp = conn
        .borrow()
        .tcp
        .try_clone()
        .unwrap_or_else(|e| fail(format!("{host}: {e}")));
    let mut t = tcp;
    let _ = t.write_all(&Frames::length(MAX_FRAME));
    hold(vec![t], seconds, "trickling owner sessions", true);
}

/// Keep `conns` open for at most `seconds`, reading what comes, with
/// `trickle` a byte a second on each; succeed when the machine has closed
/// every one of them, having answered none with as much as a byte (a
/// replayed first message answered is the machine taking it for the
/// owner's).
fn hold(mut conns: Vec<TcpStream>, seconds: u64, what: &str, trickle: bool) {
    let n = conns.len();
    let start = Instant::now();
    let mut closed: Vec<Option<Duration>> = vec![None; n];
    let mut answered = 0;
    for t in &conns {
        t.set_read_timeout(Some(Duration::from_millis(20))).ok();
    }
    let mut buf = [0u8; 4096];
    let mut tick = 0;
    while start.elapsed() < Duration::from_secs(seconds) && closed.iter().any(Option::is_none) {
        let now = start.elapsed();
        let send = trickle && now.as_secs() > tick;
        if send {
            tick = now.as_secs();
        }
        for (t, c) in conns.iter_mut().zip(closed.iter_mut()).filter(|(_, c)| c.is_none()) {
            let gone = match t.read(&mut buf) {
                Ok(0) => true,
                Ok(_) => {
                    answered += 1;
                    false
                }
                Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => false,
                Err(_) => true,
            };
            if gone || (send && t.write_all(&[0]).is_err()) {
                *c = Some(now);
            }
        }
    }
    let shut: Vec<Duration> = closed.iter().filter_map(|c| *c).collect();
    let last = shut.iter().max().copied().unwrap_or_default();
    println!(
        "remoteprobe: {} of {n} {what} closed by the machine, the last after {:.1} s",
        shut.len(),
        last.as_secs_f64()
    );
    if shut.len() != n {
        fail(format!("{} {what} were still open after {seconds} s", n - shut.len()));
    }
    if answered > 0 {
        fail(format!("the machine answered {what} ({answered} reads had bytes)"));
    }
}

/// See the module's documentation.
fn stage_hold(host: &str, owner: &Keypair, machine: &[u8; 32], seconds: u64) {
    let conn = Rc::new(RefCell::new(Conn::connect(host, owner, machine)));
    let channel = |channel| Channel {
        conn: conn.clone(),
        channel,
    };
    let names: Vec<String> = {
        let mut s = session::Client::<Channel, NoCap>::from(channel(silica_remote::SESSION));
        match s.protocols() {
            Ok(r) => r.names.iter().map(|n| n.to_string()).collect(),
            Err(e) => fail(format!("protocols: {e:?}")),
        }
    };
    let on = names
        .iter()
        .position(|n| n == manager::NAME)
        .unwrap_or_else(|| fail("the session does not carry the service manager")) as u8
        + 1;
    let mut mgr = manager::Client::<Channel, NoCap>::from(channel(on));
    match mgr.stage(1 << 40, b"past the largest program") {
        Err(CallError::Error(e)) => println!("remoteprobe: a piece past the largest program was refused: {e:?}"),
        Ok(_) => fail("a piece past the largest program was taken"),
        Err(e) => fail(format!("stage: {e:?}")),
    }
    std::thread::sleep(Duration::from_secs(seconds));
}
