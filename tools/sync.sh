#!/usr/bin/env bash
# Clone or update every repository in os/manifest.toml next to the workshop,
# then generate the local Cargo path overrides. Called by bootstrap.sh on a
# fresh clone.
#   sync.sh            clone missing repos at their pinned commit; existing
#                      clones are left on their branch (never reset)
#   sync.sh --update   also fetch existing clones (needs the network)
# Writes target/cargo-patch.toml: a [patch."<url>"] section per repository
# pointing every crate at its local clone. Tools pass it to Cargo.
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"
update=0
case "${1:-}" in
  "") ;;
  --update) [ $# = 1 ] && update=1 || die "usage: sync.sh [--update]" ;;
  *) die "usage: sync.sh [--update]" ;;
esac
net() { git -c protocol.allow=always "$@"; }
fail=0
for r in $(manifest_repos); do
  url=$(manifest_get "$r" url); pin=$(manifest_get "$r" commit); m=$(manifest_get "$r" milestone)
  dir=$WS/$r
  if [ -e "$dir/.git" ]; then
    if [ $update = 1 ]; then net -C "$dir" fetch --quiet "$url" 2>/dev/null || echo "SKIP: sync: cannot fetch $r (no network?)"; fi
    if [ -n "$pin" ] && ! git -C "$dir" cat-file -e "$pin^{commit}" 2>/dev/null; then
      echo "ERROR: sync: $r lacks pinned commit $pin"; fail=1
    fi
    continue
  fi
  [ "${m:-0}" -le "$(milestone)" ] || continue
  # Only a directory this run creates (or an empty one) is removed on failure.
  if [ -e "$dir" ] && { [ ! -d "$dir" ] || [ -n "$(ls -A "$dir" 2>/dev/null)" ]; }; then
    echo "ERROR: sync: $dir exists and is not a clone of $r; move it away"; fail=1; continue
  fi
  if net clone --quiet --no-checkout "$url" "$dir" 2>/dev/null && git -C "$dir" checkout --quiet -B main "$pin"; then
    echo "sync: cloned $r at ${pin:0:12}"
  else
    rm -rf "$dir"; echo "ERROR: sync: cannot clone $r from $url"; fail=1
  fi
done
if [ -w "$WS/target" ] || mkdir -p "$WS/target" 2>/dev/null; then
  patch_config "$WS/target/cargo-patch.toml" && echo "sync: wrote target/cargo-patch.toml"
fi
[ $fail = 0 ] && echo "SYNC: OK"
exit $fail
