// The host's end of the network benchmarks (tools/bench.sh): bound to a tap
// interface, it sends back every frame of EtherType 0x88B5 at once (its
// addresses swapped) and drops frames of 0x88B6 (what a guest sends to
// measure its transmit rate). It spins instead of sleeping, on a processor
// of its own, so a round trip measures the guest and the virtual device,
// not the host waking a thread. The same program answers every guest.
//
// echo <interface>
#include <arpa/inet.h>
#include <linux/if_ether.h>
#include <linux/if_packet.h>
#include <net/if.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define ECHO 0x88B5

int main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: echo <interface>\n");
		return 2;
	}
	int s = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
	unsigned index = if_nametoindex(argv[1]);
	if (s < 0 || !index) {
		perror("echo: socket or interface");
		return 1;
	}
	struct sockaddr_ll at = { .sll_family = AF_PACKET, .sll_protocol = htons(ETH_P_ALL), .sll_ifindex = index };
	if (bind(s, (struct sockaddr *)&at, sizeof(at)) != 0) {
		perror("echo: bind");
		return 1;
	}
	// Only what arrives from the guest: not the frames this program sends.
	int out = PACKET_IGNORE_OUTGOING, one = 1;
	setsockopt(s, SOL_PACKET, out, &one, sizeof(one));
	printf("echo: on %s\n", argv[1]);
	fflush(stdout);
	unsigned char f[2048], t[6];
	for (;;) {
		ssize_t n = recv(s, f, sizeof(f), MSG_DONTWAIT);
		if (n < 14 || f[12] != (ECHO >> 8) || f[13] != (ECHO & 0xFF))
			continue;
		memcpy(t, f + 6, 6);
		memcpy(f + 6, f, 6);
		memcpy(f, t, 6);
		send(s, f, n, 0);
	}
}
