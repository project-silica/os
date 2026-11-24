#!/usr/bin/env bash
# Test for tools/fuzz.sh (component A07; spec/TESTING.md
# section 3): target discovery, time-boxed runs, reproducers kept under
# target/fuzz/, replay of stored reproducers, coverage report, the hard time
# limit, build failures, usage errors, and `test.sh --deep` calling it.
#
# Runs a private copy of the tool suite in a disposable fake workshop. The
# libFuzzer side is faked: a `cargo-fuzz` whose `build` writes a stand-in fuzz
# binary that prints libFuzzer-style progress lines, writes a reproducer on
# demand, hangs on demand or replays a file; `rustc` and `cargo` are shims. The
# real libFuzzer needs the vendored libfuzzer-sys crate. One "ERROR:" line per
# failed check.
set -uo pipefail
SRC=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd -P)
BASE=${SILICA_RUN:-${TMPDIR:-/tmp}}; mkdir -p "$BASE"
FX=$(mktemp -d "$BASE/fuzztest.XXXX") || exit 2
FX=$(cd "$FX" && pwd -P)
trap 'rm -rf "${FX:?}"' EXIT
fails=0
bad() { echo "ERROR: fuzz-test: $1"; fails=$((fails + 1)); }

WS=$FX/ws; OS=$WS/os; K=$WS/kernel; BIN=$FX/bin; RUNS=$FX/runs.log; BUILDS=$FX/builds.log
mkdir -p "$BIN" "$OS/tools" "$K"
echo x >"$WS/bootstrap.pins"; echo 0 >"$WS/MILESTONE"
cp -r "$SRC/lib" "$SRC/fuzz.sh" "$SRC/test.sh" "$SRC/size.sh" "$SRC/qemu.sh" "$OS/tools/"
printf '[repos.kernel]\nurl = "https://example.invalid/kernel"\nmilestone = 0\ncommit = "x"\n' >"$OS/manifest.toml"
: >"$RUNS"; : >"$BUILDS"

cat >"$BIN/rustc" <<'EOF'
#!/bin/bash
case "$*" in
  *-vV*) printf 'rustc 1.0.0\nhost: x86_64-unknown-linux-gnu\n' ;;
  *"--print sysroot"*) echo "$FAKE_FX/sysroot" ;;
esac
EOF
cat >"$BIN/cargo" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$FAKE_FX/cargo.argv"
exit 0
EOF

# The fake cargo-fuzz: `build` records its arguments and the CARGO it was given
# and writes the stand-in fuzz binary at <target-dir>/<triple>/release/<name>.
cat >"$BIN/cargo-fuzz" <<'EOF'
#!/bin/bash
sub=$1; shift
[ "$sub" = build ] || { echo "error: the fake cargo-fuzz only builds" >&2; exit 2; }
tdir="" triple="" name=""
while [ $# -gt 0 ]; do
  case "$1" in
    --target-dir) tdir=$2; shift 2 ;;
    --target) triple=$2; shift 2 ;;
    --fuzz-dir | -s) shift 2 ;;
    *) name=$1; shift ;;
  esac
done
echo "CARGO=$CARGO target-dir=$tdir target=$triple name=$name" >>"$FAKE_FX/builds.log"
case "$name" in
  buildfail_*) echo "error: could not compile \`fake\` due to 1 previous error" >&2; exit 101 ;;
esac
mkdir -p "$tdir/$triple/release"
cp "$FAKE_FX/fuzzbin" "$tdir/$triple/release/$name"
chmod +x "$tdir/$triple/release/$name"
EOF
# The stand-in fuzz binary: libFuzzer's command line (corpus directories or
# files, then -flags). A file argument is a replay.
cat >"$FX/fuzzbin" <<'EOF'
#!/bin/bash
name=$(basename "$0")
echo "$name $*" >>"$FAKE_FX/runs.log"
prefix="" pos=()
for a in "$@"; do
  case "$a" in
    -artifact_prefix=*) prefix=${a#-artifact_prefix=} ;;
    -*) ;;
    *) pos+=("$a") ;;
  esac
