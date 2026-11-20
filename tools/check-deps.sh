#!/usr/bin/env bash
# Dependency direction (spec/REPOSITORIES.md, Dependencies).
#   check-deps.sh
# idl depends on nothing; kernel only on idl; every other repository only on
# idl and the kernel's interface crates (libsys, silica-formats); nothing
# depends on os or workshop. Code of another repository is named by a path
# into its checkout beside this one (the workshop layout is the build
# layout: a git URL cannot be resolved offline even when it is overridden),
# or by the git URL of the published repository; either way the direction
# rules apply. A path dependency that leaves its repository for anywhere
# else is an error.
# Every Cargo manifest of a checkout counts, not only the root workspace
# (fuzz targets and tools are workspaces of their own); vendor/ and target/
# are not searched. Prints "CHECK-DEPS: OK" or one "ERROR: check-deps:" line
# per violation, naming the repository, the package and what it depends on.
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"
[ $# = 0 ] || { echo "usage: check-deps.sh"; die "unknown argument: $1"; }
fail=0
bad() { echo "ERROR: check-deps: $*"; fail=1; }

# A git URL in any spelling (scheme, user, www, case, .git, slash, query) as
# "host/path". Cargo reports the URL as written in the manifest.
norm_url() {
  local u=${1#git+}
  u=${u%%[?#]*}; u=${u,,}
  u=${u#*://}; u=${u#*@}; u=${u#www.}
  u=${u%/}; u=${u%.git}; u=${u%/}
  echo "$u"
}
declare -A URL_REPO=()
for r in $(all_repos); do
  u=$(manifest_get "$r" url 2>/dev/null) && [ -n "$u" ] && URL_REPO[$(norm_url "$u")]=$r
done
repo_of_url() { # the repository a git URL names, or nothing for a foreign URL
  local n; n=$(norm_url "$1")
  if [ -n "${URL_REPO[$n]:-}" ]; then echo "${URL_REPO[$n]}"; return; fi
  case "$n" in github.com/project-silica/*) n=${n#github.com/project-silica/}; echo "${n%%/*}" ;; esac
}
allowed() { # allowed <from repo> <to repo> <crate>
  case "$1:$2" in
    idl:*) return 1 ;;
    *:os | *:workshop) return 1 ;;
    kernel:idl) return 0 ;;
    kernel:*) return 1 ;;
    *:idl) return 0 ;;
    *:kernel) [ "$3" = libsys ] || [ "$3" = silica-formats ] ;;
    *) return 1 ;;
  esac
}
repo_of_path() { # the repository whose checkout contains <path>, or nothing
  local q dir
  for q in $(all_repos); do
    dir=$(realdir "$(checkout_of "$q")") || continue
    case "$1/" in "$dir"/*) echo "$q"; return ;; esac
  done
}
check_manifest() { # check_manifest <repo> <dir> <manifest> <root|nested>; adds the packages it saw to SEEN
  local r=$1 d=$2 mf=$3 kind=$4 meta
  meta=$(cd "$d" && cargo metadata --no-deps --format-version 1 --offline --manifest-path "$mf" 2>/dev/null) || {
    if [ "$kind" = root ]; then bad "$r: cargo metadata failed"; else echo "WARNING: check-deps: $r: cannot read ${mf#"$d"/}, skipped"; fi
    return
  }
  SEEN+=$'\n'$(jq -r '.packages[].manifest_path' <<<"$meta")$'\n'
  local pkg dep src path to
  while IFS=$'\t' read -r pkg dep src path; do
    if [ "$path" != - ]; then
      path=$(realdir "$path" || echo "$path")
      case "$path/" in
        "$d"/*) ;;
        *)
          to=$(repo_of_path "$path")
          if [ -z "$to" ]; then bad "$r/$pkg: path dependency $dep leaves the repository for a place that is no repository of the workshop ($path)"
          elif ! allowed "$r" "$to" "$dep"; then bad "$r/$pkg depends on $to/$dep (not allowed: spec/REPOSITORIES.md, Dependencies)"; fi ;;
      esac
    fi
    case "$src" in
      git+*)
        to=$(repo_of_url "$src")
        [ -n "$to" ] || continue
        allowed "$r" "$to" "$dep" || bad "$r/$pkg depends on $to/$dep (not allowed: spec/REPOSITORIES.md, Dependencies)" ;;
    esac
  done < <(jq -r '.packages[] | .name as $p | .dependencies[] | [$p, .name, (.source // "-"), (.path // "-")] | @tsv' <<<"$meta")
}
for r in $(all_repos); do
  d=$(realdir "$(checkout_of "$r")") || continue
  [ -f "$d/Cargo.toml" ] || continue
  SEEN=
  check_manifest "$r" "$d" "$d/Cargo.toml" root
  while IFS= read -r mf; do
    case "$SEEN" in *$'\n'"$mf"$'\n'*) continue ;; esac
    check_manifest "$r" "$d" "$mf" nested
  done < <(find "$d" \( -name .git -o -name target -o -name vendor -o -name node_modules \) -prune -o -name Cargo.toml -type f -print | LC_ALL=C sort)
done
[ $fail = 0 ] && echo "CHECK-DEPS: OK"
exit $fail
