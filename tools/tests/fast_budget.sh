#!/usr/bin/env bash
# Budget test for tools/test.sh --fast (feature A02.02;
# spec/adr/0007-harness-self-tests-are-t2.md, spec/TESTING.md section 1).
# Runs this tool suite's test.sh --fast twice on the workshop, with the os
# checkout that holds this test (other overrides pass through
# SILICA_CHECKOUTS when the environment carries them), and fails if the second run's
# RESULT time is 60 or more, or if --fast prints an os.tools suite line.
# The first run only warms the build caches; its time is not judged.
# Full output of each run goes to target/logs (or $SILICA_RUN).
set -uo pipefail
SRC=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd -P)
OSDIR=$(cd "$SRC/.." && pwd -P)
BASE=${SILICA_RUN:-${TMPDIR:-/tmp}}; mkdir -p "$BASE"
OUTDIR=$(mktemp -d "$BASE/fastbudget.XXXX") || { echo "ERROR: fast-budget: no scratch directory"; exit 2; }
fails=0
bad() { echo "ERROR: fast-budget: $1"; fails=$((fails + 1)); }

for n in 1 2; do
  bash "$SRC/test.sh" --fast --checkout os "$OSDIR" >"$OUTDIR/run$n.log" 2>&1
  rc=$?
  if [ "$rc" != 0 ]; then bad "run $n exited $rc: $(grep -m1 ^ERROR "$OUTDIR/run$n.log")"; fi
done
res=$(grep -E '^RESULT: ' "$OUTDIR/run2.log" | tail -n 1)
t=$(printf '%s\n' "$res" | sed -n 's/.* time=\([0-9][0-9]*\)$/\1/p')
if [ -z "$t" ]; then
  bad "second --fast run printed no RESULT time ($(grep -m1 -E '^ERROR' "$OUTDIR/run2.log" | cut -c1-160))"
elif [ "$t" -ge 60 ]; then
  bad "second --fast run took time=$t, want under 60 ($res; log: $OUTDIR/run2.log)"
fi
for n in 1 2; do
  l=$(grep -m1 -E '^os\.tools: ' "$OUTDIR/run$n.log")
  [ -z "$l" ] || bad "--fast run $n printed an os.tools suite line: $l"
done
if [ "$fails" = 0 ]; then
  echo "fast-budget: ok ($res)"
  rm -rf "${OUTDIR:?}"
fi
exit $((fails > 0))
