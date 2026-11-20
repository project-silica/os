#!/usr/bin/env bash
# Test for tools/check-deps.sh (component A11, feature A11.02;
# spec/REPOSITORIES.md section 2, rules 1 and 2): idl depends on nothing, kernel
# only on idl, every other repository only on idl and kernel's libsys, nothing
# on os or workshop, and no path dependency leaves its repository. A planted
# violation is reported by name, in every dependency kind and every spelling of
# the repository URL.
#
# Runs a private copy of the tool suite in a disposable fake workshop of small
# Cargo crates (no network, nothing is built). One "ERROR:" line per failed
# check. A last section runs the tool on the real repositories.
set -uo pipefail
SRC=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd -P)
BASE=${SILICA_RUN:-${TMPDIR:-/tmp}}; mkdir -p "$BASE"
FX=$(mktemp -d "$BASE/depstest.XXXX") || exit 2
FX=$(cd "$FX" && pwd -P)
trap 'rm -rf "${FX:?}"' EXIT
fails=0
bad() { echo "ERROR: deps-test: $1"; fails=$((fails + 1)); }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.invalid
git() { command git -c core.hooksPath=/dev/null -c init.defaultBranch=main "$@"; }

WS=$FX/ws; OS=$WS/os
ORG=https://github.com/project-silica
mkdir -p "$WS/state" "$OS/tools" "$FX/home"
echo x >"$WS/bootstrap.pins"; echo 0 >"$WS/MILESTONE"
cp -r "$SRC/lib" "$SRC/check-deps.sh" "$OS/tools/"
cat >"$OS/manifest.toml" <<EOF2
[repos.spec]
url = "$ORG/spec"
milestone = 0
commit = "x"

[repos.idl]
url = "$ORG/idl"
milestone = 0
commit = "x"

[repos.kernel]
url = "$ORG/kernel"
milestone = 0
commit = "x"

[repos.system]
url = "$ORG/system"
milestone = 0
commit = "x"

[repos.drivers]
url = "https://git.example.invalid/silica/drivers.git"
milestone = 0
commit = "x"

[repos.".github"]
url = "$ORG/.github"
milestone = 0
commit = "x"
EOF2

# mk <repo> <package> <deps>: the repository's root crate. <deps> is the body of its [dependencies] table,
# the last section of the file, so a violation appended after it is a dependency line or a new section.
declare -A DEPS=() PKG=()
mk() {
  PKG[$1]=$2; DEPS[$1]=$3
  mkdir -p "$WS/$1/src"; touch "$WS/$1/src/lib.rs"
  write "$1" ""
}
write() { # write <repo> <extra>: the root manifest plus a violation
  printf '[package]\nname = "%s"\nversion = "0.1.0"\nedition = "2021"\n\n[dependencies]\n%s\n%s\n' "${PKG[$1]}" "${DEPS[$1]}" "$2" >"$WS/$1/Cargo.toml"
}
mkcrate() { # mkcrate <dir> <package> [<body>]: a small crate under a repository
  mkdir -p "$1/src"; touch "$1/src/lib.rs"
  printf '[package]\nname = "%s"\nversion = "0.1.0"\nedition = "2021"\n%s\n' "$2" "${3:-}" >"$1/Cargo.toml"
}

