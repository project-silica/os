#!/usr/bin/env bash
# Benchmarks against Linux (spec/TESTING.md section 4).
#   bench.sh [--runs <n>] [--only <prefix,...>] [--fresh] [--now] [--linux] [--out <results.json>] [--update-ratchet]
#   bench.sh [--runs <n>] [--only <prefix,...>] [--aa] [--steps] --compare <kernel>[,<kernel>...]
#   bench.sh [--runs <n>] [--only <prefix,...>] [--aa] --sweep NAME=value[,value...]
# The last two put several kernels side by side instead of Silica beside
# Linux (see "variants" below): the question "did this change, which of
# these designs, which commit of this range, or which value of this
# constant, made the kernel faster" asked of the machine once, for as many
# kernels as there are candidates.
#
# What is measured, and what is not (spec/TESTING.md 4.1, "Linux is locked"
# and "Measured once"):
# - Silica is compared with Linux's final numbers in bench/reference.tsv
#   (Linux at its best over the clean sessions that were run), and its
#   target on every metric is MARGIN percent better than that. Every boot
#   of a run is Silica's; a metric with no number there is held by its
#   ratchet. --linux is the owner's instrument for a decision about that
#   file.
# - The instruction counts are a function of the kernel's source: counted
#   when it changed, all eight boots at once.
# - Silica's timings come in three groups with their own boots: the kernel
#   paths (the benchmark image: the kernel repository) and the devices
#   (blk_*, net_*: the system image, plain and confined: the kernel and the
#   system), and the server (http_*, tcp_*, boot_server: the system image's
#   httpd on a tap, measured from the host by host-tools' tcpbench, the
#   Linux baseline's server likewise: boot_server below). A group whose
#   sources did not change is not booted: its results
#   are kept under its inputs (lib/evidence.sh) and read back.
# - --only blk,net (prefixes of metric names) measures and judges those
#   metrics alone, booting only the images that report them.
# So a run after a change to a driver boots the system image ten times and
# nothing else; a run of an unchanged tree boots nothing and prints the
# results it has. --fresh measures Silica's groups again whatever is kept.
# The timed boots take the machine over (turbo off, eight processors busy,
# a real-time echo on a ninth): with someone at its desktop they are not
# started unless --now says to.
#
# Builds the Silica benchmark image (the kernel's root task run with "bench"
# on its command line) and boots it --runs times (default 5) on pinned host
# processors (with --linux, the Linux baseline image as well: tools/lib/linux.sh,
# from the pinned source in bench/linux, alternately, Silica first). A guest prints
#     BENCH <metric> <number> <unit>     one line per metric, then
#     BENCH DONE
# and the host stamps the firmware's "BdsDxe: starting" and "BENCH MARK
# userspace" for the boot time (the operating system's part of it). A metric's
# value is the median over the runs; its noise is the median absolute
# deviation; the noise of a ratio to Linux combines both systems' deviations.
#
# Each metric below has a gate against Linux and the milestone it applies
# from (the MILESTONE file in the workshop root). Every metric with a Linux
# equivalent has a target MARGIN percent better than Linux's locked number
# (a ratio to it of at most 1 - MARGIN/100; a metric whose own limit is
# stricter keeps that): the margin is wider than Linux moves from one
# session to the next on this host, so a result at its target is ahead of
# Linux without Linux being booted to say so. A gate fails when the ratio
# is above its limit by more than the noise of Silica's runs. Before its
# milestone a missing value is a SKIP line, from it an ERROR; a measured
# result that misses its gate or its ratchet is an ERROR at every milestone.
# Every metric is also a ratchet: bench/ratchet.tsv keeps the best ratio to
# Linux (or the best value where Linux has no equivalent), and a result
# worse than that by more than three times the noise is an ERROR.
# --update-ratchet records improvements in that file, to be committed with
# the change that earned them. Timings are gated only under KVM; under TCG
# they are printed and recorded.
#
# Open gaps (bench/open.tsv): a shortfall that is known and not yet closed,
# one line "<metric> <linux|ratchet> <bound> <host> <why>" (tabs), added by
# a commit that says why and never by this tool. While a metric is no worse
# than its bound the miss is an OPEN line, not an ERROR, so the run's
# status says whether anything got worse, and the debt stays in view: every
# run lists it. Worse than the bound is an ERROR again. A milestone is not
# declared over an open gap: with SILICA_MILESTONE set (how the next
# milestone's gates are checked) a gap of a metric due by then is an ERROR.
# --update-ratchet tightens a bound that improved and drops a gap that closed.
#
# Output: one line per metric, one ERROR: bench::<metric>: line per failure,
# one OPEN: bench: <metric>: line per open gap,
# a "behind Linux" line naming every metric still slower than Linux (a
# scaling factor, unit x, is not one: its throughputs are; the
# system is not finished while there is one), last line
# RESULT: pass=<n> fail=<n> skipped=<n> time=<s>.
# Exit: 0 pass, 1 a gate failed, 2 usage or setup error, 3 Linux baseline unavailable.
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"
. "$TOOLS/lib/build.sh"
. "$TOOLS/lib/evidence.sh"
. "$TOOLS/lib/linux.sh"
start=$SECONDS
export LC_ALL=C

# name unit better gate limit from-milestone [repeat]
#   repeat: how far, in percent of its best, a timing may sit from one session
#   to the next on a host held still (default 1). The two timer metrics are
#   how promptly the host wakes a virtual processor more than anything Silica
#   does: three sessions of one kernel read 830, 937 and 995 ns (median) and
#   7.4, 9.9 and 8.4 us (p99), so their ratchets allow 25% and 40%; the gate
#   against Linux, measured in the same session, is what holds them.
#   gate: win  ours/linux strictly below limit     le   ours/linux at most limit
#         min  ours at least limit (no Linux value needed)
#         max  ours at most limit                  none ratchet only
#   A new metric with a number in bench/reference.tsv takes win or le; one
#   without takes none, min or max, and its ratchet holds it from its first
#   measurement.
METRICS='ipc_roundtrip ns lower win 0.5 2
ctx_switch ns lower le 1 2
boot_userspace ms lower win 1 2
timer_overshoot_p99 ns lower le 1 2 40
ipc_pairs1 ops/s higher le 1 2
ipc_pairs8 ops/s higher le 1 2
ipc_scaling x higher min 7 2
ipc_cross_pairs1 ops/s higher le 1 2
ipc_cross_pairs4 ops/s higher le 1 2
ipc_cross_scaling x higher min 3.5 2
page_fault ns lower le 1 2
null_syscall ns lower le 1 2
ipc_roundtrip_p99 ns lower le 1 2
ctx_switch_p99 ns lower le 1 2
timer_overshoot ns lower le 1 2 25
insns_null_syscall insns lower none 0 2
insns_ipc_roundtrip insns lower none 0 2
insns_ctx_switch insns lower none 0 2
insns_page_fault insns lower none 0 2
insns_notify_roundtrip insns lower none 0 2
blk_read4k_qd1 ns lower le 1 3
blk_read4k_qd1_p99 ns lower le 1 3
blk_read4k_qd32 ops/s higher le 1 3
blk_read4k_qd1_confined ns lower le 1 3
blk_read4k_qd1_p99_confined ns lower le 1 3
blk_read4k_qd32_confined ops/s higher le 1 3
net_rtt ns lower le 1 3
net_rtt_p99 ns lower le 1 3
net_tx frames/s higher le 1 3
net_rtt_confined ns lower le 1 3
net_rtt_p99_confined ns lower le 1 3
net_tx_confined frames/s higher le 1 3
spawn ns lower win 1 3
spawn_p99 ns lower le 1 3
sched_latency_p999 ns lower le 1 3 40
sched_latency_max ns lower le 1 3 40
http_p50 ns lower le 1 4
http_p99 ns lower le 1 4
tcp_cpu_gb ms lower le 1 4
boot_server ms lower win 1 4'

