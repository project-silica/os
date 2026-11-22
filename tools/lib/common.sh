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
realdir() { (cd "$1" 2>/dev/null && pwd -P); }

# Builds use the pinned toolchain and nothing from the developer's Cargo
# configuration: a rustc wrapper found in ~/.cargo/config.toml (sccache hangs
# on -Zbuild-std's core; a wrapper's link arguments change the artifacts) is off.
export RUSTC_WRAPPER=

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
# The milestone whose requirements apply: SILICA_MILESTONE overrides the MILESTONE file, so the
# next milestone's gates can be checked (SILICA_MILESTONE=2 tools/test.sh --full) before it is declared.
milestone() { if [ -n "${SILICA_MILESTONE:-}" ]; then echo "$SILICA_MILESTONE"; elif [ -f "$WS/MILESTONE" ]; then cat "$WS/MILESTONE"; else echo 0; fi; }

# Source tree of a repository. SRC[<repo>] names another copy (repro.sh builds the same tree from two directories).
declare -A SRC=()
checkout_of() { echo "${SRC[$1]:-$WS/$1}"; }

# ---- output directories (never inside a source checkout) ------------------
OUTBASE=$WS/target
if [ ! -w "$OUTBASE" ] && { [ -e "$OUTBASE" ] || [ ! -w "$WS" ]; }; then
  # A read-only workshop still needs room for Rust, disk images and QEMU.
  # Respect an explicit scratch directory; otherwise use the user's cache.
  OUTBASE=${TMPDIR:-${XDG_CACHE_HOME:-$HOME/.cache}}/silica
fi
mkdir -p "$OUTBASE/logs" "$OUTBASE/runs" "$OUTBASE/cache" || die "cannot create build directories under $OUTBASE"
export TMPDIR=${TMPDIR:-$OUTBASE/tmp}
mkdir -p "$TMPDIR" || die "cannot create scratch directory $TMPDIR"
LOGS=$OUTBASE/logs
new_run() { # private per-run directory
  # A run directory is a tool's working space; what is worth keeping of a run
  # is under logs/. Nothing removed them, and three days of work left 7,000.
  # Each new run removes those older than three days (longer than any run
  # there is; a soak longer than that must touch its directory as it goes).
  find "$OUTBASE/runs" -mindepth 1 -maxdepth 1 -mmin +4320 \
    -exec sh -c 'chmod -R u+rwx "$@" 2>/dev/null; rm -rf "$@"' sh {} + 2>/dev/null
  RUN=$(mktemp -d "$OUTBASE/runs/$TOOL_NAME.$(date +%Y%m%dT%H%M%S).XXXX") || die "cannot create a run under $OUTBASE/runs"
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

# ---- cargo ----------------------------------------------------------------
SYSROOT_VENDOR() { echo "$(cd "$1" && rustc --print sysroot)/lib/rustlib/src/rust/library/vendor"; }
# A Cargo invocation keeps one immutable directory of links for its entire
# build. The checkout wins if it vendors the same crate as the sysroot.
merged_vendor() (
  local dir cache sysroot crate name key out stage
  dir=$(checkout_of "$1"); cache=$(cache_of "$1")
  sysroot=$(SYSROOT_VENDOR "$dir") || return 1
  local -A links=()
  for crate in "$sysroot"/* "$dir"/vendor/*; do
    [ -f "$crate/.cargo-checksum.json" ] || continue
    links[${crate##*/}]=$crate
  done
  key=$(printf '%s\0' "${links[@]}" | LC_ALL=C sort -z | sha256sum) || return 1
  out=$cache/vendor-${key%% *}
  if [ ! -d "$out" ]; then
    mkdir -p "$cache" && stage=$(mktemp -d "$cache/.vendor.XXXXXX") || return 1
    trap 'rm -rf -- "$stage"' EXIT
    for name in "${!links[@]}"; do
      ln -s -- "${links[$name]}" "$stage/$name" || return 1
    done
    # Concurrent builders of this set of links publish identical directories.
    mv -T -- "$stage" "$out" 2>/dev/null || [ -d "$out" ] || return 1
  fi
  printf '%s\n' "$out"
)
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
# offline, with a private target directory; output to logfile.
# CARGO_ENV (an array of NAME=value) adds variables to the environment.
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
  (cd "$dir" && env CARGO_TARGET_DIR="$cache/target" CARGO_TERM_COLOR=never CARGO_NET_OFFLINE=true \
    "${CARGO_ENV[@]+"${CARGO_ENV[@]}"}" cargo --config "$cache/cargo-patch.toml" "$@") >"$log" 2>&1
}

