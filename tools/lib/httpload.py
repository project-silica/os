"""HTTP load from the host against a server in a guest (M4's exit test).

httpload.py <port> <requests> <connections> [restart]

Sends <requests> GET /<n> requests over <connections> kept-alive
connections at once, n cycling through sizes from 1 KiB to 1 MiB, and
checks every body against the pattern the server sends (byte i is i % 251)
and its length against Content-Length. Then asks GET /quit. Prints one
line: answers, errors, bytes, seconds; exits 1 on any error.

The connections are opened one after another, each through its first
answer, and only then all run at once: QEMU's user-mode network listens on
a forwarded port with a backlog of 1 (seen with ss: Send-Q 1), so
connections opened together overflow the host's accept queue and complete
only when the host retransmits, up to 30 s later. That is the emulator's
port forwarding, not the system under test, which never sees them. A
connection made anew after a failure is opened the same way.

With `restart`, the network stack is restarted during the load: a
connection that fails (reset, or closed with no answer) is made anew and
counted, and what is judged is the longest time without an answer (the
outage, at most 1 s), that no body is ever wrong, and that every failure is
a connection's (never a wrong answer).
"""
import http.client
import sys
import threading
import time

SIZES = [1024, 4096, 16384, 65536, 262144, 1048576]
PATTERN = bytes(i % 251 for i in range(max(SIZES)))


def main():
    port, total, conns = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
    lock = threading.Lock()
    restart = len(sys.argv) > 4 and sys.argv[4] == "restart"
    state = {"next": 0, "ok": 0, "bytes": 0, "errors": [], "done": [], "wrong": 0}

    def take():
        with lock:
            if state["next"] >= total:
                return None
            n = state["next"]
            state["next"] += 1
            return n

    opening = threading.Lock()
    start = time.monotonic()

    def worker():
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
        first = True
        while True:
            if first:
                opening.acquire()
            k = take()
            if k is None:
                break
            size = SIZES[k % len(SIZES)]
            try:
                c.request("GET", f"/{size}")
                r = c.getresponse()
                body = r.read()
                if r.status != 200 or len(body) != size or body != PATTERN[:size]:
                    with lock:
                        state["wrong"] += 1
                    raise ValueError(f"status {r.status}, {len(body)} bytes of {size}, body {'matches' if body == PATTERN[:len(body)] else 'differs'}")
                with lock:
                    state["ok"] += 1
                    state["bytes"] += size
                    state["done"].append(time.monotonic())
            except Exception as e:  # recorded, and the connection made anew
                with lock:
                    state["errors"].append(f"request {k} (/{size}) at {time.monotonic() - start:.2f} s: {e!r}")
                c.close()
                c = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
                # Made anew, one at a time as at the start (QEMU's backlog
                # of 1): the next request opens it under the lock.
                reopen = True
            else:
                reopen = False
            finally:
                if first:
                    first = False
                    opening.release()
            if reopen:
                first = True
        if first:
            opening.release()
        c.close()

    threads = [threading.Thread(target=worker) for _ in range(conns)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    took = time.monotonic() - start
    try:
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
        c.request("GET", "/quit", headers={"Connection": "close"})
        c.getresponse().read()
        c.close()
    except Exception as e:
        state["errors"].append(f"/quit: {e!r}")
    errors = state["errors"]
    if restart:
        done = sorted(state["done"])
        gap = max((b - a for a, b in zip(done, done[1:])), default=0.0)
        print(f"httpload: {state['ok']} answers, {len(errors)} connections failed, {state['wrong']} wrong, longest without an answer {gap * 1000:.0f} ms, in {took:.2f} s")
        for e in sorted(errors, key=lambda e: float(e.split(" at ")[1].split(" s:")[0]))[:30]:
            print(f"httpload: {e}")
        sys.exit(1 if state["wrong"] or gap > 1.0 or not errors or state["ok"] + len(errors) != total else 0)
    print(f"httpload: {state['ok']} answers, {len(errors)} errors, {state['bytes']} bytes in {took:.2f} s")
    for e in errors[:5]:
        print(f"httpload: {e}")
    sys.exit(1 if errors or state["ok"] != total else 0)


main()
