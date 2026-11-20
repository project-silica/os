#!/usr/bin/env bash
# Run a build command with isolated network, home and writable output directories.
set -euo pipefail
command -v bwrap >/dev/null 2>&1 || { echo "ERROR: sandbox: bubblewrap (bwrap) is not installed" >&2; exit 126; }

rwdir=()
ro=()
net=0
while [ $# -gt 0 ]; do
  case "$1" in
    --rwdir) rwdir+=("$2"); shift 2 ;;
    --ro) ro+=("$2"); shift 2 ;;
    --net) net=1; shift ;;
    --) shift; break ;;
    *) echo "ERROR: sandbox: bad argument $1" >&2; exit 2 ;;
  esac
done
[ $# -gt 0 ] || { echo "ERROR: sandbox: no command" >&2; exit 2; }

home=${HOME:-/root}
ws_root=${SILICA_WS:-$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd -P)}
b=(--die-with-parent --new-session --unshare-all
   --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp
   --tmpfs "$home"
   --ro-bind "$ws_root" "$ws_root"
   --ro-bind-try "$home/.rustup" "$home/.rustup"
   --ro-bind-try "$home/.cargo/bin" "$home/.cargo/bin"
   --chdir "$(pwd -P)")

for d in "${rwdir[@]}"; do
  mkdir -p "$d"; d=$(cd "$d" && pwd -P); b+=(--bind "$d" "$d")
done
for p in "${ro[@]}"; do
  [ -e "$p" ] || { echo "ERROR: sandbox: read-only path $p is missing" >&2; exit 2; }
  b+=(--ro-bind "$p" "$p")
done
[ "$net" = 1 ] && b+=(--share-net)

# Commits made inside the sandbox carry the identity of whoever runs the build.
name=$(git config user.name || true)
email=$(git config user.email || true)

exec env -i \
  PATH="$home/.cargo/bin:/usr/local/bin:/usr/bin:/bin" \
  HOME="$home" USER="${USER:-silica}" LANG="${LANG:-C.UTF-8}" TERM=dumb \
  RUSTUP_HOME="$home/.rustup" CARGO_HOME=/tmp/cargo-home CARGO_NET_OFFLINE=true \
  GIT_AUTHOR_NAME="$name" GIT_AUTHOR_EMAIL="$email" \
  GIT_COMMITTER_NAME="$name" GIT_COMMITTER_EMAIL="$email" \
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=3 \
  GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null \
  GIT_CONFIG_KEY_1=gc.auto GIT_CONFIG_VALUE_1=0 \
  GIT_CONFIG_KEY_2=core.fsmonitor GIT_CONFIG_VALUE_2=false \
  bwrap "${b[@]}" -- "$@"