firmware_of() { # firmware_of <arch> <code|vars>: the UEFI firmware qemu.sh boots
  local f FW=${SILICA_FW_ROOT:-}
  case "$1:$2" in
    x86_64:code) set -- /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2-ovmf/x64/OVMF_CODE.fd ;;
    x86_64:vars) set -- /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/edk2-ovmf/x64/OVMF_VARS.fd ;;
    aarch64:code) set -- /usr/share/AAVMF/AAVMF_CODE.fd /usr/share/edk2/aarch64/QEMU_EFI-pflash.raw /usr/share/qemu-efi-aarch64/QEMU_EFI.fd ;;
    aarch64:vars) set -- /usr/share/AAVMF/AAVMF_VARS.fd /usr/share/edk2/aarch64/vars-template-pflash.raw ;;
    *) return 1 ;;
  esac
  for f in "$@"; do [ -f "$FW$f" ] && { echo "$FW$f"; return 0; }; done
  return 1
}

# fastest_cpus <n>: a comma-separated list of host processors for a guest
# with <n> processors: one hardware thread of each of the <n> fastest cores
# (by maximum frequency; on a hybrid processor, the performance cores).
# Empty where the host does not say.
fastest_cpus() {
  [ -d /sys/devices/system/cpu/cpu0/topology ] || return 0
  local c first
  for c in /sys/devices/system/cpu/cpu[0-9]*; do
    [ -r "$c/topology/thread_siblings_list" ] || continue
    first=$(cut -d, -f1 "$c/topology/thread_siblings_list" | cut -d- -f1)
    [ "${c##*cpu}" = "$first" ] || continue
    echo "$(cat "$c/cpufreq/cpuinfo_max_freq" 2>/dev/null || echo 0) ${c##*cpu}"
  done | sort -k1,1nr -k2,2n | head -n "$1" | awk '{ print $2 }' | sort -n | paste -sd, -
}

# host_tune <cpu list> <state file>: hold those processors, and the other
# hardware threads of their cores, at one fixed policy while a benchmark
# runs: the "performance" frequency governor and preference (no ramp from a
# low frequency inside a sample), no idle state slower to leave than 20 us
# (a processor a guest wakes answers at once instead of after a deep sleep),
# and, for the whole machine, no turbo: with it a core's frequency depends
# on how many other cores happen to be awake, and the same kernel measured
# 53 ns in one boot and 55 ns in the next for a null system call; without
# it, 84 ns in five boots of five. Absolute timings are therefore at the
# processor's base frequency, for both systems; ratios are what carry.
# What everything was set to is recorded in <state file> first, for
# host_restore. Needs passwordless sudo; returns 1 without changing anything
# where there is none.
host_tune() {
  local cpu sib f s v list=""
  sudo -n true 2>/dev/null || return 1
  : >"$2" || return 1
  for f in /sys/devices/system/cpu/intel_pstate/no_turbo /sys/devices/system/cpu/cpufreq/boost; do
    [ -e "$f" ] && list="$list $f"
  done
  for cpu in $(echo "$1" | tr , ' '); do
    for sib in $(tr ',-' '  ' <"/sys/devices/system/cpu/cpu$cpu/topology/thread_siblings_list"); do
      f=/sys/devices/system/cpu/cpu$sib
      list="$list $f/cpufreq/scaling_governor $f/cpufreq/energy_performance_preference"
      for s in "$f"/cpuidle/state[0-9]*; do
        [ "$(cat "$s/latency" 2>/dev/null || echo 0)" -gt 20 ] && list="$list $s/disable"
      done
    done
  done
  # Everything is recorded before anything changes: the "performance"
  # governor rewrites the preference beside it.
  for f in $list; do [ -e "$f" ] && printf '%s %s\n' "$f" "$(cat "$f")" >>"$2"; done
  while read -r f _; do
    case $f in */scaling_governor|*/energy_performance_preference) v=performance ;; */boost) v=0 ;; *) v=1 ;; esac
    echo "$v" | sudo -n tee "$f" >/dev/null || return 1
  done <"$2"
}

# host_restore <state file>: put back what host_tune recorded (the governor
# first: the preference cannot be written under "performance").
host_restore() {
  local f v
  [ -s "$1" ] || return 0
  { grep scaling_governor "$1"; grep -v scaling_governor "$1"; } | while read -r f v; do echo "$v" | sudo -n tee "$f" >/dev/null; done
  rm -f "$1"
}
