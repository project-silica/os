#!/usr/bin/env bash
# The toolchain image and the compiler cache of the hosted lanes
# (every job uses a shared compiler cache and a prebuilt toolchain image, so a
# cold build never happens in the pre-merge lane).
#   toolchain-image.sh check               tools/image/Containerfile against the pins
#   toolchain-image.sh tag                 the image tag: 12 hex of the Containerfile's hash
#   toolchain-image.sh key <repo>          the cache key of <repo>:
#                                          silica-<repo>-<arch>-<tag>-<16 hex>
#   toolchain-image.sh restore-key <repo>  silica-<repo>-<arch>-<tag>-, the prefix a
#                                          fallback restore may use
#   (each also takes --checkout <repo> <absolute-dir>, repeatable)
# check: the base image is pinned (a tag other than latest, or a digest); the
# channel and components of the image equal what every rust-toolchain.toml of
# a repository asks for (plus llvm-tools); the packages every tools/ script
# needs are installed; the toolchain is installed from those two values with
# the minimal profile; nothing is piped from a download into a shell; no
# source is copied in. One ERROR line per defect, then exit 1; otherwise
# "TOOLCHAIN-IMAGE: OK". key: the hash covers every Cargo.lock and
# rust-toolchain.toml of the repository (never vendor/, target/ or .git/),
# by path and content, and the tag, so the cache is new exactly when a
# dependency, the pin or the image changes. Exit 2 on a usage error.
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"
parse_checkouts "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"

USAGE="usage: toolchain-image.sh check | tag | key <repo> | restore-key <repo> [--checkout <repo> <absolute-dir>]..."
CF=$(checkout_of os)/tools/image/Containerfile
REQUIRED_PKGS="bubblewrap ca-certificates git jq mtools ovmf python3 python3-yaml qemu-efi-aarch64 qemu-system-arm qemu-system-x86 rustup socat"
EXTRA_COMPONENTS="llvm-tools"

need_cf() { [ -f "$CF" ] || { err "$CF: Containerfile is missing"; exit 1; }; }

image_tag() { sha256sum <"$CF" | cut -c1-12; }

# The Containerfile as logical lines: comments dropped, continuations joined.
logical() {
  awk '
    /^[ \t]*#/ { next }
    { line = $0; if (line ~ /\\[ \t]*$/) { sub(/\\[ \t]*$/, "", line); acc = acc line " "; next }
      print acc line; acc = "" }
    END { if (acc != "") print acc }' "$CF"
}

# toolchain_field <file> channel|components: the value(s) of the [toolchain] key,
# one per line (arrays may span lines).
toolchain_field() {
  awk -v k="$2" '
    /^\[/ { t = ($0 ~ /^\[toolchain\]/); next }
    t && !inarr && $0 ~ "^[ \t]*" k "[ \t]*=" {
      v = $0; sub(/^[^=]*=/, "", v)
      if (k == "components" && v !~ /\]/) inarr = 1
      buf = v; if (!inarr) { print buf }; next }
    inarr { buf = buf " " $0; if ($0 ~ /\]/) { inarr = 0; print buf } }
  ' "$1" | grep -o '"[^"]*"' | tr -d '"'
}

