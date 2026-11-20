#!/usr/bin/env bash
# Test for tools/bench.sh (component A02; spec/TESTING.md section 4).
# Runs a private copy of the tool suite in a disposable fake workshop whose
# tools/qemu.sh is replaced by a stub that "boots" an image by copying a canned
# serial transcript, so every gate, the baseline build, the baseline unavailable reports,
# the median over runs and the 5% regression rule are checked without QEMU.
# One "ERROR:" line per failed check.
set -uo pipefail
SRC=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd -P)
BASE=${SILICA_RUN:-${TMPDIR:-/tmp}}; mkdir -p "$BASE"
FX=$(mktemp -d "$BASE/benchtest.XXXX") || exit 2
FX=$(cd "$FX" && pwd -P)
trap 'rm -rf "${FX:?}"' EXIT
fails=0
bad() { echo "ERROR: bench-test: $1"; fails=$((fails + 1)); }
command -v jq >/dev/null || { echo "ERROR: bench-test: jq is not installed"; exit 2; }

WS=$FX/ws; OS=$WS/os; K=$WS/kernel; SER=$FX/serials; SRCDIR=$FX/linux-src
mkdir -p "$OS/tools" "$K" "$SER" "$FX/img" "$SRCDIR"
echo x >"$WS/bootstrap.pins"
cp -r "$SRC/lib" "$SRC/bench.sh" "$OS/tools/"
printf '# fake manifest\n' >"$OS/manifest.toml"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.invalid
(cd "$K" && git init -q . && git commit -qm fake --allow-empty) ||
  { echo "ERROR: bench-test: cannot create the fake kernel repository"; exit 2; }
cat >"$OS/tools/qemu.sh" <<STUB
#!/usr/bin/env bash
# Stub: copies the canned transcript <serials>/<image name>[.<boot number>] to the serial file.
img="" ser="" smp="" mem=""
while [ \$# -gt 0 ]; do
  case "\$1" in --image) img=\$2 ;; --serial) ser=\$2 ;; --smp) smp=\$2 ;; --mem) mem=\$2 ;; esac
  shift 2
done
n=\$(( \$(cat "$FX/count" 2>/dev/null || echo 0) + 1 )); echo \$n >"$FX/count"
echo "\$(basename "\$img") smp=\$smp mem=\$mem" >>"$FX/calls"
f=$SER/\$(basename "\$img"); [ -f "\$f.\$n" ] && f=\$f.\$n
cp "\$f" "\$ser" 2>/dev/null || : >"\$ser"
exit \$(cat "$FX/rc" 2>/dev/null || echo 0)
STUB
chmod +x "$OS/tools/qemu.sh"
ART=$WS/target/cache/kernel-$(printf '%s' "$K" | sha256sum | cut -c1-16)/artifacts/x86_64
accel=tcg; [ -w /dev/kvm ] && accel=kvm