runs=5 out="" update=0 compare="" sweep="" only="" relinux=0 aa=0 steps=0 now=0
# How much better than Linux's locked number Silica's target is, in percent.
MARGIN=15
while [ $# -gt 0 ]; do
  case "$1" in
    --runs) [ $# -ge 2 ] || die "--runs needs a value"; runs=$2; shift 2 ;;
    --out) [ $# -ge 2 ] || die "--out needs a file"; out=$2; shift 2 ;;
    --update-ratchet) update=1; shift ;;
    --only) [ $# -ge 2 ] || die "--only needs metric prefixes"; only=$2; shift 2 ;;
    --linux) relinux=1; shift ;;
    --now) now=1; shift ;;
    --fresh) FRESH=1; shift ;;
    --compare) [ $# -ge 2 ] || die "--compare needs commits of the kernel repository, a range of them, or kernel checkouts"; compare=$2; shift 2 ;;
    --aa) aa=1; shift ;;
    --steps) steps=1; shift ;;
    --sweep) [ $# -ge 2 ] && [[ $2 =~ ^[A-Z_]+=[0-9]+(,[0-9]+)*$ ]] || die "--sweep needs NAME=value[,value...]"; sweep=$2; shift 2 ;;
    *) die "unknown argument $1" ;;
  esac
done
case "$runs" in ''|0|*[!0-9]*) die "--runs must be a positive number" ;; esac
command -v jq >/dev/null || die "jq is not installed (run tools/init.sh)"

OS=$(checkout_of os)
RATCHET=$OS/bench/ratchet.tsv
REFERENCE=$OS/bench/reference.tsv
OPEN=$OS/bench/open.tsv
ms=$(milestone)
mkdir -p "$LOGS/bench"
new_run
evidence_init
pass=0 fail=0 skipped=0
# wanted <metric>: whether this run measures and judges it (--only).
wanted() {
  local p
  [ -z "$only" ] && return 0
  for p in ${only//,/ }; do case "$1" in "$p"*) return 0 ;; esac; done
  return 1
}
# group_of <metric>: which of the run's parts reports it. Each part has its
# own boots and its own inputs, and is measured when those changed: the
# instruction counts (the kernel's source, emulated), the devices (the
# system image, on the machines with and without an IOMMU), the kernel
# paths (the benchmark image).
group_of() { case "$1" in insns_*) echo counts ;; blk_*|net_*) echo io ;; http_*|tcp_*|boot_server) echo server ;; *) echo kernel ;; esac; }
accel=tcg; [ -w /dev/kvm ] && [ -z "${SILICA_NO_KVM:-}" ] && accel=kvm
SMP=${SILICA_BENCH_SMP:-8} MEM=${SILICA_BENCH_MEM:-512}

finish() {
  echo "RESULT: pass=$pass fail=$fail skipped=$skipped time=$((SECONDS - start))"
  [ "$fail" = 0 ] || exit 1
  exit 0
}
ok() { echo "bench: $1"; pass=$((pass + 1)); }
# Instruction counts (insns_*) do not depend on the accelerator: they are
# gated under TCG as well.
gated() { [ $accel = kvm ] || [ "${1#insns_}" != "$1" ]; }
enforce() { # enforce <metric> <from-milestone> <message>: a metric not measured yet: ERROR from its milestone (under KVM), SKIP before
  if [ "$ms" -ge "$2" ] && gated "$1"; then echo "ERROR: bench::$1: $3"; fail=$((fail + 1))
  else echo "SKIP: bench: $1: $3 (required from M$2 under KVM)"; skipped=$((skipped + 1)); fi
}
declare -A missed=()   # metrics that missed (miss): an open gap of one is not closed
miss() { # miss <metric> <message>: a measured result that misses its gate or ratchet: ERROR at every milestone (under KVM)
  missed[$1]=1
  if gated "$1"; then echo "ERROR: bench::$1: $2"; fail=$((fail + 1))
  else echo "SKIP: bench: $1: $2 (timings are gated under KVM only)"; skipped=$((skipped + 1)); fi
}
fmt() { awk -v x="$1" 'BEGIN { printf "%.4g", x }'; }

# Host processors for the guests: $SILICA_BENCH_CPUS, else one hardware thread
# of each of the fastest cores, as many as the guest has processors.
pin=${SILICA_BENCH_CPUS:-$(fastest_cpus "$SMP")}
# The network benchmarks' other end: the host's echo (os/bench/net/echo.c)
# on a tap interface with vhost-net, the same for both systems, spinning on
# one more processor of the fastest kind, held like the guests'.
tap=silica-bench0 netargs=() echo_pid=""
echo_cpu=$(fastest_cpus "$((SMP + 1))" | tr , '\n' | grep -vxF -f <(echo "$pin" | tr , '\n') | head -n 1)
# The emulator's own threads (qemu.sh --emulator), each where it neither
# takes turns with a virtual processor on one host processor nor shares a
# core with one that works: the disk's I/O thread on the other hardware
# thread of the last virtual processor's core and the network's (vhost-net)
# on the one before it, the cores of the processors both systems leave idle
# longest; the rest (the main loop, its workers) on processors of no
# virtual processor's core. Left to the host's scheduler, the I/O thread
# sat beside whichever virtual processor it happened to land by, and a
# guest spinning there for its next completion slowed the device by a
# microsecond (host trace of the doorbell and the interrupt,
# spec/ARCHITECTURE.md section 7); a run's tail depended on where it landed.
pins=$(echo "$pin" | tr , '\n')
io_cpu=$(siblings_of "$(tail -n 1 <<<"$pins")")
net_cpu=$(siblings_of "$(tail -n 2 <<<"$pins" | head -n 1)")
rest=$(grep -vxF -f <(printf '%s\n' $pins $(siblings_of "$pin" | tr , ' ') "$echo_cpu") \
  <(ls -d /sys/devices/system/cpu/cpu[0-9]* | sed 's/.*cpu//' | sort -n) | paste -sd, -)
emu=${SILICA_BENCH_EMULATOR_CPUS:-$(echo "$io_cpu,$net_cpu,${rest:-$(siblings_of "$pin")}" | sed 's/^,*//; s/,,*/,/g; s/,$//')}
# The boot disk without event indices (VIRTIO_F_RING_EVENT_IDX): QEMU's I/O
# thread, while it polls the ring, can say "no doorbell needed" only through
# the ring's flag; with event indices every request rang it, a guest exit
# each (host trace: 2,940 of 2,940). Off, both systems read at depth 1 in
# two thirds of the time (Linux 5.4 to 3.4 us), so it is the baseline's
# tuning as much as ours.
disk_props=event_idx=off
# Those processors are held at one policy for both systems while the guests
# run (host_tune), and put back afterwards, whichever way this script ends.
# A host left on its power-saving default measures its own frequency ramps
# and sleep states: the same kernel then reads several percent apart from
# one session to the next. Where the policy cannot be set the results say so.
policy=$LOGS/bench/host-policy tuned=no
mkdir -p "$LOGS/bench"
host_restore "$policy"   # left by a run that was killed
# (The tool's own test boots nothing: there is no host to hold.)
[ -n "${SILICA_BENCH_IMG:-}" ] && tuned=stub
# Whether the host can be held (and the network's other end set up): known
# before anything is, because what a measurement was taken on is one of its
# inputs, and a run that measures nothing leaves the host alone.
can_sudo=no; sudo -n true 2>/dev/null && can_sudo=yes
[ $accel = kvm ] && [ -n "$pin" ] && [ $tuned = no ] && [ $can_sudo = yes ] && tuned=yes
held_host=0
# Someone at the machine: a graphical session that is active, not idle and
# not locked (KDE's lock screen leaves IdleHint at "no": nobody uses a
# locked desktop).
desk_in_use() {
  local s
  command -v loginctl >/dev/null || return 1
  for s in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{ print $1 }'); do
    [ "$(loginctl show-session "$s" -p Active --value 2>/dev/null)" = yes ] || continue
    case "$(loginctl show-session "$s" -p Type --value 2>/dev/null)" in wayland|x11) ;; *) continue ;; esac
    [ "$(loginctl show-session "$s" -p LockedHint --value 2>/dev/null)" = yes ] && continue
    [ "$(loginctl show-session "$s" -p IdleHint --value 2>/dev/null)" = yes ] || return 0
  done
  return 1
}
hold_host() { # hold the host still, once, before the first timed boot
  [ $held_host = 0 ] || return 0
  held_host=1
  if [ $tuned != stub ] && [ $now = 0 ] && desk_in_use; then
    err "someone is at this machine's desktop, and timed boots take the machine over (turbo off, eight processors busy, a real-time echo): not started. Run it when the desktop is idle, or with --now if its owner said so. (--only insns counts instructions and disturbs nobody.)"
    quit 2
  fi
  [ $tuned = yes ] || { [ $tuned = stub ] || echo "bench: host not tuned (needs KVM and passwordless sudo) so timings carry its power-saving policy"; return 0; }
  trap 'host_restore "$policy"; net_down' EXIT
  trap 'exit 130' INT TERM
  host_tune "$pin${echo_cpu:+,$echo_cpu}" "$policy" || { host_restore "$policy"; err "cannot hold the host still (host_tune failed)"; exit 2; }
  # Nothing else on the host runs where the benchmark does (host_shield).
  host_shield "$pin${echo_cpu:+,$echo_cpu}" "$policy" || { host_restore "$policy"; err "cannot keep the host's other programs off the timed processors (host_shield failed)"; exit 2; }
}