do_check() {
  need_cf
  local fails=0 line base ch comps pin repo f want c have p
  bad() { err "$*"; fails=$((fails + 1)); }

  # base images
  local froms=0
  while IFS= read -r line; do
    case "$line" in FROM\ *|FROM) ;; *) continue ;; esac
    froms=$((froms + 1))
    base=$(awk '{ for (i = 2; i <= NF; i++) if ($i !~ /^--/) { print $i; exit } }' <<<"$line")
    case "$base" in
      *@sha256:*) ;;
      *:latest | "" ) bad "base image ${base:-?} is not pinned (use a version tag or a digest)" ;;
      *:*) ;;
      *) bad "base image $base is not pinned (use a version tag or a digest)" ;;
    esac
  done < <(logical | sed 's/^[ \t]*//' | grep -E '^FROM([ \t]|$)')
  [ $froms -gt 0 ] || bad "no FROM line"

  # channel and components
  ch=$(logical | sed -n 's/^[ \t]*ARG[ \t][ \t]*RUST_CHANNEL=\(.*\)$/\1/p' | head -n 1)
  comps=$(logical | sed -n 's/^[ \t]*ARG[ \t][ \t]*RUST_COMPONENTS=\(.*\)$/\1/p' | head -n 1)
  if [ -z "$ch" ]; then bad "no ARG RUST_CHANNEL (the image must pin the toolchain)"
  else
    printf '%s' "$ch" | grep -Eq '^nightly-[0-9]{4}-[0-9]{2}-[0-9]{2}$' || bad "RUST_CHANNEL $ch is not a dated nightly"
  fi
  [ -n "$comps" ] || bad "no ARG RUST_COMPONENTS"

  declare -A need_by=()
  for c in $EXTRA_COMPONENTS; do need_by[$c]="the image"; done
  for repo in $(all_repos); do
    f=$(checkout_of "$repo")/rust-toolchain.toml
    [ -f "$f" ] || continue
    pin=$(toolchain_field "$f" channel | head -n 1)
    if [ -n "$ch" ] && [ -n "$pin" ] && [ "$pin" != "$ch" ]; then
      bad "RUST_CHANNEL $ch differs from the pin $pin in $repo/rust-toolchain.toml"
    fi
    for c in $(toolchain_field "$f" components); do
      if [ -n "${need_by[$c]:-}" ] && [ "${need_by[$c]}" != "the image" ]; then need_by[$c]+=", $repo"; else need_by[$c]="$repo"; fi
    done
  done
  if [ -n "$comps" ]; then
    for c in $(printf '%s\n' "${!need_by[@]}" | sort); do
      case ",$comps," in *",$c,"*) ;; *) bad "component $c (wanted by ${need_by[$c]}) is missing from RUST_COMPONENTS" ;; esac
    done
  fi

  # packages
  have=$(logical | grep -E 'apt(-get)?[ \t]+install' | sed 's/^.*apt\(-get\)\{0,1\}[ \t][ \t]*install//' \
    | sed 's/&&.*$//' | tr -s ' \t' '\n\n' | grep -v '^-' | grep -v '^$')
  for p in $REQUIRED_PKGS; do
    grep -qx -- "$p" <<<"$have" || bad "package $p is not installed (apt-get install)"
  done

  # the toolchain installation
  local inst
  inst=$(logical | grep -E '^[ \t]*RUN\b' | sed 's/&&/\n/g' | grep -E 'rustup[ \t]+toolchain[ \t]+install' | head -n 1)
  if [ -z "$inst" ]; then
    bad "no 'rustup toolchain install' (the image must install the pinned toolchain)"
  else
    grep -Eq '\$\{?RUST_CHANNEL\}?' <<<"$inst" || bad "rustup toolchain install does not use RUST_CHANNEL"
    grep -Eq '\$\{?RUST_COMPONENTS\}?' <<<"$inst" || bad "rustup toolchain install does not use RUST_COMPONENTS"
    grep -Eq -- '--profile[ \t]+minimal' <<<"$inst" || bad "rustup toolchain install does not use --profile minimal"
  fi

  # hygiene
  logical | grep -Eq '^[ \t]*RUN\b.*\b(curl|wget)\b.*\|[ \t]*(sudo[ \t]+)?(ba|z)?sh\b' && bad "RUN pipes a download into a shell"
  logical | grep -Eq '^[ \t]*COPY\b' && bad "COPY copies sources into the image (the image holds tools only)"
  logical | grep -Eq '^[ \t]*ADD\b' && bad "ADD copies sources into the image (the image holds tools only)"

  if [ $fails = 0 ]; then echo "TOOLCHAIN-IMAGE: OK"; return 0; fi
  return 1
}

arch_part() { uname -m | tr -c 'A-Za-z0-9_\n' _; }

key_prefix() { # key_prefix <repo>
  need_cf
  echo "silica-$1-$(arch_part)-$(image_tag)-"
}

do_key() { # do_key <repo>
  local repo=$1 dir list h
  dir=$(checkout_of "$repo")
  [ -d "$dir" ] || { err "no checkout of $repo at $dir"; exit 1; }
  need_cf
  list=$(cd "$dir" && find . \( -name .git -o -name target -o -name vendor \) -prune -o -type f \
    \( -name Cargo.lock -o -name rust-toolchain.toml -o -name rust-toolchain \) -print | LC_ALL=C sort)
  if ! grep -q '/Cargo\.lock$' <<<"$list"; then
    err "$repo: no Cargo.lock in $dir (a compiler cache is keyed by lock files)"; exit 1
  fi
  h=$(cd "$dir" && while IFS= read -r f; do printf '%s %s\n' "$f" "$(sha256sum <"$f" | cut -d' ' -f1)"; done <<<"$list" | sha256sum | cut -c1-16)
  echo "$(key_prefix "$repo")$h"
}

[ $# -ge 1 ] || die "$USAGE"
cmd=$1; shift
case "$cmd" in
  check) [ $# = 0 ] || die "check takes no argument ($USAGE)"; do_check ;;
  tag) [ $# = 0 ] || die "tag takes no argument ($USAGE)"; need_cf; image_tag ;;
  key) [ $# = 1 ] || die "key needs one repository ($USAGE)"; do_key "$1" ;;
  restore-key) [ $# = 1 ] || die "restore-key needs one repository ($USAGE)"; key_prefix "$1" ;;
  *) die "unknown argument $cmd ($USAGE)" ;;
esac