# name unit direction limit kind from: the table of spec/TESTING.md section 4, written out independently.
M='boot_userspace_ms ms lower 1 win 2
ipc_roundtrip_ns ns lower 0.5 win 2
ctx_switch_ns ns lower 1 le 2
boot_network_ms ms lower 1 win 4
idle_mem_kib KiB lower 0.25 le 4
driver_recovery_blk_ms ms lower 250 abs 3
driver_recovery_net_ms ms lower 250 abs 3
driver_lost_writes_blk count lower 0 abs 3
driver_lost_writes_net count lower 0 abs 3
sched_p99_us us lower 1 le 3
tcp_mbit_s Mbit/s higher 1.25 le 4
file_meta_ops_s ops/s higher 1.5 le 5
blk_iops iops higher 1.1 le 5
app_cold_start_ms ms lower 1 win 6
nvme_iops iops higher 1.1 le 8'
B=1200   # the Linux value of every metric in the fixture baseline
unit_of() { echo "$M" | awk -v m="$1" '$1 == m { print $2 }'; }
good_of() { # a passing value for <metric> against $B
  echo "$M" | awk -v m="$1" -v b=$B '$1 == m {
    if ($5 == "abs") print $4 == 0 ? 0 : $4 - 1
    else if ($3 == "lower") print b * $4 * ($5 == "win" ? 0.5 : 1)
    else print b / $4 }'
}
over_of() { # the smallest failing value for <metric> against $B
  echo "$M" | awk -v m="$1" -v b=$B '$1 == m {
    if ($5 == "abs") print $4 + 1
    else if ($3 == "lower") print b * $4 + 1
    else print b / $4 - 1 }'
}
serial() { # serial <image name> [metric=value]...: a full good transcript with overrides; "metric=-" omits it
  local f=$SER/$1 name unit v a ov; shift
  { echo "boot noise"; while read -r name unit _; do
      v=$(good_of "$name")
      for a in "$@"; do [ "${a%%=*}" = "$name" ] && v=${a#*=}; done
      [ "$v" = - ] || printf 'BENCH %s %s %s\r\n' "$name" "$v" "$unit"
    done <<<"$M"
    echo "BENCH DONE"; } >"$f"
}
mkbase() { # mkbase [accel]: a baseline in the os checkout, every metric $B, smp 3, mem 384
  mkdir -p "$OS/bench"
  echo "$M" | awk -v b=$B '{ print $1 "\t" b "\t" $2 }' |
    jq -Rn --arg a "${1:-$accel}" '{schema:1, linux:{kernel:"6.12-test"}, config:{smp:3, mem_mib:384, accel:$a, runs:3},
      metrics: ([inputs | split("\t") | {key:.[0], value:{value:(.[1]|tonumber), unit:.[2]}}] | from_entries)}' >"$OS/bench/linux-baseline.json"
}
ms() { echo "$1" >"$WS/MILESTONE"; }
run() { # run <args>: bench.sh in the fake workshop; OUT, RC
  rm -f "$FX/count" "$FX/calls" "$FX/rc"
  OUT=$(cd "$FX" && env -i PATH="${PATH:-/usr/bin:/bin}" HOME="$FX" TMPDIR="$FX" SILICA_WS="$WS" ${SILICA_LINUX_SRC_T:+SILICA_LINUX_SRC="$SILICA_LINUX_SRC_T"} \
    bash "$OS/tools/bench.sh" "$@" 2>&1)
  RC=$?
}
errs() { printf '%s\n' "$OUT" | grep -c '^ERROR:'; }
has() { printf '%s\n' "$OUT" | grep -qE -- "$1"; }
result_ok() { # <case>: output rules: <= 30 lines, last line is RESULT
  [ "$(printf '%s\n' "$OUT" | wc -l)" -le 30 ] || bad "$1: more than 30 lines of output"
  printf '%s\n' "$OUT" | tail -n 1 | grep -qE '^RESULT: pass=[0-9]+ fail=[0-9]+ skipped=[0-9]+ time=[0-9]+$' || bad "$1: last line is not RESULT: $OUT"
}
expect() { # expect <case> <exit> <errors> [regex that must appear]; usage errors (exit 2) end without RESULT
  [ "$2" = 2 ] && [ "$(errs)" = 1 ] && ! has '^RESULT:' || result_ok "$1"
  [ "$RC" = "$2" ] || bad "$1: exit $RC, want $2: $OUT"
  [ "$(errs)" = "$3" ] || bad "$1: want $3 ERROR lines, got $(errs): $OUT"
  [ -z "${4:-}" ] || has "$4" || bad "$1: output lacks /$4/: $OUT"
}
IMG=$FX/img/silica.img; : >"$IMG"
LI=$SRCDIR/linux.img

# ---- 1. usage errors ------------------------------------------------------------
ms 0
run --frobnicate;               expect usage-unknown 2 1 'unknown argument'
run --runs;                     expect usage-missing-value 2 1 'needs a value'
run --runs 0;                   expect usage-runs-zero 2 1
run --runs abc;                 expect usage-runs-text 2 1 'not a positive number'
run --smp 2;                    expect usage-smp-in-run 2 1 'build-baseline'
run --force;                    expect usage-force-in-run 2 1 'build-baseline'

# ---- 2. no bench image: SKIP before M2, ERROR from M2 ---------------------------------
rm -rf "$OS/bench"
ms 0; run;                       expect no-image-m0 0 0 '^SKIP: bench: .*not built.*M2'
ms 1; run;                       expect no-image-m1 0 0 '^SKIP: bench'
ms 2; run;                       expect no-image-m2 1 1 'ERROR: bench::.*not built'

# ---- 3. image but no baseline: baseline unavailable ---------------------------------------------
ms 0; serial silica.img
run --image "$IMG";             expect no-baseline 3 1 'baseline unavailable.*--build-baseline'
[ -e "$OS/bench/linux-baseline.json" ] && bad "no-baseline: wrote a baseline"

# ---- 4. --build-baseline without sources: baseline unavailable, nothing written -------------------
SILICA_LINUX_SRC_T=$SRCDIR
run --build-baseline;           expect baseline-no-sources 3 1 'baseline unavailable.*not available offline.*linux\.img'
[ -e "$OS/bench/linux-baseline.json" ] && bad "baseline-no-sources: wrote a baseline"
echo "6.12.99-test" >"$SRCDIR/linux.version"
run --build-baseline;           expect baseline-no-image 3 1 'baseline unavailable'
: >"$LI"
unset SILICA_LINUX_SRC_T

