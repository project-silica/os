#!/usr/bin/env bash
# Pin the system (spec/REPOSITORIES.md section 2, rule 4).
#   pin.sh           set every pin in os/manifest.toml to that repository's
#                    last verified commit (the head of its canonical main,
#                    which only the integration tools advance) and commit
#                    exactly manifest.toml in os; an error changes nothing
#   pin.sh --check   exit non-zero unless every clone is at its pinned commit
#                    with no modified or untracked files; changes nothing
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"
OS=$(realdir "$TOOLS/..")
fail=0
case "$#:${1:-}" in
  0:) mode=pin ;;
  1:--check) mode=--check ;;
  *) die "usage: pin.sh [--check]" ;;
esac
if [ "$mode" = --check ]; then
  for r in $(manifest_repos); do
    pin=$(manifest_get "$r" commit); d=$WS/$r
    if [ ! -e "$d/.git" ]; then
      [ "$(manifest_get "$r" milestone)" -gt "$(milestone)" ] 2>/dev/null && continue
      echo "ERROR: pin: $r is not cloned"; fail=1; continue
    fi
    head=$(g -C "$d" rev-parse -q --verify HEAD)
    [ "$head" = "$pin" ] || { echo "ERROR: pin: $r is at ${head:0:12}, pinned ${pin:0:12}"; fail=1; }
    [ -z "$(g -C "$d" status --porcelain --untracked-files=all)" ] || { echo "ERROR: pin: $r has modified or untracked files"; fail=1; }
  done
  [ -z "$(g -C "$OS" status --porcelain --untracked-files=all)" ] || { echo "ERROR: pin: os has modified or untracked files"; fail=1; }
  [ $fail = 0 ] && echo "PIN: CHECK OK"
  exit $fail
fi
exec 9>"$OUTBASE/.pin.lock" || die "cannot open pin lock"
flock -n 9 || die "pin lock is held by another operation"
[ -z "$(g -C "$OS" status --porcelain -- manifest.toml)" ] || die "os/manifest.toml has uncommitted changes"
new=$(cat "$MANIFEST")
changed=()
for r in $(manifest_repos); do
  d=$WS/$r; [ -e "$d/.git" ] || continue
  head=$(g -C "$d" rev-parse -q --verify refs/heads/main) || { echo "ERROR: pin: $r has no main"; fail=1; continue; }
  [ "$(manifest_get "$r" commit)" = "$head" ] && continue
  [ -n "$(manifest_get "$r" commit)" ] || { echo "ERROR: pin: $r has no commit value in the manifest"; fail=1; continue; }
  new=$(awk -v r="$r" -v h="$head" '
    /^\[/ { s = $0; gsub(/^\[repos\.|"|\]$/, "", s); cur = s }
    cur == r && $1 == "commit" { sub(/"[^"]*"/, "\"" h "\""); print; next } { print }' <<<"$new")
  changed+=("$r")
done
[ $fail = 0 ] || exit 1
[ ${#changed[@]} -gt 0 ] || { echo "PIN: unchanged"; exit 0; }
saved=$(mktemp "$OUTBASE/runs/pin-manifest.XXXXXX") || die "cannot save the manifest"
cat "$MANIFEST" >"$saved"
undo() { cat "$saved" >"$MANIFEST"; g -C "$OS" reset -q -- manifest.toml 2>/dev/null; rm -f "${saved:?}"; }
printf '%s\n' "$new" >"$MANIFEST"
for r in "${changed[@]}"; do
  [ "$(manifest_get "$r" commit)" = "$(g -C "$WS/$r" rev-parse refs/heads/main)" ] || { undo; die "cannot set the pin of $r in the manifest"; }
done
g -C "$OS" add manifest.toml && g -C "$OS" commit -q -m "os: pin ${changed[*]} [A11]" -- manifest.toml ||
  { undo; die "commit in os failed; manifest unchanged"; }
rm -f "${saved:?}"
echo "PIN: ${changed[*]}"
