#!/usr/bin/env bash
# Pin the component revisions the system image is built from.
#   pin.sh           set every pin in os/manifest.toml to the head of that
#                    repository's local main and commit exactly manifest.toml
#                    in os; an error changes nothing. Then rewrite the lines
#                    of the workshop's bootstrap.pins to the same revisions
#                    and to the head of os, so the two files cannot disagree
#                    (the workshop commit is left to the caller). Run it once
#                    the integrated build passes with those revisions
#   pin.sh --check   exit non-zero unless every clone is at its pinned commit
#                    with no modified or untracked files and bootstrap.pins
#                    names the same revisions; changes nothing
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"
OS=$(realdir "$TOOLS/..")
BOOT=$WS/bootstrap.pins
fail=0
boot_want() { # the revision bootstrap.pins should name for <repo>
  if [ "$1" = os ]; then git -C "$OS" rev-parse -q --verify HEAD; else manifest_get "$1" commit; fi
}
boot_repos() { # repositories that have a line in bootstrap.pins
  awk '$2 ~ /^[0-9a-f]{40}$/ { print $1 }' "$BOOT" 2>/dev/null
}
sync_boot() { # rewrite the lines of bootstrap.pins that differ; prints the repositories changed
  local r want tmp moved=()
  [ -f "$BOOT" ] || return 0
  tmp=$(mktemp "$OUTBASE/runs/bootstrap-pins.XXXXXX") || die "cannot write bootstrap.pins"
  cat "$BOOT" >"$tmp"
  for r in $(boot_repos); do
    want=$(boot_want "$r"); [ -n "$want" ] || continue
    [ "$(awk -v r="$r" '$1 == r { print $2 }' "$BOOT")" = "$want" ] && continue
    awk -v r="$r" -v h="$want" '$1 == r { print r " " h; next } { print }' "$tmp" >"$tmp.2" && mv "$tmp.2" "$tmp"
    moved+=("$r")
  done
  if [ ${#moved[@]} -gt 0 ]; then cat "$tmp" >"$BOOT" || die "cannot write bootstrap.pins"; echo "PIN: bootstrap.pins ${moved[*]}"; fi
  rm -f "${tmp:?}"
}
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
    head=$(git -C "$d" rev-parse -q --verify HEAD)
    [ "$head" = "$pin" ] || { echo "ERROR: pin: $r is at ${head:0:12}, pinned ${pin:0:12}"; fail=1; }
    [ -z "$(git -C "$d" status --porcelain --untracked-files=all)" ] || { echo "ERROR: pin: $r has modified or untracked files"; fail=1; }
  done
  [ -z "$(git -C "$OS" status --porcelain --untracked-files=all)" ] || { echo "ERROR: pin: os has modified or untracked files"; fail=1; }
  for r in $(boot_repos); do
    want=$(boot_want "$r"); [ -n "$want" ] || continue
    have=$(awk -v r="$r" '$1 == r { print $2 }' "$BOOT")
    [ "$have" = "$want" ] || { echo "ERROR: pin: bootstrap.pins has $r at ${have:0:12}, want ${want:0:12} (run tools/pin.sh)"; fail=1; }
  done
  [ $fail = 0 ] && echo "PIN: CHECK OK"
  exit $fail
fi
[ -z "$(git -C "$OS" status --porcelain -- manifest.toml)" ] || die "os/manifest.toml has uncommitted changes"
new=$(cat "$MANIFEST")
changed=()
for r in $(manifest_repos); do
  d=$WS/$r; [ -e "$d/.git" ] || continue
  head=$(git -C "$d" rev-parse -q --verify refs/heads/main) || { echo "ERROR: pin: $r has no main"; fail=1; continue; }
  [ "$(manifest_get "$r" commit)" = "$head" ] && continue
  [ -n "$(manifest_get "$r" commit)" ] || { echo "ERROR: pin: $r has no commit value in the manifest"; fail=1; continue; }
  new=$(awk -v r="$r" -v h="$head" '
    /^\[/ { s = $0; gsub(/^\[repos\.|"|\]$/, "", s); cur = s }
    cur == r && $1 == "commit" { sub(/"[^"]*"/, "\"" h "\""); print; next } { print }' <<<"$new")
  changed+=("$r")
done
[ $fail = 0 ] || exit 1
[ ${#changed[@]} -gt 0 ] || { echo "PIN: unchanged"; sync_boot; exit 0; }
saved=$(mktemp "$OUTBASE/runs/pin-manifest.XXXXXX") || die "cannot save the manifest"
cat "$MANIFEST" >"$saved"
undo() { cat "$saved" >"$MANIFEST"; git -C "$OS" reset -q -- manifest.toml 2>/dev/null; rm -f "${saved:?}"; }
printf '%s\n' "$new" >"$MANIFEST"
for r in "${changed[@]}"; do
  [ "$(manifest_get "$r" commit)" = "$(git -C "$WS/$r" rev-parse refs/heads/main)" ] || { undo; die "cannot set the pin of $r in the manifest"; }
done
git -C "$OS" add manifest.toml && git -C "$OS" commit -q -m "Pin ${changed[*]}" -- manifest.toml ||
  { undo; die "commit in os failed; manifest unchanged"; }
rm -f "${saved:?}"
echo "PIN: ${changed[*]}"
sync_boot
