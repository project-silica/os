#!/usr/bin/env bash
# Test for tools/sync.sh (component A11, feature A11.01; spec/REPOSITORIES.md
# sections 2 and 3): sync clones missing repositories at their pin, never
# resets an existing clone, honours the milestone, and writes the Cargo [patch]
# path overrides for the local clones. Also checks the real manifest: every M0
# repository other than os is pinned, and has a README at its pin.
#
# Runs a private copy of the tool suite in a disposable fake workshop whose
# "remote" repositories are local directories. Nothing real is cloned. One
# "ERROR:" line per failed check.
set -uo pipefail
SRC=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd -P)
OSDIR=$(dirname "$SRC")
BASE=${SILICA_RUN:-${TMPDIR:-/tmp}}; mkdir -p "$BASE"
FX=$(mktemp -d "$BASE/synctest.XXXX") || exit 2
FX=$(cd "$FX" && pwd -P)
trap 'rm -rf "${FX:?}"' EXIT
fails=0
bad() { echo "ERROR: sync-test: $1"; fails=$((fails + 1)); }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.invalid
git() { command git -c protocol.file.allow=always -c init.defaultBranch=main -c core.hooksPath=/dev/null "$@"; }

WS=$FX/ws; OS=$WS/os; R=$FX/remotes
mkdir -p "$WS/state" "$OS/tools" "$R" "$FX/home"
echo x >"$WS/bootstrap.pins"; echo 0 >"$WS/MILESTONE"
cp -r "$SRC/lib" "$SRC/sync.sh" "$OS/tools/"

# Remotes: alpha (a Rust crate), .dot (no Cargo.toml, a dotted name like .github), later (milestone 1).
# Each has two commits; the manifest pins the first.
mkremote() { # mkremote <name> <crate-or-empty>
  local d=$R/$1; mkdir -p "$d"
  (cd "$d" && git init -q . && echo "# $1" >README.md &&
    if [ -n "$2" ]; then mkdir -p src && printf '[package]\nname = "%s"\nversion = "0.1.0"\nedition = "2021"\n' "$2" >Cargo.toml && echo "" >src/lib.rs; fi &&
    git add -A && git commit -qm first && git rev-parse HEAD >"$FX/$1.pin" &&
    echo second >second.txt && git add -A && git commit -qm second && git rev-parse HEAD >"$FX/$1.head") ||
    { echo "ERROR: sync-test: cannot create remote $1"; exit 2; }
}
mkremote alpha alpha-crate; mkremote .dot ""; mkremote later later-crate
cat >"$OS/manifest.toml" <<EOF
[repos.alpha]
url = "file://$R/alpha"
milestone = 0
commit = "$(cat "$FX/alpha.pin")"

[repos.".dot"]
url = "file://$R/.dot"
milestone = 0
commit = "$(cat "$FX/.dot.pin")"

[repos.later]
url = "file://$R/later"
milestone = 1
commit = "$(cat "$FX/later.pin")"
EOF
(cd "$OS" && git init -q . && git add -A && git commit -qm fake) || { echo "ERROR: sync-test: cannot create the fake os"; exit 2; }

run() { # run <args...>: sync.sh in the fake workshop; output in $OUT, status in $RC
  OUT=$(cd "$FX" && env -i PATH="${PATH:-/usr/bin:/bin}" HOME="$FX/home" TMPDIR="$FX" SILICA_WS="$WS" RUSTUP_HOME="$RUSTUP_HOME" \
    ${CARGO_HOME:+CARGO_HOME="$CARGO_HOME"} bash "$OS/tools/sync.sh" "$@" 2>&1)
  RC=$?
}
errs() { printf '%s\n' "$OUT" | grep -c '^ERROR:'; }
head_of() { git -C "$1" rev-parse HEAD 2>/dev/null; }
PATCH=$WS/target/cargo-patch.toml
RUSTUP_HOME=${RUSTUP_HOME:-${HOME:-/root}/.rustup}

