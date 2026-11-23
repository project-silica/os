# Evidence: what a check has already shown, kept so it is not shown again.
# Sourced after common.sh, by the tools that run checks (test.sh, bench.sh).
#
# A check is a function of its inputs: the sources it builds and runs, the
# harness that runs it, the emulator and firmware it boots on. Run again on
# the same inputs it says the same thing, and the second run buys nothing.
# So each check (a "unit": a suite, one guest boot, one self-test, an
# instruction count, the Linux baseline) names its inputs, and a unit that
# passed on exactly these inputs is not run: its results are read back.
# Change a file a unit depends on and it runs; change one it does not
# depend on and it does not.
#
#   evidence_init                      once per tool run, after new_run
#   held <unit> <input>... -- <cmd>    run <cmd> (a function that appends its
#                                      results to $RES with `record`) unless
#                                      <unit> passed on these inputs before
#   held_bg <unit> <input>... -- <cmd> the same, up to $JOBS at once; `wait`
#                                      collects them
#
# Inputs (each resolves to a hash; the key is the hash of them all):
#   repo:<r>          the checkout of <r> as it is now, tracked changes and
#                     untracked files included
#   repo+:<r>         that, and every repository <r> builds from
#   crate:<r>:<pkg>   the package, the packages of <r> it depends on, and the
#                     workspace's manifest, lock, toolchain, configuration
#                     and vendored crates (a crate's fuzz/ directory is a
#                     crate of its own and is left out)
#   path:<r>:<path>   one file or directory of <r>
#   ws:<path>         a file of the workshop itself (spec/, MILESTONE)
#   file:<path>       a file outside the workshop (its path is part of the key)
#   fn:<name>         a shell function of the harness and every function it
#                     calls, as bash holds them (so a comment is no change).
#                     The unit's own command is always one of its inputs.
#   host:<name>       qemu-<arch> (the emulator, its firmware, whether it
#                     has KVM), kani, cpu (the processor model and microcode,
#                     the host's kernel)
#   env:<NAME>        a variable that changes what the unit does
#   anything else     itself (a machine's options, a duration, a milestone)
#
# The store is one small file per unit and key, <workshop>/target/evidence,
# shared by every worktree of the workshop: the key is content, not place.
# Each file holds its inputs, when and where it ran and how long it took,
# and the unit's result lines. A unit with a failure is never stored, nor
# one that recorded nothing. FRESH=1 (test.sh --fresh, SILICA_FRESH=1) reads
# nothing back and stores what passes; a hosted run starts from a fresh
# clone and so from an empty store, and what is stored is forgotten after a
# month.
#
# What this cannot see: a test whose outcome depends on timing passes once
# and is then held. A test suspected of that is run by name, repeatedly
# (test.sh --guest NAME always runs), not by running everything again.

is_own_git() { # is <dir> the top of a Git working tree of its own (not a directory inside another's)?
  local top
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ "$top" = "$(realdir "$1")" ]
}

