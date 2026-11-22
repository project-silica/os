// The Linux side of the Silica benchmarks (spec/TESTING.md section 4).
//
// Runs as /init of the baseline image, built against the kernel's own nolibc.
// It measures the same operations, with the same message sizes and the same
// statistics, as the Silica benchmark task (kernel/benchroot), prints one
//     BENCH <metric> <value> <unit>
// line per result on the console, then BENCH DONE, and leaves through the
// emulator's exit device.
//
// Every latency metric is the time of one operation measured with the
// timestamp counter, over SAMPLES operations after WARMUP; reported as
// minimum, median and 99th percentile.

#include <linux/io_uring.h>

#define SAMPLES 20000
#define WARMUP 2000

static unsigned long tsc_hz;
static unsigned long samples[SAMPLES];

static inline unsigned long rdtsc(void)
{
	unsigned int lo, hi;
	__asm__ volatile("lfence; rdtsc" : "=a"(lo), "=d"(hi));
	return ((unsigned long)hi << 32) | lo;
}

static unsigned long now_ns(void)
{
	struct { long sec, nsec; } ts;
	syscall(__NR_clock_gettime, 1 /* CLOCK_MONOTONIC */, &ts);
	return ts.sec * 1000000000UL + ts.nsec;
}

static void pin(int cpu)
{
	unsigned long mask[2] = { 1UL << cpu, 0 };
	syscall(__NR_sched_setaffinity, 0, sizeof(mask), mask);
}

static void sort(unsigned long *v, int n)
{
	for (int gap = n / 2; gap > 0; gap /= 2)
		for (int i = gap; i < n; i++) {
			unsigned long x = v[i];
			int j = i;
			for (; j >= gap && v[j - gap] > x; j -= gap)
				v[j] = v[j - gap];
			v[j] = x;
		}
}

static unsigned long to_ns(unsigned long ticks)
{
	return (unsigned long)((unsigned __int128)ticks * 1000000000UL / tsc_hz);
}

// Print min, median and p99 of samples[0..n) (in ticks) as nanoseconds.
static void report(const char *name, int n, unsigned long div)
{
	sort(samples, n);
	printf("BENCH %s_min %lu ns\n", name, to_ns(samples[0]) / div);
	printf("BENCH %s %lu ns\n", name, to_ns(samples[n / 2]) / div);
	printf("BENCH %s_p99 %lu ns\n", name, to_ns(samples[n - n / 100 - 1]) / div);
}

// A 32-byte message there and back between two processes on one processor:
// the payload of a Silica call that fits in registers.
static void ipc_roundtrip(void)
{
	int a[2], b[2];
	char msg[32] = { 0 };
	pipe(a);
	pipe(b);
	if (fork() == 0) {
		pin(0);
		close(a[1]);
		close(b[0]);
		while (read(a[0], msg, sizeof(msg)) == sizeof(msg))
			write(b[1], msg, sizeof(msg));
		exit(0);
	}
	close(a[0]);
	close(b[1]);
	for (int i = -WARMUP; i < SAMPLES; i++) {
		unsigned long t = rdtsc();
		write(a[1], msg, sizeof(msg));
		read(b[0], msg, sizeof(msg));
		t = rdtsc() - t;
		if (i >= 0)
			samples[i] = t;
	}
	close(a[1]);
	close(b[0]);
	wait(0);
	report("ipc_roundtrip", SAMPLES, 1);
}

// Two processes on one processor yielding to each other, each with live
// AVX state: one sample is two switches between address spaces.
static void touch_fpu(unsigned long v)
{
	__asm__ volatile("vmovq %0, %%xmm0; vpbroadcastq %%xmm0, %%ymm15" : : "r"(v) : "xmm0", "xmm15");
}

static void ctx_switch(void)
{
	int stop[2];
	pipe(stop);
	int child = fork();
	if (child == 0) {
		pin(0);
		for (unsigned long i = 0;; i++) {
			touch_fpu(i);
			sched_yield();
		}
	}
	for (int i = -WARMUP; i < SAMPLES; i++) {
		touch_fpu(i);
		unsigned long t = rdtsc();
		sched_yield();
		t = rdtsc() - t;
		if (i >= 0)
			samples[i] = t;
	}
	kill(child, 9);
	wait(0);
	report("ctx_switch", SAMPLES, 2);
}

// How late a sleep to an absolute deadline wakes.
static void timer_overshoot(void)
{
	int n = 10000;
	// A latency-sensitive Linux program asks for no timer slack (the
	// default is 50 us); 1 ns is the least the kernel accepts.
	if (syscall(__NR_prctl, 29 /* PR_SET_TIMERSLACK */, 1UL, 0UL, 0UL, 0UL) != 0)
		printf("ERROR: bench: prctl(PR_SET_TIMERSLACK) failed\n");
	for (int i = 0; i < n; i++) {
		unsigned long at = now_ns() + 1000000;
		struct { long sec, nsec; } ts = { at / 1000000000UL, at % 1000000000UL };
		syscall(__NR_clock_nanosleep, 1, 1 /* TIMER_ABSTIME */, &ts, 0);
		samples[i] = now_ns() - at;
	}
	sort(samples, n);
	printf("BENCH timer_overshoot %lu ns\n", samples[n / 2]);
	printf("BENCH timer_overshoot_p99 %lu ns\n", samples[n - n / 100 - 1]);
}

