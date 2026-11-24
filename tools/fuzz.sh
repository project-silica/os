#!/usr/bin/env bash
# Coverage-guided fuzzing of any repository (spec/TESTING.md section 3;
# test.sh --deep calls this).
#   fuzz.sh [--repo <repo>]... [--target <id|name>]... [--time <seconds>]
#           [--unit-timeout <seconds>] [--save] [--list | --report]
# A fuzz target is a cargo-fuzz target of a libfuzzer-sys crate:
#   <crate dir>/fuzz/Cargo.toml (depends on libfuzzer-sys) and
#   <crate dir>/fuzz/fuzz_targets/<name>.rs, found up to four levels deep in
#   each repository's checkout. A target is named <repo>/<crate dir>::<name>
#   (<repo>::<name> for a crate at the repository root); --target takes that id
#   or the bare name.
# Each target is built and run for --time seconds (default $SILICA_FUZZ_TIME or
# 60; the build is not part of it) with a hard limit of $SILICA_FUZZ_GRACE
# (default 120) seconds more. Nothing is written inside a checkout except by
# --save (below). Under target/fuzz/<repo>/<target>/
#   corpus/    grows from run to run; the checkout's fuzz/corpus/<name>, when
#              present, is read as seed input
#   crashes/   reproducers (crash-*, timeout-*, oom-*, leak-*). Every stored
#              reproducer is replayed before the run: one that still fails is
#              an ERROR; one that no longer fails moves into corpus/ as a
#              regression input.
#   run.log    the full libFuzzer output (build.log for the build)
# Coverage floor (spec/TESTING.md section 4.4): <crate dir>/fuzz/coverage-floor.tsv
# names each target and the edges its committed seed corpus (fuzz/corpus/<name>)
# reaches when libFuzzer loads it. That number does not depend on time or luck,
# so every run checks it before fuzzing: fewer edges than the floor, or a
# target with no floor, is an ERROR. --save merges what a clean run found into
# the committed corpus (minimized) and records its coverage as the new floor;
# commit both with the change that earned them. Under --save a corpus below
# its floor is fuzzed anyway, to win the coverage back, and the run fails if
# the merged seeds still fall short: --save never lowers a floor. A floor only
# goes down by hand, in a commit that says why.
# target/fuzz/coverage.tsv has one row per target of the last run that
# included it: id, edges covered, features, corpus size, executions, status.
# --report prints it.
# Output: one "fuzz: <id>: ok execs= cov= ft= corpus= time=" line per clean
# target, one "ERROR: fuzz: <id>: <reason>" line per failure, then
# "RESULT: pass= fail= skipped= time=". Exit 0 when every target ran clean (or
# there are none), 1 on any crash or failure, 2 on a usage error.
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"
. "$TOOLS/lib/build.sh"

repos=() targets=() secs=${SILICA_FUZZ_TIME:-60} unit=${SILICA_FUZZ_UNIT_TIMEOUT:-30} mode=run save=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || die "--repo needs a repository"; repos+=("$2"); shift 2 ;;
    --target) [ $# -ge 2 ] || die "--target needs a target"; targets+=("$2"); shift 2 ;;
    --time) [ $# -ge 2 ] || die "--time needs seconds"; secs=$2; shift 2 ;;
    --unit-timeout) [ $# -ge 2 ] || die "--unit-timeout needs seconds"; unit=$2; shift 2 ;;
    --save) save=1; shift ;;
    --list) mode=list; shift ;;
    --report) mode=report; shift ;;
    *) die "unknown argument $1" ;;
  esac
