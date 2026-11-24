//! HTTP load from the host against a server in a guest (M4's exit test).
//!
//! `httpload <port> <requests> <connections> [restart]`
//!
//! Sends `<requests>` `GET /<n>` requests over `<connections>` kept-alive
//! connections at once, n cycling through sizes from 1 KiB to 1 MiB, and
//! checks every body against the pattern the server sends (byte i is
//! i % 251) and its length against Content-Length. Then asks `GET /quit`.
//! Prints one line: answers, errors, bytes, seconds; exits 1 on any error.
//!
//! The connections are opened one after another, each through its first
//! answer, and only then all run at once: QEMU's user-mode network listens
//! on a forwarded port with a backlog of 1 (seen with ss: Send-Q 1), so
//! connections opened together overflow the host's accept queue and
//! complete only when the host retransmits, up to 30 s later. That is the
//! emulator's port forwarding, not the system under test, which never sees
//! them. A connection made anew after a failure is opened the same way.
//!
//! With `restart`, the network stack is restarted during the load: a
//! connection that fails (reset, or closed with no answer) is made anew and
//! counted, and what is judged is the longest time without an answer (the
//! outage, at most 1 s), that no body is ever wrong, and that every failure
//! is a connection's (never a wrong answer).

use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::process::exit;
use std::sync::Mutex;
use std::time::{Duration, Instant};

const SIZES: [usize; 6] = [1024, 4096, 16384, 65536, 262_144, 1_048_576];
const TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Default)]
struct State {
    next: usize,
    ok: usize,
    bytes: usize,
    wrong: usize,
    /// When each failure happened (seconds into the run), and what it was.
    errors: Vec<(f64, String)>,
    /// When each right answer arrived.
    done: Vec<Instant>,
}

/// One kept-alive connection, opened when its first request is made.
struct Conn {
    port: u16,
    stream: Option<BufReader<TcpStream>>,
}

