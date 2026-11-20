#!/usr/bin/env bash
# Test for tools/ci.sh (component A08, feature A08.01; spec/CI_RELEASE.md
# section 2): the fast tier runs test.sh --fast and check-deps.sh, the nightly
# tier runs test.sh --deep, both exactly the commands the hosted lanes run;
# every step runs even when an earlier one failed; failures keep their ERROR
# lines, full output goes to target/logs/ci/; usage errors exit 2.
#
# Runs a private copy of ci.sh in a disposable fake workshop whose test.sh and
# check-deps.sh record how they were called. One "ERROR:" line per failed check.
set -uo pipefail
SRC=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd -P)
BASE=${SILICA_RUN:-${TMPDIR:-/tmp}}; mkdir -p "$BASE"
FX=$(mktemp -d "$BASE/citest.XXXX") || exit 2
FX=$(cd "$FX" && pwd -P)
trap 'rm -rf "${FX:?}"' EXIT
fails=0
bad() { echo "ERROR: ci-test: $1"; fails=$((fails + 1)); }

WS=$FX/ws; OS=$WS/os; CALLS=$FX/calls.log
mkdir -p "$WS/state" "$OS/tools" "$WS/target"
echo x >"$WS/bootstrap.pins"; echo 0 >"$WS/MILESTONE"
printf '[repos.kernel]\nurl = "https://example.invalid/kernel"\nmilestone = 0\ncommit = "x"\n' >"$OS/manifest.toml"
git init -q "$OS" || exit 2
git init -q "$WS/kernel" || exit 2
cp -r "$SRC/lib" "$SRC/ci.sh" "$OS/tools/"
: >"$CALLS"

# Fakes: record the arguments and the checkout list, then behave as told by
# FAKE_TEST_RC / FAKE_DEPS_RC (default 0) and FAKE_TEST_SLEEP.
cat >"$OS/tools/test.sh" <<'EOF2'
#!/bin/bash
echo "test.sh $* | checkouts=$(printf '%s' "${SILICA_CHECKOUTS:-}" | tr '\n' ' ') | fuzz=${SILICA_FUZZ_TIME:-}" >>"$FAKE_FX/calls.log"
sleep "${FAKE_TEST_SLEEP:-0}"
echo "os.tools: pass=3 fail=0 skipped=0"
if [ "${FAKE_TEST_RC:-0}" != 0 ]; then echo "ERROR: os.tools::tools/tests/x.sh: boom in test"; echo "RESULT: pass=3 fail=1 skipped=0 time=1"; exit 1; fi
echo "RESULT: pass=3 fail=0 skipped=0 time=1"
EOF2
cat >"$OS/tools/check-deps.sh" <<'EOF2'
#!/bin/bash
echo "check-deps.sh $* | checkouts=$(printf '%s' "${SILICA_CHECKOUTS:-}" | tr '\n' ' ')" >>"$FAKE_FX/calls.log"
if [ "${FAKE_DEPS_RC:-0}" != 0 ]; then echo "ERROR: check-deps: kernel/x depends on os/y"; exit 1; fi
echo "CHECK-DEPS: OK"
EOF2
chmod +x "$OS/tools/test.sh" "$OS/tools/check-deps.sh"

ENVX=()
run() { # run <args...>: output in $OUT, status in $RC
  : >"$CALLS"
  OUT=$(cd "$FX" && env -i PATH="${PATH:-/usr/bin:/bin}" HOME="$FX" TMPDIR="$FX" SILICA_WS="$WS" FAKE_FX="$FX" \
    "${ENVX[@]+"${ENVX[@]}"}" bash "$OS/tools/ci.sh" "$@" 2>&1)
  RC=$?
}
calls() { sed 's/ | .*//' "$CALLS"; }