# ---- 5. --build-baseline records the baseline ------------------------------------------
SILICA_LINUX_SRC_T=$SRCDIR
for i in 1 2 3; do serial "linux.img.$i" ipc_roundtrip_ns=$((1000 * i)) driver_lost_writes_blk=$((i - 1)); done
run --build-baseline;
expect baseline-build 0 0 'bench: baseline: 15 metrics.*6\.12\.99-test.*smp 2, mem 512M'
BL=$OS/bench/linux-baseline.json
[ "$(jq -r '.schema' "$BL" 2>/dev/null)" = 1 ] || bad "baseline-build: no schema 1 file at $BL"
[ "$(jq -r '.metrics.ipc_roundtrip_ns | "\(.value) \(.unit)"' "$BL" 2>/dev/null)" = "2000 ns" ] || bad "baseline-build: ipc median of 1000,2000,3000 is not 2000 ns: $(jq -c .metrics.ipc_roundtrip_ns "$BL" 2>/dev/null)"
[ "$(jq -r '.metrics.driver_lost_writes_blk.value' "$BL" 2>/dev/null)" = 2 ] || bad "baseline-build: abs metric did not take the worst run"
[ "$(jq -r '"\(.config.smp) \(.config.mem_mib) \(.config.accel) \(.linux.kernel)"' "$BL" 2>/dev/null)" = "2 512 $accel 6.12.99-test" ] || bad "baseline-build: wrong config: $(jq -c '.config, .linux' "$BL" 2>/dev/null)"
[ "$(grep -c . "$FX/calls")" = 3 ] && grep -qx 'linux.img smp=2 mem=512' "$FX/calls" || bad "baseline-build: three boots of linux.img at smp 2 mem 512 expected: $(cat "$FX/calls")"
sum=$(sha256sum "$BL")
run --build-baseline;           expect baseline-rebuild-refused 2 1 'built once.*--force'
[ "$(sha256sum "$BL")" = "$sum" ] || bad "baseline-rebuild-refused: the baseline changed"
rm -f "$SER"/linux.img.*; serial linux.img
run --build-baseline --force --runs 1 --smp 4 --mem 1024
expect baseline-force 0 0 'smp 4, mem 1024M'
[ "$(jq -r '"\(.config.smp) \(.config.mem_mib) \(.config.runs)"' "$BL")" = "4 1024 1" ] || bad "baseline-force: config not replaced"
[ "$(grep -c . "$FX/calls")" = 1 ] || bad "baseline-force: --runs 1 must boot once"
# a Linux image that never prints BENCH DONE, one with unknown metrics, one with a wrong unit
printf 'BENCH ipc_roundtrip_ns 5 ns\n' >"$SER/linux.img"
run --build-baseline --force --runs 1;   expect baseline-unfinished 1 1 'bench::linux.*did not finish'
printf 'BENCH bogus 5 ns\nBENCH DONE\n' >"$SER/linux.img"
run --build-baseline --force --runs 1;   expect baseline-unknown-metric 1 1 'bench::bogus.*unknown metric'
printf 'BENCH ipc_roundtrip_ns 5 ms\nBENCH DONE\n' >"$SER/linux.img"
run --build-baseline --force --runs 1;   expect baseline-wrong-unit 1 1 'bench::ipc_roundtrip_ns.*unit ms'
printf 'BENCH DONE\n' >"$SER/linux.img"
run --build-baseline --force --runs 1;   expect baseline-empty 1 1 'no metrics'
unset SILICA_LINUX_SRC_T

# ---- 6. every gate at its limit and just over, before and from its milestone ---------
mkbase
while read -r name unit dir limit kind from; do
  serial silica.img "$name=$(good_of "$name")"
  ms 9; run --image "$IMG" --runs 1
  expect "$name-good" 0 0 "^bench: $name: "
  has "^bench: $name: .*limit" || bad "$name-good: no pass line"
  serial silica.img "$name=$(over_of "$name")"
  ms "$from"; run --image "$IMG" --runs 1
  expect "$name-over-at-m$from" 1 1 "^ERROR: bench::$name: "
  ms $((from - 1)); run --image "$IMG" --runs 1
  expect "$name-over-before-m$from" 0 0 "^SKIP: bench: $name: .*gated from M$from"
  serial silica.img "$name=-"
  ms "$from"; run --image "$IMG" --runs 1
  expect "$name-missing-at-m$from" 1 1 "^ERROR: bench::$name: .*no value"
  ms $((from - 1)); run --image "$IMG" --runs 1
  expect "$name-missing-before-m$from" 0 0 "^SKIP: bench: $name: .*no value"