# net_up: the tap and the echo, or return 1 (no sudo, no spare processor).
net_ok=no; [ -z "${SILICA_BENCH_IMG:-}" ] && [ -n "$echo_cpu" ] && [ $can_sudo = yes ] && net_ok=yes
net_up() {
  [ $net_ok = yes ] || return 1
  [ -z "$echo_pid" ] || return 0
  gcc -O2 -Wall -o "$RUN/echo" "$OS/bench/net/echo.c" >>"$LOGS/bench/echo.log" 2>&1 || return 1
  ip link show "$tap" >/dev/null 2>&1 || sudo -n ip tuntap add dev "$tap" mode tap user "$(id -un)" || return 1
  sudo -n ip link set "$tap" up && sudo -n sysctl -q -w "net.ipv6.conf.$tap.disable_ipv6=1" || return 1
  sudo -n taskset -c "$echo_cpu" chrt -f 50 "$RUN/echo" "$tap" >>"$LOGS/bench/echo.log" 2>&1 &
  echo_pid=$!
}
net_down() { [ -z "$echo_pid" ] || sudo -n pkill -P "$echo_pid" 2>/dev/null; echo_pid=""; }
[ $net_ok = yes ] && netargs=(--net "tap:$tap")
quit() { echo "RESULT: pass=$pass fail=1 skipped=$skipped time=$((SECONDS - start))"; exit "$1"; }

# What else the host did while the timed boots ran: the processors' busy
# time over the whole machine (/proc/stat) less this run's own (its
# emulators, as the shell accounts its children, and the network's echo,
# which spins on its processor by design), per second of the timed boots: how
# many processors other programs kept busy, on average. A timing shares the
# host's caches, memory and hardware threads with whatever else runs, so
# this is measured, reported with the results and kept beside them.
busy_now() { awk '$1 == "cpu" { printf "%.2f", ($2 + $3 + $4 + $7 + $8 + $9) / 100; exit }' /proc/stat; }
# ours_now: sets $ours, the processor seconds this tool and what it ran used
# so far. `times` runs in this shell, not in a $( ) subshell: there it
# reports the subshell's own children, none, and every benchmark guest
# counted as another program's load (2026-11-23: "7.72 processors busy"
# while top showed QEMU at 797% and the echo at 99%, and nothing else).
ours_now() {
  local e=0
  [ -z "$echo_pid" ] || e=$(ps -o cputimes= --ppid "$echo_pid" 2>/dev/null | awk '{ s += $1 } END { print s + 0 }')
  times >"$RUN/times"
  ours=$(awk -v e="$e" '{ for (i = 1; i <= NF; i++) { split($i, a, /[ms]/); s += a[1] * 60 + a[2] } } END { printf "%.2f", s + e }' "$RUN/times")
}
watch_start() { ours_now; w_busy=$(busy_now) w_ours=$ours w_at=$EPOCHREALTIME; }
watch_end() { # sets host_other
  ours_now
  host_other=$(awk -v b0="$w_busy" -v b1="$(busy_now)" -v o0="$w_ours" -v o1="$ours" -v t0="$w_at" -v t1="$EPOCHREALTIME" \
    'BEGIN { d = t1 - t0; x = (d > 0) ? ((b1 - b0) - (o1 - o0)) / d : 0; printf "%.2f", (x > 0 ? x : 0) }')
}

