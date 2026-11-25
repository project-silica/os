#!/usr/bin/env bash
# inputs: idl
# Change a shipped method's ordinal, then remove its protocol altogether.
set -eu
tools=$(cd "$(dirname "$0")/.." && pwd -P)
ws=${SILICA_WS:-$(cd "$tools/../.." && pwd -P)}
scratch=$(mktemp -d "${SILICA_RUN:-$ws/target}/protocol-compat.XXXXXX")
trap 'rm -rf "${scratch:?}"' EXIT
SILICA_WS=$ws bash "$tools/test.sh" --fast --repo idl --plan --fresh >"$scratch/plan"
grep -q '^plan: idl.compat:' "$scratch/plan" || { echo "ERROR: IDL pre-merge tier omitted compatibility"; exit 1; }
git clone -q --local "$ws/idl" "$scratch/idl"
cp "$ws/bootstrap.pins" "$scratch/"
terminal=protocols/silica/console/terminal.idl
pin=$(awk '$1 == "idl" {print $2}' "$scratch/bootstrap.pins")
git -C "$scratch/idl" show "$pin:$terminal" >"$scratch/terminal.idl"
check() { SILICA_WS=$scratch bash "$tools/check-protocols.sh" >"$scratch/result" 2>&1; }
check || { cat "$scratch/result"; exit 1; }
sed 's/write @1 (/write @99 (/' "$scratch/terminal.idl" >"$scratch/idl/$terminal"
if check || ! grep -q 'ordinal' "$scratch/result"; then
  cat "$scratch/result"; echo "ERROR: a changed terminal write ordinal was not diagnosed"; exit 1
fi
rm "$scratch/idl/$terminal"
if check || ! grep -q 'terminal.idl' "$scratch/result"; then
  cat "$scratch/result"; echo "ERROR: a missing shipped terminal protocol was not diagnosed"; exit 1
fi
echo "protocol compatibility regression: OK"
