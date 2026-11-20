# Shared helpers for every tool in os/tools/. Sourced, never run.
#
#   . "$(dirname "$(readlink -f "$0")")/lib/common.sh"
#
set -uo pipefail
umask 077

TOOLS=$(cd "$(dirname "$(readlink -f "$0")")" && pwd -P)
TOOL_NAME=$(basename "$0" .sh)
err() { echo "ERROR: $TOOL_NAME: $*"; }
die() { err "$*"; exit "${DIE_CODE:-2}"; }

find_ws() { # workshop root: SILICA_WS, else the first ancestor of the tool suite with bootstrap.pins
  if [ -n "${SILICA_WS:-}" ]; then (cd "$SILICA_WS" && pwd -P); return; fi
  local d=$TOOLS
  while [ "$d" != / ]; do
    if [ -f "$d/bootstrap.pins" ]; then echo "$d"; return; fi
    d=$(dirname "$d")
  done
  return 1
}
WS=$(find_ws) || die "cannot find the workshop root above $TOOLS"
export SILICA_WS=$WS
MANIFEST=$TOOLS/../manifest.toml
SANDBOX=${SILICA_SANDBOX:-$TOOLS/sandbox.sh}

# Hook-free Git: hooks off (an empty directory the harness owns), no
# fsmonitor, no attributes (so no filter, merge or diff drivers run), no
# external diff or textconv, no global or system config.
NOHOOKS=${SILICA_NOHOOKS:-${TMPDIR:-/tmp}/silica-nohooks}
mkdir -p "$NOHOOKS" 2>/dev/null || true
g() {
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0 \
    git -c core.hooksPath="$NOHOOKS" -c core.fsmonitor=false -c core.attributesFile=/dev/null \
    -c diff.external= -c core.sshCommand=false -c credential.helper= -c protocol.allow=never \
    -c protocol.file.allow=always -c user.name="${GIT_AUTHOR_NAME:-$(git config user.name 2>/dev/null || echo silica-harness)}" \
    -c user.email="${GIT_AUTHOR_EMAIL:-$(git config user.email 2>/dev/null || echo harness@silica.invalid)}" \
    --attr-source=4b825dc642cb6eb9a060e54bf8d69288fbee4904 "$@"
}

realdir() { (cd "$1" 2>/dev/null && pwd -P); }