EVID=${SILICA_EVIDENCE:-}
if [ -z "$EVID" ]; then
  EVID=$OUTBASE/evidence
  if is_own_git "$WS"; then
    # Every worktree of the workshop reads and writes the main one's store.
    _c=$(git -C "$WS" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || _c=""
    [ -n "$_c" ] && [ -w "$(dirname "$_c")" ] && EVID=$(dirname "$_c")/target/evidence
    unset _c
  fi
fi
FRESH=${SILICA_FRESH:-0}
PLAN=0
# Units at once: each is mostly one emulator of one to four processors, a
# third of a processor each on a large host. Most of a unit is spent waiting
# (a boot, a device, a build step), so a host of four to eight processors
# still runs two: a hosted CI runner (4) ran its whole --fast tier one unit
# at a time and past the job's 5 minutes. On 4 processors (taskset), the
# kernel's --fast --fresh: 1 at once 71 s, 2 at once 47 s, 3 at once 44 s
# (work 71 -> 74 s, guests contending). The units that judge a time run
# alone whatever this is.
_n=$(nproc 2>/dev/null || echo 4)
JOBS=${SILICA_JOBS:-$(( _n / 3 > 2 ? _n / 3 : (_n >= 4 ? 2 : 1) ))}
unset _n
[ "$JOBS" -ge 1 ] 2>/dev/null || JOBS=1

declare -A TREE=() EV_MEMO=() EV_KEYS=() EV_GIT=() EV_OBJECTS=() EV_FN=()
EV_KEY="" EV_TEXT="" EV_VAL=""

ev_git() { # ev_git <repo> <git arguments>: git in the checkout, with the objects of this run's snapshot
  local r=$1; shift
  GIT_OBJECT_DIRECTORY=$RUN/objects GIT_ALTERNATE_OBJECT_DIRECTORIES=${EV_OBJECTS[$r]} git -C "$(checkout_of "$r")" "$@"
}
plain_hash() { # a file or a directory that Git does not track: its contents
  if [ -f "$1" ]; then sha256sum <"$1" | cut -c1-40
  elif [ -d "$1" ]; then
    (cd "$1" && find . \( -name target -o -name .git \) -prune -o -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum | sha256sum | cut -c1-40)
  else echo absent; fi
}
# tree_now <repo>: the Git tree of the checkout as it is now. The index is
# copied and everything not ignored is added to the copy; the objects go to
# the run's directory, so nothing in the checkout or its repository changes.
# Markdown is left out: no build, test or image reads a repository's .md
# files (the workshop's own, spec/ among them, are named one by one as ws:
# inputs), and with them in, an edit to a README made every check that
# depends on the repository run again.
tree_now() {
  local r=$1 d idx
  d=$(checkout_of "$r")
  if [ "${EV_GIT[$r]}" = 1 ]; then
    idx=$RUN/index.${r//[!A-Za-z0-9]/_}
    cp "$(git -C "$d" rev-parse --absolute-git-dir)/index" "$idx" 2>/dev/null || rm -f "$idx"
    GIT_INDEX_FILE=$idx ev_git "$r" add -A . >/dev/null 2>&1 &&
      GIT_INDEX_FILE=$idx ev_git "$r" rm -r -q --cached --ignore-unmatch -- '*.md' >/dev/null 2>&1 &&
      GIT_INDEX_FILE=$idx ev_git "$r" write-tree 2>/dev/null && return 0
  fi
  plain_hash "$d"
}
evidence_init() {
  local r d
  [ -n "${RUN:-}" ] || die "evidence_init before new_run"
  mkdir -p "$EVID" "$RUN/objects" || die "cannot create the evidence store $EVID"
  # Nothing is believed for longer than a month: the host is an input no
  # key names in full, and a tree that old is rarely the one being built.
  find "$EVID" -type f -mtime +30 -delete 2>/dev/null
  : >>"$RUN/units.tsv"
  for r in $(all_repos); do
    d=$(checkout_of "$r"); [ -d "$d" ] || continue
    EV_GIT[$r]=0
    if is_own_git "$d"; then
      EV_GIT[$r]=1
      EV_OBJECTS[$r]=$(git -C "$d" rev-parse --path-format=absolute --git-path objects)
    fi
    TREE[$r]=$(tree_now "$r")
  done
}

# repo_deps <repo>: the repositories its manifests name, directly or through
# another (a path into a sibling checkout, or the repository's URL).
repo_deps() {
  local r=$1 o d url seen=" $1 " todo="$1" cur out=""
  while [ -n "$todo" ]; do
    cur=${todo%% *}; todo=${todo#"$cur"}; todo=${todo# }
    d=$(checkout_of "$cur")
    for o in $(all_repos); do
      case "$seen" in *" $o "*) continue ;; esac
      [ -d "$(checkout_of "$o")" ] || continue
      url=$(manifest_get "$o" url)
      if grep -rqsE --include=Cargo.toml --exclude-dir=vendor --exclude-dir=target "\"(\.\./)+${o//./\\.}/${url:+|\"$url\"}" "$d" 2>/dev/null; then
        seen="$seen$o "; todo="$todo $o"; todo=${todo# }; out="$out $o"
      fi
    done
  done
  echo "$out"
}
path_hash() { # path_hash <repo> <path> [<left out>]: one file or directory of the checkout's snapshot
  local r=$1 p=$2 d
  d=$(checkout_of "$r")
  if [ "${EV_GIT[$r]:-0}" = 1 ]; then
    if [ -n "${3:-}" ]; then
      ev_git "$r" ls-tree "${TREE[$r]}" -- "$p/" 2>/dev/null | grep -v "	$p/$3\$" | sha256sum | cut -c1-40
    else
      ev_git "$r" ls-tree "${TREE[$r]}" -- "$p" 2>/dev/null | awk '{ print $3; found = 1 } END { if (!found) print "absent" }'
    fi
  elif [ -n "${3:-}" ] && [ -d "$d/$p" ]; then
    (cd "$d/$p" && find . \( -name target -o -name .git -o -path "./$3" \) -prune -o -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum | sha256sum | cut -c1-40)
  else plain_hash "$d/$p"; fi
}
# crate_hash <repo> <package>: see "crate:" above.
crate_hash() {
  local r=$1 pkg=$2 d meta dirs dir o od out=""
  d=$(checkout_of "$r"); meta=$RUN/metadata.${r//[!A-Za-z0-9]/_}.json
  [ -s "$meta" ] || (cd "$d" && cargo metadata --no-deps --format-version 1 --offline 2>/dev/null) >"$meta"
  dirs=$(jq -r --arg pkg "$pkg" '. as $doc
    | def close($todo; $seen): if ($todo | length) == 0 then $seen
        elif ($seen | index($todo[0])) then close($todo[1:]; $seen)
        else close($todo[1:] + [$doc.packages[] | select((.manifest_path | rtrimstr("/Cargo.toml")) == $todo[0]) | .dependencies[] | select(.path) | .path]; $seen + [$todo[0]]) end;
      close([$doc.packages[] | select(.name == $pkg) | .manifest_path | rtrimstr("/Cargo.toml")]; []) | .[]' "$meta" 2>/dev/null)
  [ -n "$dirs" ] || { echo "no-package-$pkg"; return; }
  while IFS= read -r dir; do
    case "$dir" in
      "$d") out="$out . ${TREE[$r]}" ;;
      "$d"/*) out="$out ${dir#"$d"/} $(path_hash "$r" "${dir#"$d"/}" fuzz)" ;;
      *) # a package of another checkout: that repository, whole
        for o in $(all_repos); do
          od=$(checkout_of "$o")
          case "$dir" in "$od"|"$od"/*) out="$out $o ${TREE[$o]:-absent}" ;; esac
        done ;;
    esac
  done <<<"$dirs"
  for dir in Cargo.toml Cargo.lock rust-toolchain.toml .cargo vendor; do out="$out $dir $(path_hash "$r" "$dir")"; done
  printf '%s' "$out" | sha256sum | cut -c1-40
}
host_hash() {
  local a f
  case "$1" in
    qemu-*)
      a=${1#qemu-}; f=$(firmware_of "$a" code)
      { "qemu-system-$a" --version 2>/dev/null | head -n 1
        [ -n "$f" ] && sha256sum <"$f"
        [ "$a" = x86_64 ] && [ -w /dev/kvm ] && [ -z "${SILICA_NO_KVM:-}" ] && echo kvm
      } | sha256sum | cut -c1-40 ;;
    kani) { cargo kani --version 2>/dev/null || echo none; } | sha256sum | cut -c1-40 ;;
    cpu) { LC_ALL=C lscpu 2>/dev/null | grep -E '^(Model name|Stepping)'; grep -m1 microcode /proc/cpuinfo 2>/dev/null; uname -r; } | sha256sum | cut -c1-40 ;;
    *) echo unknown ;;
  esac
}
# fn_hashes: for every shell function defined now, the hash of its text and
# of the text of every function it names, directly or through another (a
# name appearing as a word counts: more than the calls, never fewer).
fn_hashes() {
  local dir=$RUN/functions n h f
  [ ${#EV_FN[@]} -eq 0 ] || return 0
  rm -rf "$dir"; mkdir -p "$dir"
  declare -f | awk -v dir="$dir" '
    /^[A-Za-z_][A-Za-z0-9_]* \(\) *$/ { name = $1; names[name] = 1; next }
    name != "" { body[name] = body[name] $0 "\n" }
    END {
      for (n in names) { text = body[n]; gsub(/[^A-Za-z0-9_]+/, " ", text); k = split(text, w, " ")
        for (i = 1; i <= k; i++) if ((w[i] in names) && w[i] != n) calls[n, w[i]] = 1 }
      for (n in names) {
        delete seen; seen[n] = 1; m = 1; todo[1] = n
        while (m > 0) { cur = todo[m--]; for (o in names) if (((cur, o) in calls) && !(o in seen)) { seen[o] = 1; todo[++m] = o } }
        k = 0; for (o in seen) list[++k] = o
        # A fixed order, so the same closure hashes the same.
        for (i = 2; i <= k; i++) { v = list[i]; for (j = i - 1; j >= 1 && list[j] > v; j--) list[j + 1] = list[j]; list[j + 1] = v }
        f = dir "/" n; for (i = 1; i <= k; i++) printf "%s ()\n%s", list[i], body[list[i]] >f; close(f)
      }
    }'
  while read -r h f; do EV_FN[${f##*/}]=${h:0:40}; done < <(cd "$dir" && sha256sum -- * 2>/dev/null)
  rm -rf "$dir"
}

ev_resolve() { # ev_resolve <input>: sets EV_VAL to its hash (remembered for the run)
  local t=$1 v r o rest
  if [ -n "${EV_MEMO[$t]+x}" ]; then EV_VAL=${EV_MEMO[$t]}; return; fi
  case "$t" in
    repo:*) v=${TREE[${t#repo:}]:-absent} ;;
    repo+:*) r=${t#repo+:}; v=${TREE[$r]:-absent}; for o in $(repo_deps "$r"); do v="$v+${TREE[$o]:-absent}"; done ;;
    crate:*:*) rest=${t#crate:}; v=$(crate_hash "${rest%%:*}" "${rest#*:}") ;;
    path:*:*) rest=${t#path:}; v=$(path_hash "${rest%%:*}" "${rest#*:}") ;;
    ws:*) v=$(plain_hash "$WS/${t#ws:}") ;;
    file:*) v=$(plain_hash "${t#file:}") ;;
    fn:*) fn_hashes; v=${EV_FN[${t#fn:}]:-absent} ;;
    host:*) v=$(host_hash "${t#host:}") ;;
    env:*) r=${t#env:}; v=${!r-unset} ;;
    *) v=- ;;
  esac
  EV_MEMO[$t]=$v; EV_VAL=$v
}
evidence_key() { # evidence_key <input>...: sets EV_TEXT (one "<input> <hash>" line each) and EV_KEY
  local t memo="$*"
  EV_TEXT=""
  for t in "$@"; do ev_resolve "$t"; EV_TEXT+="$t $EV_VAL"$'\n'; done
  if [ -z "${EV_KEYS[$memo]+x}" ]; then
    t=$(printf '%s' "$EV_TEXT" | sha256sum); EV_KEYS[$memo]=${t:0:32}
  fi
  EV_KEY=${EV_KEYS[$memo]}
}
ev_dir() { echo "$EVID/${1//[!A-Za-z0-9_.+-]/_}"; }
# ev_last <unit>: "<seconds> <changed inputs>" against the unit's last pass
# ($EV_TEXT is what it would run on now): why it runs, and for how long.
ev_last() {
  local dir; dir=$(ev_dir "$1")
  [ -f "$dir/latest" ] || { echo "- new"; return; }
  NOW=$EV_TEXT awk '
    BEGIN { n = split(ENVIRON["NOW"], l, "\n"); for (i = 1; i <= n; i++) if (l[i] != "") { k = l[i]; sub(/ [^ ]*$/, "", k); want[k] = l[i] } }
    /^# seconds / { secs = $3 }
    /^# input / { line = substr($0, 9); k = line; sub(/ [^ ]*$/, "", k); had[k] = line }
    END { out = ""
      for (k in want) if (had[k] != want[k]) out = out " " k
      for (k in had) if (!(k in want)) out = out " " k
      printf "%s%s\n", (secs == "" ? "-" : secs), (out == "" ? " nothing (asked to run again)" : out) }' "$dir/latest"
}

held() { ev_unit 0 "$@"; }
held_bg() { ev_unit 1 "$@"; }
ev_unit() {
  local bg=$1 unit=$2 dir; shift 2
  local -a in=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do in+=("$1"); shift; done
  shift
  # The command is an input: its words, and the function behind the first.
  evidence_key "${in[@]+"${in[@]}"}" "fn:$1" "command:$*"
  dir=$(ev_dir "$unit")
  if [ "$FRESH" != 1 ] && [ -f "$dir/$EV_KEY" ]; then
    grep -v '^#' "$dir/$EV_KEY" >>"$RES"
    printf 'held\t%s\n' "$unit" >>"$RUN/units.tsv"
    return 0
  fi
  if [ "$PLAN" = 1 ]; then
    printf 'plan\t%s\t%s\n' "$unit" "$(ev_last "$unit")" >>"$RUN/units.tsv"
    return 0
  fi
  if [ "$bg" = 1 ]; then
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n 2>/dev/null || break; done
    ev_run "$unit" "$dir" "$EV_KEY" "$EV_TEXT" "$@" &
  else
    ev_run "$unit" "$dir" "$EV_KEY" "$EV_TEXT" "$@"
  fi
}
# ev_run: the unit's command with a result file and a scratch directory
# ($UNIT_DIR: its images) of its own; then its results join the run's, and
# go to the store if none is a failure.
ev_run() {
  local unit=$1 dir=$2 key=$3 text=$4 part t0=$SECONDS rc tmp
  shift 4
  part=$(mktemp "$RUN/unit.XXXXXX") || return 1
  mkdir -p "$part.d"
  UNIT_DIR=$part.d RES=$part "$@"
  rc=$?
  cat "$part" >>"$RES"
  printf 'ran\t%s\t%s\n' "$unit" "$((SECONDS - t0))" >>"$RUN/units.tsv"
  if [ -s "$part" ] && ! grep -q $'^fail\t' "$part"; then
    mkdir -p "$dir" && tmp=$(mktemp "$dir/.new.XXXXXX") && {
      printf '# unit %s\n# at %s\n# run %s\n# workshop %s\n# seconds %s\n' "$unit" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${RUN##*/}" "$WS" "$((SECONDS - t0))"
      printf '%s' "$text" | sed 's/^/# input /'
      cat "$part"
    } >"$tmp" && mv "$tmp" "$dir/$key" && ln -sfn "$key" "$dir/latest"
  fi
  rm -rf "$part" "$part.d"
  return $rc
}
# units_summary: what this run ran and what it held, one line.
units_summary() {
  awk -F'\t' '$1 == "ran" { r++; s += $3 } $1 == "held" { h++ }
    END { if (r + h) printf "%s: ran %d checks (%d s of work), held %d that passed on these inputs before%s\n", tool, r, s, h, (h ? " (--fresh runs them again)" : "") }' \
    tool="$TOOL_NAME" "$RUN/units.tsv"
}
# plan_summary: what would run (test.sh --plan), by suite, with how long each
# took the last time it ran and which of its inputs changed since it passed.
plan_summary() {
  awk -F'\t' '
    $1 == "held" { h++ }
    $1 == "plan" { s = $2; sub(/\/.*/, "", s); if (!(s in n)) order[++k] = s; n[s]++
      split($3, a, " "); if (a[1] != "-") t[s] += a[1]; else unknown[s] = 1
      why = $3; sub(/^[^ ]* /, "", why); if (!(s in w)) w[s] = why }
    END {
      for (i = 1; i <= k; i++) { s = order[i]; total += t[s]
        printf "plan: %s: %d to run, %s%d s the last time; changed: %s\n", s, n[s], (s in unknown ? "at least " : ""), t[s], w[s] }
      printf "plan: %d checks to run (about %d s of work, less in parallel), %d held\n", length(n) ? sumn() : 0, total, h }
    function sumn(  x, c) { for (x in n) c += n[x]; return c }' "$RUN/units.tsv"
}

# A unit whose result is a file of values (an instruction count, a
# benchmark's samples, the Linux baseline) instead of test results:
#   kept <unit> <input>...   sets EV_KEY, EV_TEXT and EV_FILE (where the
#                            values are stored); succeeds when they are
#                            there and FRESH is not set
#   keep <unit> <key> <text> <file>
#                            stores <file> as the unit's values for the key
#                            and inputs a `kept` call computed
#   kept_at <file>           when a stored file was measured (its date)
kept() {
  local unit=$1; shift
  evidence_key "$@"
  EV_FILE=$(ev_dir "$unit")/$EV_KEY
  [ "$FRESH" != 1 ] && [ -f "$EV_FILE" ]
}
keep() {
  local dir tmp; dir=$(ev_dir "$1")
  mkdir -p "$dir" && tmp=$(mktemp "$dir/.new.XXXXXX") || return 1
  { printf '# unit %s\n# at %s\n# run %s\n# workshop %s\n' "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${RUN##*/}" "$WS"
    printf '%s' "$3" | sed 's/^/# input /'
    grep -v '^#' "$4"
  } >"$tmp" && mv "$tmp" "$dir/$2" && ln -sfn "$2" "$dir/latest"
}
kept_at() { sed -n 's/^# at \([0-9-]*\)T\([0-9:]*\)Z$/\1 \2 UTC/p' "$1" | head -n 1; }