// First touch of a fresh anonymous page: the kernel's own pager.
static void page_fault(void)
{
	int n = 8192;
	char *p = mmap(0, (long)n * 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	for (int i = 0; i < n; i++) {
		unsigned long t = rdtsc();
		p[(long)i * 4096] = 1;
		samples[i] = rdtsc() - t;
	}
	report("page_fault", n, 1);
}

// The cheapest way into the kernel and back.
static void null_syscall(void)
{
	for (int i = -WARMUP; i < SAMPLES; i++) {
		unsigned long t = rdtsc();
		syscall(__NR_getppid);
		t = rdtsc() - t;
		if (i >= 0)
			samples[i] = t;
	}
	report("null_syscall", SAMPLES, 1);
}

// Round trips per second of `pairs` independent pairs, one pair per
// processor, or with `cross` the client on one and the server on the next.
static unsigned long throughput(int pairs, int cross)
{
	int done[2];
	pipe(done);
	for (int p = 0; p < pairs; p++) {
		if (fork() == 0) {
			int a[2], b[2];
			char msg[32] = { 0 };
			unsigned long count = 0;
			pin(cross ? 2 * p : p);
			pipe(a);
			pipe(b);
			if (fork() == 0) {
				if (cross)
					pin(2 * p + 1);
				while (read(a[0], msg, sizeof(msg)) == sizeof(msg))
					write(b[1], msg, sizeof(msg));
				exit(0);
			}
			unsigned long end = now_ns() + 300000000UL;
			do {
				for (int i = 0; i < 256; i++) {
					write(a[1], msg, sizeof(msg));
					read(b[0], msg, sizeof(msg));
				}
				count += 256;
			} while (now_ns() < end);
			write(done[1], &count, sizeof(count));
			exit(0);
		}
	}
	unsigned long total = 0, c;
	for (int p = 0; p < pairs; p++) {
		read(done[0], &c, sizeof(c));
		total += c;
	}
	return total * 10 / 3;
}

// Block reads, as a program that cares would issue them: 4 KiB, the page
// cache bypassed (O_DIRECT), at offsets spread over the first RANGE bytes
// of the disk by the same sequence Silica's blkcheck uses. Queue depth 1 is
// pread; queue depth 32 is io_uring, Linux's fastest interface, without
// a polling thread (Silica's client makes a system call only when the
// driver sleeps, which is what io_uring_enter does here per batch).
#define RANGE (4UL << 20)
#define BLOCK_READS 2000
#define BLOCK_WARMUP 200
#define DEPTH 32
#define DEEP_READS 20000
static char block_buf[DEPTH * 4096] __attribute__((aligned(4096)));

static unsigned long block_at(unsigned long i)
{
	return (i * 2654435761UL) % (RANGE / 512 - 8) * 512;
}

static void block_reads(void)
{
	if (syscall(__NR_mount, "devtmpfs", "/dev", "devtmpfs", 0UL, 0UL) != 0 && errno != EBUSY) {
		printf("ERROR: bench: cannot mount devtmpfs\n");
		return;
	}
	int fd = open("/dev/vda", O_RDONLY | O_DIRECT, 0);
	if (fd < 0) {
		printf("ERROR: bench: cannot open /dev/vda for direct reads\n");
		return;
	}
	int n = 0;
	for (int i = 0; i < BLOCK_READS; i++) {
		unsigned long t = now_ns();
		if (pread(fd, block_buf, 4096, block_at(i)) != 4096) {
			printf("ERROR: bench: a direct read failed\n");
			return;
		}
		t = now_ns() - t;
		if (i >= BLOCK_WARMUP)
			samples[n++] = t;
	}
	sort(samples, n);
	printf("BENCH blk_read4k_qd1 %lu ns\n", samples[n / 2]);
	printf("BENCH blk_read4k_qd1_p99 %lu ns\n", samples[n * 99 / 100]);

	struct io_uring_params p;
	memset(&p, 0, sizeof(p));
	int ring = syscall(__NR_io_uring_setup, 64, &p);
	if (ring < 0) {
		printf("ERROR: bench: io_uring_setup failed\n");
		return;
	}
	unsigned long sq_size = p.sq_off.array + p.sq_entries * sizeof(unsigned);
	unsigned long cq_size = p.cq_off.cqes + p.cq_entries * sizeof(struct io_uring_cqe);
	if (p.features & IORING_FEAT_SINGLE_MMAP)
		sq_size = cq_size = sq_size > cq_size ? sq_size : cq_size;
	char *sq = mmap(0, sq_size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, ring, IORING_OFF_SQ_RING);
	char *cq = (p.features & IORING_FEAT_SINGLE_MMAP) ? sq : mmap(0, cq_size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, ring, IORING_OFF_CQ_RING);
	struct io_uring_sqe *sqes = mmap(0, p.sq_entries * sizeof(struct io_uring_sqe), PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, ring, IORING_OFF_SQES);
	if (sq == MAP_FAILED || cq == MAP_FAILED || sqes == MAP_FAILED) {
		printf("ERROR: bench: cannot map the io_uring\n");
		return;
	}
	unsigned *sq_tail = (unsigned *)(sq + p.sq_off.tail), *sq_mask = (unsigned *)(sq + p.sq_off.ring_mask);
	unsigned *sq_array = (unsigned *)(sq + p.sq_off.array);
	unsigned *cq_head = (unsigned *)(cq + p.cq_off.head), *cq_tail = (unsigned *)(cq + p.cq_off.tail);
	unsigned *cq_mask = (unsigned *)(cq + p.cq_off.ring_mask);
	struct io_uring_cqe *cqes = (struct io_uring_cqe *)(cq + p.cq_off.cqes);
	unsigned long sent = 0, done = 0, start = now_ns();
	while (done < DEEP_READS) {
		unsigned queued = 0, tail = *sq_tail;
		while (sent < DEEP_READS && sent - done < DEPTH) {
			unsigned at = tail & *sq_mask;
			struct io_uring_sqe *e = &sqes[at];
			memset(e, 0, sizeof(*e));
			e->opcode = IORING_OP_READ;
			e->fd = fd;
			e->addr = (unsigned long)(block_buf + (sent % DEPTH) * 4096);
			e->len = 4096;
			e->off = block_at(sent);
			e->user_data = sent;
			sq_array[at] = at;
			tail++;
			sent++;
			queued++;
		}
		__atomic_store_n(sq_tail, tail, __ATOMIC_RELEASE);
		if (syscall(__NR_io_uring_enter, ring, queued, 1, IORING_ENTER_GETEVENTS, 0UL, 0UL) < 0) {
			printf("ERROR: bench: io_uring_enter failed\n");
			return;
		}
		unsigned head = *cq_head;
		while (head != __atomic_load_n(cq_tail, __ATOMIC_ACQUIRE)) {
			if (cqes[head & *cq_mask].res != 4096) {
				printf("ERROR: bench: a queued direct read failed\n");
				return;
			}
			head++;
			done++;
		}
		__atomic_store_n(cq_head, head, __ATOMIC_RELEASE);
	}
	printf("BENCH blk_read4k_qd32 %lu ops/s\n", DEEP_READS * 1000000000UL / (now_ns() - start));
	close(fd);
}

int main(void)
{
	// The host stamps this line: the first instruction-level sign of userspace.
	printf("BENCH MARK userspace\n");
	// Before pinning, the affinity mask names every processor.
	unsigned long mask[16] = { 0 };
	long bytes = syscall(__NR_sched_getaffinity, 0, sizeof(mask), mask);
	int ncpu = 0;
	for (long i = 0; i < bytes * 8; i++)
		ncpu += (mask[i / 64] >> (i % 64)) & 1;
	pin(0);
	unsigned long t0 = now_ns(), c0 = rdtsc();
	while (now_ns() - t0 < 20000000)
		;
	tsc_hz = (unsigned long)((unsigned __int128)(rdtsc() - c0) * 1000000000UL / (now_ns() - t0));

	null_syscall();
	ipc_roundtrip();
	ctx_switch();
	page_fault();
	timer_overshoot();
	unsigned long one = throughput(1, 0);
	printf("BENCH ipc_pairs1 %lu ops/s\n", one);
	if (ncpu >= 8) {
		unsigned long eight = throughput(8, 0);
		printf("BENCH ipc_pairs8 %lu ops/s\n", eight);
		printf("BENCH ipc_scaling %lu.%02lu x\n", eight / one, eight * 100 / one % 100);
	}
	if (ncpu >= 2) {
		one = throughput(1, 1);
		printf("BENCH ipc_cross_pairs1 %lu ops/s\n", one);
		if (ncpu >= 8) {
			unsigned long four = throughput(4, 1);
			printf("BENCH ipc_cross_pairs4 %lu ops/s\n", four);
			printf("BENCH ipc_cross_scaling %lu.%02lu x\n", four / one, four * 100 / one % 100);
		}
	}
	block_reads();
	printf("BENCH DONE\n");

	// Wait until the console has sent everything (TCSBRK with a non-zero
	// argument is tcdrain), or the last lines die with the machine.
	syscall(__NR_ioctl, 1, 0x5409, 1);

	// Leave through the emulator's exit device; power off if there is none.
	if (syscall(__NR_ioperm, 0xf4, 4, 1) == 0)
		__asm__ volatile("outb %%al, %%dx" : : "a"(0x10), "d"(0xf4));
	syscall(__NR_reboot, 0xfee1dead, 672274793, 0x4321fedc, 0);
	for (;;)
		;
}
