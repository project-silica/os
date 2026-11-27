#!/usr/bin/env bash
# inputs: idl
# Change a shipped method's ordinal, then remove its protocol altogether;
# retire the protocol by reserving every method, then, with that pinned,
# give its ordinals new methods.
set -eu
tools=$(cd "$(dirname "$0")/.." && pwd -P)
ws=${SILICA_WS:-$(cd "$tools/../.." && pwd -P)}
scratch=$(mktemp -d "${SILICA_RUN:-$ws/target}/protocol-compat.XXXXXX")
trap 'rm -rf "${scratch:?}"' EXIT
SILICA_WS=$ws bash "$tools/test.sh" --fast --repo idl --plan --fresh >"$scratch/plan"
grep -q '^plan: idl.compat:' "$scratch/plan" || { echo "ERROR: IDL pre-merge tier omitted compatibility"; exit 1; }
git clone -q --local "$ws/idl" "$scratch/idl"
cp "$ws/bootstrap.pins" "$ws/MILESTONE" "$scratch/"
terminal=protocols/silica/console/terminal.idl
pin=$(awk '$1 == "idl" {print $2}' "$scratch/bootstrap.pins")
git -C "$scratch/idl" show "$pin:$terminal" >"$scratch/terminal.idl"
check() { SILICA_WS=$scratch bash "$tools/check-protocols.sh" >"$scratch/result" 2>&1; }
check || { cat "$scratch/result"; exit 1; }
sed 's/write @1 (/write @99 (/' "$scratch/terminal.idl" >"$scratch/idl/$terminal"
if check || ! grep -q 'ordinal' "$scratch/result"; then
  cat "$scratch/result"; echo "ERROR: a changed terminal write ordinal was not diagnosed"; exit 1
fi
# A published protocol's file stays, even while protocols are provisional:
# with it gone its ordinals are free for anyone to give other methods.
rm "$scratch/idl/$terminal"
if check || ! grep -q 'terminal.idl' "$scratch/result"; then
  cat "$scratch/result"; echo "ERROR: a missing shipped terminal protocol was not diagnosed"; exit 1
fi
# Retired whole before M9: every method reserved at its ordinal, the
# version raised, the file kept.
awk '
  /^protocol / { sub(/version [0-9]+/, "version 99") }
  match($0, /^ *[a-z_]+ @[0-9]+ \(/) { n = $0; sub(/^ *[a-z_]+ @/, "", n); sub(/ .*/, "", n); print "    reserved @" n ";"; skip = ($0 !~ /;[ ]*$/); next }
  skip { if ($0 ~ /;[ ]*$/) skip = 0; next }
  { print }' "$scratch/terminal.idl" >"$scratch/idl/$terminal"
check || { cat "$scratch/result"; echo "ERROR: the terminal protocol retired whole (every method reserved) was refused"; exit 1; }
# Once that is pinned, a new protocol of the same name cannot reuse the
# ordinals: an old client of write @1 would run something else.
git -C "$scratch/idl" -c user.name=t -c user.email=t@t commit -qam "retire terminal" >/dev/null
retired=$(git -C "$scratch/idl" rev-parse HEAD)
awk -v p="$retired" '$1 == "idl" { $2 = p } { print }' "$ws/bootstrap.pins" >"$scratch/bootstrap.pins"
printf 'protocol silica.console.Terminal version 1 {\n    scribble @1 (data: bytes) -> ();\n}\n' >"$scratch/idl/$terminal"
if check || ! grep -q 'reserved @1' "$scratch/result"; then
  cat "$scratch/result"; echo "ERROR: a retired protocol's reserved ordinal was given a new method"; exit 1
fi
echo "protocol compatibility regression: OK"
