//! `silica-remote`: manage a Silica machine from another one.
//!
//! ```text
//! silica-remote keygen <key file>       make an owner's key; print its public half
//! silica-remote public <key file>       print the public half of a key
//! silica-remote hash <program>          the BLAKE2s-256 of a program, as `services` shows it
//! silica-remote -i <key file> -m <machine key> <host>[:<port>] <command>...
//!
//!   services                  every service: state, failures, provides, program
//!   describe <service>        what it holds and what its threads are doing
//!   log <service>             its log;  logs: every log there is
//!   memory                    the machine's memory, free and held
//!   start|stop|restart <service>
//!   update <service> <program> run the service on a new program (an ELF file)
//!   revert <service>          back to the program the machine booted with
//!   shutdown | reboot
//! ```
//!
//! The owner's key is a file of 64 hexadecimal digits (`keygen` makes one,
//! readable by its owner alone); the machine's public key is given as its
//! 64 digits or a file holding them (the machine prints it when its remote
//! service starts). A session is a Noise IK handshake to that key and then
//! the machine's own protocols (`silica.remote.Session`'s page): this tool
//! is one client of them, written on the generated bindings, as the
//! machine's shell is another.
//!
//! Exit status: 0 done, 1 refused or failed (said on stderr), 2 usage.

use std::cell::RefCell;
use std::io::Write;
use std::process::exit;
use std::rc::Rc;
use std::time::Duration;

#[path = "remote_session.rs"]
mod wire;
use wire::{Channel, Conn, NoCap, fail, printable, random, read_key};

use silica_crypto::noise::Keypair;
use silica_idl_rt::{CallError, TransportError};
use silica_protocols::log::reader;
use silica_protocols::remote::session;
use silica_protocols::system::manager;

/// The bytes of one piece of a program sent with `stage`.
const PIECE: usize = 3900;

fn usage() -> ! {
    eprintln!(
        "usage: silica-remote keygen <key file> | public <key file> | hash <program> |\n       \
         silica-remote -i <key file> -m <machine key> <host>[:<port>] <command>...\n       \
         commands: services | describe <s> | log <s> | logs | memory | start <s> | stop <s> |\n       \
         restart <s> | update <s> <program> | revert <s> | shutdown | reboot"
    );
    exit(2)
}