done
for a in "$@"; do
  case "$a" in
    -runs=0) # load the corpus only: 4 edges plus one per input
      if grep -rqs SEEDCRASH "${pos[@]}"; then
        echo "thread '<unnamed>' panicked at fuzz_targets/x.rs:1:1:"; echo "a seed broke it"
        printf SEEDCRASH >"${prefix}crash-5eed"; echo "SUMMARY: libFuzzer: deadly signal"; exit 77
      fi
      n=0; for d in "${pos[@]}"; do n=$((n + $(ls "$d" 2>/dev/null | wc -l))); done
      echo "#$n	INITED cov: $((4 + n)) ft: $((4 + n)) corp: $n/${n}b exec/s: 0 rss: 30Mb"; exit 0 ;;
    -merge=1) # the first directory receives every input of the others it lacks
      for d in "${pos[@]:1}"; do cp -n "$d"/* "${pos[0]}/" 2>/dev/null; done; exit 0 ;;
  esac
done
if [ -f "${pos[0]:-}" ]; then # replay
  if grep -q CRASH "${pos[0]}"; then echo "==1==ERROR: AddressSanitizer: replay of ${pos[0]}"; exit 77; fi
  echo "Executed ${pos[0]} in 0 ms"; exit 0
fi
case "$name" in
  hang_*) exec sleep 300 ;;
  crash_*)
    if [ ! -e "$FAKE_FX/fixed" ]; then
      echo "#1	INITED cov: 5 ft: 5 corp: 1/1b lim: 4 exec/s: 0 rss: 30Mb"
      echo "#37	NEW    cov: 7 ft: 8 corp: 2/3b lim: 4 exec/s: 0 rss: 30Mb L: 2/2 MS: 1 ChangeBit-"
      echo "==1==ERROR: AddressSanitizer: heap-buffer-overflow on address 0x1"
      printf CRASH >"${prefix}crash-deadbeef"
      echo "SUMMARY: AddressSanitizer: heap-buffer-overflow"
      exit 77
    fi ;;
esac
echo "#1	INITED cov: 5 ft: 5 corp: 1/1b lim: 4 exec/s: 0 rss: 30Mb"
echo "#100	NEW    cov: 9 ft: 12 corp: 3/20b lim: 4 exec/s: 0 rss: 30Mb L: 4/4 MS: 1 ChangeBit-"
echo "#4096	DONE   cov: 9 ft: 12 corp: 3/20b lim: 4 exec/s: 0 rss: 30Mb"
echo "stat::number_of_executed_units: 4096"
touch "${pos[0]}/new-$$"
exit 0
EOF
chmod +x "$BIN"/* "$FX/fuzzbin"

mk_crate() { # mk_crate <repo dir> <crate rel path or .> <libfuzzer-sys|none> <target names...>
  local d=$1/$2/fuzz r=$1 c=$2; shift 3
  [ "$c" = . ] && d=$r/fuzz
  mkdir -p "$d/fuzz_targets"
  printf '[package]\nname = "x-fuzz"\nversion = "0.0.0"\n[dependencies]\n%s\n' "$([ "$LIBF" = none ] || echo 'libfuzzer-sys = "0.4"')" >"$d/Cargo.toml"
  local t; for t in "$@"; do echo "fn main() {}" >"$d/fuzz_targets/$t.rs"; seed "$d" "$t"; done
}
seed() { # seed <fuzz dir> <target>: one committed seed and its floor (5 edges)
  mkdir -p "$1/corpus/$2"; echo "seed $2" >"$1/corpus/$2/seed-$2"
  [ -f "$1/coverage-floor.tsv" ] || printf 'target\tedges\n' >"$1/coverage-floor.tsv"
  printf '%s\t5\n' "$2" >>"$1/coverage-floor.tsv"
}
LIBF=yes mk_crate "$K" kernel-core x ok_parse crash_decode hang_loop buildfail_x
LIBF=none mk_crate "$K" bad x plain
LIBF=yes mk_crate "$OS" . x ok_root
# Never targets: a vendored crate and a build directory.
mkdir -p "$K/vendor/dep/fuzz/fuzz_targets" "$K/target/fuzz/fuzz_targets"
for d in "$K/vendor/dep/fuzz" "$K/target/fuzz"; do
  printf '[dependencies]\nlibfuzzer-sys = "0.4"\n' >"$d/Cargo.toml"; echo "fn main() {}" >"$d/fuzz_targets/ghost.rs"
done

# run <args...>: fuzz.sh in the fake workshop; output in $OUT, status in $RC, seconds in $SECS.
ENVX=()
run() {
  local t0=$SECONDS
  OUT=$(cd "$FX" && env -i PATH="$BIN:${PATH:-/usr/bin:/bin}" HOME="$FX" TMPDIR="$FX" SILICA_WS="$WS" \
    FAKE_FX="$FX" "${ENVX[@]+"${ENVX[@]}"}" bash "$OS/tools/fuzz.sh" "$@" 2>&1)
  RC=$?; SECS=$((SECONDS - t0))
}
run_test() { # run_test <args...>: test.sh in the fake workshop
  local t0=$SECONDS
  OUT=$(cd "$FX" && env -i PATH="$BIN:${PATH:-/usr/bin:/bin}" HOME="$FX" TMPDIR="$FX" SILICA_WS="$WS" \
    FAKE_FX="$FX" "${ENVX[@]+"${ENVX[@]}"}" bash "$OS/tools/test.sh" "$@" 2>&1)
  RC=$?; SECS=$((SECONDS - t0))
}
nerr() { printf '%s\n' "$OUT" | grep -c '^ERROR:'; }
has() { printf '%s\n' "$OUT" | grep -qE -- "$1"; }
expect() { # expect <name> <rc> <ERROR lines>
  [ "$RC" = "$2" ] || bad "$1: exit status $RC, expected $2 (output: $(printf '%s' "$OUT" | head -c 600))"
  [ "$(nerr)" = "$3" ] || bad "$1: $(nerr) ERROR lines, expected $3 (output: $(printf '%s' "$OUT" | head -c 600))"
}
F=$WS/target/fuzz
OKID='kernel/kernel-core::ok_parse'
CRID='kernel/kernel-core::crash_decode'
tree() { (cd "$WS" && find kernel os -type f -printf '%p %s\n' | sort); }

# ---- 1. discovery -------------------------------------------------------------
run --list
expect "list" 0 0
want=$'kernel/bad::plain\nkernel/kernel-core::buildfail_x\nkernel/kernel-core::crash_decode\nkernel/kernel-core::hang_loop\nkernel/kernel-core::ok_parse\nos::ok_root'
[ "$OUT" = "$want" ] || bad "list: wrong targets (vendor and target directories must be ignored): $OUT"
run --list --repo os
[ "$OUT" = "os::ok_root" ] || bad "list --repo os: $OUT"

# ---- 2. a clean run -------------------------------------------------------------
before=$(tree)
run --target "$OKID" --time 5
expect "clean run" 0 0
has "^fuzz: $OKID: ok execs=4096 cov=9 ft=12 corpus=3 floor=5 seeds=5 time=[0-9]+s\$" || bad "clean run: no coverage line: $OUT"
has '^RESULT: pass=1 fail=0 skipped=0 time=[0-9]+$' || bad "clean run: no RESULT line: $OUT"
[ "$(printf '%s\n' "$OUT" | wc -l)" -le 3 ] || bad "clean run: too much output: $OUT"
[ "$(tree)" = "$before" ] || bad "a run changed files inside a checkout"
grep -q -- "-max_total_time=5" "$RUNS" || bad "the run is not time-boxed by --time: $(cat "$RUNS")"
grep -q -- "-artifact_prefix=$F/kernel/" "$RUNS" || bad "reproducers are not stored under target/fuzz/: $(cat "$RUNS")"
grep -q -- " $F/kernel/[^ ]*/corpus " "$RUNS" || bad "the corpus is not under target/fuzz/: $(cat "$RUNS")"
grep -q "target=x86_64-unknown-linux-gnu name=ok_parse" "$BUILDS" || bad "the build does not name the host triple and the target: $(cat "$BUILDS")"
w=$(sed -n 's/^CARGO=\([^ ]*\) .*/\1/p' "$BUILDS" | head -n 1)
if [ -x "$w" ]; then
  : >"$FX/cargo.argv"; PATH="$BIN:$PATH" FAKE_FX="$FX" "$w" build -q
  grep -q -- '--config .*cargo-patch.toml --config source.vendored-sources.directory=' "$FX/cargo.argv" ||
    bad "the CARGO wrapper does not pass the patch and vendor configuration: $(cat "$FX/cargo.argv")"
