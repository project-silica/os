#!/usr/bin/env bash
# Component manifest pinning and clean-checkout checks.
set -uo pipefail
SRC=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd -P)
BASE=${SILICA_RUN:-${TMPDIR:-/tmp}}; mkdir -p "$BASE"
FX=$(mktemp -d "$BASE/pintest.XXXX") || exit 2
FX=$(cd "$FX" && pwd -P)
trap 'rm -rf "${FX:?}"' EXIT
fails=0
bad() { echo "ERROR: pin-test: $1"; fails=$((fails + 1)); }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.invalid
G() { git -c core.hooksPath=/dev/null -c commit.gpgsign=false "$@"; }

WS=$FX/ws; OS=$WS/os; ST=$WS/elsewhere; MF=$OS/manifest.toml
mkdir -p "$ST" "$OS/tools"
echo x >"$WS/bootstrap.pins"
cp -r "$SRC/lib" "$SRC/pin.sh" "$OS/tools/"
ln -s os/tools "$WS/tools"
ZERO40=$(printf 'a%.0s' $(seq 40))

commit() { # commit <dir> <file> <text>: a commit changing one file
  echo "$3" >"$1/$2"; G -C "$1" add "$2"; G -C "$1" commit -qm "$3"
}
head_of() { G -C "$WS/$1" rev-parse refs/heads/main; }
mkrepo() { # mkrepo <name>: a repository with two commits on main
  mkdir -p "$WS/$1"; G -C "$WS/$1" init -q -b main .
  commit "$WS/$1" f "$1 one"; commit "$WS/$1" f "$1 two"
}
setup() { # a fresh workshop: spec, idl, .github cloned; kernel (milestone 1) not cloned; os
  local r
  for r in spec idl .github kernel; do rm -rf "${WS:?}/${r:?}"; done
  rm -rf "${OS:?}/.git" "${ST:?}"; mkdir -p "$ST"
  for r in spec idl .github; do mkrepo "$r"; done
  G -C "$OS" init -q -b main .
  {
    echo "# The single definition of the system."
    for r in spec idl .github; do
      printf '\n[repos.%s]\nurl = "https://example.invalid/%s"\nmilestone = 0\ncommit = "%s"  # old\n' \
        "$( [ "$r" = .github ] && echo '".github"' || echo "$r" )" "$r" "$(G -C "$WS/$r" rev-parse HEAD~1)"
    done
    printf '\n[repos.kernel]\nurl = "https://example.invalid/kernel"\nmilestone = 1\ncommit = "%s"\n' "$ZERO40"
  } >"$MF"
  chmod 644 "$MF"
  echo tools >"$OS/README"
  G -C "$OS" add -A; G -C "$OS" commit -qm base
  for r in spec idl .github; do commit "$WS/$r" f three; done   # main is now one ahead of every pin
}
RENV=()
run() { # run <script> <args...>: OUT and RC; the tools are reached through the workshop link
  local s=$1; shift
  OUT=$(cd "$ST" && env -i PATH="${PATH:-/usr/bin:/bin}" HOME="$FX" TMPDIR="$FX" SILICA_WS="$WS" "${RENV[@]+"${RENV[@]}"}" bash "$WS/tools/$s" "$@" 2>&1)
  RC=$?
}
run_locked() { # like run, while another process holds the pin lock
  ( exec 9>"$WS/target/.pin.lock"; flock -n 9 && { run "$@"; echo "$RC" >"$FX/rc"; printf '%s\n' "$OUT" >"$FX/out"; } ) 2>/dev/null
  RC=$(cat "$FX/rc" 2>/dev/null || echo 0); OUT=$(cat "$FX/out" 2>/dev/null)
  rm -f "$FX/rc" "$FX/out"
}
snap() { # everything that must not change on an error or a read-only run
  (for d in "$WS"/*/ "$WS"/.github/; do [ -e "$d/.git" ] || continue
     echo "$d"; G -C "$d" rev-parse HEAD refs/heads/main 2>&1; G -C "$d" for-each-ref 2>&1; G -C "$d" status --porcelain --untracked-files=all 2>&1
     (cd "$d" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 sha256sum 2>/dev/null); done
   ls -A "$ST") | sha256sum
}
nerr() { printf '%s\n' "$OUT" | grep -c '^ERROR:'; }
want_err() { # want_err <label> <regex>: nonzero, an ERROR: line matches, nothing changed ($S)
  [ "$RC" != 0 ] || bad "$1: exit 0, want an error: $OUT"
  printf '%s\n' "$OUT" | grep -E '^ERROR:' | grep -qE -- "$2" || bad "$1: no ERROR line matching '$2': $(printf '%s' "$OUT" | head -n 3 | tr '\n' '|')"
  [ "$(snap)" = "$S" ] || bad "$1: something changed on an error"
}
want_ok() { # want_ok <label> <last-line regex>
  [ "$RC" = 0 ] || bad "$1: exit $RC, want 0: $(printf '%s' "$OUT" | tail -n 3 | tr '\n' '|')"
  printf '%s\n' "$OUT" | tail -n 1 | grep -qE -- "$2" || bad "$1: last line '$(printf '%s\n' "$OUT" | tail -n 1)' does not match '$2'"
  [ "$(nerr)" = 0 ] || bad "$1: an ERROR: line on success: $OUT"
}
nc() { G -C "$OS" rev-list --count HEAD; }
pinned() { awk -v r="$1" '/^\[/ { s=$0; gsub(/^\[repos\.|"|\]$/, "", s); cur=s } cur==r && $1=="commit" { gsub(/"/, "", $3); print $3 }' "$MF"; }

# ===== 1. pin ===============================================================
setup
cp "$MF" "$FX/manifest.before"
echo dirty >>"$OS/README"; echo staged >"$OS/staged.txt"; G -C "$OS" add staged.txt
N=$(nc)
run pin.sh
want_ok "pin" '^PIN: spec idl \.github$'
for r in spec idl .github; do [ "$(pinned "$r")" = "$(head_of "$r")" ] || bad "pin: $r pinned $(pinned "$r"), want its main $(head_of "$r")"; done
[ "$(pinned kernel)" = "$ZERO40" ] || bad "pin: the uncloned kernel's pin changed to $(pinned kernel)"
diff <(sed 's/commit = "[0-9a-f]*"/commit = X/' "$FX/manifest.before") <(sed 's/commit = "[0-9a-f]*"/commit = X/' "$MF") >/dev/null ||
  bad "pin: the manifest changed in more than the commit values"
grep -q 'commit = "[0-9a-f]*"  # old' "$MF" || bad "pin: a comment after a pin was lost"
[ "$(stat -c %a "$MF")" = 644 ] || bad "pin: manifest mode is $(stat -c %a "$MF"), want 644"
[ "$(nc)" = $((N + 1)) ] || bad "pin: want one new commit in os, got $(($(nc) - N))"
G -C "$OS" log -1 --format=%s | grep -qE '^Pin ' || bad "pin: commit subject '$(G -C "$OS" log -1 --format=%s)'"
[ "$(G -C "$OS" show --name-only --format= HEAD | tr '\n' ' ')" = "manifest.toml " ] || bad "pin: commit touches $(G -C "$OS" show --name-only --format= HEAD | tr '\n' ' ')"
[ "$(G -C "$OS" diff --name-only | tr '\n' ' ')" = "README " ] || bad "pin: unrelated dirty file was committed or reset"
[ "$(G -C "$OS" diff --cached --name-only | tr '\n' ' ')" = "staged.txt " ] || bad "pin: another staged file was committed or unstaged"
[ "$(for r in spec idl .github; do G -C "$WS/$r" status --porcelain; done | wc -l)" = 0 ] || bad "pin: changed a pinned repository"
# a second pin changes nothing
N=$(nc); S=$(snap)
run pin.sh; want_ok "pin again" '^PIN: unchanged$'
[ "$(nc)" = "$N" ] && [ "$(snap)" = "$S" ] || bad "pin again: changed something"
# the pin is main's head, not the clone's current HEAD or an unmerged branch
G -C "$WS/spec" checkout -q -b side; commit "$WS/spec" f side; G -C "$WS/spec" checkout -q --detach main
commit "$WS/idl" f four
G -C "$OS" reset -q; rm -f "${OS:?}/staged.txt"; G -C "$OS" checkout -q -- README
run pin.sh; want_ok "pin one" '^PIN: idl$'
[ "$(pinned idl)" = "$(head_of idl)" ] && [ "$(pinned spec)" = "$(head_of spec)" ] || bad "pin one: wrong pins"
# a later milestone's repository that is cloned is pinned too
mkrepo kernel; run pin.sh; want_ok "pin kernel" '^PIN: kernel$'
[ "$(pinned kernel)" = "$(head_of kernel)" ] || bad "pin kernel: not pinned"
G -C "$OS" log -1 --format=%s | grep -q 'kernel' || bad "pin kernel: commit subject does not name kernel"

# ===== 2. pin errors change nothing ========================================
setup
echo "# edit" >>"$MF"; S=$(snap)
run pin.sh; want_err "uncommitted manifest" 'uncommitted'
G -C "$OS" checkout -q -- manifest.toml
G -C "$WS/idl" branch -m main other
S=$(snap); run pin.sh; want_err "a repository without main" 'idl.*no main'
G -C "$WS/idl" branch -m other main
[ "$(pinned spec)" != "$(head_of spec)" ] || bad "a repository without main: the other pins were moved"
setup
touch "$OS/.git/index.lock"; S=$(snap)
run pin.sh; want_err "failed commit" 'commit'
[ -z "$(G -C "$OS" status --porcelain -- manifest.toml)" ] || bad "failed commit: manifest.toml left modified"
rm -f "${OS:?}/.git/index.lock"
run pin.sh; want_ok "pin after a failed commit" '^PIN: '
# a manifest entry without a commit value cannot be pinned
setup; sed -i '/^\[repos.idl\]/,/^$/{/^commit/d}' "$MF"; G -C "$OS" commit -qam "no commit key"; S=$(snap)
run pin.sh; want_err "no commit key" 'idl'
# the pin lock is held: no pin
setup; run_locked pin.sh
[ "$RC" != 0 ] && printf '%s\n' "$OUT" | grep -q '^ERROR:.*lock' || bad "lock held: pin.sh ran or gave no lock error: rc=$RC $OUT"
[ "$(pinned spec)" != "$(head_of spec)" ] || bad "lock held: the manifest changed"
# arguments
setup; S=$(snap)
run pin.sh --bogus; want_err "unknown argument" '^ERROR: pin: usage'
run pin.sh --check extra; want_err "extra argument to --check" 'usage'
run pin.sh pin; want_err "the word pin is not an argument" 'usage'
run pin.sh --check --check; want_err "repeated --check" 'usage'
# hooks never run
setup
for h in pre-commit commit-msg post-commit; do printf '#!/bin/sh\necho ran >>%s/hook.log\nexit 1\n' "$FX" >"$OS/.git/hooks/$h"; chmod +x "$OS/.git/hooks/$h"; done
G -C "$OS" config core.hooksPath "$OS/.git/hooks"
run pin.sh; want_ok "hooks configured" '^PIN: '
[ ! -e "$FX/hook.log" ] || bad "a Git hook ran"
G -C "$OS" config --unset core.hooksPath

# ===== 3. pin --check ======================================================
setup; run pin.sh >/dev/null; S=$(snap)
run pin.sh --check; want_ok "check ok" '^PIN: CHECK OK$'
[ "$(snap)" = "$S" ] || bad "check ok: changed something"
# a clone on a detached head at its pin is at its pin
G -C "$WS/spec" checkout -q --detach "$(pinned spec)"; S=$(snap)
run pin.sh --check; want_ok "check detached at pin" '^PIN: CHECK OK$'
# a clone ahead of its pin
commit "$WS/idl" f five; S=$(snap)
run pin.sh --check; want_err "clone ahead" '^ERROR: pin: idl is at [0-9a-f]{12}, pinned [0-9a-f]{12}'
[ "$(nerr)" = 1 ] || bad "clone ahead: want one ERROR line, got $(nerr)"
printf '%s\n' "$OUT" | grep -q "CHECK OK" && bad "clone ahead: printed CHECK OK"
G -C "$WS/idl" reset -q --hard HEAD~1
# modified and untracked files, in two repositories and in os: one line each
echo m >>"$WS/spec/f"; echo u >"$WS/.github/untracked"; echo u >"$OS/untracked"; S=$(snap)
run pin.sh --check; want_err "dirty" '^ERROR: pin: spec has modified'
[ "$(nerr)" = 3 ] || bad "dirty: want 3 ERROR lines, got $(nerr): $OUT"
printf '%s\n' "$OUT" | grep -q '^ERROR: pin: \.github has modified' || bad "dirty: untracked file in .github not reported"
printf '%s\n' "$OUT" | grep -q '^ERROR: pin: os has modified' || bad "dirty: untracked file in os not reported"
G -C "$WS/spec" checkout -q -- f; rm -f "${WS:?}/.github/untracked" "${OS:?}/untracked"
# a modified manifest in os
echo "# x" >>"$MF"; S=$(snap); run pin.sh --check; want_err "manifest modified" '^ERROR: pin: os has modified'; G -C "$OS" checkout -q -- manifest.toml
# a repository that is not cloned: an error when its milestone has come, none before
echo 1 >"$WS/MILESTONE"; mkrepo kernel; run pin.sh >/dev/null
mv "$WS/kernel" "$FX/kernel.away"; S=$(snap)
run pin.sh --check; want_err "uncloned at its milestone" '^ERROR: pin: kernel is not cloned'
echo 0 >"$WS/MILESTONE"; S=$(snap)
run pin.sh --check; want_ok "uncloned before its milestone" '^PIN: CHECK OK$'
rm -f "${WS:?}/MILESTONE"
run pin.sh --check; want_ok "uncloned, no milestone file" '^PIN: CHECK OK$'
mv "$FX/kernel.away" "$WS/kernel"
# a clone with no commits
mv "$WS/idl" "$FX/idl.away"; mkdir "$WS/idl"; G -C "$WS/idl" init -q -b main .; S=$(snap)
run pin.sh --check; want_err "empty clone" '^ERROR: pin: idl'
rm -rf "${WS:?}/idl"; mv "$FX/idl.away" "$WS/idl"

[ "$fails" = 0 ]
