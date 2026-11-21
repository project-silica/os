#!/usr/bin/env bash
# Test for tools/bench.sh (spec/TESTING.md section 4).
# Runs a private copy of the tool in a disposable fake workshop whose
# tools/qemu.sh is a stub that "boots" an image by copying a canned serial
# transcript and writing host stamps, so the interleaving, the medians, every
# kind of gate, the milestone rule, the ratchet and the failure reports are
# checked without QEMU or a Linux build. One "ERROR:" line per failed check.
set -uo pipefail
SRC=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd -P)
BASE=${SILICA_RUN:-${TMPDIR:-/tmp}}; mkdir -p "$BASE"
FX=$(mktemp -d "$BASE/benchtest.XXXX") || exit 2
FX=$(cd "$FX" && pwd -P)
trap 'rm -rf "${FX:?}"' EXIT
fails=0
bad() { echo "ERROR: bench-test: $1"; fails=$((fails + 1)); }
command -v jq >/dev/null || { echo "ERROR: bench-test: jq is not installed"; exit 2; }
[ -w /dev/kvm ] || { echo "bench-test: no KVM on this host: gates are not enforced here, nothing to check"; exit 0; }

WS=$FX/ws; OS=$WS/os; SER=$FX/serials
mkdir -p "$OS/tools" "$OS/bench/linux" "$SER"
echo x >"$WS/bootstrap.pins"
cp -r "$SRC/lib" "$SRC/bench.sh" "$OS/tools/"
printf '# fake manifest\n' >"$OS/manifest.toml"
printf 'version=0.0\nurl=file:///nonexistent/linux.tar.xz\nsha256=00\n' >"$OS/bench/linux/VERSION"
: >"$OS/bench/linux/config"; : >"$OS/bench/linux/init.c"; : >"$OS/bench/linux/initramfs.list"
: >"$FX/silica.img"; : >"$FX/linux.img"
cat >"$OS/tools/qemu.sh" <<STUB
#!/usr/bin/env bash
# Stub: the transcript <serials>/<image>.<boot number of that image> (or
# <image>) becomes the serial log; the stamps say userspace came up after
# the number of milliseconds in <serials>/<image>.boot.
img="" ser="" st=""
while [ \$# -gt 0 ]; do
  case "\$1" in --image) img=\$(basename "\$2") ;; --serial) ser=\$2 ;; --stamp) st=\$2 ;; esac
  shift 2
done
n=\$(( \$(cat "$FX/count.\$img" 2>/dev/null || echo 0) + 1 )); echo \$n >"$FX/count.\$img"
echo "\$img" >>"$FX/calls"
f=$SER/\$img; [ -f "\$f.\$n" ] && f=\$f.\$n
cp "\$f" "\$ser" 2>/dev/null || : >"\$ser"
ms=\$(cat "$SER/\$img.boot" 2>/dev/null || echo 500)
printf '1000.000000 QEMU START\n%s BENCH MARK userspace\n' "\$(awk -v m=\$ms 'BEGIN { printf "%.6f", 1000 + m / 1000 }')" >"\$st"
exit 0
STUB
chmod +x "$OS/tools/qemu.sh"