done <<<"$M"

# Exact boundaries: "faster" and "under" are strict; "at most", "at or below" and "within" are not.
serial silica.img boot_userspace_ms=1200; ms 9; run --image "$IMG" --runs 1
expect win-equal-fails 1 1 'bench::boot_userspace_ms.*ratio 1 \(limit < 1\)'
serial silica.img ctx_switch_ns=1200; run --image "$IMG" --runs 1
expect le-equal-passes 0 0
serial silica.img idle_mem_kib=300; run --image "$IMG" --runs 1
expect ratios-at-limit 0 0 'idle_mem_kib: ours 300 KiB, linux 1200 KiB, ratio 0\.25'
# IPC is "under half" a Linux pipe ping-pong: strict, so exactly half fails and just under passes.
serial silica.img ipc_roundtrip_ns=600; run --image "$IMG" --runs 1
expect ipc-equal-fails 1 1 'bench::ipc_roundtrip_ns.*ratio 0\.5 \(limit < 0\.5\)'
serial silica.img ipc_roundtrip_ns=599; run --image "$IMG" --runs 1
expect ipc-under-limit-passes 0 0 'ipc_roundtrip_ns: .*\(limit < 0\.5\)'
serial silica.img tcp_mbit_s=960; run --image "$IMG" --runs 1
expect higher-at-limit 0 0 'tcp_mbit_s: .*ratio 1\.25'
serial silica.img tcp_mbit_s=959; run --image "$IMG" --runs 1
expect higher-over-limit 1 1 'bench::tcp_mbit_s'
serial silica.img tcp_mbit_s=0; run --image "$IMG" --runs 1
expect higher-zero 1 1 'bench::tcp_mbit_s'

# ---- 7. the Linux side: smp and memory come from the baseline; a missing value ---------
serial silica.img; ms 9; run --image "$IMG" --runs 2
expect run-config 0 0
grep -qx 'silica.img smp=3 mem=384' "$FX/calls" && [ "$(grep -c . "$FX/calls")" = 2 ] || bad "run-config: want two boots at the baseline's smp 3 mem 384: $(cat "$FX/calls")"
jq 'del(.metrics.tcp_mbit_s)' "$OS/bench/linux-baseline.json" >"$FX/b.json" && cp "$FX/b.json" "$OS/bench/linux-baseline.json"
ms 4; run --image "$IMG" --runs 1;  expect baseline-lacks-metric-at-gate 1 1 'bench::tcp_mbit_s: the baseline has no Linux value'
ms 3; run --image "$IMG" --runs 1;  expect baseline-lacks-metric-before-gate 0 0 'SKIP: bench: tcp_mbit_s'
jq '.metrics.sched_p99_us.value = 0' "$OS/bench/linux-baseline.json" >"$FX/b.json" && cp "$FX/b.json" "$OS/bench/linux-baseline.json"
ms 9; run --image "$IMG" --runs 1;  expect baseline-zero 1 2 'sched_p99_us.*not positive'
mkbase
# Driver recovery is gated on the absolute limit even when the baseline lacks it (Linux recorded, not gated).
jq 'del(.metrics.driver_recovery_blk_ms)' "$OS/bench/linux-baseline.json" >"$FX/b.json" && cp "$FX/b.json" "$OS/bench/linux-baseline.json"
serial silica.img; ms 9; run --image "$IMG" --runs 1
expect abs-without-linux-value 0 0 '^bench: driver_recovery_blk_ms: ours 249 ms \(limit <= 250\)$'
mkbase
# Acceleration mismatch: timings are not comparable.
other=kvm; [ "$accel" = kvm ] && other=tcg
mkbase $other; serial silica.img; ms 9
run --image "$IMG" --runs 1;       expect accel-mismatch 2 1 "recorded under $other.*runs $accel"
echo 'not json' >"$OS/bench/linux-baseline.json"
run --image "$IMG" --runs 1;       expect baseline-garbage 2 1 'not a schema 1 baseline'
mkbase

