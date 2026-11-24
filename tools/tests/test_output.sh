#!/usr/bin/env bash
# Test for tools/test.sh tiers and output rules (component A02). Runs a private copy of the tool suite
# inside a disposable fake workshop (fake os repository), so nothing real is built, booted or changed and the
# test cannot recurse into the real test.sh. One "ERROR:" line per failed check.
set -uo pipefail
SRC=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd -P)
BASE=${SILICA_RUN:-${TMPDIR:-/tmp}}; mkdir -p "$BASE"
FX=$(mktemp -d "$BASE/outtest.XXXX") || exit 2
trap 'rm -rf "$FX"' EXIT
fails=0
bad() { echo "ERROR: output-test: $1"; fails=$((fails + 1)); }

WS=$FX/ws
OS=$WS/os
mkdir -p "$FX/bin" "$OS/tools/tests"
echo x >"$WS/bootstrap.pins"
# The unsafe check's table, listing nothing: the fixture has no unsafe code.
mkdir -p "$WS/spec" && printf '| Repo | Path | Why |\n| --- | --- | --- |\n' >"$WS/spec/UNSAFE_MODULES.md"
echo 0 >"$WS/MILESTONE"
# Private copy of the tool suite under test (the files test.sh reads).
cp -r "$SRC/lib" "$SRC/test.sh" "$SRC/size.sh" "$SRC/qemu.sh" "$OS/tools/"
printf '# fake manifest: no repositories besides os\n' >"$OS/manifest.toml"

T=$OS/tools/tests
printf '#!/bin/bash\necho fine\nexit 0\n' >"$T/pass_a.sh"
printf '#!/bin/bash\nexit 0\n' >"$T/pass_b.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.invalid
(cd "$OS" && git init -q . && git add -A && git commit -qm fake) ||
  { echo "ERROR: output-test: cannot create the fake os repository"; exit 2; }

# run <args...>: test.sh from the fake os; output in $OUT, status in $RC, seconds in $SECS.
run() {
  local t0=$SECONDS
  OUT=$(cd "$FX" && env -i PATH="$FX/bin:${PATH:-/usr/bin:/bin}" HOME="$FX" TMPDIR="$FX" \
    SILICA_WS="$WS" \
    bash "$OS/tools/test.sh" "$@" 2>&1)
  RC=$?; SECS=$((SECONDS - t0))
}
nlines() { printf '%s\n' "$OUT" | wc -l; }
errs() { printf '%s\n' "$OUT" | grep -c '^ERROR:'; }
last() { printf '%s\n' "$OUT" | tail -n 1; }
has() { printf '%s\n' "$OUT" | grep -qE -- "$1"; }
# Every line must be a suite summary, an ERROR line or the RESULT line.
shape() { # shape <case>
  local l seen=" " s
  while IFS= read -r l; do
    case "$l" in
      RESULT:*) ;;
      ERROR:*) ;;
      "test: ran "*" checks ("*" s of work), held "*) ;;   # what ran and what was held
      *)
        printf '%s\n' "$l" | grep -qE '^[A-Za-z0-9_.-]+: pass=[0-9]+ fail=[0-9]+ skipped=[0-9]+$' ||
          { bad "$1: line is neither a suite summary, ERROR nor RESULT: $l"; continue; }
        s=${l%%:*}
        case "$seen" in *" $s "*) bad "$1: more than one summary line for suite $s" ;; esac
        seen+="$s " ;;
    esac
  done <<<"$OUT"
  printf '%s\n' "$OUT" | grep -qE '^RESULT: pass=[0-9]+ fail=[0-9]+ skipped=[0-9]+ time=[0-9]+$' || bad "$1: no well-formed RESULT line: $OUT"
  [ "$(last | cut -c1-7)" = "RESULT:" ] || bad "$1: RESULT is not the final line: $(last)"
}

# ---- 1. green --fast run: summary lines, no ERROR, RESULT last, exit 0 --------
run --fast --repo os
[ "$RC" = 0 ] || bad "green: exit $RC, want 0: $OUT"
[ "$(errs)" = 0 ] || bad "green: unexpected ERROR: $OUT"
[ "$(nlines)" -le 30 ] || bad "green: $(nlines) lines, want at most 30"
has '^os\.tools:' && bad "fast ran harness tests: $OUT"
has '^size: pass=1 fail=0 skipped=0$' || bad "green: no size summary line: $OUT"
has '^RESULT: pass=1 fail=0 skipped=0 time=[0-9]+$' || bad "green: RESULT is not pass=3 fail=0 skipped=0: $(last)"
shape green
[ "$SECS" -lt 60 ] || bad "green: --fast took $SECS s, want under 60"
run; [ "$RC" = 0 ] && has '^RESULT: pass=3 ' && has '^unsafe: pass=1 fail=0 skipped=0$' && has '^no_python: pass=1 fail=0 skipped=0$' || bad "green: bare test.sh does not default to --fast: $OUT"

