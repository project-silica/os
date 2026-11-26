#!/usr/bin/env bash
# landed.sh names each thing that is not on main, and is silent about a
# workshop where everything is.
set -uo pipefail
SRC=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd -P)
BASE=${SILICA_RUN:-${TMPDIR:-/tmp}}; mkdir -p "$BASE"
FX=$(mktemp -d "$BASE/landedtest.XXXX") || exit 2
FX=$(cd "$FX" && pwd -P)
trap 'rm -rf "${FX:?}"' EXIT
fails=0
bad() { echo "ERROR: landed-test: $1"; fails=$((fails + 1)); }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.invalid
G() { git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c protocol.file.allow=always "$@"; }

# A workshop with two repositories beside it (idl and os), each cloned from
# a bare origin it is level with.
WS=$FX/ws; UP=$FX/origin
mkrepo() { # mkrepo <name> <dir>: an origin with one commit, cloned to <dir>
  G init -q --bare -b main "$UP/$1.git"
  G clone -q "$UP/$1.git" "$2" 2>/dev/null
  G -C "$2" checkout -q -b main 2>/dev/null
  echo "$1" >"$2/f"; G -C "$2" add f; G -C "$2" commit -qm "$1"; G -C "$2" push -q origin main
  G -C "$2" fetch -q origin
}
mkdir -p "$UP"
mkrepo workshop "$WS"
echo "idl $(printf 'a%.0s' $(seq 40))" >"$WS/bootstrap.pins"; printf 'idl\nos\n' >"$WS/.gitignore"
G -C "$WS" add -A; G -C "$WS" commit -qm pins; G -C "$WS" push -q origin main
mkrepo idl "$WS/idl"
mkrepo os "$WS/os"
mkdir -p "$WS/os/tools"; cp -r "$SRC/lib" "$SRC/landed.sh" "$WS/os/tools/"
printf '[repos.idl]\nurl = "https://example.invalid/idl"\nmilestone = 0\ncommit = "%s"\n' "$(G -C "$WS/idl" rev-parse HEAD)" >"$WS/os/manifest.toml"
G -C "$WS/os" add -A; G -C "$WS/os" commit -qm tools; G -C "$WS/os" push -q origin main
ln -s os/tools "$WS/tools"; echo tools >>"$WS/.gitignore"
G -C "$WS" add -A; G -C "$WS" commit -qm link; G -C "$WS" push -q origin main

run() { OUT=$(cd "$FX" && env -i PATH="${PATH:-/usr/bin:/bin}" HOME="$FX" TMPDIR="$FX" SILICA_WS="$WS" bash "$WS/tools/landed.sh" "$@" 2>&1); RC=$?; }
want() { # want <what> <line pattern>: the run failed and said it, once
  [ $RC = 1 ] || bad "$1: exit status $RC, not 1: $OUT"
  [ "$(grep -cE "$2" <<<"$OUT")" = 1 ] || bad "$1: no single line matching '$2' in: $OUT"
}

run; { [ $RC = 0 ] && grep -q '^LANDED: ' <<<"$OUT" && ! grep -q UNLANDED <<<"$OUT"; } || bad "a workshop with everything on main: status $RC: $OUT"

G -C "$WS/idl" branch side; run; want "a local branch" '^UNLANDED: idl: branch side '
G -C "$WS/idl" push -q origin side; G -C "$WS/idl" branch -q -D side; run; want "a remote branch" '^UNLANDED: idl: remote branch side$'
G -C "$WS/idl" push -q origin :side

G -C "$WS/idl" worktree add -q --detach "$FX/wt" HEAD; run; want "a worktree" "^UNLANDED: idl: worktree $FX/wt\$"
G -C "$WS/idl" worktree remove --force "$FX/wt"

echo more >"$WS/idl/f"; run; want "a modified file" '^UNLANDED: idl: 1 modified or untracked files$'
G -C "$WS/idl" commit -qam more; run; want "an unpushed commit" '^UNLANDED: idl: main has 1 commits origin/main lacks$'
G -C "$WS/idl" push -q origin main

G -C "$WS" checkout -q -b work; run
want "the workshop on a branch" '^UNLANDED: workshop: is on work, not main$'
grep -q '^UNLANDED: workshop: branch work ' <<<"$OUT" || bad "the workshop's branch is not named: $OUT"
G -C "$WS" checkout -q main; G -C "$WS" branch -q -D work

echo stray >"$WS/os/stray"; run; want "an untracked file in os" '^UNLANDED: os: 1 modified or untracked files$'
rm "$WS/os/stray"

run; [ $RC = 0 ] || bad "after everything was put back: status $RC: $OUT"
run --bogus; [ $RC = 2 ] || bad "an unknown option: status $RC, not 2"

[ $fails = 0 ] && echo "RESULT: pass" || { echo "RESULT: fail ($fails)"; exit 1; }