# ---- 8. guest failures ---------------------------------------------------------------
serial silica.img; ms 9
printf 'BENCH boot_userspace_ms 5 ms\n' >"$SER/silica.img"
run --image "$IMG" --runs 1;       expect guest-unfinished 1 1 'bench::silica.*did not finish'
: >"$SER/silica.img"
run --image "$IMG" --runs 1;       expect guest-silent 1 1 'did not finish'
printf 'BENCH bogus 5 ns\nBENCH DONE\n' >"$SER/silica.img"
run --image "$IMG" --runs 1;       expect guest-unknown-metric 1 1 'bench::bogus.*unknown'
serial silica.img boot_userspace_ms=notanumber
run --image "$IMG" --runs 1;       expect guest-bad-number 1 1 'bench::boot_userspace_ms.*no value'
serial silica.img
# qemu.sh exit codes: 2 is a setup error, other codes with a finished transcript are fine (debug-exit status)
rm -f "$FX/count"; OUT=$(cd "$FX" && env -i PATH="$PATH" HOME="$FX" TMPDIR="$FX" SILICA_WS="$WS" bash -c "echo 2 >'$FX/rc'; exec bash '$OS/tools/bench.sh' --image '$IMG' --runs 1" 2>&1); RC=$?
# (run() clears rc; this call sets it itself)
expect qemu-setup-error 2 1 'qemu.sh setup error'

# ---- 9. median over runs; the default image path; results file ----------------------------
rm -f "$SER"/silica.img.*; serial silica.img
for i in 1 2 3; do serial "silica.img.$i" ctx_switch_ns=$((i == 1 ? 100 : i == 2 ? 1100 : 300)) driver_recovery_blk_ms=$((i * 50)); done
OUTJ=$FX/res.json
ms 9; run --image "$IMG" --out "$OUTJ"
expect median 0 0 "results in $OUTJ"
[ "$(jq -r .metrics.ctx_switch_ns.value "$OUTJ" 2>/dev/null)" = 300 ] || bad "median: ctx median of 100,1100,300 is not 300: $(jq -c .metrics.ctx_switch_ns "$OUTJ" 2>/dev/null)"
[ "$(jq -r .metrics.driver_recovery_blk_ms.value "$OUTJ" 2>/dev/null)" = 150 ] || bad "median: abs metric must take the worst run (150)"
[ "$(jq -r '"\(.schema) \(.milestone)"' "$OUTJ" 2>/dev/null)" = "1 9" ] || bad "median: results file lacks schema and milestone"
rm -f "$SER"/silica.img.*
mkdir -p "$ART"; : >"$ART/bench.img"; cp "$SER/silica.img" "$SER/bench.img"
ms 9; run;                         expect default-image 0 0 '^bench: boot_userspace_ms'
[ "$(grep -c '^bench.img' "$FX/calls")" = 3 ] || bad "default-image: want three boots of bench.img: $(cat "$FX/calls")"
rm -rf "${WS:?}/target"

# ---- 10. regression against an earlier results file ---------------------------------------
PREV=$FX/prev.json
mkprev() { # mkprev <metric> <value> <unit>
  jq -n --arg n "$1" --argjson v "$2" --arg u "$3" '{schema:1, milestone:9, metrics:{($n):{value:$v, unit:$u}}}' >"$PREV"
}
serial silica.img ipc_roundtrip_ns=500; ms 9
mkprev ipc_roundtrip_ns 477 ns;  run --image "$IMG" --runs 1 --previous "$PREV"
expect regress-lower-under-5pct 0 0
mkprev ipc_roundtrip_ns 470 ns;  run --image "$IMG" --runs 1 --previous "$PREV"
expect regress-lower-over-5pct 1 1 'bench::ipc_roundtrip_ns: regression over 5%'
mkprev ipc_roundtrip_ns 2000 ns; run --image "$IMG" --runs 1 --previous "$PREV"
expect regress-improved 0 0
serial silica.img tcp_mbit_s=1000
mkprev tcp_mbit_s 1040 Mbit/s;   run --image "$IMG" --runs 1 --previous "$PREV"
expect regress-higher-under-5pct 0 0
mkprev tcp_mbit_s 1060 Mbit/s;   run --image "$IMG" --runs 1 --previous "$PREV"
expect regress-higher-over-5pct 1 1 'bench::tcp_mbit_s: regression'
mkprev tcp_mbit_s 5000 Mbit/s;   ms 0; run --image "$IMG" --runs 1 --previous "$PREV"
expect regress-applies-before-gate 1 1 'bench::tcp_mbit_s: regression'
echo '{}' >"$PREV"
run --image "$IMG" --runs 1 --previous "$PREV";   expect previous-garbage 2 1 'not a bench results file'
run --image "$IMG" --runs 1 --previous "$FX/none.json"; expect previous-missing 2 1 'not a bench results file'

[ $fails = 0 ] && echo "bench-test: ok"
exit $((fails > 0))