# ---- 2. one deliberately failing test: exactly one ERROR line, non-zero exit --
printf '#!/bin/bash\necho "assertion failed: boom"\nexit 1\n' >"$T/fail_x.sh"
run --full --repo os
[ "$RC" != 0 ] || bad "fail: exit 0 with a failing test"
[ "$(errs)" = 1 ] || bad "fail: want exactly one ERROR line, got $(errs): $OUT"
has '^ERROR: os\.tools::tools/tests/fail_x\.sh: .*boom' || bad "fail: ERROR line is not 'ERROR: <suite>::<test>: <reason>' with the reason: $OUT"
has '^os\.tools: pass=2 fail=1 skipped=0$' || bad "fail: summary line does not count the failure: $OUT"
has '^RESULT: pass=3 fail=1 skipped=0 time=[0-9]+$' || bad "fail: RESULT line wrong: $(last)"
shape fail
logs=$(grep -Rl boom "$WS/target/logs/os.tools" 2>/dev/null | head -1)
[ -n "$logs" ] || bad "fail: no details under target/logs/os.tools/ containing the test output"
case "$logs" in *fail_x.sh.log) ;; *) bad "fail: log file is not named after the test: $logs" ;; esac

# a failing test that prints nothing, and one that prints a lot: still one ERROR line each
printf '#!/bin/bash\nexit 3\n' >"$T/fail_x.sh"
run --full --repo os
[ "$RC" != 0 ] && [ "$(errs)" = 1 ] || bad "silent failure: want one ERROR and non-zero exit, got $(errs) (exit $RC): $OUT"
printf '#!/bin/bash\nfor i in $(seq 1 200); do echo "ERROR: noise $i"; done\nexit 1\n' >"$T/fail_x.sh"
run --full --repo os
[ "$RC" != 0 ] && [ "$(errs)" = 1 ] || bad "noisy failure: want one ERROR line on stdout, got $(errs) (exit $RC)"
[ "$(nlines)" -le 30 ] || bad "noisy failure: $(nlines) lines on stdout, want at most 30"
[ "$(grep -c noise "$WS/target/logs/os.tools/tools_tests_fail_x.sh.log" 2>/dev/null)" -ge 200 ] || bad "noisy failure: full output not kept under target/logs"
rm -f "$T/fail_x.sh"

# ---- 3. many passing tests: still one summary line, at most 30 lines ---------
for i in $(seq 1 45); do printf '#!/bin/bash\nexit 0\n' >"$T/many_$i.sh"; done
run --full --repo os
[ "$RC" = 0 ] && [ "$(nlines)" -le 30 ] || bad "many: exit $RC, $(nlines) lines (want 0 and at most 30)"
has '^os\.tools: pass=47 fail=0 skipped=0$' || bad "many: summary line wrong: $OUT"
shape many
# several failures: one ERROR line each, sorted out per test
for i in 1 2 3; do printf '#!/bin/bash\necho "assertion failed: f%s"\nexit 1\n' "$i" >"$T/many_$i.sh"; done
run --full --repo os
[ "$(errs)" = 3 ] || bad "many failures: want 3 ERROR lines, got $(errs): $OUT"
for i in 1 2 3; do has "^ERROR: os\\.tools::tools/tests/many_$i\\.sh: .*f$i" || bad "many failures: no ERROR for many_$i: $OUT"; done
has '^RESULT: pass=45 fail=3 ' || bad "many failures: RESULT wrong: $(last)"
rm -f "$T"/many_*.sh

# ---- 6. tiers: --full and --deep accepted; the fixture is not part of --fast --
printf '#!/bin/bash\necho "assertion failed: fixture"\nexit 1\n' >"$T/fixture.sh"
run --fast --repo os
[ "$RC" = 0 ] && ! has fixture || bad "fast: the slow fixture must not run in --fast: $OUT"
run --full --repo os
[ "$RC" != 0 ] && [ "$(errs)" = 1 ] && has 'fixture\.sh' || bad "full: --full must run the fixture, got $(errs) ERROR (exit $RC): $OUT"
rm -f "$T/fixture.sh"
run --full --repo os
[ "$RC" = 0 ] && [ "$(errs)" = 0 ] && has '^RESULT: pass=3 fail=0 skipped=0 ' || bad "full: green --full run wrong (exit $RC): $OUT"
shape full
run --deep --repo os
[ "$RC" = 0 ] && [ "$(errs)" = 0 ] || bad "deep: exit $RC: $OUT"
has '^(deep|bench|kani): ' && bad "deep: with --repo os there is nothing to benchmark or prove and nothing to report for either: $OUT"
[ "$(nlines)" -le 30 ] || bad "deep: $(nlines) lines, want at most 30"
shape deep

# ---- 7. an unknown argument or repository fails with one ERROR line ----------
run --bogus
[ "$RC" != 0 ] && [ "$(errs)" = 1 ] || bad "bogus: want one ERROR and non-zero exit, got $(errs) (exit $RC): $OUT"
run --fast --repo nosuchrepo
[ "$RC" != 0 ] && [ "$(errs)" = 1 ] || bad "repo: unknown repository must be one ERROR, got $(errs) (exit $RC): $OUT"

[ $fails = 0 ] && echo "test-output-test: ok"
exit $((fails > 0))
