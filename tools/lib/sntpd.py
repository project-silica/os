"""A time server for a test: sntpd.py <port> <seconds ahead>.

Answers every SNTP question on the host's loopback with the host's time
plus <seconds ahead> (so that a client that takes it is seen to have taken
it), as a synchronized stratum-1 server, echoing the question's transmit
time. Prints one line per answer.
"""
import socket
import struct
import sys
import time

EPOCH = 2208988800


def ntp(t):
    secs = int(t)
    return ((secs + EPOCH) & 0xFFFFFFFF) << 32 | int((t - secs) * (1 << 32))


def main():
    port, ahead = int(sys.argv[1]), float(sys.argv[2])
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", port))
    while True:
        q, peer = s.recvfrom(512)
        received = time.time() + ahead
        if len(q) < 48 or q[0] & 7 != 3:
            continue
        origin = q[40:48]
        reply = struct.pack("!BBbb11I", 4 << 3 | 4, 1, 6, -20, 0, 0, 0x54455354, 0, 0, 0, 0, 0, 0, 0, 0)
        reply = reply[:24] + origin + struct.pack("!QQ", ntp(received), ntp(time.time() + ahead))
        s.sendto(reply, peer)
        print(f"sntpd: answered {peer[0]}:{peer[1]}", flush=True)


main()
