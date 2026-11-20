#!/usr/bin/env bash
# Runs locally exactly what the hosted lanes run (spec/CI_RELEASE.md section 2),
# so local and hosted results match. The hosted workflows call this script.
#   ci.sh fast    [--repo <repo>] [--checkout <repo> <absolute-dir>]...
#   ci.sh nightly [--repo <repo>] [--checkout <repo> <absolute-dir>]...
# fast (pre-merge): test.sh --fast, then check-deps.sh. Both always run.
# nightly:          test.sh --deep ($SILICA_FUZZ_TIME passes through).
# --repo limits the test suites to one repository (the dependency check always
# looks at every repository). Full output of each step goes to
# target/logs/ci/<tier>.<step>.log; this script prints one status line per step,
# the steps' ERROR lines and a final "CI: <tier> OK|FAILED" line. The pre-merge
# lane has a wall-clock budget ($SILICA_CI_FAST_BUDGET seconds, default 300);
# going over it is a WARNING line, not a failure.
# Exit 0 when every step passed, 1 when any step failed, 2 on a usage error.
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"
parse_checkouts "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"

tier="" repo=""
while [ $# -gt 0 ]; do
  case "$1" in
    fast | nightly)
      [ -z "$tier" ] || die "one tier only ($tier and $1)"
      tier=$1; shift ;;
    --repo) [ $# -ge 2 ] || die "--repo needs a repository"; repo=$2; shift 2 ;;
    *) die "unknown argument $1 (usage: ci.sh fast|nightly [--repo <repo>] [--checkout <repo> <dir>]...)" ;;
  esac
done
[ -n "$tier" ] || die "usage: ci.sh fast|nightly [--repo <repo>] [--checkout <repo> <dir>]..."

fails=0
step() { # step <name> <command...>: runs it, logs everything, prints status and its ERROR lines
  local name=$1 log rc t0=$SECONDS; shift
  mkdir -p "$LOGS/ci"; log=$LOGS/ci/$tier.$name.log
  if [ ! -x "$1" ]; then
    err "$name: $1 is missing or not executable"; echo "ci: $tier: $name: FAILED"; fails=$((fails + 1)); return
  fi
  "$@" >"$log" 2>&1; rc=$?
  if [ $rc = 0 ]; then
    echo "ci: $tier: $name: ok ($((SECONDS - t0))s)"
  else
    echo "ci: $tier: $name: FAILED status $rc ($((SECONDS - t0))s, log: $log)"
    grep '^ERROR:' "$log" | head -n 40
    grep -q '^ERROR:' "$log" || err "$name failed with status $rc and no ERROR line (log: $log)"
    fails=$((fails + 1))
  fi
}

start=$SECONDS
case "$tier" in
  fast)
    step test "$TOOLS/test.sh" --fast ${repo:+--repo "$repo"}
    step deps "$TOOLS/check-deps.sh"
    budget=${SILICA_CI_FAST_BUDGET:-300}
    if [ $((SECONDS - start)) -gt "$budget" ]; then
      echo "WARNING: ci: the fast tier took $((SECONDS - start))s, over the ${budget}s pre-merge budget (spec/CI_RELEASE.md section 2)"
    fi ;;
  nightly)
    step test "$TOOLS/test.sh" --deep ${repo:+--repo "$repo"} ;;
esac

if [ $fails = 0 ]; then echo "CI: $tier OK ($((SECONDS - start))s)"; else echo "CI: $tier FAILED ($((SECONDS - start))s)"; fi
[ $fails = 0 ]