# The machines (spec/TESTING.md 4.1, "Confinement is compared with
# confinement"): the kernel paths and boot compare Silica as it runs, its
# devices confined by the IOMMU, with Linux at its fastest, on the machine
# without one; the block path compares both on the machine without an
# IOMMU (blk_*), and both confining DMA on the machine with one
# (blk_*_confined: Linux with intel_iommu=on, its fastest lazy mode).
# boot <system> <image> <run> [<values> [<machine> [<keep>]]]: one boot;
# appends "<metric> <value> <unit>" lines to $RUN/<values>.values (default:
# <system>), and its boot time and the firmware's when <keep> is "all" (the
# default). <machine>:
# "iommu" (the default) or "plain". <keep> "blk" keeps only the device
# metrics (blk_, net_), "confined" keeps them as *_confined.
boot() {
  local sys=$1 img=$2 i=$3 vals=${4:-$1} machine=${5:-iommu} keep=${6:-all} ser=$RUN/$1.$3.serial st=$RUN/$1.$3.stamp qlog=$LOGS/bench/$1.$3.log rc t0 t1
  local -a margs=()
  [ "$machine" = plain ] && margs=(--no-iommu)
  # The system image runs netcheck even on a host without a spare core
  # for the TAP echo. Its functional ARP and ping checks need a NIC.
  # Only the benchmark echo can produce net_rtt and net_tx.
  if [ "$keep" != all ] && [ "$net_ok" = no ]; then margs+=(--net user); fi
  # $SILICA_BENCH_MACHINE: further qemu.sh arguments, the same for every boot.
  "$TOOLS/qemu.sh" --image "$img" --serial "$ser" --stamp "$st" --timeout "${SILICA_BENCH_TIMEOUT:-300}" \
    --smp "$SMP" --mem "$MEM" ${pin:+--pin "$pin"} ${pin:+${emu:+--emulator "$emu"}} --disk-props "$disk_props" "${margs[@]+"${margs[@]}"}" "${netargs[@]+"${netargs[@]}"}" ${SILICA_BENCH_MACHINE:-} >"$qlog" 2>&1
  rc=$?
  if [ $rc = 2 ]; then err "$sys: qemu.sh setup error: $(head -c 200 "$qlog" | tr '\n' ' ')"; quit 2; fi
  if ! serial_has "$ser" -x 'BENCH DONE'; then
    echo "ERROR: bench::$sys: run $i did not finish (qemu.sh exit $rc, no BENCH DONE; serial $ser)"
    quit 1
  fi
  tr -d '\r' <"$ser" | awk -v k="$keep" '$1 == "BENCH" && NF == 4 && $3 ~ /^[0-9]+([.][0-9]+)?$/ {
      if (k != "all" && $2 !~ /^(blk|net)_/) next
      print (k == "confined" ? $2 "_confined" : $2), $3, $4 }' >>"$RUN/$vals.values"
  [ "$keep" = all ] || return 0
  # Boot time, by the host's clock: from the firmware starting the boot
  # option (the operating system's loader) to the first line from userspace.
  # The firmware before that is the same code for both systems and moves by
  # tens of milliseconds from boot to boot, more than the operating system's
  # own boot takes; it is printed for context, not gated.
  t0=$(tr -d '\r' <"$st" | awk '/BdsDxe: starting/ { print $1; exit }')
  tq=$(awk '$2 == "QEMU" && $3 == "START" { print $1; exit }' "$st")
  t1=$(tr -d '\r' <"$st" | awk '$2 == "BENCH" && $3 == "MARK" { print $1; exit }')
  [ -n "$t0" ] && [ -n "$t1" ] && awk -v a="$t0" -v b="$t1" 'BEGIN { printf "boot_userspace %.3f ms\n", (b - a) * 1000 }' >>"$RUN/$vals.values"
  [ -n "$tq" ] && [ -n "$t0" ] && awk -v a="$tq" -v b="$t0" 'BEGIN { printf "firmware %.3f ms\n", (b - a) * 1000 }' >>"$RUN/$vals.values"
}
# boot_server <system> <image> <run> <values>: one boot of a server image
# (Silica's system image with httpd, or the Linux baseline's server:
# build_linux server) on a tap of its own, measured from the host by
# host-tools' tcpbench, the same for both (spec/TESTING.md 4.2, M4):
# boot_server, the first HTTP answer from the firmware starting the boot
# option (as boot_userspace is taken); http_p50 and http_p99, 64 kept-alive
# connections asking 1 KiB at 5,000 a second for 10 s, open loop; tcp_cpu_gb,
# the guest's processors per GiB read at a fixed 200 MB/s, KVM's halt polling
# off meanwhile so that only the guest's own time is counted. The host's end
# runs on a processor of its own ($srv_cpu).
srvtap=silica-srv0 srvhost=10.214.15.1 srvguest=10.214.15.2
srv_cpu=$(fastest_cpus "$((SMP + 2))" | tr , '\n' | grep -vxF -f <(printf '%s\n' $pins "$echo_cpu") | head -n 1)
boot_server() {
  local sys=$1 img=$2 i=$3 vals=$4 ser=$RUN/$1.$3.serial st=$RUN/$1.$3.stamp qlog=$LOGS/bench/$1.$3.log q qpid out t0 poll
  if ! ip link show "$srvtap" >/dev/null 2>&1; then
    sudo -n ip tuntap add dev "$srvtap" mode tap user "$(id -un)" && sudo -n ip addr add "$srvhost/24" dev "$srvtap" \
      && sudo -n sysctl -q -w "net.ipv6.conf.$srvtap.disable_ipv6=1" || { err "cannot make the server benchmarks' tap $srvtap"; quit 2; }
  fi
  sudo -n ip link set "$srvtap" up
  "$TOOLS/qemu.sh" --image "$img" --serial "$ser" --stamp "$st" --timeout "${SILICA_BENCH_TIMEOUT:-300}" \
    --smp "$SMP" --mem "$MEM" ${pin:+--pin "$pin"} ${pin:+${emu:+--emulator "$emu"}} --disk-props "$disk_props" \
    --net "tap:$srvtap" ${SILICA_BENCH_MACHINE:-} >"$qlog" 2>&1 &
  q=$!
  tb() { ${srv_cpu:+taskset -c "$srv_cpu"} "$tcpbench" "$srvguest:80" "$@"; }
  fail_run() { kill "$q" 2>/dev/null; wait "$q" 2>/dev/null; echo "ERROR: bench::$sys: run $i: $1 (serial $ser)"; quit 1; }
  out=$(tb ready 60) || fail_run "no first answer: $out"
  t0=$(tr -d '\r' <"$st" | awk '/BdsDxe: starting/ { print $1; exit }')
  [ -n "$t0" ] && awk -v a="$t0" -v b="${out#ready }" 'BEGIN { printf "boot_server %.3f ms\n", (b - a) * 1000 }' >>"$RUN/$vals.values"
  qpid=$(pgrep -f "qemu-system-x86_64.*$srvtap" | head -n 1)
  out=$(tb http 64 5000 10) || fail_run "$(grep -m1 ERROR <<<"$out")"
  awk '$1 == "BENCH" { print $2, $3, $4 }' <<<"$out" >>"$RUN/$vals.values"
  poll=$(cat /sys/module/kvm/parameters/halt_poll_ns)
  echo 0 | sudo -n tee /sys/module/kvm/parameters/halt_poll_ns >/dev/null
  out=$(tb bulk 1024 200 "$qpid"); rc=$?
  echo "$poll" | sudo -n tee /sys/module/kvm/parameters/halt_poll_ns >/dev/null
  [ $rc = 0 ] || fail_run "$(grep -m1 ERROR <<<"$out")"
  awk '$1 == "BENCH" { print $2, $3, $4 }' <<<"$out" >>"$RUN/$vals.values"
  # Asked to end: its answer, then the machine turns off.
  { exec 3<>"/dev/tcp/$srvguest/80" && printf 'GET /quit HTTP/1.1\r\nHost: guest\r\n\r\n' >&3 && timeout 5 cat <&3 >/dev/null; exec 3>&-; } 2>/dev/null
  wait "$q"
}
# Kernel instructions per operation of the fixed paths (spec/TESTING.md
# 4.1), counted under TCG with icount by tools/profile.sh: a boot running
# the benchmark twice minus one running it once is exactly one benchmark.
# A boot's count moves by up to 4,000 instructions with the other
# processor's timing (measured over repeated boots), under 0.5 per
# operation over the 8,192 or more operations of the difference, so a
# tolerance of one instruction per operation is added in the ratchet check.
# The count is a property of the kernel's source and has no noise worth a
# second sample: one line per count, kept until the kernel changes. The
# images are assembled from one build and the eight boots run at once
# (emulated, one host processor each: nothing here is a timing).
# $SILICA_BENCH_COUNTS names a file of ready "insns_<metric> <n> insns"
# lines instead (the tool's own test).
# The second boot of a pair runs the benchmark `more` times more than the
# first: a benchmark of few operations (2048 page faults) takes four more,
# so that what the boot itself varies by is spread over as many operations
# as the others have.
COUNT_SPECS=("null null_syscall 22000 1" "ipc ipc_roundtrip 22000 1" "ctx ctx_switch 44000 1" "notify notify_roundtrip 22000 1" "fault page_fault 2048 16")
# count_start <label>: builds the counting images of the kernel selected now
# (the working tree, or SRC[kernel] and SILICA_TUNE_*: a variant) and starts
# their boots, as many at once as the host has processors; `wait`, then
# count_finish <label> <values file>.
count_start() {
  local label=$1 spec b name per more n img
  [ -z "${SILICA_BENCH_COUNTS:-}" ] || return 0
  for spec in "${COUNT_SPECS[@]}"; do
    read -r b name per more <<<"$spec"
    for n in 1 $((1 + more)); do
      img=$(PIECES_ONCE=1 PIECES_DIR=$RUN/v.$label UNIT_DIR=$RUN/count.$label.$b.$n build_image x86_64 "$LOGS/bench/count.$label.$b.$n.build.log" "bench=$b:$n") ||
        { err "cannot build the counting image of $label (log: $LOGS/bench/count.$label.$b.$n.build.log)"; quit 2; }
      while [ "$(jobs -rp | wc -l)" -ge "$(nproc)" ]; do wait -n 2>/dev/null || break; done
      "$TOOLS/profile.sh" --count --bench "$b" --times "$n" --image "$img" --out "$RUN/count.$label.$b.$n" >"$RUN/count.$label.$b.$n.out" 2>&1 &
    done
  done
}
count_finish() {
  local label=$1 to=$2 spec b name per more one two n failed=0
  : >"$to"
  for spec in "${COUNT_SPECS[@]}"; do
    read -r b name per more <<<"$spec"
    if [ -n "${SILICA_BENCH_COUNTS:-}" ]; then
      if ! awk -v key="insns_$name" '$1 == key && $2 ~ /^[0-9]+([.][0-9]+)?$/ && $3 == "insns" { print; found++ } END { exit found != 1 }' "$SILICA_BENCH_COUNTS" >>"$to"; then
        err "missing or invalid insns_$name for $label"; failed=1
      fi
      continue
    fi
    one=$(awk '$1 == "COUNT" { print $2 }' "$RUN/count.$label.$b.1.out" 2>/dev/null)
    two=$(awk '$1 == "COUNT" { print $2 }' "$RUN/count.$label.$b.$((1 + more)).out" 2>/dev/null)
    if [ -z "$one" ] || [ -z "$two" ]; then
      for n in 1 $((1 + more)); do cp "$RUN/count.$label.$b.$n.out" "$LOGS/bench/count.$label.$b.$n.log"; done
      err "no insns_$name for $label (logs $LOGS/bench/count.$label.$b.*.log)"; failed=1; continue
    fi
    awk -v a="$one" -v b="$two" -v p="$((per * more))" -v n="$name" 'BEGIN { printf "insns_%s %.1f insns\n", n, (b - a) / p }' >>"$to"
  done
  return "$failed"
}
LIB=(path:os:tools/lib/common.sh path:os:tools/lib/build.sh)
# What a count is a function of: the kernel's source (and a constant it was
# built with), the image, and the tools that count.
# (COUNT_SPECS by its text: the functions' text does not hold the variable's.)
IN_COUNTS=(repo+:kernel crate:os:silica-image "${LIB[@]}" path:os:tools/profile.sh path:os:tools/profile host:qemu-x86_64 fn:count_start fn:count_finish
  "specs:$(IFS='|'; echo "${COUNT_SPECS[*]}" | tr ' ' _)" "file:${SILICA_BENCH_COUNTS:-}")

