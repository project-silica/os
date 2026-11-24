#!/usr/bin/env bash
# Test for tools/bench.sh (spec/TESTING.md section 4).
# Runs a private copy of the tool in a disposable fake workshop whose
# tools/qemu.sh is a stub that "boots" an image by copying a canned serial
# transcript and writing host stamps, so the medians, every kind of gate
# against Linux's locked numbers, the milestone rule, the ratchet, what is
# kept and what is measured again, the open gaps and the failure reports are
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
  case "\$1" in
    --image) img=\$(basename "\$2") ;; --serial) ser=\$2 ;; --stamp) st=\$2 ;;
    # Flags without a value.
    --no-iommu|--no-exit-device|--el2) shift; continue ;;
  esac
  shift 2
done
n=\$(( \$(cat "$FX/count.\$img" 2>/dev/null || echo 0) + 1 )); echo \$n >"$FX/count.\$img"
echo "\$img" >>"$FX/calls"
f=$SER/\$img; [ -f "\$f.\$n" ] && f=\$f.\$n
cp "\$f" "\$ser" 2>/dev/null || : >"\$ser"
ms=\$(cat "$SER/\$img.boot" 2>/dev/null || echo 500)
printf '1000.000000 QEMU START\n1000.500000 BdsDxe: starting Boot0001\n%s BENCH MARK userspace\n' "\$(awk -v m=\$ms 'BEGIN { printf "%.6f", 1000.5 + m / 1000 }')" >"\$st"
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
GOOD=(ipc_roundtrip 400 ns ctx_switch 200 ns timer_overshoot_p99 30000 ns ipc_scaling 7.5 x page_fault 505 ns null_syscall 54 ns
  ipc_roundtrip_p99 450 ns ctx_switch_p99 220 ns timer_overshoot 10000 ns ipc_cross_pairs1 900000 ops/s ipc_cross_pairs4 3200000 ops/s
  ipc_cross_scaling 3.5 x ipc_pairs1 5000000 ops/s ipc_pairs8 35000000 ops/s)
LINUX=(ipc_roundtrip 1200 ns ctx_switch 340 ns timer_overshoot_p99 80000 ns page_fault 600 ns null_syscall 64 ns
  ipc_roundtrip_p99 1400 ns ctx_switch_p99 360 ns timer_overshoot 60000 ns ipc_cross_pairs1 300000 ops/s
  ipc_cross_pairs4 1000000 ops/s ipc_cross_scaling 3.8 x ipc_pairs1 800000 ops/s ipc_pairs8 6500000 ops/s)
