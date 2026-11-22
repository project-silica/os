#!/usr/bin/env bash
# Budget test for tools/test.sh --fast (component A02): the fast tier stays
# under a minute when every check of it runs, which is why the tool
# self-tests run only in --full and --deep.
# Runs this tool suite's test.sh --fast --fresh on the workshop (nothing read
# back from the evidence store: a held check takes no time and proves
# nothing about the budget) and fails if its RESULT time is 60 or more, or
# if --fast prints an os.tools suite line. The builds are warm: the full
# tier this runs in has built everything. A time is only worth judging on a
# host doing nothing else, so test.sh runs this one by itself.
# Full output goes to target/logs (or $SILICA_RUN).
# inputs: system
# alone
set -uo pipefail
SRC=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd -P)
BASE=${SILICA_RUN:-${TMPDIR:-/tmp}}; mkdir -p "$BASE"
OUTDIR=$(mktemp -d "$BASE/fastbudget.XXXX") || { echo "ERROR: fast-budget: no scratch directory"; exit 2; }
fails=0
bad() { echo "ERROR: fast-budget: $1"; fails=$((fails + 1)); }

bash "$SRC/test.sh" --fast --fresh >"$OUTDIR/run.log" 2>&1
rc=$?
if [ "$rc" != 0 ]; then bad "the run exited $rc: $(grep -m1 ^ERROR "$OUTDIR/run.log")"; fi
res=$(grep -E '^RESULT: ' "$OUTDIR/run.log" | tail -n 1)
t=$(printf '%s\n' "$res" | sed -n 's/.* time=\([0-9][0-9]*\)$/\1/p')
if [ -z "$t" ]; then
  bad "the --fast run printed no RESULT time ($(grep -m1 -E '^ERROR' "$OUTDIR/run.log" | cut -c1-160))"
elif [ "$t" -ge 60 ]; then
  bad "the --fast run took time=$t, want under 60 ($res; log: $OUTDIR/run.log)"
fi
l=$(grep -m1 -E '^os\.tools: ' "$OUTDIR/run.log")
[ -z "$l" ] || bad "--fast printed an os.tools suite line: $l"
if [ "$fails" = 0 ]; then
  echo "fast-budget: ok ($res)"
  rm -rf "${OUTDIR:?}"
fi
exit $((fails > 0))
