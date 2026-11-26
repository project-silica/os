//! The session's wire, shared by the owner's client (`silica-remote`) and
//! the test's attacker (`remoteprobe`): framing, the Noise IK handshake to a
//! machine's key, and each channel as an IDL transport.

use std::cell::RefCell;
use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::process::exit;
use std::rc::Rc;
use std::time::Duration;

use silica_crypto::noise::{self, Initiator, Keypair, Transport as Keys};
use silica_idl_rt::{CapList, Capability, Transport, TransportError};
use silica_remote::{Frames, MAX_FRAME, MAX_MESSAGE, PORT, PROLOGUE, STAMP, Status, TAG, stamp};

/// No capability crosses a network: the type stands in for one.
pub struct NoCap;
impl Capability for NoCap {}

pub fn fail(why: impl std::fmt::Display) -> ! {
    let me = std::env::args().next().unwrap_or_default();
    eprintln!("{}: {why}", me.rsplit('/').next().unwrap_or("silica-remote"));
    exit(1)
}

/// A session: the connection and its keys.
pub struct Conn {
    pub tcp: TcpStream,
    pub keys: Keys,
}

impl Conn {
    pub fn connect(addr: &str, owner: &Keypair, machine: &[u8; 32]) -> Conn {
        Conn::try_connect(addr, owner, machine).unwrap_or_else(|e| fail(e))
    }

    pub fn try_connect(addr: &str, owner: &Keypair, machine: &[u8; 32]) -> Result<Conn, String> {
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
        let mut first = [0u8; noise::FIRST + STAMP];
        let (init, n) = Initiator::start(PROLOGUE, owner, machine, e, &stamp(now_ns()), &mut first)
            .map_err(|e| format!("handshake: {e:?}"))?;
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

pub fn write_frame(tcp: &mut TcpStream, frame: &[u8]) -> std::io::Result<()> {
    let mut out = Vec::with_capacity(2 + frame.len());
    out.extend_from_slice(&Frames::length(frame.len()));
    out.extend_from_slice(frame);
    tcp.write_all(&out)
}

/// The next message, or `None` when the machine closed the connection.
pub fn read_frame(tcp: &mut TcpStream) -> Option<Vec<u8>> {
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

/// Text the machine sent (a service's log, a description, names), made
/// safe for the owner's terminal: every control character but the line end
/// (`\n`, or `\r\n` as the machine's `println!` ends a line) and the tab
/// shown as `?`, so a service on the machine cannot move the cursor,
/// rewrite lines, set the window title or reach the terminal's other
/// features through what it wrote (as `silica_rt::text` on the machine's
/// own console).
pub fn printable(text: &str) -> String {
    let unsafe_at =
        |i: usize, c: char| c.is_control() && c != '\n' && c != '\t' && !(c == '\r' && text[i + 1..].starts_with('\n'));
    text.char_indices()
        .map(|(i, c)| if unsafe_at(i, c) { '?' } else { c })
        .collect()
}

/// One of the session's channels, as an IDL transport.
pub struct Channel {
    pub conn: Rc<RefCell<Conn>>,
    pub channel: u8,
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

/// This machine's clock, in nanoseconds since 1970: what an owner's first
/// message says of when it was made (`silica_remote::stamp`), so that each
/// one is later than the last.
pub fn now_ns() -> u64 {
    let t = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    u64::try_from(t.as_nanos()).unwrap_or(u64::MAX)
}

pub fn random(out: &mut [u8]) {
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(out))
        .unwrap_or_else(|e| fail(format!("/dev/urandom: {e}")));
}

pub fn read_key(path: &str) -> [u8; 32] {
    let text = std::fs::read_to_string(path).unwrap_or_else(|e| fail(format!("{path}: {e}")));
    silica_remote::parse_key(&text).unwrap_or_else(|| fail(format!("{path} is not a key (64 hexadecimal digits)")))
}

#[cfg(test)]
mod tests {
    use super::printable;

    #[test]
    fn a_machines_text_cannot_drive_the_owners_terminal() {
        assert_eq!(
            printable("netd: up\n\tlease 10.0.2.15\n"),
            "netd: up\n\tlease 10.0.2.15\n"
        );
        assert_eq!(printable("\x1b]0;owned\x07\x1b[2J\rforged"), "?]0;owned??[2J?forged");
        assert_eq!(printable("\u{9b}31mé"), "?31mé");
        assert_eq!(printable("line\r\nnext\r"), "line\r\nnext?");
    }
}