# ---- 1. fresh workspace ------------------------------------------------------
run
[ $RC = 0 ] || bad "fresh sync: exit $RC, want 0: $OUT"
printf '%s\n' "$OUT" | grep -qx 'SYNC: OK' || bad "fresh sync: no 'SYNC: OK' line: $OUT"
[ "$(errs)" = 0 ] || bad "fresh sync: unexpected ERROR lines: $OUT"
[ "$(head_of "$WS/alpha")" = "$(cat "$FX/alpha.pin")" ] || bad "alpha not at its pin (it has the later commit or is missing)"
[ "$(head_of "$WS/.dot")" = "$(cat "$FX/.dot.pin")" ] || bad "dotted-name repository not at its pin"
[ "$(git -C "$WS/alpha" symbolic-ref --short HEAD 2>/dev/null)" = main ] || bad "alpha is not on branch main"
[ -z "$(git -C "$WS/alpha" status --porcelain)" ] || bad "fresh clone of alpha is not clean"
[ ! -e "$WS/later" ] || bad "repository of milestone 1 cloned at milestone 0"
[ -f "$WS/alpha/README.md" ] || bad "clone of alpha has no checked-out files"
[ -f "$PATCH" ] || bad "target/cargo-patch.toml not written"
grep -qxF "[patch.\"file://$R/alpha\"]" "$PATCH" 2>/dev/null || bad "cargo-patch.toml has no [patch] section for alpha's URL"
grep -qF "alpha-crate = { path = \"$WS/alpha\" }" "$PATCH" 2>/dev/null || bad "cargo-patch.toml does not point alpha-crate at the local clone"
grep -q 'later' "$PATCH" 2>/dev/null && bad "cargo-patch.toml mentions a repository that is not cloned"
grep -qF ".dot" "$PATCH" 2>/dev/null && bad "cargo-patch.toml has a section for a repository without crates"

# ---- 2. existing clones are never reset --------------------------------------
echo mine >"$WS/alpha/local.txt"; git -C "$WS/alpha" add local.txt; git -C "$WS/alpha" commit -qm local
echo dirty >>"$WS/alpha/README.md"
mine=$(head_of "$WS/alpha")
git -C "$WS/.dot" checkout -q -b topic
run
[ $RC = 0 ] || bad "second sync: exit $RC, want 0: $OUT"
[ "$(head_of "$WS/alpha")" = "$mine" ] || bad "second sync moved alpha's HEAD"
[ -f "$WS/alpha/local.txt" ] || bad "second sync lost a local commit"
grep -q dirty "$WS/alpha/README.md" || bad "second sync reverted an uncommitted change"
[ "$(git -C "$WS/.dot" symbolic-ref --short HEAD)" = topic ] || bad "second sync switched a clone off its branch"
printf '%s\n' "$OUT" | grep -q 'cloned' && bad "second sync claims to have cloned something: $OUT"
git -C "$WS/alpha" checkout -q -- README.md; git -C "$WS/.dot" checkout -q main

# ---- 3. a clone that lacks its pin is an error --------------------------------
mkdir -p "$FX/lonely" && (cd "$FX/lonely" && git init -q . && echo l >f && git add -A && git commit -qm l)
rm -rf "$WS/.dot"; git clone -q "$FX/lonely" "$WS/.dot"
run
[ $RC != 0 ] || bad "clone without its pin: exit 0, want non-zero"
[ "$(errs)" = 1 ] || bad "clone without its pin: want exactly 1 ERROR line, got $(errs): $OUT"
printf '%s\n' "$OUT" | grep '^ERROR:' | grep -q '\.dot' || bad "clone without its pin: ERROR does not name the repository"
printf '%s\n' "$OUT" | grep -qx 'SYNC: OK' && bad "clone without its pin: printed 'SYNC: OK'"
[ -d "$WS/.dot/.git" ] && [ "$(head_of "$WS/.dot")" = "$(head_of "$FX/lonely")" ] || bad "clone without its pin was modified"
rm -rf "$WS/.dot"

# ---- 4. a missing clone whose pin is not in the remote ------------------------
sed -i "0,/^commit = \"$(cat "$FX/.dot.pin")\"/s//commit = \"0123456789012345678901234567890123456789\"/" "$OS/manifest.toml"
run
[ $RC != 0 ] || bad "unknown pin: exit 0, want non-zero"
[ "$(errs)" = 1 ] || bad "unknown pin: want exactly 1 ERROR line, got $(errs): $OUT"
[ ! -e "$WS/.dot" ] || bad "unknown pin: a half-made clone was left behind"
[ "$(head_of "$WS/alpha")" = "$mine" ] || bad "unknown pin: alpha was touched"
[ -f "$PATCH" ] || bad "unknown pin: the other repositories got no cargo-patch.toml"
sed -i "s/0123456789012345678901234567890123456789/$(cat "$FX/.dot.pin")/" "$OS/manifest.toml"

# ---- 5. unreachable remote ----------------------------------------------------
mv "$R/.dot" "$R/.dot.away"
run
[ $RC != 0 ] || bad "unreachable remote: exit 0, want non-zero"
[ "$(errs)" = 1 ] || bad "unreachable remote: want exactly 1 ERROR line, got $(errs): $OUT"
[ ! -e "$WS/.dot" ] || bad "unreachable remote: a half-made clone was left behind"
mv "$R/.dot.away" "$R/.dot"

