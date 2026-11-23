"""HTTP load from the host against a server in a guest (M4's exit test).

httpload.py <port> <requests> <connections>

Sends <requests> GET /<n> requests over <connections> kept-alive
connections at once, n cycling through sizes from 1 KiB to 1 MiB, and
checks every body against the pattern the server sends (byte i is i % 251)
and its length against Content-Length. Then asks GET /quit. Prints one
line: answers, errors, bytes, seconds; exits 1 on any error.
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
    state = {"next": 0, "ok": 0, "bytes": 0, "errors": []}

    def take():
        with lock:
            if state["next"] >= total:
                return None
            n = state["next"]
            state["next"] += 1
            return n

    def worker():
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
        while True:
            k = take()
            if k is None:
                break
            size = SIZES[k % len(SIZES)]
            try:
                c.request("GET", f"/{size}")
                r = c.getresponse()
                body = r.read()
                if r.status != 200 or len(body) != size or body != PATTERN[:size]:
                    raise ValueError(f"status {r.status}, {len(body)} bytes of {size}, body {'matches' if body == PATTERN[:len(body)] else 'differs'}")
                with lock:
                    state["ok"] += 1
                    state["bytes"] += size
            except Exception as e:  # recorded, and the connection made anew
                with lock:
                    state["errors"].append(f"request {k} (/{size}): {e!r}")
                c.close()
                c = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
        c.close()

    start = time.monotonic()
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
    print(f"httpload: {state['ok']} answers, {len(errors)} errors, {state['bytes']} bytes in {took:.2f} s")
    for e in errors[:5]:
        print(f"httpload: {e}")
    sys.exit(1 if errors or state["ok"] != total else 0)


main()