# ---- what to measure: what its inputs changed for -----------------------------
# Four parts, each kept under its inputs: the Linux baseline, Silica's
# kernel paths, Silica's devices, the instruction counts. What a timing was
# taken on (the host, its policy, the virtual machine, the function that
# boots it) is one of its inputs.
if [ -z "$compare$sweep" ]; then
  stubbed=${SILICA_BENCH_IMG:+1}
  need_kernel=0 need_io=0 need_counts=0 need_server=0
  while read -r name _; do
    wanted "$name" || continue
    eval "need_$(group_of "$name")=1"
  done <<<"$METRICS"
  [ -z "$stubbed" ] || { need_io=0; need_server=0; }   # the tool's own test has no system image
  [ $((need_kernel + need_io + need_counts + need_server)) -gt 0 ] || die "--only $only names no metric"
  # The build-time constants set in the environment (SILICA_TUNE_*) are an
  # input of every group: a tuned kernel's results once stood in, read
  # back, for the untuned kernel's (2026-11-24).
  MACHINE=("${LIB[@]}" path:os:tools/qemu.sh host:qemu-x86_64 host:cpu fn:boot env:SILICA_BENCH_MACHINE
    "machine:accel=$accel smp=$SMP mem=$MEM pin=$pin tuned=$tuned net=$net_ok"
    "tune:$(env | grep '^SILICA_TUNE_' | sort | paste -sd, -)")
  IN_KERNEL=(repo+:kernel crate:os:silica-image "${MACHINE[@]}" "runs:$runs" "file:${SILICA_BENCH_IMG:-}")
  IN_IO=(repo+:system repo+:kernel path:os:bench/net crate:os:silica-image "${MACHINE[@]}" "runs:$runs")
  do_linux=0 do_kernel=0 do_io=0 do_counts=0 do_server=0
  # The baseline image is built for the owner's --linux alone.
  do_linux=$relinux
  kept bench.kernel "${IN_KERNEL[@]}" || do_kernel=$need_kernel; f_kernel=$EV_FILE k_kernel=$EV_KEY t_kernel=$EV_TEXT
  kept bench.io "${IN_IO[@]}" || do_io=$need_io; f_io=$EV_FILE k_io=$EV_KEY t_io=$EV_TEXT
  IN_SERVER=(repo+:system repo+:kernel crate:os:silica-image crate:os:silica-host fn:boot_server "${MACHINE[@]}" "runs:$runs")
  kept bench.server "${IN_SERVER[@]}" || do_server=$need_server; f_server=$EV_FILE k_server=$EV_KEY t_server=$EV_TEXT
  kept bench.counts "${IN_COUNTS[@]}" tune: || do_counts=$need_counts; f_counts=$EV_FILE k_counts=$EV_KEY t_counts=$EV_TEXT

  silica="" silica_sys="" linux=""
  if [ $do_kernel = 1 ]; then
    log=$LOGS/bench/build.silica.log
    # $SILICA_BENCH_IMG names a ready-made Silica image (used by the tool's own test).
    silica=${SILICA_BENCH_IMG:-$(build_image x86_64 "$log" bench)} && [ -f "$silica" ] || { err "cannot build the Silica benchmark image (log: $log)"; quit 2; }
  fi
  if [ $do_io = 1 ]; then
    # The device benchmarks run in the system image: the device manager, the
    # drivers confined by the IOMMU, and blkcheck and netcheck as the clients.
    log=$LOGS/bench/build.silica-system.log
    silica_sys=$(build_system_image x86_64 "$log" "checks=spawn,block,net off=netd bench") && [ -f "$silica_sys" ] || { err "cannot build the Silica system image (log: $log)"; quit 2; }
  fi
  if [ $do_server = 1 ] || { [ $do_linux = 1 ] && [ $need_server = 1 ]; }; then
    # The server benchmarks: httpd on the stack at the address the Linux
    # baseline's server takes, and the host's end.
    log=$LOGS/bench/build.silica-server.log
    silica_srv=$(build_system_image x86_64 "$log" "checks=http httpd.quit=allowed netd.address=$srvguest/24 netd.router=$srvhost") && [ -f "$silica_srv" ] \
      || { err "cannot build the Silica server image (log: $log)"; quit 2; }
    tcpbench=$(host_tool tcpbench "$log") || { err "cannot build tcpbench (log: $log)"; quit 2; }
  fi
  if [ $do_linux = 1 ] && [ $need_server = 1 ]; then
    log=$LOGS/bench/build.linux-server.log
    linux_srv=$(build_linux "$log" server) || { err "cannot build the Linux server image (log: $log)"; quit 2; }
  fi
  if [ $do_linux = 1 ]; then
    log=$LOGS/bench/build.linux.log
    linux=$(build_linux "$log"); rc=$?
    if [ $rc = 3 ]; then
      echo "ERROR: bench::baseline: Linux baseline unavailable: $(tail -n 1 "$log") (log: $log)"
      echo "RESULT: pass=0 fail=1 skipped=0 time=$((SECONDS - start))"; exit 3
    elif [ $rc != 0 ]; then
      err "cannot build the Linux baseline image: $(grep -m1 -iE 'error' "$log" | cut -c1-160) (log: $log)"; quit 2
    fi
  fi
  # The counts first: they are not timings, and use every processor.
  [ $do_counts = 0 ] || { count_start silica; wait; count_finish silica "$RUN/counts.values" || quit 1; keep bench.counts "$k_counts" "$t_counts" "$RUN/counts.values"; }
  if [ $((do_kernel + do_io + do_linux + do_server)) -gt 0 ]; then
    hold_host
    [ -n "$stubbed" ] || net_up || echo "bench: no network benchmarks (the tap and the host's echo need passwordless sudo and a spare processor)"
    watch_start
    # Alternately, Silica first: what the host does meanwhile falls on both.
    for ((i = 1; i <= runs; i++)); do
      [ $do_kernel = 0 ] || boot silica "$silica" "$i" kernel
      if [ $do_io = 1 ]; then
        boot silica-system "$silica_sys" "$i" io plain blk
        boot silica-system-confined "$silica_sys" "$i" io iommu confined
      fi
      [ $do_server = 0 ] || boot_server silica-server "$silica_srv" "$i" server
      if [ $do_linux = 1 ]; then
        [ -n "$stubbed" ] || boot linux-confined "$linux" "$i" linuxnow iommu confined
        boot linux "$linux" "$i" linuxnow plain
        [ -z "${linux_srv:-}" ] || boot_server linux-server "$linux_srv" "$i" linuxnow
      fi
    done
    watch_end
    echo "bench: other programs kept $host_other of the host's processors busy during the timed boots"
    for part in kernel io server; do [ ! -s "$RUN/$part.values" ] || echo "host_other $host_other cpus" >>"$RUN/$part.values"; done
    [ $do_kernel = 0 ] || keep bench.kernel "$k_kernel" "$t_kernel" "$RUN/kernel.values"
    [ $do_io = 0 ] || keep bench.io "$k_io" "$t_io" "$RUN/io.values"
    [ $do_server = 0 ] || keep bench.server "$k_server" "$t_server" "$RUN/server.values"
  fi
  # What was not measured is read back; the run says which, and from when.
  : >"$RUN/silica.values"; note=""
  for part in kernel io counts server; do
    eval "f=\$f_$part do=\$do_$part need=\$need_$part"
    [ "$need" = 1 ] || continue
    [ "$do" = 1 ] || { [ -f "$f" ] && grep -v '^#' "$f" >"$RUN/$part.values" && note="$note $part ($(kept_at "$f"))"; }
    cat "$RUN/$part.values" >>"$RUN/silica.values" 2>/dev/null
  done
  [ -z "$note" ] || echo "bench: not measured again, their inputs being what they were when measured -$note"
fi

