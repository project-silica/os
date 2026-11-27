#!/usr/bin/env bash
# Check the published protocols against the revision a fresh workshop boots
# and the integration pin (which can be ahead before the workshop is pinned).
# Until a `stable` release can exist (before M9, spec/CI_RELEASE.md section
# 9) protocols are provisional and a removal is allowed in stages
# (spec/ARCHITECTURE.md section 4): each file is checked with
# `check-compat --retire`, which accepts a method retired into `reserved` at
# its ordinal and nothing else that is not additive, and a published file
# that is gone is said and accepted. From M9 every file is checked additive
# only, and a published file must still be there.
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"
set -e
idl=$(checkout_of idl)
shipped=$(awk '$1 == "idl" {print $2}' "$WS/bootstrap.pins")
integrated=$(manifest_get idl commit)
pins=("$shipped")
[[ $integrated == "$shipped" ]] || pins+=("$integrated")
milestone=$(tr -dc '0-9' <"$WS/MILESTONE")
[[ -n $milestone ]] || die "no milestone in $WS/MILESTONE"
mode=()
(( milestone < 9 )) && mode=(--retire)
scratch=$(mktemp -d "$OUTBASE/runs/idl-compat.XXXXXX")
trap 'rm -rf "${scratch:?}"' EXIT
cargo_run idl "$scratch/build.log" build -p silica-idlc --bin silica-idlc || { cat "$scratch/build.log"; exit 1; }
compiler=$(cache_of idl)/target/debug/silica-idlc
shopt -s globstar nullglob
current=("$idl"/protocols/silica/**/*.idl)
[[ ${#current[@]} -gt 0 ]] || die "no current protocols under $idl/protocols/silica"
"$compiler" check "${current[@]}"
for pin in "${pins[@]}"; do
  [[ $pin =~ ^[0-9a-f]{40}$ ]] || die "missing or invalid IDL pin: $pin"
  git -C "$idl" ls-tree -rz --name-only "$pin" -- protocols/silica >"$scratch/paths"
  count=0 retired=0
  while IFS= read -r -d '' path; do
    [[ $path == *.idl ]] || continue
    if [[ ! -e $idl/$path && ${#mode[@]} -gt 0 ]]; then
      echo "protocols: $path retired since $pin (provisional until M9)"
      retired=$((retired + 1))
      continue
    fi
    git -C "$idl" show "$pin:$path" >"$scratch/old.idl"
    "$compiler" check-compat "${mode[@]}" "$scratch/old.idl" "$idl/$path" >/dev/null
    count=$((count + 1))
  done <"$scratch/paths"
  (( count + retired > 0 )) || die "no published protocols at $pin"
  echo "protocols: $count compatible with $pin${mode[*]:+ (retirements allowed until M9)}"
done