# ---- 6. a directory that is not a clone is never deleted ----------------------
mkdir -p "$WS/.dot" && echo precious >"$WS/.dot/notes.txt"
run
[ $RC != 0 ] || bad "plain directory in the way: exit 0, want non-zero"
[ "$(errs)" = 1 ] || bad "plain directory in the way: want exactly 1 ERROR line, got $(errs): $OUT"
[ "$(cat "$WS/.dot/notes.txt" 2>/dev/null)" = precious ] || bad "sync deleted or changed a directory that is not a clone"
rm -rf "$WS/.dot"
mkdir -p "$WS/.dot"   # an empty directory is fine
run
[ $RC = 0 ] || bad "empty directory in the way: exit $RC, want 0: $OUT"
[ "$(head_of "$WS/.dot")" = "$(cat "$FX/.dot.pin")" ] || bad "empty directory in the way: not cloned at the pin"

# ---- 7. the milestone gate ----------------------------------------------------
echo 1 >"$WS/MILESTONE"
run
[ $RC = 0 ] || bad "milestone 1: exit $RC, want 0: $OUT"
[ "$(head_of "$WS/later")" = "$(cat "$FX/later.pin")" ] || bad "milestone 1: later not cloned at its pin"
grep -qF "later-crate = { path = \"$WS/later\" }" "$PATCH" 2>/dev/null || bad "milestone 1: cargo-patch.toml lacks later-crate"
grep -qF "alpha-crate = { path = \"$WS/alpha\" }" "$PATCH" 2>/dev/null || bad "milestone 1: cargo-patch.toml lost alpha-crate"

# ---- 8. --update fetches and still never moves a checkout ---------------------
(cd "$R/alpha" && echo third >third.txt && git add -A && git commit -qm third && git rev-parse HEAD >"$FX/alpha.head3")
run
git -C "$WS/alpha" cat-file -e "$(cat "$FX/alpha.head3")^{commit}" 2>/dev/null && bad "plain sync fetched (needs the network)"
run --update
[ $RC = 0 ] || bad "--update: exit $RC, want 0: $OUT"
git -C "$WS/alpha" cat-file -e "$(cat "$FX/alpha.head3")^{commit}" 2>/dev/null || bad "--update did not fetch the new commit"
[ "$(head_of "$WS/alpha")" = "$mine" ] || bad "--update moved alpha's HEAD"
mv "$R/alpha" "$R/alpha.away"
run --update
[ $RC = 0 ] || bad "--update with an unreachable remote: exit $RC, want 0 (a SKIP): $OUT"
printf '%s\n' "$OUT" | grep -q '^SKIP:' || bad "--update with an unreachable remote: no SKIP line: $OUT"
[ "$(errs)" = 0 ] || bad "--update with an unreachable remote: ERROR lines: $OUT"
mv "$R/alpha.away" "$R/alpha"

# ---- 9. usage -----------------------------------------------------------------
run --bogus
[ $RC = 2 ] || bad "unknown argument: exit $RC, want 2"
[ "$(errs)" = 1 ] || bad "unknown argument: want exactly 1 ERROR line, got $(errs): $OUT"

# ---- 10. the real manifest -----------------------------------------------------
M=$OSDIR/manifest.toml
for r in spec idl kernel .github; do
  grep -qF "[repos.$r]" "$M" || grep -qF "[repos.\"$r\"]" "$M" || { bad "real manifest does not pin $r"; continue; }
  sec=$(awk -v r="$r" '/^\[/ { cur = $0; gsub(/^\[repos\.|"|\]$/, "", cur) } cur == r { print }' "$M")
  pin=$(printf '%s\n' "$sec" | sed -n 's/^commit = "\(.*\)"/\1/p')
  url=$(printf '%s\n' "$sec" | sed -n 's/^url = "\(.*\)"/\1/p')
  ms=$(printf '%s\n' "$sec" | sed -n 's/^milestone = \(.*\)/\1/p')
  printf '%s' "$pin" | grep -Eq '^[0-9a-f]{40}$' || bad "real manifest: $r has no 40-hex commit pin"
  [ "$url" = "https://github.com/project-silica/$r" ] || bad "real manifest: $r has url '$url'"
  [ "$ms" = 0 ] || bad "real manifest: $r is not marked milestone 0"
  # The clone, when this checkout can see it, has the pin and a README at the pin.
  d=${SILICA_WS:-$OSDIR/..}/$r
  if [ -e "$d/.git" ] && [ -n "$pin" ]; then
    command git -C "$d" cat-file -e "$pin^{commit}" 2>/dev/null || bad "real manifest: $r clone lacks pinned commit $pin"
    command git -C "$d" cat-file -e "$pin:README.md" 2>/dev/null || bad "real manifest: $r has no README.md at its pin"
  fi
done
[ -f "$OSDIR/README.md" ] || bad "os has no README.md"
grep -qF '[repos.os]' "$M" && bad "real manifest pins os in itself"

[ $fails = 0 ] && echo "sync-test: OK"
exit $((fails > 0))