# transcript <file> <metric> <value> <unit>...: a guest's serial output
transcript() {
  local f=$1; shift
  { echo "noise before"; echo "BENCH MARK userspace"
    while [ $# -gt 0 ]; do printf 'BENCH %s %s %s\r\n' "$1" "$2" "$3"; shift 3; done
    echo "BENCH DONE"; } >"$f"
}
GOOD=(ipc_roundtrip 400 ns ctx_switch 200 ns timer_overshoot_p99 30000 ns ipc_scaling 7.5 x page_fault 550 ns null_syscall 60 ns
  ipc_roundtrip_p99 450 ns ctx_switch_p99 220 ns timer_overshoot 10000 ns ipc_cross_pairs1 900000 ops/s ipc_cross_pairs4 3200000 ops/s
  ipc_cross_scaling 3.5 x)
LINUX=(ipc_roundtrip 1200 ns ctx_switch 340 ns timer_overshoot_p99 80000 ns page_fault 600 ns null_syscall 64 ns
  ipc_roundtrip_p99 1400 ns ctx_switch_p99 360 ns timer_overshoot 60000 ns ipc_cross_pairs1 300000 ops/s
  ipc_cross_pairs4 1000000 ops/s ipc_cross_scaling 3.3 x)
reset() {
  rm -f "$FX"/count.* "$FX/calls" "$SER"/* "$OS/bench/ratchet.tsv" "$WS/MILESTONE"
  transcript "$SER/silica.img" "${GOOD[@]}"; transcript "$SER/linux.img" "${LINUX[@]}"
  echo 600 >"$SER/silica.img.boot"; echo 800 >"$SER/linux.img.boot"
}
run() { # run <milestone> [bench.sh args]: sets OUT and RC
  local m=$1; shift
  echo "$m" >"$WS/MILESTONE"
  OUT=$(SILICA_WS=$WS SILICA_BENCH_IMG=$FX/silica.img SILICA_LINUX_IMG=$FX/linux.img SILICA_BENCH_CPUS=0 "$OS/tools/bench.sh" "$@" 2>&1); RC=$?
}
has() { grep -qE -- "$1" <<<"$OUT"; }
errs() { grep -c '^ERROR:' <<<"$OUT"; }

# ---- 1. everything within its gate -------------------------------------------
reset; run 2 --runs 2
[ "$RC" = 0 ] && [ "$(errs)" = 0 ] || bad "good run: exit $RC, $(errs) ERROR: $OUT"
has '^bench: ipc_roundtrip: silica 400 ns .*linux 1200 ns, ratio 0\.3333' || bad "good run: ipc line wrong: $OUT"
has '^bench: boot_userspace: silica 600 ms .*linux 800 ms, ratio 0\.75' || bad "good run: boot time must come from the host stamps: $OUT"
has '^bench: ipc_scaling: silica 7\.5 x' || bad "good run: a metric with no Linux value passes on its own limit: $OUT"
has '^bench: behind Linux' && bad "good run: nothing is slower than Linux, so nothing is named behind it: $OUT"
has '^RESULT: pass=13 fail=0 skipped=0 ' || bad "good run: RESULT wrong: $OUT"
[ "$(tr '\n' ' ' <"$FX/calls")" = "silica.img linux.img silica.img linux.img " ] || bad "boots must alternate, Silica first: $(tr '\n' ' ' <"$FX/calls")"
jq -e '.schema == 2 and .metrics.ipc_roundtrip.ratio < 0.34 and .metrics.ipc_scaling.linux == null' "$WS/target/logs/bench/results.json" >/dev/null 2>&1 ||
  bad "good run: results.json wrong"

# ---- 2. the median over the runs ----------------------------------------------
reset
transcript "$SER/silica.img.1" "${GOOD[@]/400/900}"; transcript "$SER/silica.img.3" "${GOOD[@]/400/100}"
run 2 --runs 3
has '^bench: ipc_roundtrip: silica 400 ns \(noise 300\)' || bad "median: want the middle run and its deviation: $OUT"

# ---- 3. a missed gate: ERROR from its milestone, SKIP before -------------------
reset; transcript "$SER/silica.img" "${GOOD[@]/400/700}"
run 2 --runs 1
[ "$RC" = 1 ] && [ "$(errs)" = 1 ] || bad "missed gate at M2: want one ERROR and exit 1, got $(errs) (exit $RC): $OUT"
has '^ERROR: bench::ipc_roundtrip: .*ratio 0\.5833, gate: ratio < 0\.5' || bad "missed gate: message wrong: $OUT"
run 1 --runs 1
[ "$RC" = 0 ] && has '^SKIP: bench: ipc_roundtrip: .*gated from M2' || bad "missed gate before its milestone must be a SKIP: $OUT"
reset; transcript "$SER/silica.img" "${GOOD[@]/200/341}"
run 2 --runs 1
has '^ERROR: bench::ctx_switch: .*gate: ratio <= 1' || bad "an at-most gate missed by a hair must fail: $OUT"
# Every metric with a Linux value is gated at or better than Linux: a
# metric 1.167x slower fails, and is named behind Linux.
reset; transcript "$SER/silica.img" "${GOOD[@]/550/700}"
run 2 --runs 1
has '^ERROR: bench::page_fault: .*ratio 1\.167, gate: ratio <= 1' || bad "a metric slower than Linux must fail its gate: $OUT"
has '^bench: behind Linux: page_fault \(1\.167x\)$' || bad "must name exactly the metrics slower than Linux: $OUT"
reset; transcript "$SER/silica.img" "${GOOD[@]/7.5/6.9}"
run 2 --runs 1
has '^ERROR: bench::ipc_scaling: .*gate: at least 7' || bad "a minimum gate must fail below its limit: $OUT"

# ---- 4. a metric nobody reported ----------------------------------------------
reset; transcript "$SER/silica.img" "${GOOD[@]:0:9}"
run 2 --runs 1
has '^ERROR: bench::ipc_scaling: Silica reported no value' || bad "missing metric at its milestone must be an ERROR: $OUT"
run 1 --runs 1
[ "$RC" = 0 ] && has '^SKIP: bench: ipc_scaling: Silica reported no value' || bad "missing metric before its milestone must be a SKIP: $OUT"

# ---- 5. a guest that does not finish -------------------------------------------
reset; grep -v 'BENCH DONE' "$SER/linux.img" >"$SER/linux.img.2"
run 2 --runs 2
[ "$RC" = 1 ] && has '^ERROR: bench::linux: run 2 did not finish' || bad "unfinished guest: want exit 1 naming the run: exit $RC: $OUT"

# ---- 6. the ratchet -------------------------------------------------------------
reset; run 2 --runs 1 --update-ratchet
has '^bench: ratchet updated' && grep -q "^ipc_roundtrip	0.333333	vs-linux$" "$OS/bench/ratchet.tsv" || bad "ratchet: first run must record ratios: $(cat "$OS/bench/ratchet.tsv" 2>&1)"
grep -q "^ipc_scaling	7.5	value$" "$OS/bench/ratchet.tsv" || bad "ratchet: a metric without a Linux value records the value"
rm -f "$FX"/count.*; transcript "$SER/silica.img" "${GOOD[@]/400/460}"
run 2 --runs 1
has '^ERROR: bench::ipc_roundtrip: regression: vs-linux 0\.3833 against the ratchet 0\.3333' || bad "ratchet: a slower result inside its gate must still fail: $OUT"
rm -f "$FX"/count.*; transcript "$SER/silica.img" "${GOOD[@]/400/300}"
run 2 --runs 1 --update-ratchet
[ "$RC" = 0 ] && has 'ipc_roundtrip: .*better than the ratchet' && grep -q "^ipc_roundtrip	0.25	vs-linux$" "$OS/bench/ratchet.tsv" ||
  bad "ratchet: an improvement must pass and move the ratchet: $OUT"
# Within the noise of the runs is not a regression.
rm -f "$FX"/count.*; transcript "$SER/silica.img.1" "${GOOD[@]/400/280}"; transcript "$SER/silica.img.2" "${GOOD[@]/400/310}"; transcript "$SER/silica.img.3" "${GOOD[@]/400/340}"
run 2 --runs 3
[ "$RC" = 0 ] || bad "ratchet: a result within three deviations of the best must pass: $OUT"

# ---- 7. no Linux to compare with -------------------------------------------------
reset
OUT=$(SILICA_WS=$WS SILICA_BENCH_IMG=$FX/silica.img SILICA_BENCH_CPUS=0 "$OS/tools/bench.sh" --runs 1 2>&1); RC=$?
[ "$RC" = 3 ] && has '^ERROR: bench::baseline: Linux baseline unavailable' || bad "no baseline: want exit 3 and one ERROR, got exit $RC: $OUT"

# ---- 8. usage ----------------------------------------------------------------------
run 2 --runs 0; [ "$RC" = 2 ] || bad "--runs 0 must be a usage error"
run 2 --bogus; [ "$RC" = 2 ] || bad "an unknown argument must be a usage error"

[ $fails = 0 ] && echo "bench-test: all checks passed"
exit $((fails > 0))