else bad "cargo-fuzz was not given an executable CARGO wrapper (got '$w')"; fi
[ -f "$F/coverage.tsv" ] && grep -qP "^$OKID\t9\t12\t3\t4096\tok$" "$F/coverage.tsv" || bad "coverage.tsv has no row for the run: $(cat "$F/coverage.tsv" 2>/dev/null)"
run --report
has "^$OKID"$'\t'"9"$'\t'"12" || bad "--report does not print the coverage table: $OUT"
# the corpus persists; a checked-in seed corpus is read
mkdir -p "$K/kernel-core/fuzz/corpus/ok_parse"; echo seed >"$K/kernel-core/fuzz/corpus/ok_parse/seed1"
: >"$RUNS"
run --target ok_parse --time 5 --unit-timeout 7
expect "bare name, second run" 0 0
grep -q -- "$K/kernel-core/fuzz/corpus/ok_parse" "$RUNS" || bad "the checked-in seed corpus is not passed: $(cat "$RUNS")"
grep -q -- "-timeout=7" "$RUNS" || bad "--unit-timeout is not passed: $(cat "$RUNS")"
ls "$F"/kernel/*ok_parse/corpus | grep -q '^new-' || bad "the corpus was not kept between runs"
rm -f "$K/kernel-core/fuzz/corpus/ok_parse/seed1"

# ---- 2b. the coverage floor ------------------------------------------------------
FL=$K/kernel-core/fuzz/coverage-floor.tsv; cp "$FL" "$FX/floor.orig"
sed -i 's/^ok_parse\t5$/ok_parse\t50/' "$FL"; : >"$RUNS"
run --target ok_parse --time 5
expect "coverage drop" 1 1
has "^ERROR: fuzz: $OKID: coverage dropped: the committed seeds reach 5 edges, the floor is 50" || bad "coverage drop: wrong ERROR line: $OUT"
grep -q -- '-max_total_time' "$RUNS" && bad "coverage drop: the fuzzer ran anyway: $(cat "$RUNS")"
# --save under the floor fuzzes to win it back, keeps what it found, and fails
# without lowering the floor when the seeds still fall short
: >"$RUNS"
run --target ok_parse --time 5 --save
expect "save under the floor" 1 1
grep -q -- '-max_total_time' "$RUNS" || bad "save under the floor: the fuzzer did not run: $(cat "$RUNS")"
has "^ERROR: fuzz: $OKID: coverage dropped: after this run the committed seeds reach [0-9]* edges, still under the floor 50" || bad "save under the floor: wrong ERROR line: $OUT"
grep -qP '^ok_parse\t50$' "$FL" || bad "save under the floor: the floor was lowered: $(cat "$FL")"
ls "$K/kernel-core/fuzz/corpus/ok_parse" | grep -q '^new-' || bad "save under the floor: what the run found was not kept"
rm -f "$K"/kernel-core/fuzz/corpus/ok_parse/new-*
for f in "/^ok_parse\t/d" 's/^ok_parse\t50$/ok_parse\t0/'; do
  cp "$FX/floor.orig" "$FL"; sed -i 's/^ok_parse\t5$/ok_parse\t50/' "$FL"; sed -i "$f" "$FL"
  run --target ok_parse --time 5
  expect "no floor ($f)" 1 1
  has "^ERROR: fuzz: $OKID: no coverage floor: .*coverage-floor.tsv has no non-zero row for ok_parse" || bad "no floor ($f): wrong ERROR line: $OUT"
done
# --save keeps what the run found in the checkout and raises the floor to match
cp "$FX/floor.orig" "$FL"; sed -i '/^ok_parse\t/d' "$FL"
run --target ok_parse --time 5 --save
expect "save" 0 0
n=$(ls "$K/kernel-core/fuzz/corpus/ok_parse" | wc -l)
[ "$n" -ge 2 ] && ls "$K/kernel-core/fuzz/corpus/ok_parse" | grep -q '^new-' || bad "save: the found inputs were not merged into the committed corpus: $(ls "$K/kernel-core/fuzz/corpus/ok_parse")"
[ "$(cat "$K/kernel-core/fuzz/corpus/ok_parse/seed-ok_parse" 2>/dev/null)" = "seed ok_parse" ] || bad "save: a committed seed lost its name or content"
grep -q -- "-merge=1 .* $K/kernel-core/fuzz/corpus/ok_parse " "$RUNS" || bad "save: the merge does not go into the committed corpus itself: $(grep merge "$RUNS")"
grep -qP "^ok_parse\t$((4 + n))$" "$FL" || bad "save: the floor is not the coverage of the new seeds ($((4 + n))): $(cat "$FL")"
head -n 1 "$FL" | grep -qP '^target\tedges$' || bad "save: the floor file lost its header: $(cat "$FL")"
grep -qP '^crash_decode\t5$' "$FL" || bad "save: other targets' floors were not kept: $(cat "$FL")"
run --target ok_parse --time 5
expect "after save" 0 0
has "floor=$((4 + n)) seeds=$((4 + n)) " || bad "after save: the new floor is not checked: $OUT"
cp "$FX/floor.orig" "$FL"; rm -rf "$K/kernel-core/fuzz/corpus/ok_parse"; seed_dir=$K/kernel-core/fuzz/corpus/ok_parse
mkdir -p "$seed_dir"; echo "seed ok_parse" >"$seed_dir/seed-ok_parse"

# ---- 3. a crash: reproducer kept, replayed, retired once fixed -------------------
: >"$RUNS"
run --target "$CRID" --time 5
expect "crash" 1 1
has "^ERROR: fuzz: $CRID: crash: .*AddressSanitizer.*reproducer $F/kernel/[^ ]*/crashes/crash-deadbeef" || bad "crash: ERROR line lacks the reason or the reproducer: $OUT"
has '^RESULT: pass=0 fail=1 ' || bad "crash: RESULT: $OUT"
repro=$(ls "$F"/kernel/*crash_decode/crashes/crash-deadbeef 2>/dev/null)
[ -n "$repro" ] && grep -q CRASH "$repro" || bad "crash: the reproducer is not stored under target/fuzz/"
grep -qP "^$CRID\t7\t8\t2\t[0-9]+\tcrash$" "$F/coverage.tsv" || bad "crash: coverage row: $(cat "$F/coverage.tsv")"
: >"$RUNS"
run --target "$CRID" --time 5
expect "known crash" 1 1
has "known reproducer still fails: .*crash-deadbeef" || bad "known crash: not reported as such: $OUT"
[ "$(wc -l <"$RUNS")" = 1 ] || bad "known crash: the stored reproducer must be replayed once and the run skipped: $(cat "$RUNS")"
touch "$FX/fixed"; echo fixed >"$repro"
run --target "$CRID" --time 5
expect "fixed crash" 0 0
[ ! -e "$repro" ] || bad "fixed crash: the reproducer was not retired from crashes/"
ls "$F"/kernel/*crash_decode/corpus | grep -q 'regress-crash-deadbeef' || bad "fixed crash: the reproducer did not become a corpus regression input"
rm -f "$FX/fixed"

# ---- 4. hard time limit, build failure, invalid crate ----------------------------
ENVX=(SILICA_FUZZ_GRACE=2)
run --target kernel/kernel-core::hang_loop --time 1
ENVX=()
expect "hang" 1 1
has 'ERROR: fuzz: .*hang_loop: timeout: no exit within 3 s' || bad "hang: not reported as a timeout: $OUT"
[ "$SECS" -lt 60 ] || bad "hang: took $SECS s, the hard limit is not enforced"
: >"$RUNS"
run --target buildfail_x --time 5
expect "build failure" 1 1
has 'ERROR: fuzz: .*buildfail_x: build failed: error: could not compile' || bad "build failure: not reported: $OUT"
[ ! -s "$RUNS" ] || bad "build failure: the fuzzer ran anyway"
run --target kernel/bad::plain --time 5
expect "no libfuzzer-sys" 1 1
has 'libfuzzer-sys' || bad "no libfuzzer-sys: reason missing: $OUT"

# ---- 5. several targets, root-level crate, none at all ---------------------------
run --target ok_parse --target ok_root --time 5
expect "two targets" 0 0
has '^RESULT: pass=2 fail=0 ' && has '^fuzz: os::ok_root: ok ' || bad "two targets: $OUT"
mv "$OS/fuzz" "$FX/os-fuzz"
run --repo os
expect "no targets" 0 0
has '^fuzz: no fuzz targets in os$' && has '^RESULT: pass=0 fail=0 ' || bad "no targets: $OUT"
mv "$FX/os-fuzz" "$OS/fuzz"

# ---- 6. usage errors: one ERROR line, exit 2 -----------------------------------
for a in "--bogus" "--time 0" "--time x" "--time" "--repo nope" "--target nope" "--unit-timeout -1"; do
  run $a
  expect "usage ($a)" 2 1
done

# ---- 7. test.sh --deep runs the fuzz targets; --fast does not --------------------
: >"$RUNS"
run_test --fast --repo os
[ ! -s "$RUNS" ] && ! has '^fuzz:' || bad "--fast ran fuzz targets: $OUT"
ENVX=(SILICA_FUZZ_TIME=3)
run_test --deep --repo os
ENVX=()
[ "$RC" = 0 ] && [ "$(nerr)" = 0 ] || bad "deep: exit $RC: $OUT"
has '^fuzz: pass=1 fail=0 skipped=0$' || bad "deep: no fuzz suite line: $OUT"
has '^(deep|bench|kani): ' && bad "deep: with --repo os there is no kernel to benchmark or prove and nothing to report for either: $OUT"
grep -q -- "-max_total_time=3" "$RUNS" || bad "deep: SILICA_FUZZ_TIME is not the time box: $(cat "$RUNS")"
[ "$(printf '%s\n' "$OUT" | wc -l)" -le 30 ] || bad "deep: more than 30 lines"
echo "fn main() {}" >"$OS/fuzz/fuzz_targets/crash_root.rs"; seed "$OS/fuzz" crash_root
ENVX=(SILICA_FUZZ_TIME=3)
run_test --deep --repo os
ENVX=()
[ "$RC" != 0 ] && [ "$(nerr)" = 1 ] || bad "deep with a crash: exit $RC, $(nerr) ERROR lines: $OUT"
has '^ERROR: fuzz::os::crash_root: crash: ' || bad "deep with a crash: wrong ERROR line: $OUT"
has '^fuzz: pass=1 fail=1 skipped=0$' || bad "deep with a crash: wrong suite line: $OUT"
has '^RESULT: .* fail=1 ' || bad "deep with a crash: RESULT: $OUT"
rm -rf "$OS/fuzz/fuzz_targets/crash_root.rs" "$OS/fuzz/corpus/crash_root"; sed -i '/^crash_root\t/d' "$OS/fuzz/coverage-floor.tsv"

# A committed seed that fails is said to be one, and its reproducer is kept
# with the others under target/fuzz/, never in the checkout.
SD=$K/kernel-core/fuzz
echo SEEDCRASH >"$SD/corpus/ok_parse/seed-bad"
run --target ok_parse --time 1
[ "$RC" != 0 ] && printf '%s\n' "$OUT" | grep -q '^ERROR: fuzz: kernel/kernel-core::ok_parse: a committed seed fails: .*a seed broke it' ||
  bad "a failing seed: not said as one: $OUT"
ls "$SD" | grep -q '^crash-' && bad "a failing seed left a reproducer in the checkout: $(ls "$SD")"
find "$WS/target/fuzz" -name crash-5eed | grep -q . || bad "a failing seed's reproducer was not kept under target/fuzz"
rm -f "$SD/corpus/ok_parse/seed-bad"; find "$WS/target/fuzz" -name crash-5eed -delete

# Several targets run side by side, their lines in the order the targets were listed.
ENVX=(SILICA_FUZZ_JOBS=4)
run --target ok_parse --target ok_root --time 1
ENVX=()
[ "$(printf '%s\n' "$OUT" | grep -o '^fuzz: [^:]*::[a-z_]*' | tr '\n' ' ')" = "fuzz: kernel/kernel-core::ok_parse fuzz: os::ok_root " ] ||
  bad "side by side: lines out of order or missing: $OUT"

[ "$fails" = 0 ]
