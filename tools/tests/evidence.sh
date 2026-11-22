#!/usr/bin/env bash
# Test for tools/lib/evidence.sh (spec/TESTING.md section 2): a check that
# passed on its inputs is held, and anything that could change its answer
# runs it again. Each rule is shown both ways, because a store that holds
# too much lets a broken change through and one that holds too little is
# the hour it was built to save. Runs a private copy of the library in a
# disposable fake workshop (a Git repository with two checkouts: `os`, and
# `lib`, a Cargo workspace of three small crates), driven by a script that
# runs the units a check names. One "ERROR:" line per failed check.
set -uo pipefail
SRC=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd -P)
BASE=${SILICA_RUN:-${TMPDIR:-/tmp}}; mkdir -p "$BASE"
FX=$(mktemp -d "$BASE/evidencetest.XXXX") || exit 2
FX=$(cd "$FX" && pwd -P)
trap 'rm -rf "${FX:?}"' EXIT
fails=0
bad() { echo "ERROR: evidence-test: $1"; fails=$((fails + 1)); }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.invalid
gx() { git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c init.defaultBranch=main "$@"; }

WS=$FX/ws; OS=$WS/os; LIBR=$WS/lib; COUNT=$FX/count
mkdir -p "$OS/tools" "$LIBR/a/src" "$LIBR/b/src" "$LIBR/c/src" "$LIBR/a/fuzz"
cp -r "$SRC/lib" "$OS/tools/"
printf '[repos.lib]\nurl = "https://example.invalid/lib"\nmilestone = 0\ncommit = "x"\n' >"$OS/manifest.toml"
printf '[workspace]\nresolver = "2"\nmembers = ["a", "b", "c"]\n' >"$LIBR/Cargo.toml"
for c in a b c; do
  printf '[package]\nname = "%s"\nversion = "0.0.0"\nedition = "2021"\n' "$c" >"$LIBR/$c/Cargo.toml"
  echo "pub fn $c() {}" >"$LIBR/$c/src/lib.rs"
done
printf '[dependencies]\nb = { path = "../b" }\n' >>"$LIBR/a/Cargo.toml"   # a builds from b; c is nobody's
echo seed >"$LIBR/a/fuzz/corpus"
printf 'target/\nignored.txt\n' >"$LIBR/.gitignore"
# The driver: defines a few checks, then runs what $SCRIPT says.
cat >"$OS/tools/drive.sh" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"
. "$TOOLS/lib/evidence.sh"
new_run; RES=$RUN/results.tsv; : >"$RES"
record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >>"$RES"; }
helper() { :; }
unrelated() { :; }
check() { echo "$1" >>"$COUNT"; helper; record "${OUTCOME:-pass}" suite "$1" "${WHY:-}"; }
silent() { echo "$1" >>"$COUNT"; }
slow() { sleep 0.3; check "$1"; }
eval "${DEFS:-}"
evidence_init
eval "$SCRIPT"
wait
cat "$RES"
[ "$PLAN" = 1 ] && plan_summary
units_summary
EOF
for r in "$OS" "$LIBR"; do gx -C "$r" init -q && gx -C "$r" add -A && gx -C "$r" commit -qm one; done
echo x >"$WS/bootstrap.pins"; printf '/os/\n/lib/\n/target/\n' >"$WS/.gitignore"
gx -C "$WS" init -q && gx -C "$WS" add -A && gx -C "$WS" commit -qm one

# drive <script>: sets OUT; ran: how many times a check ran since `fresh`.
drive() { OUT=$(SILICA_WS=${WSNOW:-$WS} COUNT=$COUNT SCRIPT=$1 bash "${WSNOW:-$WS}/os/tools/drive.sh" 2>&1); }
fresh() { rm -f "$COUNT"; }
ran() { [ -f "$COUNT" ] && wc -l <"$COUNT" || echo 0; }
has() { grep -qE -- "$1" <<<"$OUT"; }
# twice <what> <script>: after a first run, the same again must be held.
held_now() { fresh; drive "$2"; [ "$(ran)" = 0 ] || bad "$1: must be held, ran $(ran): $OUT"; }
runs_now() { fresh; drive "$2"; [ "$(ran)" = "${3:-1}" ] || bad "$1: must run ${3:-1}, ran $(ran): $OUT"; }

# ---- 1. held on the same inputs, with the same results -------------------------
U='held u repo:lib -- check one'
runs_now "first run" "$U"
has '^pass	suite	one	$' && has '^drive: ran 1 checks .*held 0 ' || bad "first run: result and summary: $OUT"
held_now "second run" "$U"
has '^pass	suite	one	$' && has '^drive: ran 0 checks .*held 1 that passed on these inputs before' || bad "held: the result is read back and the run says so: $OUT"