fn text(key: &[u8; 32]) -> String {
    String::from_utf8_lossy(&silica_remote::key_text(key)).into_owned()
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn or_fail<T, E: std::fmt::Debug>(what: &str, r: Result<T, CallError<E>>) -> T {
    r.unwrap_or_else(|e| match e {
        CallError::Error(e) => fail(format!("{what}: refused: {e:?}")),
        CallError::Transport(t) => fail(format!("{what}: {t}")),
    })
}

fn keygen(path: &str) {
    let mut secret = [0u8; 32];
    random(&mut secret);
    let mut text_secret = silica_remote::key_text(&secret).to_vec();
    text_secret.push(b'\n');
    use std::os::unix::fs::OpenOptionsExt;
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .unwrap_or_else(|e| fail(format!("{path}: {e}")));
    f.write_all(&text_secret)
        .unwrap_or_else(|e| fail(format!("{path}: {e}")));
    println!("{}", text(&Keypair::new(secret).public));
}

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("keygen") if args.len() == 2 => return keygen(&args[1]),
        Some("public") if args.len() == 2 => return println!("{}", text(&Keypair::new(read_key(&args[1])).public)),
        Some("hash") if args.len() == 2 => {
            let program = std::fs::read(&args[1]).unwrap_or_else(|e| fail(format!("{}: {e}", args[1])));
            return println!("{}", hex(&silica_crypto::blake2s::hash(&[&program])));
        }
        _ => {}
    }
    let (mut owner, mut machine) = (None, None);
    while args.len() >= 2 && args[0].starts_with('-') {
        let value = args.remove(1);
        match args.remove(0).as_str() {
            "-i" => owner = Some(value),
            "-m" => machine = Some(value),
            _ => usage(),
        }
    }
    let (Some(owner), Some(machine)) = (owner, machine) else {
        usage()
    };
    if args.len() < 2 {
        usage();
    }
    let owner = Keypair::new(read_key(&owner));
    let machine = silica_remote::parse_key(&machine).unwrap_or_else(|| read_key(&machine));
    let host = args.remove(0);
    let conn = Rc::new(RefCell::new(Conn::connect(&host, &owner, &machine)));
    let channel = |channel| Channel {
        conn: conn.clone(),
        channel,
    };
    // Which channel carries which protocol: the machine says.
    let names: Vec<String> = {
        let mut s = session::Client::<Channel, NoCap>::from(channel(silica_remote::SESSION));
        let reply = or_fail("protocols", s.protocols());
        reply.names.iter().map(|n| n.to_string()).collect()
    };
    let on = |name: &str| -> u8 {
        let i = names
            .iter()
            .position(|n| n == name)
            .unwrap_or_else(|| fail(format!("the machine's session does not carry {name}")));
        i as u8 + 1
    };
    let mut mgr = manager::Client::<Channel, NoCap>::from(channel(on(manager::NAME)));
    let mut log = reader::Client::<Channel, NoCap>::from(channel(on(reader::NAME)));
    let command: Vec<&str> = args.iter().map(String::as_str).collect();
    match command[..] {
        ["services"] => {
            let reply = or_fail("services", mgr.list());
            println!(
                "{:<14} {:<8} {:>8}  {:<24} program",
                "service", "state", "failures", "provides"
            );
            for s in reply.services.iter() {
                let state = match s.state {
                    manager::State::Running => "running",
                    manager::State::Stopped => "stopped",
                    manager::State::Failed => "failed",
                    _ => "?",
                };
                let program = format!(
                    "{}{}",
                    hex(&s.program[..s.program.len().min(8)]),
                    if s.updated { " (updated)" } else { "" }
                );
                println!(
                    "{:<14} {:<8} {:>8}  {:<24} {}",
                    printable(s.name),
                    state,
                    s.failures,
                    printable(s.provides),
                    program
                );
            }
        }
        ["describe", name] => {
            let mut from = 0;
            loop {
                let reply = or_fail("describe", mgr.describe(name, from));
                print!("{}", printable(reply.text));
                if reply.next == 0 {
                    break;
                }
                from = reply.next;
            }
        }
        ["logs"] => {
            let reply = or_fail("logs", log.sources());
            for s in reply.sources.iter() {
                println!("{:<32} {:>10} bytes written", printable(s.name), s.written);
            }
        }
        ["log", name] => {
            let mut from = 0;
            loop {
                let reply = or_fail("log", log.read(name, from));
                print!("{}", printable(reply.text));
                if reply.text.is_empty() || reply.next <= from {
                    break;
                }
                from = reply.next;
            }
        }
        ["memory"] => {
            let m = or_fail("memory", mgr.memory());
            println!("free {} KiB, held by services {} KiB", m.free >> 10, m.held >> 10);
        }
        ["start", name] => drop(or_fail("start", mgr.start(name))),
        ["stop", name] => drop(or_fail("stop", mgr.stop(name))),
        ["restart", name] => drop(or_fail("restart", mgr.restart(name))),
        ["revert", name] => drop(or_fail("revert", mgr.revert(name))),
        ["update", name, path] => {
            let program = std::fs::read(path).unwrap_or_else(|e| fail(format!("{path}: {e}")));
            for (k, piece) in program.chunks(PIECE).enumerate() {
                or_fail("stage", mgr.stage((k * PIECE) as u64, piece));
            }
            match mgr.update(name, program.len() as u64) {
                Ok(_) => {}
                // Updating the session's own service, or the network stack,
                // ends this session with it: a new one asks what runs.
                Err(CallError::Transport(TransportError::PeerGone)) => {
                    let started = std::time::Instant::now();
                    let fresh = loop {
                        match Conn::try_connect(&host, &owner, &machine) {
                            Ok(c) => break c,
                            Err(e) if started.elapsed() > Duration::from_secs(20) => fail(format!(
                                "the session ended with the update, and no new one was answered in 20 s: {e}"
                            )),
                            Err(_) => std::thread::sleep(Duration::from_millis(100)),
                        }
                    };
                    *conn.borrow_mut() = fresh;
                }
                Err(e) => or_fail("update", Err::<(), _>(e)),
            }
            // What runs now is what was sent: the machine's hash of it.
            let want = silica_crypto::blake2s::hash(&[&program]);
            let reply = or_fail("services", mgr.list());
            let s = reply
                .services
                .iter()
                .find(|s| s.name == name)
                .unwrap_or_else(|| fail(format!("{name} is not among the machine's services")));
            if s.program != want || !s.updated {
                fail(format!(
                    "{name} runs program {} after the update, not the one sent ({})",
                    hex(s.program),
                    hex(&want)
                ));
            }
            println!(
                "{name} runs the program sent: {} bytes, BLAKE2s {}",
                program.len(),
                hex(&want)
            );
        }
        ["shutdown"] | ["reboot"] => match mgr.shutdown(command[0] == "reboot") {
            // Answered only if it cannot be done; otherwise the machine goes.
            Ok(_) => {}
            Err(CallError::Transport(TransportError::PeerGone)) => println!("the machine is going down"),
            Err(e) => fail(format!("{}: {e:?}", command[0])),
        },
        _ => usage(),
    }
}