# 1. fast, everything green.
run fast
[ $RC = 0 ] || bad "fast green: exit $RC, want 0"
[ "$(calls)" = $'test.sh --fast\ncheck-deps.sh ' ] || bad "fast runs test.sh --fast then check-deps.sh, got: $(calls | tr '\n' ';')"
grep -q -- '--deep' "$CALLS" && bad "fast must not run --deep"
grep -q '^ERROR:' <<<"$OUT" && bad "fast green prints an ERROR line"
grep -qi 'fast' <<<"$OUT" || bad "fast green output does not name the tier"
[ "$(wc -l <<<"$OUT")" -le 12 ] || bad "fast green output is long ($(wc -l <<<"$OUT") lines)"
ls "$WS"/target/logs/ci/* >/dev/null 2>&1 || bad "no logs under target/logs/ci/"
grep -rq 'os.tools: pass=3' "$WS"/target/logs/ci/ 2>/dev/null || bad "step output is not kept in target/logs/ci/"

# 2. fast, the tests fail: the ERROR line shows, check-deps still runs, exit 1.
ENVX=(FAKE_TEST_RC=1); run fast; ENVX=()
[ $RC = 1 ] || bad "fast with failing tests: exit $RC, want 1"
grep -q '^ERROR: os.tools::tools/tests/x.sh: boom in test$' <<<"$OUT" || bad "failing test ERROR line not relayed"
[ "$(calls)" = $'test.sh --fast\ncheck-deps.sh ' ] || bad "fast stopped after failing tests, got: $(calls | tr '\n' ';')"

# 3. fast, the dependency check fails.
ENVX=(FAKE_DEPS_RC=1); run fast; ENVX=()
[ $RC = 1 ] || bad "fast with failing check-deps: exit $RC, want 1"
grep -q '^ERROR: check-deps: kernel/x depends on os/y$' <<<"$OUT" || bad "check-deps ERROR line not relayed"

# 4. both fail: both errors, exit 1.
ENVX=(FAKE_TEST_RC=1 FAKE_DEPS_RC=1); run fast; ENVX=()
[ $RC = 1 ] && [ "$(grep -c '^ERROR:' <<<"$OUT")" -ge 2 ] || bad "both failing: want exit 1 and two ERROR lines, got exit $RC"

# 5. nightly: test.sh --deep only.
run nightly
[ $RC = 0 ] || bad "nightly green: exit $RC, want 0"
[ "$(calls)" = 'test.sh --deep' ] || bad "nightly runs test.sh --deep only, got: $(calls | tr '\n' ';')"
ENVX=(FAKE_TEST_RC=1); run nightly; ENVX=()
[ $RC = 1 ] && grep -q '^ERROR: os.tools::tools/tests/x.sh: boom in test$' <<<"$OUT" || bad "nightly with failing tests: want exit 1 and the ERROR line, got exit $RC"
ENVX=(SILICA_FUZZ_TIME=7); run nightly; ENVX=()
grep -q 'fuzz=7' "$CALLS" || bad "SILICA_FUZZ_TIME does not reach test.sh --deep"

# 6. --repo goes to test.sh only; --checkout reaches both steps.
run fast --repo kernel --checkout kernel "$WS/kernel"
[ $RC = 0 ] || bad "fast --repo kernel --checkout: exit $RC; $OUT"
grep -q '^test.sh --fast --repo kernel | checkouts=kernel='"$WS"'/kernel ' "$CALLS" || bad "test.sh did not get --repo kernel and the checkout: $(cat "$CALLS")"
grep -q '^check-deps.sh  | checkouts=kernel='"$WS"'/kernel ' "$CALLS" || bad "check-deps.sh did not get the checkout or got extra arguments: $(cat "$CALLS")"
run nightly --repo kernel
grep -q '^test.sh --deep --repo kernel ' "$CALLS" || bad "nightly --repo not passed: $(cat "$CALLS")"

# 7. the pre-merge budget is reported, not enforced.
ENVX=(FAKE_TEST_SLEEP=2 SILICA_CI_FAST_BUDGET=1); run fast; ENVX=()
[ $RC = 0 ] || bad "slow fast tier: exit $RC, want 0 (budget overrun is a warning)"
grep -q '^WARNING: ci: .*budget' <<<"$OUT" || bad "no budget WARNING line for a slow fast tier"
run fast
grep -q 'WARNING' <<<"$OUT" && bad "budget WARNING on a fast run"

# 8. usage errors: exit 2, one ERROR line, nothing run.
for args in "" "weekly" "fast nightly" "fast --bogus" "fast --repo"; do
  # shellcheck disable=SC2086
  run $args
  [ $RC = 2 ] || bad "usage '$args': exit $RC, want 2"
  grep -q '^ERROR: ci: ' <<<"$OUT" || bad "usage '$args': no ERROR: ci: line"
  [ ! -s "$CALLS" ] || bad "usage '$args': a step ran"
done

# 9. a missing step tool is a failure, not a silent pass.
mv "$OS/tools/check-deps.sh" "$FX/cd.sh"
run fast
[ $RC = 1 ] && grep -q '^ERROR: ci: ' <<<"$OUT" || bad "missing check-deps.sh: want exit 1 and an ERROR: ci: line, got exit $RC"
mv "$FX/cd.sh" "$OS/tools/check-deps.sh"

[ $fails = 0 ] && echo "ci-test: OK"
exit $((fails > 0))