# ---- manifest -------------------------------------------------------------
manifest_repos() { # repo names pinned in the manifest, in file order
  sed -n 's/^\[repos\.\("\{0,1\}\)\([^]"]*\)\1\]$/\2/p' "$MANIFEST"
}
manifest_get() { # manifest_get <repo> <key>
  awk -v r="$1" -v k="$2" '
    /^\[/ { s = $0; gsub(/^\[repos\.|"|\]$/, "", s); cur = s; next }
    cur == r && $1 == k { v = $0; sub(/^[^=]*= *"?/, "", v); sub(/"? *(#.*)?$/, "", v); print v; exit }' "$MANIFEST"
}
all_repos() { manifest_repos; echo os; }
milestone() { if [ -f "$WS/MILESTONE" ]; then cat "$WS/MILESTONE"; else echo 0; fi; }

# ---- checkout overrides ---------------------------------------------------
# --checkout <repo> <absolute-dir>, repeatable; inherited by children through
# SILICA_CHECKOUTS ("repo=dir" lines).
declare -A CHECKOUT=()
if [ -n "${SILICA_CHECKOUTS:-}" ]; then
  while IFS='=' read -r r d; do [ -n "$r" ] && CHECKOUT[$r]=$d; done <<<"$SILICA_CHECKOUTS"
fi
ARGS=()
parse_checkouts() { # strips --checkout pairs from "$@" into CHECKOUT; the rest goes to ARGS
  ARGS=()
  while [ $# -gt 0 ]; do
    if [ "$1" = --checkout ]; then
      [ $# -ge 3 ] || die "--checkout needs <repo> <absolute-dir>"
      case "$3" in /*) ;; *) die "--checkout $2: $3 is not an absolute path" ;; esac
      local d; d=$(realdir "$3") || die "--checkout $2: $3 does not exist"
      CHECKOUT[$2]=$d; shift 3
    else
      ARGS+=("$1"); shift
    fi
  done
  local r
  for r in "${!CHECKOUT[@]}"; do check_checkout "$r" "${CHECKOUT[$r]}"; done
  export_checkouts

}
export_checkouts() {
  local r s=""
  for r in "${!CHECKOUT[@]}"; do s+="$r=${CHECKOUT[$r]}"$'\n'; done
  export SILICA_CHECKOUTS=$s
}
check_checkout() { # the directory must be a worktree of the workshop's clone
  local repo=$1 dir=$2 want got
  [ -d "$WS/$repo/.git" ] || [ -f "$WS/$repo/.git" ] || die "--checkout $repo: no clone at $WS/$repo"
  want=$(realdir "$(g -C "$WS/$repo" rev-parse --path-format=absolute --git-common-dir)")
  got=$(g -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die "--checkout $repo: $dir is not a Git checkout"
  got=$(realdir "$got")
  [ "$want" = "$got" ] || die "--checkout $repo: $dir belongs to another repository"
  [ "$(realdir "$(g -C "$dir" rev-parse --show-toplevel)")" = "$dir" ] || die "--checkout $repo: $dir is not a worktree root"
}
checkout_of() { echo "${CHECKOUT[$1]:-$WS/$1}"; }

# ---- output directories (never inside a source checkout) ------------------
if [ -w "$WS/target" ] || { [ ! -e "$WS/target" ] && [ -w "$WS" ]; }; then
  OUTBASE=$WS/target
else
  OUTBASE=${TMPDIR:-/tmp}/silica
fi
mkdir -p "$OUTBASE/logs" "$OUTBASE/runs" "$OUTBASE/cache" 2>/dev/null || OUTBASE=${TMPDIR:-/tmp}/silica
mkdir -p "$OUTBASE/logs" "$OUTBASE/runs" "$OUTBASE/cache"
LOGS=$OUTBASE/logs
new_run() { # private per-run directory
  RUN=$(mktemp -d "$OUTBASE/runs/$TOOL_NAME.$(date +%Y%m%dT%H%M%S).XXXX")
  case "$TOOL_NAME" in
    test)
      LOGS=$OUTBASE/logs/${RUN##*/}
      mkdir -p "$LOGS" || die "cannot create private log directory" ;;
  esac
  export SILICA_RUN=$RUN
}
cache_of() { # build cache for one checkout of one repo (keyed by real path)
  local d; d=$(checkout_of "$1")
  echo "$OUTBASE/cache/$1-$(printf '%s' "$d" | sha256sum | cut -c1-16)"
}

# ---- sandbox for builds and tests -----------------------------------------
# No network, empty environment and home (no credentials), filesystem
# read-only except the given output directories.
# The sandbox hides $HOME, so the checkouts in use, the tool suite and spec/
# are bound read-only; the rw directories must not lie inside them.
sandboxed() { # sandboxed <rwdir>... -- <command...>
  local a=() r d seen=" "
  while [ $# -gt 0 ] && [ "$1" != -- ]; do a+=(--rwdir "$1"); shift; done
  shift
  for d in $(for r in $(all_repos); do checkout_of "$r"; done) "$(realdir "$TOOLS/..")" "$WS/spec"; do
    [ -e "$d" ] || continue
    case "$seen" in *" $d "*) continue ;; esac
    seen+="$d "; a+=(--ro "$d")
  done
  if [ -x "$SANDBOX" ] && command -v bwrap >/dev/null 2>&1; then
    "$SANDBOX" "${a[@]}" -- "$@"
  else
    err "sandbox $SANDBOX unavailable"; return 125
  fi
}

# ---- cargo ----------------------------------------------------------------
SYSROOT_VENDOR() { echo "$(cd "$1" && rustc --print sysroot)/lib/rustlib/src/rust/library/vendor"; }
merged_vendor() { # repo vendor/ plus the toolchain's library vendor, for -Zbuild-std
  local repo=$1 dir out c
  dir=$(checkout_of "$repo"); out=$(cache_of "$repo")/vendor-merged
  rm -rf "$out"; mkdir -p "$out"
  for c in "$(SYSROOT_VENDOR "$dir")"/* "$dir"/vendor/*/; do
    c=${c%/}; [ -f "$c/.cargo-checksum.json" ] && ln -sfn "$c" "$out/$(basename "$c")"
  done
  echo "$out"
}
patch_config() { # Cargo [patch] for every checkout in use, written to $1
  local f=$1 r d url
  : >"$f"
  for r in $(manifest_repos); do
    d=$(checkout_of "$r"); url=$(manifest_get "$r" url)
    [ -f "$d/Cargo.toml" ] || continue
    local pk
    pk=$(cd "$d" && cargo metadata --no-deps --format-version 1 --offline 2>/dev/null |
      jq -r '.packages[] | "\(.name)\t\(.manifest_path)"') || continue
    [ -n "$pk" ] || continue
    printf '[patch."%s"]\n' "$url" >>"$f"
    while IFS=$'\t' read -r n p; do printf '%s = { path = "%s" }\n' "$n" "$(dirname "$p")" >>"$f"; done <<<"$pk"
  done
}
# cargo_run <repo> <logfile> <cargo args...>: runs cargo in the checkout,
# inside the sandbox, with a private target directory; output to logfile.
# CARGO_ENV (an array of NAME=value) adds variables to the empty environment.
CARGO_ENV=()
# write_cargo_patch <repo>: the Cargo [patch] config for the checkouts in use,
# restricted to the repositories this checkout refers to, into its cache
# (cargo-patch.toml). Generated once per tool run; prints the file name.
write_cargo_patch() {
  local repo=$1 dir cache tmp; dir=$(checkout_of "$repo"); cache=$(cache_of "$repo")
  mkdir -p "$cache"
  tmp=$(mktemp "$cache/.cargo-patch.XXXXXX") || return 1
  # Path overrides for the checkouts in use, generated once per tool run.
  # Only repositories this checkout refers to are patched, so Cargo.lock is
  # never rewritten for an unused patch.
  if [ -z "${PATCH_DONE:-}" ]; then patch_config "${TMPDIR:-/tmp}/silica-patch.$$.toml"; PATCH_DONE=1; fi
  awk -v dir="$dir" '
    /^\[patch\."/ { u = $0; sub(/^\[patch\."/, "", u); sub(/"\]$/, "", u)
      cmd = "grep -rqsF --include=Cargo.toml \"" u "\" \"" dir "\""; keep = (system(cmd) == 0) }
    keep { print }' "${TMPDIR:-/tmp}/silica-patch.$$.toml" >"$tmp"
  mv "$tmp" "$cache/cargo-patch.toml"
  echo "$cache/cargo-patch.toml"
}
cargo_run() {
  local repo=$1 log=$2; shift 2
  local dir cache; dir=$(checkout_of "$repo"); cache=$(cache_of "$repo")
  mkdir -p "$cache" "$(dirname "$log")"
  write_cargo_patch "$repo" >/dev/null
  (cd "$dir" && sandboxed "$cache" "$(dirname "$log")" -- \
    env CARGO_TARGET_DIR="$cache/target" CARGO_TERM_COLOR=never "${CARGO_ENV[@]+"${CARGO_ENV[@]}"}" cargo --config "$cache/cargo-patch.toml" "$@") >"$log" 2>&1
}