done
num() { case "$1" in '' | *[!0-9]*) return 1 ;; esac; [ "$1" -ge 1 ]; }
num "$secs" || die "--time must be a positive number of seconds, got '$secs'"
num "$unit" || die "--unit-timeout must be a positive number of seconds, got '$unit'"
grace=${SILICA_FUZZ_GRACE:-120}
num "$grace" || die "SILICA_FUZZ_GRACE must be a positive number of seconds, got '$grace'"
for r in ${repos[@]+"${repos[@]}"}; do all_repos | grep -xF "$r" >/dev/null || die "unknown repo $r"; done
[ ${#repos[@]} -gt 0 ] || mapfile -t repos < <(all_repos | awk '!s[$0]++')

FUZZ_OUT=$OUTBASE/fuzz
COV=$FUZZ_OUT/coverage.tsv

if [ "$mode" = report ]; then
  [ -f "$COV" ] || { echo "fuzz: no coverage report yet ($COV)"; exit 0; }
  cat "$COV"; exit 0
fi

# discover: "<id>\t<repo>\t<fuzz dir>\t<name>" for every target.
discover() {
  local r dir m fd crate name id f
  for r in "${repos[@]}"; do
    dir=$(checkout_of "$r")
    [ -d "$dir" ] || continue
    while IFS= read -r m; do
      fd=$(dirname "$m"); crate=$(dirname "${fd#"$dir"/}"); [ "$fd" = "$dir/fuzz" ] && crate=.
      for f in "$fd"/fuzz_targets/*.rs; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .rs)
        if [ "$crate" = . ]; then id="$r::$name"; else id="$r/$crate::$name"; fi
        printf '%s\t%s\t%s\t%s\n' "$id" "$r" "$fd" "$name"
      done
    done < <(find "$dir" -maxdepth 4 \( -name vendor -o -name target -o -name .git \) -prune -o \
      -path '*/fuzz/Cargo.toml' -type f -print 2>/dev/null | sort)
  done
}
ALL=$(discover)
if [ ${#targets[@]} -gt 0 ]; then
  SEL=""
  for t in "${targets[@]}"; do
    m=$(awk -F'\t' -v t="$t" '$1 == t || $4 == t' <<<"$ALL")
    [ -n "$m" ] || die "no fuzz target $t (see fuzz.sh --list)"
    SEL+="$m"$'\n'
  done
  ALL=$(printf '%s' "$SEL" | awk '!s[$0]++')
fi
if [ "$mode" = list ]; then
  [ -n "$ALL" ] && cut -f1 <<<"$ALL"
  exit 0
fi
if [ -z "$ALL" ]; then
  echo "fuzz: no fuzz targets in ${repos[*]}"
  echo "RESULT: pass=0 fail=0 skipped=0 time=0"
  exit 0
fi

start=$(date +%s)
pass=0 fail=0
mkdir -p "$FUZZ_OUT"
fail_line() { echo "ERROR: fuzz: $1: $2"; fail=$((fail + 1)); }
first_err() { grep -m1 -E '^(error|ERROR|Error)|panicked|assertion' "$1" | cut -c1-140; }

# coverage_row <id> <edges> <features> <corpus> <execs> <status>
coverage_row() {
  local lock; exec {lock}>>"$FUZZ_OUT/.lock"; flock "$lock"
  local tmp="$COV.$BASHPID"
  { [ -f "$COV" ] && awk -F'\t' -v id="$1" '$1 != id && $1 != "id"' "$COV"; } >"$tmp" 2>/dev/null
  { printf 'id\tedges\tfeatures\tcorpus\texecs\tstatus\n'; cat "$tmp"; printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6"; } >"$tmp.2"
  mv "$tmp.2" "$COV"; rm -f "$tmp"
  exec {lock}>&-
}

# The cargo that cargo-fuzz invokes: the checkout's patch config and a merged
# vendor directory (the library's own crates are needed for -Zbuild-std).
# cargo-fuzz takes no --config, and cargo overrides CARGO for subcommands, so
# cargo-fuzz is run directly with CARGO pointing at this wrapper.
declare -A WRAPPER=()
make_wrapper() { # make_wrapper <repo>: sets W to the wrapper path (once per repo)
  local r=$1 cache vend patch
  if [ -z "${WRAPPER[$r]:-}" ]; then
    cache=$(cache_of "$r"); mkdir -p "$cache"
    write_cargo_patch "$r" >/dev/null; patch=$cache/cargo-patch.toml
    vend=$(merged_vendor "$r")
    printf '#!/bin/sh\nexec cargo --config "%s" --config '\''source.vendored-sources.directory="%s"'\'' "$@"\n' \
      "$patch" "$vend" >"$cache/fuzz-cargo.sh"
    chmod +x "$cache/fuzz-cargo.sh"; WRAPPER[$r]=$cache/fuzz-cargo.sh
  fi
  W=${WRAPPER[$r]}
}

last_stat() { # last_stat <log>: "<edges> <features> <corpus> <execs>" from libFuzzer's output
  awk '
    match($0, /cov: [0-9]+ ft: [0-9]+ corp: [0-9]+/) {
      split(substr($0, RSTART, RLENGTH), a, " "); cov = a[2]; ft = a[4]; corp = a[6]
      if ($0 ~ /^#[0-9]+/) { e = $1; sub(/^#/, "", e); if (e + 0 > ex + 0) ex = e }
    }
    /^stat::number_of_executed_units:/ { ex = $2 }
    END { printf "%d %d %d %d\n", cov, ft, corp, ex }' "$1"
}

# inited_cov <log>: the edges libFuzzer reported once its inputs were loaded.
inited_cov() { sed -n 's/.*INITED cov: \([0-9]*\).*/\1/p' "$1" | tail -1; }
# floor_of <fuzz dir> <name>: the committed coverage floor, or nothing.
floor_of() { [ -f "$1/coverage-floor.tsv" ] && awk -F'\t' -v n="$2" '$1 == n { print $2 }' "$1/coverage-floor.tsv"; }
# seed_cov <out> <fuzz dir> <name>: edges the committed seeds reach (0 without seeds).
seed_cov() {
  local d=$2/corpus/$3 c
  rm -f "$1/seed.log"
  [ -d "$d" ] && [ -n "$(ls -A "$d")" ] || { echo 0; return; }
  # A seed that fails leaves its reproducer with the others, not in the checkout.
  fz_run "$((unit * 4 + 300))" "$1/seed.log" -runs=0 -timeout="$unit" -artifact_prefix="$1/crashes/" "$d"
  c=$(inited_cov "$1/seed.log"); echo "${c:-0}"
}

run_target() { # run_target <id> <repo> <fuzz dir> <name>
  local id=$1 repo=$2 fd=$3 name=$4 bin slug out cache tdir host san t0 rc f before new kind why cov ft corp execs
  slug=$(printf '%s' "$id" | tr '/:' '__'); out=$FUZZ_OUT/$repo/$slug
  mkdir -p "$out/corpus" "$out/crashes"
  out=$(realdir "$out")
  cache=$(cache_of "$repo"); tdir=$cache/fuzz-target; mkdir -p "$tdir"
  t0=$(date +%s)
  if ! grep -q 'libfuzzer-sys' "$fd/Cargo.toml"; then
    fail_line "$id" "$fd/Cargo.toml does not depend on libfuzzer-sys"; coverage_row "$id" 0 0 0 0 invalid; return
  fi
  make_wrapper "$repo"
  host=$(cd "$fd" && rustc -vV 2>/dev/null | sed -n 's/^host: //p')
  san=${SILICA_FUZZ_SANITIZER:-address}
  # cargo-fuzz builds the instrumented binary (cargo-fuzz run would create
  # artifact directories inside the checkout); the binary is then run
  # directly, as libFuzzer's own command line.
  fz_build() { # fz_build <log>
    (cd "$fd" && timeout -k 10 "${SILICA_FUZZ_BUILD_LIMIT:-1800}" \
      env CARGO="$W" CARGO_TARGET_DIR="$tdir" CARGO_TERM_COLOR=never RUST_BACKTRACE=1 \
      cargo-fuzz build --fuzz-dir "$fd" --target-dir "$tdir" ${host:+--target "$host"} -s "$san" "$name") </dev/null >"$1" 2>&1
  }
  fz_run() { # fz_run <hard limit> <log> <libFuzzer args...>
    local hard=$1 log=$2; shift 2
    (cd "$fd" && timeout -k 10 "$hard" \
      env RUST_BACKTRACE=1 "$bin" "$@") </dev/null >"$log" 2>&1
  }
  # 1. build (not part of the time box)
  fz_build "$out/build.log"; rc=$?
  bin=$tdir/${host:+$host/}release/$name
  if [ $rc = 0 ] && [ ! -x "$bin" ]; then rc=1; echo "ERROR: no fuzz binary $bin after the build" >>"$out/build.log"; fi
  if [ $rc != 0 ]; then
    fail_line "$id" "build failed: $(first_err "$out/build.log") (log: $out/build.log)"
    coverage_row "$id" 0 0 0 0 build-failed; return
  fi
  # 2. replay stored reproducers
  for f in "$out"/crashes/*; do
    [ -f "$f" ] || continue
    fz_run "$((unit + 60))" "$out/replay.log" "$f" -timeout="$unit"; rc=$?
    if [ $rc != 0 ]; then
      fail_line "$id" "known reproducer still fails: $f (rerun: fuzz.sh --target $id; log: $out/replay.log)"
      coverage_row "$id" 0 0 0 0 known-crash; return
    fi
    mv "$f" "$out/corpus/regress-$(basename "$f")"
  done
  # 3. the committed seeds against the committed floor
  local floor seeded
  floor=$(floor_of "$fd" "$name"); seeded=$(seed_cov "$out" "$fd" "$name")
  if [ "${floor:-0}" = 0 ] && [ "$save" = 0 ]; then
    # A floor of 0 (no committed seeds) would check nothing.
    fail_line "$id" "no coverage floor: $fd/coverage-floor.tsv has no non-zero row for $name (run fuzz.sh --target $id --save and commit the corpus and floor)"
    coverage_row "$id" "$seeded" 0 0 0 no-floor; return
  fi
  if grep -q -E '^SUMMARY: libFuzzer: |^==[0-9]+==ERROR' "$out/seed.log" 2>/dev/null; then
    why=$(grep -m1 -A1 -E 'panicked at|^==[0-9]+==ERROR|^SUMMARY' "$out/seed.log" | tr '\n' ' ' | cut -c1-160)
    fail_line "$id" "a committed seed fails: $why (log: $out/seed.log)"
    coverage_row "$id" "$seeded" 0 0 0 seed-crash; return
  fi
  if [ -n "$floor" ] && [ "$seeded" -lt "$floor" ] && [ "$save" = 0 ]; then
    fail_line "$id" "coverage dropped: the committed seeds reach $seeded edges, the floor is $floor (log: $out/seed.log)"
    coverage_row "$id" "$seeded" 0 0 0 coverage-drop; return
  fi
  # (Under --save a drop does not stop the run: fuzzing is how the corpus
  # wins it back, and step 5 accepts nothing under the floor.)
  # 4. the time-boxed run
  before=$(ls "$out/crashes")
  local seed=(); [ -d "$fd/corpus/$name" ] && seed=("$fd/corpus/$name")
  fz_run "$((secs + grace))" "$out/run.log" "$out/corpus" ${seed[@]+"${seed[@]}"} \
    -max_total_time="$secs" -artifact_prefix="$out/crashes/" -timeout="$unit" -print_final_stats=1; rc=$?
  read -r cov ft corp execs <<<"$(last_stat "$out/run.log")"
  new=$(comm -13 <(printf '%s\n' "$before") <(ls "$out/crashes"))
  if [ -n "$new" ]; then
    while IFS= read -r f; do
      kind=${f%%-*}
      why=$(grep -m1 -E 'ERROR: (AddressSanitizer|LeakSanitizer|libFuzzer)|panicked at|deadly signal' "$out/run.log" | cut -c1-140)
      fail_line "$id" "$kind: ${why:-see log}; reproducer $out/crashes/$f (rerun: fuzz.sh --target $id; log: $out/run.log)"
    done <<<"$new"
    coverage_row "$id" "$cov" "$ft" "$corp" "$execs" crash; return
  fi
  if [ $rc = 124 ] || [ $rc = 137 ]; then
    fail_line "$id" "timeout: no exit within $((secs + grace)) s (log: $out/run.log)"
    coverage_row "$id" "$cov" "$ft" "$corp" "$execs" timeout; return
  fi
  if [ $rc != 0 ]; then
    fail_line "$id" "fuzzer exited with status $rc and no reproducer: $(first_err "$out/run.log") (log: $out/run.log)"
    coverage_row "$id" "$cov" "$ft" "$corp" "$execs" failed; return
  fi
  if [ "$save" = 1 ]; then
    # 5. keep what this run found: every committed seed stays, under its own
    # name (regression inputs are named and tests include them), and only
    # found inputs that add coverage are added. Its coverage is the floor.
    local seeds=$fd/corpus/$name
    mkdir -p "$seeds"
    if ! fz_run "$((secs + grace))" "$out/merge.log" -merge=1 -timeout="$unit" "$seeds" "$out/corpus"; then
      fail_line "$id" "merge into $seeds failed (log: $out/merge.log)"; coverage_row "$id" "$cov" "$ft" "$corp" "$execs" failed; return
    fi
    seeded=$(seed_cov "$out" "$fd" "$name")
    # The floor never goes down here: that is a hand edit in a commit that
    # says why. The merged corpus stays (it only adds inputs).
    if [ -n "$floor" ] && [ "$seeded" -lt "$floor" ]; then
      fail_line "$id" "coverage dropped: after this run the committed seeds reach $seeded edges, still under the floor $floor (the corpus keeps what was found: fuzz longer; log: $out/seed.log)"
      coverage_row "$id" "$seeded" "$ft" "$corp" "$execs" coverage-drop; return
    fi
    # Targets of one crate share its floor file: one writer at a time.
    local lock; exec {lock}>>"$FUZZ_OUT/.lock"; flock "$lock"
    { [ -f "$fd/coverage-floor.tsv" ] && awk -F'\t' -v n="$name" '$1 != n && $1 != "target"' "$fd/coverage-floor.tsv"
      printf '%s\t%s\n' "$name" "$seeded"; } | sort >"$out/floor.tsv"
    { printf 'target\tedges\n'; cat "$out/floor.tsv"; } >"$fd/coverage-floor.tsv"
    exec {lock}>&-
    floor=$seeded
  fi
  echo "fuzz: $id: ok execs=$execs cov=$cov ft=$ft corpus=$corp floor=$floor seeds=$seeded time=$(($(date +%s) - t0))s"
  pass=$((pass + 1))
  coverage_row "$id" "$cov" "$ft" "$corp" "$execs" ok
}

# Targets run side by side (each libFuzzer process uses one processor), at
# most $SILICA_FUZZ_JOBS at once (default half the processors); each one's
# lines are printed together, in the order the targets were listed.
jobs_max=${SILICA_FUZZ_JOBS:-$(($(nproc) / 2))}
num "$jobs_max" || jobs_max=1
# Each repository's cargo wrapper is written once, before any target runs.
for r in $(cut -f2 <<<"$ALL" | sort -u); do make_wrapper "$r"; done
lines=$(mktemp -d "$FUZZ_OUT/.lines.XXXXXX")
n=0
while IFS=$'\t' read -r id repo fd name; do
  while [ "$(jobs -rp | wc -l)" -ge "$jobs_max" ]; do wait -n; done
  run_target "$id" "$repo" "$fd" "$name" >"$lines/$n" 2>&1 &
  n=$((n + 1))
done <<<"$ALL"
wait
for ((i = 0; i < n; i++)); do cat "$lines/$i"; done
pass=$(cat "$lines"/* | grep -c '^fuzz: .*: ok ')
fail=$(cat "$lines"/* | grep -c '^ERROR: fuzz: ')
rm -rf -- "$lines"
echo "RESULT: pass=$pass fail=$fail skipped=0 time=$(($(date +%s) - start))"
[ "$fail" = 0 ]
