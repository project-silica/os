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
use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::process::exit;
use std::rc::Rc;
use std::time::Duration;

use silica_crypto::noise::{self, Initiator, Keypair, Transport as Keys};
use silica_idl_rt::{CallError, CapList, Capability, Transport, TransportError};
use silica_protocols::log::reader;
use silica_protocols::remote::session;
use silica_protocols::system::manager;
use silica_remote::{Frames, MAX_FRAME, MAX_MESSAGE, PORT, PROLOGUE, Status, TAG};

/// No capability crosses a network: the type stands in for one.
struct NoCap;
impl Capability for NoCap {}

/// The bytes of one piece of a program sent with `stage`.
const PIECE: usize = 3900;

fn fail(why: impl std::fmt::Display) -> ! {
    eprintln!("silica-remote: {why}");
    exit(1)
}

fn usage() -> ! {
    eprintln!(
        "usage: silica-remote keygen <key file> | public <key file> | hash <program> |\n       \
         silica-remote -i <key file> -m <machine key> <host>[:<port>] <command>...\n       \
         commands: services | describe <s> | log <s> | logs | memory | start <s> | stop <s> |\n       \
         restart <s> | update <s> <program> | revert <s> | shutdown | reboot"
    );
    exit(2)
}

/// A session: the connection and its keys.
struct Conn {
    tcp: TcpStream,
    keys: Keys,
}

impl Conn {
    fn connect(addr: &str, owner: &Keypair, machine: &[u8; 32]) -> Conn {
        Conn::try_connect(addr, owner, machine).unwrap_or_else(|e| fail(e))
    }

    fn try_connect(addr: &str, owner: &Keypair, machine: &[u8; 32]) -> Result<Conn, String> {
        let target = if addr.contains(':') {
            addr.to_string()
        } else {
            format!("{addr}:{PORT}")
        };
        let sa = target
            .to_socket_addrs()
            .ok()
            .and_then(|mut a| a.next())
            .ok_or_else(|| format!("{target}: no such address"))?;
        let mut tcp = TcpStream::connect_timeout(&sa, Duration::from_secs(10)).map_err(|e| format!("{target}: {e}"))?;
        let _ = tcp.set_nodelay(true);
        let _ = tcp.set_read_timeout(Some(Duration::from_secs(120)));
        let mut e = [0u8; 32];
        random(&mut e);
        let mut first = [0u8; noise::FIRST];
        let (init, n) =
            Initiator::start(PROLOGUE, owner, machine, e, &[], &mut first).map_err(|e| format!("handshake: {e:?}"))?;
        write_frame(&mut tcp, &first[..n]).map_err(|e| format!("{target}: {e}"))?;
        let mut answer = read_frame(&mut tcp).ok_or_else(|| {
            format!(
                "{target} closed the connection: it does not know this owner's key, or its own key is not the one given"
            )
        })?;
        let (keys, _) = init
            .finish(&mut answer)
            .map_err(|e| format!("{target}'s answer did not open ({e:?}): it is not the machine with that key"))?;
        Ok(Conn { tcp, keys })
    }
}

fn write_frame(tcp: &mut TcpStream, frame: &[u8]) -> std::io::Result<()> {
    let mut out = Vec::with_capacity(2 + frame.len());
    out.extend_from_slice(&Frames::length(frame.len()));
    out.extend_from_slice(frame);
    tcp.write_all(&out)
}

/// The next message, or `None` when the machine closed the connection.
fn read_frame(tcp: &mut TcpStream) -> Option<Vec<u8>> {
    let mut len = [0u8; 2];
    tcp.read_exact(&mut len).ok()?;
    let n = usize::from(u16::from_be_bytes(len));
    if n == 0 || n > MAX_FRAME {
        fail(format!(
            "the machine sent a message of {n} bytes, which is not this protocol's"
        ));
    }
    let mut frame = vec![0u8; n];
    tcp.read_exact(&mut frame).ok()?;
    Some(frame)
}

/// One of the session's channels, as an IDL transport.
struct Channel {
    conn: Rc<RefCell<Conn>>,
    channel: u8,
}

impl Transport<NoCap> for Channel {
    fn call(
        &mut self,
        message: &mut [u8],
        len: usize,
        caps: CapList<NoCap>,
        _reply_caps: &mut CapList<NoCap>,
    ) -> Result<usize, TransportError> {
        if !caps.is_empty() {
            // A capability cannot be sent to another machine.
            return Err(TransportError::Revoked);
        }
        let mut c = self.conn.borrow_mut();
        let mut plain = vec![0u8; 1 + len + TAG];
        plain[0] = self.channel;
        plain[1..1 + len].copy_from_slice(&message[..len]);
        c.keys
            .seal(&mut plain)
            .unwrap_or_else(|e| fail(format!("sealing: {e:?}")));
        let Conn { tcp, keys } = &mut *c;
        write_frame(tcp, &plain).map_err(|_| TransportError::PeerGone)?;
        let mut frame = read_frame(tcp).ok_or(TransportError::PeerGone)?;
        let n = keys
            .open(&mut frame)
            .unwrap_or_else(|_| fail("an answer from the machine did not open"));
        let (channel, status, reply) =
            silica_remote::answer(&frame[..n]).unwrap_or_else(|| fail("the machine's answer is not one"));
        if channel != self.channel || reply.len() > MAX_MESSAGE.min(message.len()) {
            fail("the machine answered another call than the one made");
        }
        match status {
            Status::Reply => {
                message[..reply.len()].copy_from_slice(reply);
                Ok(reply.len())
            }
            Status::PeerGone => Err(TransportError::PeerGone),
            Status::Revoked | Status::NoChannel => Err(TransportError::Revoked),
        }
    }
}

fn random(out: &mut [u8]) {
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(out))
        .unwrap_or_else(|e| fail(format!("/dev/urandom: {e}")));
}

fn read_key(path: &str) -> [u8; 32] {
    let text = std::fs::read_to_string(path).unwrap_or_else(|e| fail(format!("{path}: {e}")));
    silica_remote::parse_key(&text).unwrap_or_else(|| fail(format!("{path} is not a key (64 hexadecimal digits)")))
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
                    s.name, state, s.failures, s.provides, program
                );
            }
        }
        ["describe", name] => {
            let mut from = 0;
            loop {
                let reply = or_fail("describe", mgr.describe(name, from));
                print!("{}", reply.text);
                if reply.next == 0 {
                    break;
                }
                from = reply.next;
            }
        }
        ["logs"] => {
            let reply = or_fail("logs", log.sources());
            for s in reply.sources.iter() {
                println!("{:<32} {:>10} bytes written", s.name, s.written);
            }
        }
        ["log", name] => {
            let mut from = 0;
            loop {
                let reply = or_fail("log", log.read(name, from));
                print!("{}", reply.text);
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