# stat <system> <metric>: "<median> <mad>" over the runs, empty when never reported.
stat() {
  awk -v m="$2" '$1 == m { print $2 }' "$RUN/$1.values" | sort -g | awk '
    { v[NR] = $1 }
    END { if (!NR) exit; med = (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2
      for (i = 1; i <= NR; i++) { d[i] = v[i] - med; if (d[i] < 0) d[i] = -d[i] }
      n = asort(d); mad = (n % 2) ? d[(n + 1) / 2] : (d[n / 2] + d[n / 2 + 1]) / 2
      print med, mad }'
}
# ---- variants: the same benchmarks on several kernels, side by side -----------
# --compare <kernel>[,<kernel>...]: each a commit of the kernel repository,
# a range of commits (a..b: every commit of it, oldest first) or a
# directory holding a kernel checkout (another worktree: another design),
# and after them the working tree ("new"). --sweep NAME=v1,v2,...: the
# working tree built once per value of the build-time constant
# SILICA_TUNE_<NAME> (kernel_core::tuned). An instrument: nothing is gated.
# The devices' metrics (blk_*, net_* and their *_confined) come from each
# variant's kernel under the same system image, booted on the machine
# without an IOMMU and on the one with, interleaved as the kernel's are.
#
# Two measurements, and how each stays clean with many variants at once:
# - Instruction counts are emulated and exact, so nothing one boot does can
#   reach another: every variant's are taken at the same time, on every
#   processor the host has, and kept per kernel source (a commit counted
#   once is never counted again). Seven kernels cost what one does. This is
#   the first question to ask of a change to a fixed path, and often the
#   last: --only insns asks nothing else and holds no host.
# - Timings share the host's caches and memory with whatever runs beside
#   them, so they are never taken two at a time. The variants' boots are
#   interleaved on the held host, in an order that rotates every round (A B
#   C, then B C A, then C A B), so what the host does meanwhile, and what a
#   boot leaves behind for the next, falls on each variant alike.
# The first column is the reference, each other column shows its change
# from it (--steps: from the column before it, which is how the commit of a
# range that cost something is found). A change is marked "~" when it is
# inside the noise of the runs (three times the two deviations; one
# instruction for a count). --aa measures the reference twice, as a variant
# of its own ("again"): what that column shows as a change is what this
# instrument reports when nothing changed, and a difference between real
# variants no larger than it is not one.
if [ -n "$compare$sweep" ]; then
  labels=() vdirs=() vtunes=() legend=()
  add_variant() { labels+=("$1"); vdirs+=("$2"); vtunes+=("${3:-}"); }
  here=$(checkout_of kernel)
  if [ -n "$compare" ]; then
    slot=0
    for ref in ${compare//,/ }; do
      if [ -d "$ref" ]; then
        d=$(realdir "$ref"); [ -f "$d/Cargo.toml" ] || die "--compare: $ref is not a kernel checkout"
        add_variant "$(basename "$(dirname "$d")")" "$d"; legend+=("${labels[-1]} is the kernel in $d")
        continue
      fi
      case "$ref" in *..*) revs=$(git -C "$here" rev-list --reverse "$ref" 2>/dev/null) || die "--compare: the kernel repository has no range $ref" ;;
        *) revs=$(git -C "$here" rev-parse --verify --quiet "$ref^{commit}") || die "--compare: the kernel repository has no commit $ref" ;; esac
      for rev in $revs; do
        slot=$((slot + 1)); d=$OUTBASE/bench-variants/$slot/kernel
        if [ -d "$d" ]; then git -C "$d" checkout -q --detach "$rev"
        else mkdir -p "$(dirname "$d")" && git -C "$here" worktree add -q --detach "$d" "$rev"; fi || die "--compare: cannot check out $rev in $d"
        add_variant "${rev:0:7}" "$d"; legend+=("$(git -C "$here" log -1 --format='%h %s' "$rev" | cut -c1-110)")
      done
    done
    add_variant new ""; legend+=("new is the working tree")
  else
    for v in $(echo "${sweep#*=}" | tr , ' '); do add_variant "${sweep%%=*}-$v" "" "${sweep%%=*}=$v"; done
  fi
  [ $aa = 0 ] || { add_variant again "${vdirs[0]}" "${vtunes[0]}"; legend+=("again is ${labels[0]} measured a second time (what the instrument shows when nothing changed)"); }
  # select <n>: the kernel of variant n becomes the one the build functions
  # and the evidence keys see; deselect puts the working tree back.
  tree_here=${TREE[kernel]:-} objects_here=${EV_OBJECTS[kernel]:-}
  select_variant() {
    deselect_variant
    if [ -n "${vdirs[$1]}" ]; then
      SRC[kernel]=${vdirs[$1]}
      EV_OBJECTS[kernel]=$(git -C "${vdirs[$1]}" rev-parse --path-format=absolute --git-path objects)
      TREE[kernel]=$(tree_now kernel)
    fi
    [ -z "${vtunes[$1]}" ] || export "SILICA_TUNE_${vtunes[$1]}"
  }
  deselect_variant() {
    local n
    unset 'SRC[kernel]' 'EV_MEMO[repo+:kernel]' 'EV_MEMO[repo:kernel]'; EV_KEYS=()
    TREE[kernel]=$tree_here; EV_OBJECTS[kernel]=$objects_here
    for n in "${vtunes[@]}"; do [ -z "$n" ] || unset "SILICA_TUNE_${n%%=*}"; done
  }
  want_counts=0 want_timings=0 want_io=0
  while read -r name _; do
    wanted "$name" || continue
    case "$name" in insns_*) want_counts=1 ;; blk_*|net_*) want_io=1 ;; *) want_timings=1 ;; esac
  done <<<"$METRICS"
  [ $((want_counts + want_timings + want_io)) -gt 0 ] || die "--only $only names no metric to measure"
  # The counts: every variant not counted before, all at once.
  if [ $want_counts = 1 ]; then
    counting=() ckey=() ctext=()
    declare -A first_with=()   # two variants of one source (a commit, and the working tree at it) are counted once
    for n in "${!labels[@]}"; do
      v=${labels[$n]}; select_variant "$n"
      if kept bench.counts "${IN_COUNTS[@]}" "tune:${vtunes[$n]}"; then grep -v '^#' "$EV_FILE" >"$RUN/$v.values"
      elif [ -n "${first_with[$EV_KEY]:-}" ] && [ "$v" != again ]; then ckey[$n]="same as ${first_with[$EV_KEY]}"
      else counting+=("$n"); ckey[$n]=$EV_KEY; ctext[$n]=$EV_TEXT; first_with[$EV_KEY]=$v; count_start "$v"; fi
    done
    deselect_variant
    wait
    for n in "${counting[@]+"${counting[@]}"}"; do
      v=${labels[$n]}
      count_finish "$v" "$RUN/$v.values" || quit 1
      keep bench.counts "${ckey[$n]}" "${ctext[$n]}" "$RUN/$v.values"
    done
    for n in "${!labels[@]}"; do
      case "${ckey[$n]:-}" in "same as "*) cp "$RUN/${ckey[$n]#same as }.values" "$RUN/${labels[$n]}.values" ;; esac
    done
    echo "bench: instruction counts of ${#labels[@]} kernels, ${#counting[@]} counted now and the rest kept from when they were"
  fi
  # The timings: built side by side (a constant's values one after another:
  # they share a build directory), booted one at a time.
  if [ $want_timings = 1 ]; then
    for n in "${!labels[@]}"; do
      v=${labels[$n]}; select_variant "$n"
      ( img=$(UNIT_DIR=$RUN/v.$v.image build_image x86_64 "$LOGS/bench/build.$v.log" bench) && cp "$img" "$RUN/$v.img" ) &
      [ -n "${vdirs[$n]}" ] || wait
    done
    deselect_variant
    wait
    for v in "${labels[@]}"; do [ -f "$RUN/$v.img" ] || { err "cannot build the variant $v (log: $LOGS/bench/build.$v.log)"; exit 2; }; done
    hold_host
    [ $tuned = no ] && echo "bench: host not held still, so differences of a few percent mean nothing"
    for ((i = 1; i <= runs; i++)); do
      for ((j = 0; j < ${#labels[@]}; j++)); do v=${labels[$(((i - 1 + j) % ${#labels[@]}))]}; boot "$v" "$RUN/$v.img" "$i"; done
    done
  fi
  # The devices' metrics come from the system image: each variant's kernel
  # under the same system, booted on the machine without an IOMMU and on
  # the one with (blk_*, and *_confined), as the main run boots them.
  if [ $want_io = 1 ]; then
    for n in "${!labels[@]}"; do
      v=${labels[$n]}; select_variant "$n"
      ( img=$(UNIT_DIR=$RUN/v.$v.system build_system_image x86_64 "$LOGS/bench/build.$v.system.log" "checks=block,net off=netd bench") && cp "$img" "$RUN/$v.system.img" ) &
      [ -n "${vdirs[$n]}" ] || wait
    done
    deselect_variant
    wait
    for v in "${labels[@]}"; do [ -f "$RUN/$v.system.img" ] || { err "cannot build the system image of $v (log: $LOGS/bench/build.$v.system.log)"; exit 2; }; done
    hold_host
    [ $tuned = no ] && echo "bench: host not held still, so differences of a few percent mean nothing"
    [ -n "${SILICA_BENCH_IMG:-}" ] || net_up || echo "bench: no network benchmarks (the tap and the host's echo need passwordless sudo and a spare processor)"
    for ((i = 1; i <= runs; i++)); do
      for ((j = 0; j < ${#labels[@]}; j++)); do
        v=${labels[$(((i - 1 + j) % ${#labels[@]}))]}
        boot "$v-system" "$RUN/$v.system.img" "$i" "$v" plain blk
        boot "$v-confined" "$RUN/$v.system.img" "$i" "$v" iommu confined
      done
    done
  fi
  for l in "${legend[@]}"; do echo "bench: $l"; done
  printf '%-22s %-6s' metric unit; for v in "${labels[@]}"; do printf ' %24s' "$v"; done; echo
  while read -r name unit better _; do
    wanted "$name" || continue
    line=$(printf '%-22s %-6s' "$name" "$unit") first="" fmad="" any=0
    for v in "${labels[@]}"; do
      read -r m mad <<<"$(stat "$v" "$name")"
      if [ -z "${m:-}" ]; then cell=-
      elif [ -z "$first" ]; then first=$m fmad=$mad any=1; cell=$(fmt "$m")
      else
        any=1
        cell=$(awk -v m="$m" -v d="$mad" -v f="$first" -v fd="$fmad" -v b="$better" -v u="$unit" 'BEGIN {
          c = (f != 0) ? (m - f) / f * 100 : 0; diff = m - f; if (diff < 0) diff = -diff
          tag = (diff <= 3 * (d + fd) + (u == "insns" ? 1 : 0)) ? "~" : (((b == "lower") == (m < f)) ? "better" : "worse")
          printf "%.5g (%+.1f%% %s)", m, c, tag }')
        [ $steps = 0 ] || { first=$m fmad=$mad; }
      fi
      line+=$(printf ' %24s' "$cell")
    done
    [ $any = 1 ] && echo "$line"
  done <<<"$METRICS"
  echo "RESULT: pass=1 fail=0 skipped=0 time=$((SECONDS - start))"
  exit 0
fi

ratchet_row() { [ -f "$RATCHET" ] && awk -F'\t' -v m="$1" '$1 == m { print; exit }' "$RATCHET"; }
# The host a value was measured on: its processor model ($SILICA_BENCH_HOST
# overrides, for the tool's own test).
host=${SILICA_BENCH_HOST:-$(LC_ALL=C lscpu 2>/dev/null | sed -n 's/^Model name: *//p' | head -n 1 | tr -s ' ' '_')}
host=${host:-unknown}
# Values measured with the host held still do not compare with values from
# the same machine left to its own frequency policy: a different host.
[ "$tuned" = yes ] && host=$host+tuned
# Linux: the locked numbers for this host (bench/reference.tsv; "-" there
# is any host: the tool's own test). No line for this host, no comparison.
[ -f "$REFERENCE" ] && awk -F'\t' -v h="$host" '$1 !~ /^#/ && NF >= 4 && ($4 == h || $4 == "-") { print $1, $2, $3 }' "$REFERENCE" >"$RUN/linux.values"
[ -f "$RUN/linux.values" ] || : >"$RUN/linux.values"
if [ $relinux = 1 ] && [ -s "$RUN/linuxnow.values" ]; then
  # Asked for: what Linux measures now, beside what is locked. Nothing is judged by it.
  while read -r name unit _; do
    read -r ln _ <<<"$(stat linuxnow "$name")"; read -r ll _ <<<"$(stat linux "$name")"
    [ -n "${ln:-}" ] && [ -n "${ll:-}" ] && awk -v n="$name" -v a="$ln" -v b="$ll" -v u="$unit" 'BEGIN { printf "bench: Linux now, %s %.5g %s against %.5g locked (%+.1f%%)\n", n, a, u, b, (a - b) / b * 100 }'
  done <<<"$METRICS"
fi

# open_row <metric> <linux|ratchet>: "<bound> <host>" of an open gap, if there is one.
open_row() { [ -f "$OPEN" ] && awk -F'\t' -v m="$1" -v k="$2" '$1 == m && $2 == k { print $3, $4; exit }' "$OPEN"; }
# A milestone is not declared over an open gap of a metric due by then.
declaring() { [ -n "${SILICA_MILESTONE:-}" ] && [ "$ms" -ge "$1" ]; }
declare -A open_now=() judged=()
opened() { # opened <metric> <kind> <now> <bound> <message>: a known gap, no worse than recorded
  echo "OPEN: bench: $1: $5 (open gap, bench/open.tsv: recorded at $(fmt "$4"))"
  open_now[$1,$2]=$3; skipped=$((skipped + 1)); openlist="$openlist $1"
}

behind="" tied="" openlist="" results=() newratchet=$RUN/ratchet.tsv
printf '# Best result per metric (tools/bench.sh --update-ratchet). vs-linux: ours/linux for\n# lower-is-better metrics, linux/ours otherwise, then the best value and the host it\n# was measured on; value: the metric itself.\n' >"$newratchet"
while read -r name unit better gate limit from repeat; do
  # A metric this run does not judge keeps the ratchet it has.
  wanted "$name" || { ratchet_row "$name" >>"$newratchet"; continue; }
  read -r o omad <<<"$(stat silica "$name")"
  read -r l lmad <<<"$(stat linux "$name")"
  if [ -z "${o:-}" ]; then ratchet_row "$name" >>"$newratchet"; enforce "$name" "$from" "Silica reported no value"; continue; fi
  judged[$name]=1
  ratio="" rnoise=0
  if [ -n "${l:-}" ]; then
    ratio=$(awk -v o="$o" -v l="$l" -v b="$better" 'BEGIN { if (b == "lower") { if (l > 0) print o / l } else if (o > 0) print l / o }')
    [ -z "$ratio" ] || rnoise=$(awk -v r="$ratio" -v o="$o" -v m="$omad" -v l="$l" -v n="${lmad:-0}" 'BEGIN { print 3 * r * (m / o + n / l) }')
  fi
  desc="silica $(fmt "$o") $unit (noise $(fmt "$omad"))"
  [ -n "${l:-}" ] && desc="$desc, linux $(fmt "$l") $unit${ratio:+, ratio $(fmt "$ratio")}"
  # The target: MARGIN percent better than Linux, or the metric's own limit
  # where that is stricter.
  case "$gate" in win|le) limit=$(awk -v x="$limit" -v m="$MARGIN" 'BEGIN { t = 1 - m / 100; print (x < t ? x : t) }') ;; esac
  results+=("$(jq -cn --arg n "$name" --arg u "$unit" --argjson o "$o" --argjson mad "$omad" --arg l "${l:-}" --arg r "$ratio" \
    '{key: $n, value: {unit: $u, silica: $o, noise: $mad, linux: (if $l == "" then null else ($l | tonumber) end), ratio: (if $r == "" then null else ($r | tonumber) end)}}')")
  # A scaling factor (unit x) compares a system with itself, not with the
  # other: its own gate judges it, and the throughputs it is made of are
  # compared with Linux directly. Behind Linux is behind its locked number
  # by more than the noise of Silica's runs; closer than that, tied with it.
  if [ -n "$ratio" ] && [ "$unit" != x ] && awk -v r="$ratio" 'BEGIN { exit !(r > 1) }'; then
    if awk -v r="$ratio" -v e="$rnoise" 'BEGIN { exit !(r > 1 + e) }'; then behind="$behind $name ($(fmt "$ratio")x)"
    else tied="$tied $name ($(fmt "$ratio")x)"; fi
  fi
  good=1
  case "$gate" in
    win|le)
      # "At or better" (le) is judged to the noise of the runs: a ratio the
      # runs cannot tell from the limit is at it. "Better" (win) is not.
      if [ -z "$ratio" ]; then enforce "$name" "$from" "no Linux value is locked for this host ($host) in bench/reference.tsv ($desc)"; good=0
      elif awk -v r="$ratio" -v x="$limit" -v g="$gate" -v e="$rnoise" 'BEGIN { exit !((g == "win") ? (r < x) : (r <= x + e)) }'; then :
      else
        good=0; why="$desc, gate: ratio $([ $gate = win ] && echo '<' || echo '<=') $limit"
        read -r obound _ <<<"$(open_row "$name" linux)"
        if [ -n "${obound:-}" ] && ! declaring "$from" && awk -v r="$ratio" -v b="$obound" -v e="$rnoise" 'BEGIN { f = b / 100; exit !(r <= b + (e > f ? e : f)) }'; then
          gated "$name" && opened "$name" linux "$ratio" "$obound" "$why" || miss "$name" "$why"
        else miss "$name" "$why${obound:+ (an open gap recorded at $(fmt "$obound"): now worse, or a milestone is being declared)}"; fi
      fi ;;
    min) awk -v o="$o" -v x="$limit" 'BEGIN { exit !(o >= x) }' || { miss "$name" "$desc, gate: at least $limit"; good=0; } ;;
    max) awk -v o="$o" -v x="$limit" 'BEGIN { exit !(o <= x) }' || { miss "$name" "$desc, gate: at most $limit"; good=0; } ;;
  esac
  # The ratchet. It exists to catch Silica getting slower. On the host that
  # set it, Silica's own value is the measure: it repeats from session to
  # session within about 1%, while Linux's, and so the ratio, moves by up to
  # 5% (ipc_pairs1 Linux 804k to 847k round trips/s across sessions on the
  # reference host): a ratchet on the best ratio ever seen would keep the
  # luckiest Linux session and fail later ones at random. On another host,
  # where values do not compare, the ratio to Linux does.
  # A metric with a Linux value keeps both: "<best ratio> vs-linux <best
  # value> <host>". A timing allows at least 1% of its best either way; an
  # instruction count allows one instruction.
  IFS=$'\t' read -r _ rbest rkind vbest vhost <<<"$(ratchet_row "$name")"
  floor() { awk -v e="$1" -v b="$2" -v u="$unit" -v p="${repeat:-1}" 'BEGIN { f = (u == "insns") ? 0 : b * p / 100; if (f < 0) f = -f; print (e > f ? e : f) }'; }
  # (An instruction count is the difference of two boots divided by the
  # operations of one benchmark; the boots differ by a few hundred
  # instructions of interrupt timing, which is under 0.1 per operation over
  # 22,000 operations and about 1 over the page fault's 2,048: one kernel
  # read 2764, 2765 and 2766 there. So that count allows 2.)
  vnoise=$(awk -v m="$omad" -v u="$unit" -v n="$name" 'BEGIN { print 3 * m + (u == "insns" ? 1 : 0) }')
  vworse=$([ "$better" = lower ] && echo higher || echo lower)
  worse_than() { awk -v n="$1" -v b="$2" -v e="$3" -v w="$4" 'BEGIN { exit !((w == "higher") ? (n > b + e) : (n < b - e)) }'; }
  better_than() { awk -v n="$1" -v b="$2" -v w="$3" 'BEGIN { exit !((w == "higher") ? (n < b) : (n > b)) }'; }
  # regressed <now> <best> <noise> <worse direction> <message>: a result worse
  # than its ratchet: an open gap while no worse than its recorded bound
  # (on the host that recorded it; "-" is any host: a count), else a miss.
  regressed() {
    local obound ohost
    read -r obound ohost <<<"$(open_row "$name" ratchet)"
    if [ -n "${obound:-}" ] && { [ "$ohost" = - ] || [ "$ohost" = "$host" ]; } && ! declaring "$from" && gated "$name" && ! worse_than "$1" "$obound" "$(floor "$3" "$obound")" "$4"; then
      opened "$name" ratchet "$1" "$obound" "$5"
    else miss "$name" "$5${obound:+ (an open gap recorded at $(fmt "$obound"): now worse, on another host, or a milestone is being declared)}"; fi
  }
  if [ -n "$ratio" ] && [ "$unit" != x ]; then
    rkeep=${rbest:-$ratio} vkeep=$o
    if [ -n "$vbest" ] && [ "$vhost" = "$host" ]; then
      e=$(floor "$vnoise" "$vbest"); vkeep=$vbest
      if worse_than "$o" "$vbest" "$e" "$vworse"; then
        [ $good = 0 ] || regressed "$o" "$vbest" "$vnoise" "$vworse" "regression: silica $(fmt "$o") $unit against its best $(fmt "$vbest") $unit on this host (noise $(fmt "$e")); $desc"; good=0
      elif better_than "$o" "$vbest" "$vworse"; then vkeep=$o; desc="$desc; better than its best $(fmt "$vbest") on this host"; fi
    elif [ -n "$rbest" ]; then
      e=$(floor "$rnoise" "$rbest")
      if worse_than "$ratio" "$rbest" "$e" higher; then
        [ $good = 0 ] || miss "$name" "regression: vs-linux $(fmt "$ratio") against the ratchet $(fmt "$rbest") (noise $(fmt "$e")); $desc"; good=0
      fi
    fi
    better_than "$ratio" "$rkeep" higher && rkeep=$ratio
    printf '%s\t%s\tvs-linux\t%s\t%s\n' "$name" "$rkeep" "$vkeep" "$host" >>"$newratchet"
  else
    keep=${rbest:-$o}
    if [ -n "$rbest" ]; then
      e=$(floor "$vnoise" "$rbest")
      if worse_than "$o" "$rbest" "$e" "$vworse"; then
        [ $good = 0 ] || regressed "$o" "$rbest" "$vnoise" "$vworse" "regression: value $(fmt "$o") against the ratchet $(fmt "$rbest") (noise $(fmt "$e")); $desc"; good=0
      elif better_than "$o" "$rbest" "$vworse"; then keep=$o; desc="$desc; better than the ratchet $(fmt "$rbest")"; fi
    fi
    printf '%s\t%s\tvalue\n' "$name" "$keep" >>"$newratchet"
  fi
  [ $good = 1 ] && ok "$name: $desc"
done <<<"$METRICS"

[ -z "$behind" ] || echo "bench: behind Linux:$behind"
[ -z "$tied" ] || echo "bench: tied with Linux (above its locked number by less than the noise of the runs) -$tied"
[ -z "$openlist" ] || echo "bench: open gaps, no worse than recorded (bench/open.tsv; each is owed a fix or a decision) -$openlist"
med() { awk -v m=firmware '$1 == m { print $2 }' "$1" 2>/dev/null | sort -g | awk '{ v[NR] = $1 } END { if (NR) printf "%.0f", (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2 }'; }
fs=$(med "$RUN/silica.values")
[ -n "$fs" ] && echo "bench: firmware before the boot option (not Silica's, not gated) $fs ms"
if [ $update = 1 ]; then
  # A metric that failed keeps its previous best in the new file, so writing
  # it never loosens anything; it only records what the others improved.
  if [ $accel = kvm ] && [ $tuned != no ]; then
    cp "$newratchet" "$RATCHET" && echo "bench: ratchet updated: $RATCHET"
    # The open gaps: one that was judged and is no longer a miss has
    # closed; one that improved keeps its better bound; never a worse one.
    if [ -f "$OPEN" ]; then
      while IFS= read -r line; do
        IFS=$'\t' read -r m k b h why <<<"$line"
        case "$m" in ''|'#'*) printf '%s\n' "$line"; continue ;; esac
        [ -n "${judged[$m]:-}" ] || { printf '%s\n' "$line"; continue; }
        now=${open_now[$m,$k]:-}
        if [ -z "$now" ] && [ -n "${missed[$m]:-}" ]; then
          # Worse than its bound: still owed, and worse; the line stays as
          # it was (its run said ERROR), with what it says of the cause.
          echo "bench: open gap worse than recorded, kept: $m ($k)" >&2; printf '%s\n' "$line"; continue
        fi
        [ -n "$now" ] || { echo "bench: open gap closed, $m ($k)" >&2; continue; }
        dir=higher; [ "$k" = linux ] || dir=$(awk -v m="$m" '$1 == m { print ($3 == "lower") ? "higher" : "lower" }' <<<"$METRICS")
        better_than "$now" "$b" "$dir" && b=$now
        printf '%s\t%s\t%s\t%s\t%s\n' "$m" "$k" "$b" "$h" "$why"
      done <"$OPEN" >"$RUN/open.tsv" && cp "$RUN/open.tsv" "$OPEN"
    fi
  else echo "bench: ratchet not updated (needs KVM and a host held still: host_tune)"; fi
fi
out=${out:-$LOGS/bench/results.json}
printf '%s\n' "${results[@]+"${results[@]}"}" | jq -s --argjson ms "$ms" --arg accel "$accel" --argjson runs "$runs" --arg pin "$pin" --arg tuned "$tuned" \
  --arg linux "$(linux_field version)" --arg held "${note# }" '{schema: 2, milestone: $ms, accel: $accel, runs: $runs, host_cpus: $pin, host_tuned: $tuned, linux: $linux, not_measured_again: $held, metrics: from_entries}' >"$out" 2>/dev/null ||
  echo "ERROR: bench: cannot write $out"
echo "bench: results in $out"
finish