impl Conn {
    /// `GET <path>`: the status and the body (Content-Length bytes).
    fn get(&mut self, path: &str, close: bool) -> Result<(u16, Vec<u8>), String> {
        if self.stream.is_none() {
            let s = TcpStream::connect(("127.0.0.1", self.port)).map_err(|e| format!("connect: {e}"))?;
            s.set_read_timeout(Some(TIMEOUT))
                .and_then(|_| s.set_write_timeout(Some(TIMEOUT)))
                .map_err(|e| e.to_string())?;
            s.set_nodelay(true).map_err(|e| e.to_string())?;
            self.stream = Some(BufReader::new(s));
        }
        let r = self.stream.as_mut().expect("opened above");
        let request = format!(
            "GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nAccept-Encoding: identity\r\n{}\r\n",
            self.port,
            if close { "Connection: close\r\n" } else { "" }
        );
        r.get_mut()
            .write_all(request.as_bytes())
            .map_err(|e| format!("send: {e}"))?;
        let mut line = String::new();
        if r.read_line(&mut line).map_err(|e| format!("status line: {e}"))? == 0 {
            return Err("the connection closed with no answer".into());
        }
        let status = line
            .strip_prefix("HTTP/1.1 ")
            .or_else(|| line.strip_prefix("HTTP/1.0 "))
            .and_then(|s| s.get(..3))
            .and_then(|s| s.parse::<u16>().ok())
            .ok_or_else(|| format!("not an HTTP status line: {:?}", line.trim_end()))?;
        let (mut length, mut closes) = (None, false);
        loop {
            line.clear();
            if r.read_line(&mut line).map_err(|e| format!("headers: {e}"))? == 0 {
                return Err("the connection closed in the headers".into());
            }
            let h = line.trim_end();
            if h.is_empty() {
                break;
            }
            let Some((name, value)) = h.split_once(':') else {
                return Err(format!("a header without a colon: {h:?}"));
            };
            let value = value.trim();
            if name.eq_ignore_ascii_case("content-length") {
                length = Some(
                    value
                        .parse::<usize>()
                        .map_err(|_| format!("Content-Length {value:?}"))?,
                );
            } else if name.eq_ignore_ascii_case("connection") && value.eq_ignore_ascii_case("close") {
                closes = true;
            }
        }
        let length = length.ok_or("an answer without Content-Length")?;
        let mut body = vec![0; length];
        r.read_exact(&mut body)
            .map_err(|e| format!("body ({length} bytes): {e}"))?;
        if closes {
            self.stream = None;
        }
        Ok((status, body))
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let num = |i: usize| args.get(i).and_then(|a| a.parse::<usize>().ok());
    let (Some(port), Some(total), Some(conns)) = (num(1), num(2), num(3)) else {
        eprintln!("usage: httpload <port> <requests> <connections> [restart]");
        exit(2);
    };
    let Ok(port) = u16::try_from(port) else {
        eprintln!("httpload: port {port} is not a port");
        exit(2);
    };
    let restart = args.get(4).is_some_and(|a| a == "restart");
    let pattern: Vec<u8> = (0..SIZES[SIZES.len() - 1]).map(|i| (i % 251) as u8).collect();
    let state = Mutex::new(State::default());
    let opening = Mutex::new(());
    let start = Instant::now();

    std::thread::scope(|s| {
        for _ in 0..conns {
            s.spawn(|| {
                let mut c = Conn { port, stream: None };
                let mut first = true;
                loop {
                    // A connection's first request is made alone (QEMU's
                    // backlog of 1), the others at once.
                    let _alone = first.then(|| opening.lock().unwrap_or_else(|e| e.into_inner()));
                    let k = {
                        let mut st = state.lock().unwrap();
                        if st.next >= total {
                            break;
                        }
                        st.next += 1;
                        st.next - 1
                    };
                    let size = SIZES[k % SIZES.len()];
                    let result = c.get(&format!("/{size}"), false).and_then(|(status, body)| {
                        if status != 200 || body.len() != size || body != pattern[..size] {
                            state.lock().unwrap().wrong += 1;
                            let matches = body[..] == pattern[..body.len().min(pattern.len())];
                            return Err(format!(
                                "status {status}, {} bytes of {size}, body {}",
                                body.len(),
                                if matches { "matches" } else { "differs" }
                            ));
                        }
                        Ok(())
                    });
                    let mut st = state.lock().unwrap();
                    match result {
                        Ok(()) => {
                            st.ok += 1;
                            st.bytes += size;
                            st.done.push(Instant::now());
                            first = false;
                        }
                        Err(e) => {
                            let at = start.elapsed().as_secs_f64();
                            st.errors.push((at, format!("request {k} (/{size}) at {at:.2} s: {e}")));
                            // Made anew, one at a time as at the start.
                            c.stream = None;
                            first = true;
                        }
                    }
                }
            });
        }
    });
    let took = start.elapsed().as_secs_f64();
    let mut st = state.into_inner().unwrap();
    if let Err(e) = (Conn { port, stream: None }).get("/quit", true) {
        st.errors.push((took, format!("/quit: {e}")));
    }
    let errors = st.errors.len();
    if restart {
        st.done.sort();
        let gap = st
            .done
            .windows(2)
            .map(|w| w[1] - w[0])
            .max()
            .unwrap_or_default()
            .as_secs_f64();
        println!(
            "httpload: {} answers, {errors} connections failed, {} wrong, longest without an answer {:.0} ms, in {took:.2} s",
            st.ok,
            st.wrong,
            gap * 1000.0
        );
        st.errors.sort_by(|a, b| a.0.total_cmp(&b.0));
        for (_, e) in st.errors.iter().take(30) {
            println!("httpload: {e}");
        }
        // A restart that failed no connection did not happen under the load.
        exit(if st.wrong > 0 || gap > 1.0 || errors == 0 || st.ok + errors != total {
            1
        } else {
            0
        });
    }
    println!(
        "httpload: {} answers, {errors} errors, {} bytes in {took:.2} s",
        st.ok, st.bytes
    );
    for (_, e) in st.errors.iter().take(5) {
        println!("httpload: {e}");
    }
    exit(if errors > 0 || st.ok != total { 1 } else { 0 });
}