# ---- 2. the checkout as it is now: tracked, untracked, not ignored ---------------
echo "pub fn a2() {}" >>"$LIBR/a/src/lib.rs"; runs_now "a tracked file changed (not committed)" "$U"; held_now "after it" "$U"
echo new >"$LIBR/new.txt"; runs_now "an untracked file appeared" "$U"; held_now "after it" "$U"
echo junk >"$LIBR/ignored.txt"; mkdir -p "$LIBR/target"; echo o >"$LIBR/target/o"; held_now "an ignored file is not an input" "$U"
gx -C "$LIBR" add -A; gx -C "$LIBR" commit -qm two; held_now "committing what was there changes nothing" "$U"
# The key is content: taking the file out again gives the tree that passed
# two steps ago, and that is held; a tree never seen is not.
rm "$LIBR/new.txt"; held_now "back to a tree that passed before" "$U"
rm "$LIBR/c/src/lib.rs"; runs_now "a file removed" "$U"
# Markdown is no input of a check: a README or a document beside the code
# changes no build and no result; the source beside it still does.
echo "# lib" >"$LIBR/README.md"; mkdir -p "$LIBR/a/doc"; echo notes >"$LIBR/a/doc/notes.md"
held_now "a Markdown file added or changed is not an input" "$U"
echo "pub fn c_md() {}" >"$LIBR/c/src/lib.rs"; runs_now "the source beside it still is" "$U"
rm "$LIBR/c/src/lib.rs"; rm -rf "$LIBR/README.md" "$LIBR/a/doc"; held_now "back to the tree without them" "$U"
echo "pub fn c() {}" >"$LIBR/c/src/lib.rs"
gx -C "$LIBR" add -A; gx -C "$LIBR" commit -qm three

# ---- 3. a failure is never stored; nor a unit that recorded nothing ----------------
F='held f repo:lib -- check two'
fresh; OUTCOME=fail drive "$F"; has '^fail	suite	two' || bad "a failing unit's result is reported: $OUT"
fresh; OUTCOME=fail drive "$F"; [ "$(ran)" = 1 ] || bad "a failure must run again, never be held"
runs_now "the unit that failed, now passing" "$F"; held_now "and then it is held" "$F"
S='held s repo:lib -- silent three'
runs_now "a unit that records nothing" "$S"; runs_now "is not stored" "$S"
# Skips are results like passes.
K='held k repo:lib -- check four'
fresh; OUTCOME=skip WHY=later drive "$K"; fresh; drive "$K"
[ "$(ran)" = 0 ] && has '^skip	suite	four	later$' || bad "a skip is held with its reason: $OUT"

# ---- 4. FRESH runs whatever is held, and stores -------------------------------------
fresh; FRESH=1 SILICA_FRESH=1 drive "$U"; [ "$(ran)" = 1 ] || bad "SILICA_FRESH=1 must run a held unit"
held_now "after a fresh run" "$U"

# ---- 5. one path of a repository -----------------------------------------------------
P='held p path:lib:a -- check five'
runs_now "path: first" "$P"
echo "// c" >>"$LIBR/c/src/lib.rs"; held_now "path: a change elsewhere in the repository" "$P"
runs_now "repo: the same change" "$U"
echo "// a" >>"$LIBR/a/src/lib.rs"; runs_now "path: a change under it" "$P"
A='held absent path:lib:nothing/here file:/nonexistent/file -- check six'
runs_now "an absent path" "$A"; held_now "is an input like another" "$A"

# ---- 6. a crate: itself, what it builds from, the workspace; not its fuzz crate -----
C='held c crate:lib:a -- check seven'
runs_now "crate: first" "$C"
echo "// c2" >>"$LIBR/c/src/lib.rs"; held_now "crate: a package it does not depend on" "$C"
echo more >>"$LIBR/a/fuzz/corpus"; held_now "crate: its fuzz directory is a crate of its own" "$C"
echo "// b" >>"$LIBR/b/src/lib.rs"; runs_now "crate: a package it depends on" "$C"
echo "// a3" >>"$LIBR/a/src/lib.rs"; runs_now "crate: itself" "$C"
printf '\n[profile.release]\nopt-level = 3\n' >>"$LIBR/Cargo.toml"; runs_now "crate: the workspace manifest" "$C"
held_now "crate: settled" "$C"

# ---- 7. the harness: the command, its function, the functions it calls ------------
drive "$U"
runs_now "another argument is another command" 'held u repo:lib -- check other'
held_now "the first command is still held" "$U"
fresh; DEFS='check() { echo "$1" >>"$COUNT"; helper; record "${OUTCOME:-pass}" suite "$1" "${WHY:-}"; true; }' drive "$U"
[ "$(ran)" = 1 ] || bad "a changed function body must run its units"
fresh; DEFS='helper() { true; }' drive "$U"; [ "$(ran)" = 1 ] || bad "a changed function it calls must run its units"
fresh; DEFS='unrelated() { true; }' drive "$U"; [ "$(ran)" = 0 ] || bad "a function it does not call is not its input: $OUT"
fresh; DEFS='check() {    echo "$1" >>"$COUNT"   # a comment
  helper; record "${OUTCOME:-pass}" suite "$1" "${WHY:-}"; }' drive "$U"