mk idl idlc ""
mk kernel kernel "kernel-core = { path = \"kernel-core\" }
libsys = { path = \"libsys\" }
idlc = { git = \"$ORG/idl\" }"
mkcrate "$WS/kernel/kernel-core" kernel-core
mkcrate "$WS/kernel/libsys" libsys "[dependencies]
kernel-core = { path = \"../kernel-core\" }"
mkdir -p "$WS/kernel/vendor/junk"
mk system system "libsys = { git = \"$ORG/kernel\" }
idlc = { git = \"$ORG/idl.git\", branch = \"main\" }
helper = { path = \"crates/helper\" }
serde = \"1\"
elsewhere = { git = \"https://example.invalid/someone/os\" }"
mkcrate "$WS/system/crates/helper" helper
mk drivers drivers "idlc = { git = \"$ORG/idl\" }"
mkdir -p "$WS/spec" "$WS/.github"

run() { # run <args...>: check-deps.sh in the fake workshop; output in $OUT, status in $RC
  OUT=$(cd "$FX" && env -i PATH="${PATH:-/usr/bin:/bin}" HOME="$FX/home" TMPDIR="$FX" SILICA_WS="$WS" RUSTUP_HOME="${RUSTUP_HOME:-${HOME:-/root}/.rustup}" \
    ${CARGO_HOME:+CARGO_HOME="$CARGO_HOME"} bash "$OS/tools/check-deps.sh" "$@" 2>&1)
  RC=$?
}
errs() { printf '%s\n' "$OUT" | grep -c '^ERROR:'; }
ok_line() { printf '%s\n' "$OUT" | grep -qx 'CHECK-DEPS: OK'; }

# violation <label> <repo> <extra manifest text> <regex the one ERROR line must match>
violation() {
  write "$2" "$3"; run
  [ $RC = 1 ] || bad "$1: exit $RC, want 1: $OUT"
  [ "$(errs)" = 1 ] || bad "$1: want exactly 1 ERROR line, got $(errs): $OUT"
  printf '%s\n' "$OUT" | grep '^ERROR:' | grep -Eq "$4" || bad "$1: the ERROR line does not match /$4/: $OUT"
  ok_line && bad "$1: printed 'CHECK-DEPS: OK' for a violation"
  write "$2" ""
}
# allowed <label> <repo> <extra manifest text>
allowed() {
  write "$2" "$3"; run
  [ $RC = 0 ] && [ "$(errs)" = 0 ] && ok_line || bad "$1: a permitted dependency was reported (exit $RC): $OUT"
  write "$2" ""
}

# ---- 1. the clean workspace --------------------------------------------------
run
[ $RC = 0 ] || bad "clean workspace: exit $RC, want 0: $OUT"
ok_line || bad "clean workspace: no 'CHECK-DEPS: OK' line: $OUT"
[ "$(errs)" = 0 ] || bad "clean workspace: unexpected ERROR lines: $OUT"
printf '%s\n' "$OUT" | grep -q '^WARNING:' && bad "clean workspace: unexpected WARNING: $OUT"

# ---- 2. the dependency direction ---------------------------------------------
violation "idl on kernel" idl "libsys = { git = \"$ORG/kernel\" }" 'idl.*kernel/libsys'
violation "idl on idl" idl "again = { git = \"$ORG/idl\" }" 'idl.*idl/again'
violation "kernel on system" kernel "svc = { git = \"$ORG/system\" }" 'kernel.*system/svc'
violation "kernel on kernel by URL" kernel "k2 = { git = \"$ORG/kernel\" }" 'kernel.*kernel/k2'
violation "system on kernel-core" system "kernel-core = { git = \"$ORG/kernel\" }" 'system.*kernel/kernel-core'
violation "system on a driver" system "d = { git = \"$ORG/drivers\" }" 'system.*drivers/d'
violation "driver on a service" drivers "svc = { git = \"$ORG/system\" }" 'drivers.*system/svc'
violation "system on spec" system "s = { git = \"$ORG/spec\" }" 'system.*spec/s'
violation "system on os" system "tool = { git = \"$ORG/os\" }" 'system.*os/tool'
violation "driver on workshop" drivers "w = { git = \"$ORG/workshop\" }" 'drivers.*workshop/w'
violation "kernel on os" kernel "tool = { git = \"$ORG/os\" }" 'kernel.*os/tool'
violation "idl on os" idl "tool = { git = \"$ORG/os\" }" 'idl.*os/tool'
violation "the URL the manifest gives" system "d = { git = \"https://git.example.invalid/silica/drivers\" }" 'system.*drivers/d'
allowed "system on libsys and idl" system "idl2 = { package = \"idlc\", git = \"$ORG/idl\" }
libsys2 = { package = \"libsys\", git = \"$ORG/kernel\", rev = \"abc\" }"
allowed "kernel on idl" kernel "idl2 = { package = \"idlc\", git = \"$ORG/idl\", branch = \"main\" }"
allowed "drivers on libsys" drivers "libsys = { git = \"$ORG/kernel.git\" }"
allowed "a dependency on a foreign repository" drivers "o = { git = \"https://example.invalid/silica/os\" }
w = \"2\""
violation "renamed dependency is judged by its package" system "lib2 = { package = \"kernel-core\", git = \"$ORG/kernel\" }" 'system.*kernel/kernel-core'

# ---- 3. kinds and spellings --------------------------------------------------
violation "build-dependency" system "
[build-dependencies]
tool = { git = \"$ORG/os\" }" 'system.*os/tool'
violation "dev-dependency" idl "
[dev-dependencies]
libsys = { git = \"$ORG/kernel\" }" 'idl.*kernel/libsys'
violation "target-specific dependency" system "
[target.'cfg(unix)'.dependencies]
tool = { git = \"$ORG/os\" }" 'system.*os/tool'
violation "optional dependency" system "tool = { git = \"$ORG/os\", optional = true }" 'system.*os/tool'
violation "trailing .git" system "tool = { git = \"$ORG/os.git\" }" 'system.*os/tool'
violation "trailing slash" system "tool = { git = \"$ORG/workshop/\" }" 'system.*workshop/tool'
violation "upper case organization" system "tool = { git = \"https://github.com/Project-Silica/OS\" }" 'system.*os/tool'
violation "ssh URL" system "tool = { git = \"ssh://git@github.com/project-silica/os\" }" 'system.*os/tool'
violation "http URL" system "tool = { git = \"http://github.com/project-silica/os\" }" 'system.*os/tool'
violation "www host" system "tool = { git = \"https://www.github.com/project-silica/os\" }" 'system.*os/tool'
violation "branch, tag and rev" system "tool = { git = \"$ORG/os\", tag = \"v1\" }" 'system.*os/tool'

# ---- 4. path dependencies ----------------------------------------------------
mkcrate "$FX/outside" outside
violation "path to a sibling repository" system "other = { path = \"../idl\" }" 'system.*other.*leaves'
violation "path outside the workspace" system "other = { path = \"$FX/outside\" }" 'system.*other.*leaves'
violation "path with .." system "other = { path = \"crates/../../drivers\" }" 'system.*other.*leaves'
ln -s "$FX/outside" "$WS/system/crates/link"
violation "path through a symbolic link" system "other = { path = \"crates/link\" }" 'system.*other.*leaves'
rm "$WS/system/crates/link"
allowed "path inside the repository" system "again = { package = \"helper\", path = \"crates/helper\" }"
violation "path leaving in a dev-dependency" kernel "
[dev-dependencies]
other = { path = \"../idl\" }" 'kernel.*other.*leaves'

# ---- 5. every manifest of a repository ---------------------------------------
mkcrate "$WS/idl/fuzz" fuzz "[dependencies]
libsys = { git = \"$ORG/kernel\" }
[workspace]"
run
[ $RC = 1 ] && [ "$(errs)" = 1 ] && printf '%s\n' "$OUT" | grep '^ERROR:' | grep -q 'idl.*fuzz.*kernel/libsys' ||
  bad "separate workspace in a subdirectory: want 1 ERROR naming idl, fuzz and kernel/libsys, exit 1, got exit $RC: $OUT"
rm -rf "$WS/idl/fuzz"
mkcrate "$WS/idl/vendor/x" x "[dependencies]
libsys = { git = \"$ORG/kernel\" }"
mkcrate "$WS/idl/target/x" x "[dependencies]
libsys = { git = \"$ORG/kernel\" }"
run
[ $RC = 0 ] && ok_line || bad "manifests under vendor/ and target/ must be ignored (exit $RC): $OUT"
rm -rf "$WS/idl/vendor" "$WS/idl/target"
# a violation in a member of the root workspace is reported once, not once per manifest that reaches it
printf '\n[workspace]\nmembers = ["libsys", "kernel-core"]\n' >>"$WS/kernel/Cargo.toml"
mkcrate "$WS/kernel/libsys" libsys "[dependencies]
svc = { git = \"$ORG/system\" }"
run
[ $RC = 1 ] && [ "$(errs)" = 1 ] || bad "violation in a workspace member: want exit 1 and 1 ERROR line, got exit $RC and $(errs): $OUT"
mkcrate "$WS/kernel/libsys" libsys "[dependencies]
kernel-core = { path = \"../kernel-core\" }"
run
[ $RC = 0 ] && ok_line || bad "kernel as a workspace: clean workspace reported (exit $RC): $OUT"
write kernel ""
# a manifest cargo cannot read: an error for the root, a warning for a nested one
mkdir -p "$WS/system/templates/app"; echo 'name = {{name}}' >"$WS/system/templates/app/Cargo.toml"
run
[ $RC = 0 ] && ok_line && printf '%s\n' "$OUT" | grep -q '^WARNING:.*templates/app' || bad "unreadable nested manifest: want a WARNING naming it and exit 0, got exit $RC: $OUT"
rm -rf "$WS/system/templates"
cp "$WS/drivers/Cargo.toml" "$FX/drivers.toml"; echo 'this is not toml [' >"$WS/drivers/Cargo.toml"
run
[ $RC = 1 ] && [ "$(errs)" = 1 ] && printf '%s\n' "$OUT" | grep '^ERROR:' | grep -q drivers || bad "unreadable root manifest: want exit 1 and 1 ERROR naming drivers, got exit $RC: $OUT"
cp "$FX/drivers.toml" "$WS/drivers/Cargo.toml"

# ---- 6. several violations, one line each ------------------------------------
write idl "libsys = { git = \"$ORG/kernel\" }"
write system "tool = { git = \"$ORG/os\" }"
write drivers "other = { path = \"../idl\" }"
run
[ $RC = 1 ] || bad "three violations: exit $RC, want 1"
[ "$(errs)" = 3 ] || bad "three violations: want 3 ERROR lines, got $(errs): $OUT"
for pat in 'idl.*kernel/libsys' 'system.*os/tool' 'drivers.*other.*leaves'; do
  printf '%s\n' "$OUT" | grep -q "^ERROR:.*$pat" || bad "three violations: no ERROR line for /$pat/: $OUT"
done
write idl ""; write system ""; write drivers ""
run; [ $RC = 0 ] || bad "after the violations were removed: exit $RC: $OUT"

# ---- 7. checkouts ------------------------------------------------------------
# --checkout names the tree to check instead of the canonical clone
for r in system idl; do (cd "$WS/$r" && git init -q . && git add -A && git commit -qm base) || { echo "ERROR: deps-test: cannot create the fake repositories"; exit 2; }; done
git -C "$WS/system" worktree add -q -b topic "$FX/system-wt" 2>/dev/null || { echo "ERROR: deps-test: cannot create a worktree"; exit 2; }
printf '\ntool = { git = "%s/os" }\n' "$ORG" >>"$FX/system-wt/Cargo.toml"
run
[ $RC = 0 ] || bad "canonical clone is clean but the check failed (exit $RC): $OUT"
run --checkout system "$FX/system-wt"
[ $RC = 1 ] && [ "$(errs)" = 1 ] && printf '%s\n' "$OUT" | grep '^ERROR:' | grep -q 'system.*os/tool' || bad "--checkout: want the violation of the checkout (exit 1, 1 ERROR), got exit $RC: $OUT"
git -C "$FX/system-wt" checkout -q -- Cargo.toml
run --checkout system "$FX/system-wt"
[ $RC = 0 ] && ok_line || bad "--checkout of a clean worktree: exit $RC: $OUT"
run --checkout system "relative/dir"
[ $RC = 2 ] && [ "$(errs)" = 1 ] || bad "relative --checkout: want exit 2 and 1 ERROR line, got exit $RC: $OUT"
run --checkout nosuch "$FX/system-wt"
[ $RC != 0 ] || bad "--checkout of an unknown repository: exit 0"

# ---- 8. usage ----------------------------------------------------------------
run bogus
[ $RC = 2 ] || bad "unknown argument: exit $RC, want 2: $OUT"
[ "$(errs)" = 1 ] && printf '%s\n' "$OUT" | grep -q 'bogus' || bad "unknown argument: want 1 ERROR line naming it: $OUT"
ok_line && bad "unknown argument: printed 'CHECK-DEPS: OK'"
run --checkout system
[ $RC = 2 ] || bad "--checkout without arguments: exit $RC, want 2: $OUT"

# ---- 9. the real repositories ------------------------------------------------
if [ -x "$SRC/check-deps.sh" ] && command -v cargo >/dev/null 2>&1; then
  REAL_OS=$(cd "$SRC/.." && pwd -P)
  OUT=$("$SRC/check-deps.sh" --checkout os "$REAL_OS" 2>&1); RC=$?
  [ $RC = 0 ] || bad "real repositories: exit $RC, want 0: $(printf '%s\n' "$OUT" | head -n 5 | tr '\n' ' ')"
  ok_line || bad "real repositories: no 'CHECK-DEPS: OK' line"
fi

[ $fails = 0 ] && echo "CHECK-DEPS TEST: OK"
exit $((fails > 0))