# locked <metric> <value> <unit>...: Linux's locked numbers (bench/reference.tsv), for any host
locked() { { while [ $# -gt 0 ]; do printf '%s\t%s\t%s\t-\n' "$1" "$2" "$3"; shift 3; done; printf 'boot_userspace\t800\tms\t-\n'; } >"$OS/bench/reference.tsv"; }
reset() {
  rm -f "$FX"/count.* "$FX/calls" "$SER"/* "$OS/bench/ratchet.tsv" "$OS/bench/open.tsv" "$WS/MILESTONE"
  rm -rf "$WS/target/evidence"; : >"$FX/silica.img"
  locked "${LINUX[@]}"
  transcript "$SER/silica.img" "${GOOD[@]}"; transcript "$SER/linux.img" "${LINUX[@]}"
  echo 600 >"$SER/silica.img.boot"; echo 800 >"$SER/linux.img.boot"
  printf 'insns_null_syscall 140.0 insns\ninsns_ipc_roundtrip 977.5 insns\ninsns_ctx_switch 315.0 insns\ninsns_page_fault 1400.0 insns\n' >"$FX/counts"
}
# run <milestone> [bench.sh args]: sets OUT and RC. Silica measured whatever
# is kept (the checks below change the transcripts, which are not the
# tool's inputs); `kept` runs the tool as it is run by hand.
run() { kept "$@" --fresh; }
kept() {
  local m=$1; shift
  echo "$m" >"$WS/MILESTONE"
  OUT=$(SILICA_WS=$WS SILICA_BENCH_IMG=$FX/silica.img SILICA_LINUX_IMG=$FX/linux.img SILICA_BENCH_CPUS=0 SILICA_BENCH_COUNTS=$FX/counts "$OS/tools/bench.sh" "$@" 2>&1); RC=$?
}
calls() { [ -f "$FX/calls" ] && tr '\n' ' ' <"$FX/calls"; }
has() { grep -qE -- "$1" <<<"$OUT"; }
errs() { grep -c '^ERROR:' <<<"$OUT"; }

# ---- 1. everything within its gate -------------------------------------------
reset; run 2 --runs 2
[ "$RC" = 0 ] && [ "$(errs)" = 0 ] || bad "good run: exit $RC, $(errs) ERROR: $OUT"
has '^bench: ipc_roundtrip: silica 400 ns .*linux 1200 ns, ratio 0\.3333' || bad "good run: ipc line wrong: $OUT"
has '^bench: boot_userspace: silica 600 ms .*linux 800 ms, ratio 0\.75' || bad "good run: boot time must come from the host stamps: $OUT"
has '^bench: ipc_scaling: silica 7\.5 x' || bad "good run: a metric with no Linux value passes on its own limit: $OUT"
has '^bench: behind Linux' && bad "good run: nothing is slower than Linux (a scaling factor, unit x, below Linux's is not), so nothing is named behind it: $OUT"
# The six block and six network metrics, and the spawn and scheduling-latency
# four, come from the system image, and the four server metrics from its
# httpd, which a stubbed run does not boot: before their milestones they are
# SKIP.
has '^RESULT: pass=19 fail=0 skipped=20 ' || bad "good run: RESULT wrong: $OUT"
[ "$(tr '\n' ' ' <"$FX/calls")" = "silica.img silica.img " ] || bad "Linux is locked, not booted: only Silica's boots, got: $(tr '\n' ' ' <"$FX/calls")"
jq -e '.schema == 2 and .metrics.ipc_roundtrip.ratio < 0.34 and .metrics.ipc_scaling.linux == null' "$WS/target/logs/bench/results.json" >/dev/null 2>&1 ||
  bad "good run: results.json wrong"

# ---- 2. the median over the runs ----------------------------------------------
reset
transcript "$SER/silica.img.1" "${GOOD[@]/400/900}"; transcript "$SER/silica.img.3" "${GOOD[@]/400/100}"
run 2 --runs 3
has '^bench: ipc_roundtrip: silica 400 ns \(noise 300\)' || bad "median: want the middle run and its deviation: $OUT"

# ---- 3. a missed gate: ERROR at every milestone ---------------------------------
reset; transcript "$SER/silica.img" "${GOOD[@]/400/700}"
run 2 --runs 1
[ "$RC" = 1 ] && [ "$(errs)" = 1 ] || bad "missed gate at M2: want one ERROR and exit 1, got $(errs) (exit $RC): $OUT"
has '^ERROR: bench::ipc_roundtrip: .*ratio 0\.5833, gate: ratio < 0\.5' || bad "missed gate: message wrong: $OUT"
# Before its milestone too: a measured result that misses its gate fails.
run 1 --runs 1
[ "$RC" = 1 ] && has '^ERROR: bench::ipc_roundtrip: .*gate: ratio < 0\.5' || bad "a measured miss before its milestone must still be an ERROR: $OUT"
# The target is 15% better than Linux's locked number: 289 ns against 340
# is at it, 290 has missed it by a hair.
reset; transcript "$SER/silica.img" "${GOOD[@]/200/289}"
run 2 --runs 1
[ "$RC" = 0 ] || bad "a result exactly 15% better than Linux is at its target: $OUT"
transcript "$SER/silica.img" "${GOOD[@]/200/290}"
run 2 --runs 1
has '^ERROR: bench::ctx_switch: .*ratio 0\.8529, gate: ratio <= 0\.85' || bad "a target missed by a hair must fail: $OUT"
has '^bench: behind Linux' && bad "inside the margin is not behind Linux: $OUT"
# A metric slower than Linux fails, and is named behind Linux.
reset; transcript "$SER/silica.img" "${GOOD[@]/505/700}"
run 2 --runs 1
has '^ERROR: bench::page_fault: .*ratio 1\.167, gate: ratio <= 0\.85' || bad "a metric slower than Linux must fail its gate: $OUT"
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
reset; grep -v 'BENCH DONE' "$SER/silica.img" >"$SER/silica.img.2"
run 2 --runs 2
[ "$RC" = 1 ] && has '^ERROR: bench::silica: run 2 did not finish' || bad "unfinished guest: want exit 1 naming the run: exit $RC: $OUT"

# ---- 6. the ratchet -------------------------------------------------------------
reset; run 2 --runs 1 --update-ratchet
has '^bench: ratchet updated' && grep -q "^ipc_roundtrip	0.333333	vs-linux	400	" "$OS/bench/ratchet.tsv" || bad "ratchet: first run must record the ratio, the value and the host: $(cat "$OS/bench/ratchet.tsv" 2>&1)"
grep -q "^ipc_scaling	7.5	value$" "$OS/bench/ratchet.tsv" || bad "ratchet: a metric without a Linux value records the value"
rm -f "$FX"/count.*; transcript "$SER/silica.img" "${GOOD[@]/400/460}"
run 2 --runs 1
has '^ERROR: bench::ipc_roundtrip: regression: silica 460 ns against its best 400 ns on this host' || bad "ratchet: a slower result inside its gate must still fail: $OUT"
# On another host the value does not compare; the ratio to Linux does.
SILICA_BENCH_HOST=elsewhere run 2 --runs 1
has '^ERROR: bench::ipc_roundtrip: regression: vs-linux 0\.3833 against the ratchet 0\.3333' || bad "ratchet: on another host a slower ratio must fail: $OUT"
rm -f "$FX"/count.*; transcript "$SER/silica.img" "${GOOD[@]}"
rm -f "$FX"/count.*; transcript "$SER/silica.img" "${GOOD[@]/400/300}"
run 2 --runs 1 --update-ratchet
[ "$RC" = 0 ] && has 'ipc_roundtrip: .*better than its best 400 on this host' && grep -q "^ipc_roundtrip	0.25	vs-linux	300	" "$OS/bench/ratchet.tsv" ||
  bad "ratchet: an improvement must pass and move the ratchet: $OUT"
# Within the noise of the runs is not a regression.
rm -f "$FX"/count.*; transcript "$SER/silica.img.1" "${GOOD[@]/400/280}"; transcript "$SER/silica.img.2" "${GOOD[@]/400/310}"; transcript "$SER/silica.img.3" "${GOOD[@]/400/340}"
run 2 --runs 3
[ "$RC" = 0 ] || bad "ratchet: a result within three deviations of the best must pass: $OUT"
# A timing within 1% of its best is within what a session repeats; 2.5% is not.
rm -f "$FX"/count.* "$SER"/silica.img.*; transcript "$SER/silica.img" "${GOOD[@]/400/302}"
run 2 --runs 1
[ "$RC" = 0 ] || bad "ratchet: a timing 0.7% from its best is within what a session repeats: $OUT"
rm -f "$FX"/count.*; transcript "$SER/silica.img" "${GOOD[@]/400/308}"
run 2 --runs 1
has '^ERROR: bench::ipc_roundtrip: regression' || bad "ratchet: a timing 2.7% from its best must fail: $OUT"

# ---- 7. Linux: locked, and booted only when asked for ---------------------------
# No locked number, no comparison: a skip before the metric's milestone, an error from it.
reset; rm -f "$OS/bench/reference.tsv"; run 1 --runs 1
[ "$RC" = 0 ] && has '^SKIP: bench: ipc_roundtrip: no Linux value is locked for this host' || bad "no reference before the milestone: want a SKIP: exit $RC: $OUT"
run 2 --runs 1
[ "$RC" = 1 ] && has '^ERROR: bench::ipc_roundtrip: no Linux value is locked for this host' || bad "no reference at the milestone: want an ERROR: exit $RC: $OUT"
# --linux boots it beside Silica, prints it next to the locked number, and judges nothing by it.
reset; transcript "$SER/linux.img" "${LINUX[@]/1200/1300}"; rm -f "$FX/calls"; run 2 --runs 2 --linux
[ "$RC" = 0 ] && [ "$(calls)" = "silica.img linux.img silica.img linux.img " ] || bad "--linux: both systems, alternately, Silica first: exit $RC: $(calls)"
has '^bench: Linux now, ipc_roundtrip 1300 ns against 1200 locked \(\+8\.3%\)$' || bad "--linux: what Linux measures beside what is locked: $OUT"
has '^bench: ipc_roundtrip: silica 400 ns .*linux 1200 ns, ratio 0\.3333' || bad "--linux: the gates still use the locked number: $OUT"
grep -q '^ipc_roundtrip	1200	' "$OS/bench/reference.tsv" || bad "--linux must not change the locked numbers"
# Asked for where it cannot be built: said so.
reset
OUT=$(SILICA_WS=$WS SILICA_BENCH_IMG=$FX/silica.img SILICA_BENCH_CPUS=0 "$OS/tools/bench.sh" --runs 1 --linux 2>&1); RC=$?
[ "$RC" = 3 ] && has '^ERROR: bench::baseline: Linux baseline unavailable' || bad "--linux with no baseline: want exit 3 and one ERROR, got exit $RC: $OUT"

# ---- 7b. instruction counts: no noise, gated whatever the accelerator ------------
reset; run 2 --runs 1
has '^bench: insns_ipc_roundtrip: silica 977\.5 insns' || bad "counts: the instruction count must be reported: $OUT"
printf 'insns_ipc_roundtrip\t977.5\tvalue\n' >"$OS/bench/ratchet.tsv"
sed -i 's/insns_ipc_roundtrip 977.5/insns_ipc_roundtrip 978.3/' "$FX/counts"; run 2 --runs 1
has '^ERROR: bench::insns_ipc_roundtrip' && bad "counts: under one instruction more is the count's own jitter, not a regression: $OUT"
sed -i 's/insns_ipc_roundtrip 978.3/insns_ipc_roundtrip 979.5/' "$FX/counts"; run 2 --runs 1
has '^ERROR: bench::insns_ipc_roundtrip: regression' || bad "counts: two instructions more per round trip must fail: $OUT"

# ---- 7c. measured once ------------------------------------------------------------
# What was measured is kept under its inputs: a second run boots nothing and
# says the same; a changed Silica is measured again; a changed count file is
# counted again. Linux is never booted.
reset; kept 2 --runs 2
[ "$RC" = 0 ] && [ "$(calls)" = "silica.img silica.img " ] || bad "kept: the first run measures Silica: $(calls): $OUT"
first=$(grep '^bench: ipc_roundtrip' <<<"$OUT")
rm -f "$FX/calls"; transcript "$SER/silica.img" "${GOOD[@]/400/700}"; kept 2 --runs 2
[ "$RC" = 0 ] && [ -z "$(calls)" ] || bad "kept: an unchanged tree must boot nothing: $(calls): $OUT"
[ "$(grep '^bench: ipc_roundtrip' <<<"$OUT")" = "$first" ] || bad "kept: a run that measures nothing reports what was measured: $OUT"
has '^bench: not measured again.* kernel .* counts ' || bad "kept: a run must say what it did not measure again: $OUT"
has '^RESULT: pass=19 fail=0 skipped=20 ' || bad "kept: the kept results are judged like measured ones: $OUT"
echo changed >"$FX/silica.img"; transcript "$SER/silica.img" "${GOOD[@]/400/410}"; kept 2 --runs 2
[ "$(calls)" = "silica.img silica.img " ] || bad "kept: a changed Silica is measured again: $(calls)"
has '^bench: ipc_roundtrip: silica 410 ns .*linux 1200 ns' || bad "kept: Silica's new value beside the locked Linux: $OUT"
rm -f "$FX/calls"; kept 2 --runs 2 --fresh
[ "$(calls)" = "silica.img silica.img " ] || bad "kept: --fresh measures Silica again: $(calls)"
rm -f "$FX/calls"; kept 2 --runs 1
[ "$(calls)" = "silica.img " ] || bad "kept: another --runs is another measurement: $(calls)"
sed -i 's/insns_ipc_roundtrip 977.5/insns_ipc_roundtrip 960.0/' "$FX/counts"; rm -f "$FX/calls"; kept 2 --runs 1
[ -z "$(calls)" ] && has '^bench: insns_ipc_roundtrip: silica 960 insns' || bad "kept: changed counts are read again, with no timed boot: $(calls): $OUT"
# A failure is reported from kept results as from measured ones.
reset; transcript "$SER/silica.img" "${GOOD[@]/400/700}"; kept 2 --runs 1; kept 2 --runs 1
[ "$RC" = 1 ] && has '^ERROR: bench::ipc_roundtrip: .*gate: ratio < 0\.5' || bad "kept: a kept result that misses its gate still fails: exit $RC: $OUT"

# ---- 7d. --only ---------------------------------------------------------------------
reset; run 2 --runs 1 --update-ratchet
run 2 --runs 1 --only ipc_roundtrip,ctx --update-ratchet
[ "$RC" = 0 ] && has '^RESULT: pass=4 fail=0 skipped=0 ' || bad "--only: just the named metrics are judged: $OUT"
has '^bench: (page_fault|insns_)' && bad "--only: a metric not named must not be judged: $OUT"
grep -q "^page_fault	" "$OS/bench/ratchet.tsv" && grep -q "^insns_page_fault	1400.0	value$" "$OS/bench/ratchet.tsv" || bad "--only: metrics not judged keep their ratchets: $(cat "$OS/bench/ratchet.tsv")"
run 2 --only nothing_named_so; [ "$RC" = 2 ] || bad "--only with no metric must be a usage error"

# ---- 7e. at the target is what the runs cannot tell from it ---------------------------
# 292 against a target of 289 (340 less 15%), the runs spread 284..300: past
# it by less than their own noise.
reset; transcript "$SER/silica.img.1" "${GOOD[@]/200/284}"; transcript "$SER/silica.img.2" "${GOOD[@]/200/292}"; transcript "$SER/silica.img.3" "${GOOD[@]/200/300}"
run 2 --runs 3
[ "$RC" = 0 ] && has '^bench: ctx_switch: silica 292 ns' || bad "a ratio past its limit by less than the runs' noise is at it, not a miss: $OUT"
# The same median from runs that agree is a miss.
reset; transcript "$SER/silica.img" "${GOOD[@]/200/292}"; run 2 --runs 3
has '^ERROR: bench::ctx_switch: ' || bad "the same result with no noise to hide in must fail: $OUT"

# ---- 7f. open gaps ----------------------------------------------------------------------
reset; transcript "$SER/silica.img" "${GOOD[@]/505/700}"
printf '# metric\tkind\tbound\thost\twhy\npage_fault\tlinux\t1.17\t-\tknown\n' >"$OS/bench/open.tsv"
run 2 --runs 1
[ "$RC" = 0 ] && has '^OPEN: bench: page_fault: .*ratio 1\.167.*recorded at 1\.17' && has '^bench: open gaps.* page_fault$' || bad "open gap: a miss no worse than its recorded bound is OPEN and the run passes: exit $RC: $OUT"
has '^RESULT: pass=18 fail=0 skipped=21 ' || bad "open gap: counted apart from passes: $OUT"
transcript "$SER/silica.img" "${GOOD[@]/505/730}"; run 2 --runs 1
[ "$RC" = 1 ] && has '^ERROR: bench::page_fault: .*now worse' || bad "open gap: worse than its bound must fail: exit $RC: $OUT"
transcript "$SER/silica.img" "${GOOD[@]/505/700}"
echo 2 >"$WS/MILESTONE"
OUT=$(SILICA_MILESTONE=2 SILICA_WS=$WS SILICA_BENCH_IMG=$FX/silica.img SILICA_LINUX_IMG=$FX/linux.img SILICA_BENCH_CPUS=0 SILICA_BENCH_COUNTS=$FX/counts "$OS/tools/bench.sh" --runs 1 --fresh --linux 2>&1); RC=$?
[ "$RC" = 1 ] && has '^ERROR: bench::page_fault' || bad "open gap: a milestone is not declared over one: exit $RC: $OUT"
# A ratchet's known regression, on the host that recorded it.
reset; run 2 --runs 1 --update-ratchet
host=$(awk -F'\t' '$1 == "ipc_roundtrip" { print $5 }' "$OS/bench/ratchet.tsv")
printf 'ipc_roundtrip\tratchet\t460\t%s\tknown\ninsns_ipc_roundtrip\tratchet\t990\t-\tknown\npage_fault\tlinux\t1.17\t-\tclosed since\n' "$host" >"$OS/bench/open.tsv"
transcript "$SER/silica.img" "${GOOD[@]/400/455}"; sed -i 's/insns_ipc_roundtrip 977.5/insns_ipc_roundtrip 985.0/' "$FX/counts"
run 2 --runs 1
[ "$RC" = 0 ] && has '^OPEN: bench: ipc_roundtrip: regression: silica 455 ns' && has '^OPEN: bench: insns_ipc_roundtrip: regression: value 985' || bad "open gap: a known regression against the ratchet is OPEN: exit $RC: $OUT"
run 2 --runs 1 --update-ratchet
grep -q "^ipc_roundtrip	ratchet	455	" "$OS/bench/open.tsv" && grep -q "^insns_ipc_roundtrip	ratchet	985.0	" "$OS/bench/open.tsv" || bad "open gap: --update-ratchet keeps the better bound: $(cat "$OS/bench/open.tsv")"
grep -q '^page_fault' "$OS/bench/open.tsv" && bad "open gap: --update-ratchet drops a gap that closed: $(cat "$OS/bench/open.tsv")"
grep -q "^ipc_roundtrip	0.333333	vs-linux	400	" "$OS/bench/ratchet.tsv" || bad "open gap: the ratchet itself never loosens: $(grep ipc_roundtrip "$OS/bench/ratchet.tsv")"
transcript "$SER/silica.img" "${GOOD[@]/400/470}"; run 2 --runs 1
[ "$RC" = 1 ] && has '^ERROR: bench::ipc_roundtrip: regression: .*now worse' || bad "open gap: a regression past its bound must fail: exit $RC: $OUT"
# Worse than its bound, an open gap stays as it was: it has not closed.
run 2 --runs 1 --update-ratchet
grep -q "^ipc_roundtrip	ratchet	455	" "$OS/bench/open.tsv" || bad "open gap: --update-ratchet keeps a gap that got worse than its bound, unchanged: $(cat "$OS/bench/open.tsv")"

# ---- 8. usage ----------------------------------------------------------------------
run 2 --runs 0; [ "$RC" = 2 ] || bad "--runs 0 must be a usage error"
run 2 --bogus; [ "$RC" = 2 ] || bad "an unknown argument must be a usage error"

[ $fails = 0 ] && echo "bench-test: all checks passed"
exit $((fails > 0))