[ "$(ran)" = 0 ] || bad "comments and spacing are not a change: $OUT"

# ---- 8. a variable, a literal ----------------------------------------------------------
E='held e env:KNOB limit:5 -- check eight'
runs_now "env: first" "$E"; held_now "env: unset stays unset" "$E"
fresh; KNOB=1 drive "$E"; [ "$(ran)" = 1 ] || bad "a changed variable must run the unit"
runs_now "another literal" 'held e env:KNOB limit:6 -- check eight'

# ---- 9. at once: every result arrives, and each is stored -----------------------------
M='for i in 1 2 3 4 5 6 7 8; do held_bg "m/$i" repo:lib -- slow "m$i"; done'
fresh; t0=$SECONDS; JOBS=4 SILICA_JOBS=4 drive "$M"
[ "$(ran)" = 8 ] && [ "$(grep -c '^pass	suite	m[1-8]	$' <<<"$OUT")" = 8 ] || bad "units at once: want 8 run and 8 results: $OUT"
held_now "units at once, again" "$M"
has '^drive: ran 0 checks .*held 8 ' || bad "units at once: all eight held: $OUT"

# ---- 10. the plan: nothing runs, and it says what changed -----------------------------
drive "$C; $P"
echo "// plan" >>"$LIBR/b/src/lib.rs"
fresh; PLAN=1 DEFS='PLAN=1' drive "$C; $P"
[ "$(ran)" = 0 ] || bad "plan: nothing may run"
has '^plan: c: 1 to run, .*changed: crate:lib:a$' && has '^plan: 1 checks to run .* 1 held$' || bad "plan: what would run, why, and what is held: $OUT"

# ---- 11. values (a count, a benchmark's samples) ----------------------------------------
V='if kept v repo:lib knob:1; then echo "KEPT $(grep -v "^#" "$EV_FILE") at $(kept_at "$EV_FILE")"; else echo 42 >"$RUN/v"; keep v "$EV_KEY" "$EV_TEXT" "$RUN/v"; echo MEASURED; fi'
drive "$V"; has '^MEASURED$' || bad "values: first measured: $OUT"
drive "$V"; has '^KEPT 42 at 20[0-9-]+ [0-9:]+ UTC$' || bad "values: then kept, with their date: $OUT"
echo "// v" >>"$LIBR/c/src/lib.rs"; drive "$V"; has '^MEASURED$' || bad "values: measured again when an input changed: $OUT"

# ---- 12. one store for every worktree of the workshop ----------------------------------
# The same sources checked out in another worktree are the same inputs.
gx -C "$LIBR" add -A; gx -C "$LIBR" commit -qm four
runs_now "before the worktree" "$U"
W2=$FX/ws2
gx -C "$WS" worktree add -q "$W2" -b other >/dev/null 2>&1 || bad "cannot add a worktree"
gx -C "$OS" worktree add -q "$W2/os" -b other >/dev/null 2>&1; gx -C "$LIBR" worktree add -q "$W2/lib" -b other >/dev/null 2>&1
cp "$OS/tools/drive.sh" "$W2/os/tools/drive.sh"; cp -r "$OS/tools/lib" "$W2/os/tools/"
fresh; WSNOW=$W2 drive "$U"
[ "$(ran)" = 0 ] || bad "another worktree with the same sources must hold what the first showed: $OUT"
echo "// w2" >>"$W2/lib/a/src/lib.rs"; fresh; WSNOW=$W2 drive "$U"
[ "$(ran)" = 1 ] || bad "a change in the other worktree is a change there"
held_now "and not in the first" "$U"

# ---- 13. a checkout that is not a Git repository ---------------------------------------
PW=$FX/plain; mkdir -p "$PW/os/tools" "$PW/lib"
cp -r "$OS/tools/lib" "$OS/tools/drive.sh" "$PW/os/tools/"; cp "$OS/manifest.toml" "$PW/os/"; echo x >"$PW/bootstrap.pins"; echo one >"$PW/lib/file"
fresh; WSNOW=$PW drive "$U"; fresh; WSNOW=$PW drive "$U"
[ "$(ran)" = 0 ] || bad "plain files: held on the same contents: $OUT"
echo two >"$PW/lib/file"; fresh; WSNOW=$PW drive "$U"; [ "$(ran)" = 1 ] || bad "plain files: a changed file must run the unit"
# Its store is its own: the fake workshop sits inside a real one's tree.
[ -d "$PW/target/evidence" ] || bad "a workshop that is no Git repository keeps its store in its own target/"

[ $fails = 0 ] && echo "evidence-test: all checks passed"
exit $((fails > 0))
