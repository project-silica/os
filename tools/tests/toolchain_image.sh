#!/usr/bin/env bash
# Test for tools/toolchain-image.sh and tools/image/Containerfile (component
# A12): every hosted job uses a shared
# compiler cache and a prebuilt toolchain image, so no pre-merge job builds
# cold).
#
#   toolchain-image.sh check               the image definition against the pins
#   toolchain-image.sh tag                 the image tag (hash of the definition)
#   toolchain-image.sh key <repo>          the compiler cache key of a repository
#   toolchain-image.sh restore-key <repo>  the prefix a fallback restore may use
#
# Runs a private copy of the tool in a disposable fake workshop: a good
# Containerfile passes, every planted defect is reported by name, and the cache
# key follows the lock files and the toolchain pins (and nothing else). A last
# section runs the tool on the real repositories. One "ERROR:" line per failed
# check.
set -uo pipefail
SRC=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd -P)
BASE=${SILICA_RUN:-${TMPDIR:-/tmp}}; mkdir -p "$BASE"
FX=$(mktemp -d "$BASE/tcimgtest.XXXX") || exit 2
FX=$(cd "$FX" && pwd -P)
trap 'rm -rf "${FX:?}"' EXIT
fails=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.invalid
git() { command git -c core.hooksPath=/dev/null -c init.defaultBranch=main "$@"; }
bad() { echo "ERROR: toolchain-image-test: $1"; fails=$((fails + 1)); }

[ -x "$SRC/toolchain-image.sh" ] || { bad "tools/toolchain-image.sh is missing or not executable"; exit 1; }

WS=$FX/ws; OS=$WS/os; KERNEL=$WS/kernel; IDL=$WS/idl; CF=$OS/tools/image/Containerfile
CHANNEL=nightly-2026-10-01
mkdir -p "$OS/tools/image" "$KERNEL" "$IDL"
echo x >"$WS/bootstrap.pins"; echo 0 >"$WS/MILESTONE"
cat >"$OS/manifest.toml" <<'EOF'
[repos.kernel]
url = "https://example.invalid/kernel"
milestone = 0
commit = "x"

[repos.idl]
url = "https://example.invalid/idl"
milestone = 0
commit = "x"
EOF
cp -r "$SRC/lib" "$SRC/toolchain-image.sh" "$OS/tools/"

PKGS=(ca-certificates git jq mtools ovmf qemu-efi-aarch64 qemu-system-arm qemu-system-x86 rustup socat)
write_containerfile() { # write_containerfile <path> <channel> <components> <packages...>
  local path=$1 ch=$2 comps=$3; shift 3
  cat >"$path" <<EOF
# Toolchain image for the hosted lanes (fixture).
FROM ubuntu:24.04
ARG RUST_CHANNEL=$ch
ARG RUST_COMPONENTS=$comps
RUN apt-get update \\
    && apt-get install -y --no-install-recommends $* \\
    && rm -rf /var/lib/apt/lists/*
RUN rustup toolchain install "\$RUST_CHANNEL" --profile minimal --component "\$RUST_COMPONENTS" \\
    && rustup default "\$RUST_CHANNEL"
ENV CARGO_NET_OFFLINE=true
EOF
}
write_toolchain() { # write_toolchain <dir> <channel> <components, quoted list>
  cat >"$1/rust-toolchain.toml" <<EOF
# fixture pin
[toolchain]
channel = "$2"
components = [$3]
profile = "minimal"
EOF
}
reset_good() {
  write_containerfile "$CF" "$CHANNEL" "rust-src,miri,clippy,rustfmt,llvm-tools" "${PKGS[@]}"
  write_toolchain "$OS" "$CHANNEL" '"rust-src", "miri", "clippy", "rustfmt"'
  write_toolchain "$KERNEL" "$CHANNEL" '"rust-src", "miri", "clippy", "rustfmt"'
  rm -f "$IDL/rust-toolchain.toml"
}
reset_good

OUT="" RC=0
run() { # run <args...>: output in $OUT, status in $RC (run from outside any repository)
  OUT=$(cd "$FX" && env -i PATH="${PATH:-/usr/bin:/bin}" HOME="$FX" TMPDIR="$FX" SILICA_WS="$WS" \
    bash "$OS/tools/toolchain-image.sh" "$@" 2>&1); RC=$?
}
errs() { printf '%s\n' "$OUT" | grep -c '^ERROR:'; }
ok_line() { printf '%s\n' "$OUT" | grep -qx 'TOOLCHAIN-IMAGE: OK'; }

# ---- 1. the check: a good definition passes -----------------------------------
run check
[ $RC = 0 ] && ok_line && [ "$(errs)" = 0 ] || bad "good definition: want exit 0, 'TOOLCHAIN-IMAGE: OK' and no ERROR, got exit $RC: $OUT"

# ---- 2. the check: every planted defect is named -------------------------------
defect() { # defect <name> <error count or "any"> <pattern>: expects exit 1, that many ERROR lines, one matching the pattern
  local name=$1 n=$2 pat=$3
  run check
  [ $RC = 1 ] || bad "$name: exit $RC, want 1: $OUT"
  if [ "$n" = any ]; then [ "$(errs)" -ge 1 ] || bad "$name: no ERROR line: $OUT"
  else [ "$(errs)" = "$n" ] || bad "$name: want $n ERROR line(s), got $(errs): $OUT"; fi
  printf '%s\n' "$OUT" | grep '^ERROR:' | grep -Eq -- "$pat" || bad "$name: no ERROR line matching /$pat/: $OUT"
  ok_line && bad "$name: printed 'TOOLCHAIN-IMAGE: OK'"
  reset_good
}

rm -f "$CF"; defect "no Containerfile" 1 'Containerfile.*missing'
sed -i '/^FROM /d' "$CF"; defect "no FROM" 1 'no FROM'
sed -i 's/^FROM ubuntu:24.04/FROM ubuntu/' "$CF"; defect "untagged base image" 1 'base image ubuntu.*not pinned'
sed -i 's/^FROM ubuntu:24.04/FROM ubuntu:latest/' "$CF"; defect "latest base image" 1 'base image ubuntu:latest.*not pinned'
sed -i 's/^FROM ubuntu:24.04/FROM ubuntu:24.04@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/' "$CF"
run check; [ $RC = 0 ] || bad "base image pinned by digest: exit $RC, want 0: $OUT"; reset_good
printf 'FROM ubuntu:24.04 AS second\nFROM debian\n' >>"$CF"; defect "second stage untagged" 1 'base image debian.*not pinned'

sed -i "s/^ARG RUST_CHANNEL=.*/ARG RUST_CHANNEL=nightly-2026-09-01/" "$CF"
defect "channel differs from the pins" 2 'RUST_CHANNEL nightly-2026-09-01.*differs.*os/rust-toolchain.toml'
sed -i "s/^ARG RUST_CHANNEL=.*/ARG RUST_CHANNEL=nightly/" "$CF"; defect "undated channel" any 'RUST_CHANNEL nightly.*not a dated nightly'
sed -i "/^ARG RUST_CHANNEL=/d" "$CF"; defect "no channel" any 'no ARG RUST_CHANNEL'
write_toolchain "$KERNEL" nightly-2026-11-01 '"rust-src", "miri", "clippy", "rustfmt"'
defect "kernel pin moved, image not" 1 'differs.*kernel/rust-toolchain.toml'
write_toolchain "$IDL" nightly-2026-11-01 '"rust-src"'
defect "third repository pin differs" 1 'differs.*idl/rust-toolchain.toml'
write_toolchain "$KERNEL" "$CHANNEL" '"rust-src",
  "miri",
  "clippy",
  "rustfmt",
  "rust-analyzer"'
defect "multi-line components, one missing from the image" 1 'component rust-analyzer.*missing'

for c in rust-src miri clippy rustfmt llvm-tools; do
  sed -i "s/^ARG RUST_COMPONENTS=.*/ARG RUST_COMPONENTS=$(echo rust-src,miri,clippy,rustfmt,llvm-tools | sed "s/\(^\|,\)$c\(,\|\$\)/\1/; s/,\$//; s/^,//")/" "$CF"
  defect "component $c missing" 1 "component $c.*missing"
done
sed -i '/^ARG RUST_COMPONENTS=/d' "$CF"; defect "no component list" any 'no ARG RUST_COMPONENTS'

for p in "${PKGS[@]}"; do
  rest=(); for q in "${PKGS[@]}"; do [ "$q" = "$p" ] || rest+=("$q"); done
  write_containerfile "$CF" "$CHANNEL" "rust-src,miri,clippy,rustfmt,llvm-tools" "${rest[@]}"
  defect "package $p missing" 1 "package $p.*not installed"
done
# a package whose name only starts like a required one does not count
write_containerfile "$CF" "$CHANNEL" "rust-src,miri,clippy,rustfmt,llvm-tools" "${PKGS[@]/git/git-lfs}"
defect "git-lfs is not git" 1 'package git.*not installed'

sed -i '/^RUN rustup/,/rustup default/d' "$CF"; defect "toolchain never installed" 1 "no 'rustup toolchain install'"
sed -i 's/ --profile minimal//' "$CF"; defect "full profile" 1 'profile minimal'
sed -i 's/--component "\$RUST_COMPONENTS"/--component rust-src/' "$CF"; defect "install ignores RUST_COMPONENTS" 1 'RUST_COMPONENTS'
sed -i 's/rustup toolchain install "\$RUST_CHANNEL"/rustup toolchain install nightly/' "$CF"; defect "install ignores RUST_CHANNEL" 1 'RUST_CHANNEL'
printf 'RUN curl -sSf https://example.invalid/x.sh | sh\n' >>"$CF"; defect "download piped into a shell" 1 'pipes a download into a shell'
printf 'COPY . /src\n' >>"$CF"; defect "sources copied" 1 'COPY.*sources'
printf 'ADD https://example.invalid/x /x\n' >>"$CF"; defect "ADD" 1 'ADD.*sources'

# two defects, two lines
write_containerfile "$CF" "$CHANNEL" "rust-src,miri,clippy,rustfmt,llvm-tools" "${PKGS[@]/jq/}"
sed -i 's/^FROM ubuntu:24.04/FROM ubuntu/' "$CF"
defect "two defects" 2 'package jq|base image ubuntu'

# comments do not count as the installation
write_containerfile "$CF" "$CHANNEL" "rust-src,miri,clippy,rustfmt,llvm-tools" "${PKGS[@]/jq/}"
sed -i 's/^# Toolchain image.*/# jq is needed too/' "$CF"
defect "a package named in a comment" 1 'package jq.*not installed'

# ---- 3. the image tag ----------------------------------------------------------
run tag
[ $RC = 0 ] && printf '%s\n' "$OUT" | grep -Eq '^[0-9a-f]{12}$' && [ "$(printf '%s\n' "$OUT" | wc -l)" = 1 ] || bad "tag: want one 12-hex line, exit 0, got exit $RC: $OUT"
T1=$OUT; run tag; [ "$OUT" = "$T1" ] || bad "tag is not deterministic: $T1 then $OUT"
echo "# changed" >>"$CF"; run tag; [ "$OUT" != "$T1" ] || bad "tag does not change with the Containerfile"
reset_good; run tag; [ "$OUT" = "$T1" ] || bad "tag does not return when the Containerfile does: $T1 then $OUT"
rm -f "$CF"; run tag; [ $RC = 1 ] && [ "$(errs)" = 1 ] || bad "tag without a Containerfile: want exit 1 and 1 ERROR, got exit $RC: $OUT"
reset_good

# ---- 4. the cache key ----------------------------------------------------------
# write <repo-dir> <file> <content>
w() { mkdir -p "$(dirname "$1/$2")"; printf '%s\n' "$3" >"$1/$2"; }
for d in "$KERNEL" "$IDL"; do
  w "$d" Cargo.lock 'version = 3'
  w "$d" crates/a/Cargo.lock 'version = 3 # a'
  w "$d" src/lib.rs 'fn main() {}'
  w "$d" vendor/x/Cargo.lock 'vendored'
  w "$d" target/debug/Cargo.lock 'built'
done
rm -f "$IDL/rust-toolchain.toml"
key() { run key "$1"; K=$OUT; }
run key kernel
[ $RC = 0 ] && [ "$(printf '%s\n' "$OUT" | wc -l)" = 1 ] && printf '%s\n' "$OUT" | grep -Eq '^silica-kernel-[A-Za-z0-9_]+-[0-9a-f]{12}-[0-9a-f]{16}$' \
  || bad "key: want one line silica-kernel-<arch>-<tag>-<16 hex>, exit 0, got exit $RC: $OUT"
K0=$OUT
run tag; TAG=$OUT
case "$K0" in *"-$TAG-"*) ;; *) bad "key does not carry the image tag $TAG: $K0" ;; esac
key kernel; [ "$K" = "$K0" ] || bad "key is not deterministic: $K0 then $K"
# the name is the only difference between identical trees
cp "$KERNEL/rust-toolchain.toml" "$IDL/rust-toolchain.toml"; key idl; KI=$K; key kernel
[ "${KI#silica-idl-}" = "${K#silica-kernel-}" ] || bad "identical trees give keys that differ beyond the name: $KI and $K"
rm -f "$IDL/rust-toolchain.toml"

changes() { # changes <description>: the key of kernel must differ from K0
  key kernel; [ "$K" != "$K0" ] || bad "key does not change when $1"
}
same() { key kernel; [ "$K" = "$K0" ] || bad "key changes when $1: $K0 then $K"; }

w "$KERNEL" Cargo.lock 'version = 3 # new'; changes "the root Cargo.lock changes"; w "$KERNEL" Cargo.lock 'version = 3'; same "the lock file returns"
w "$KERNEL" crates/a/Cargo.lock 'version = 3 # b'; changes "a nested Cargo.lock changes"; w "$KERNEL" crates/a/Cargo.lock 'version = 3 # a'
w "$KERNEL" crates/b/Cargo.lock 'new'; changes "a nested Cargo.lock is added"; rm -rf "$KERNEL/crates/b"; same "the added lock file is removed"
rm "$KERNEL/crates/a/Cargo.lock"; changes "a nested Cargo.lock is removed"; w "$KERNEL" crates/a/Cargo.lock 'version = 3 # a'
w "$KERNEL" crates/a/Cargo.lock.bak 'version = 3 # a'; same "an unrelated file is named like a lock file"; rm "$KERNEL/crates/a/Cargo.lock.bak"
mkdir -p "$KERNEL/moved"; mv "$KERNEL/crates/a/Cargo.lock" "$KERNEL/moved/Cargo.lock"; changes "a lock file moves to another directory"
mv "$KERNEL/moved/Cargo.lock" "$KERNEL/crates/a/Cargo.lock"; rmdir "$KERNEL/moved"; same "the lock file moves back"
write_toolchain "$KERNEL" nightly-2026-11-01 '"rust-src", "miri", "clippy", "rustfmt"'; changes "the toolchain pin changes"
write_toolchain "$KERNEL" "$CHANNEL" '"rust-src", "miri", "clippy", "rustfmt"'; same "the toolchain pin returns"
w "$KERNEL" src/lib.rs 'fn main() { changed() }'; same "a source file changes"
w "$KERNEL" vendor/x/Cargo.lock 'other'; same "a vendored lock file changes"
w "$KERNEL" target/debug/Cargo.lock 'other'; same "a lock file under target/ changes"
w "$KERNEL" README.md 'text'; same "documentation changes"
echo "# changed" >>"$CF"; changes "the Containerfile changes"; reset_good; same "the Containerfile returns"

# restore-key: the prefix of every key of this repository and image, nothing narrower
run restore-key kernel; RK=$OUT
[ $RC = 0 ] && [ "$(printf '%s\n' "$OUT" | wc -l)" = 1 ] && case "$K0" in "$RK"*) [ "$RK" != "$K0" ] ;; *) false ;; esac \
  || bad "restore-key: want one line, a proper prefix of the key, got exit $RC: $OUT (key $K0)"
case "$RK" in *-) ;; *) bad "restore-key does not end in a dash: $RK" ;; esac
w "$KERNEL" Cargo.lock 'version = 3 # new'; run restore-key kernel; [ "$OUT" = "$RK" ] || bad "restore-key changes with the lock file: $RK then $OUT"
key kernel; case "$K" in "$RK"*) ;; *) bad "the new key $K does not start with the restore key $RK" ;; esac
w "$KERNEL" Cargo.lock 'version = 3'
echo "# changed" >>"$CF"; run restore-key kernel; [ "$OUT" != "$RK" ] || bad "restore-key does not change with the image (a cache from another compiler must not restore)"
reset_good

# a repository with no lock file cannot be keyed
rm -f "$IDL/Cargo.lock" "$IDL/crates/a/Cargo.lock" "$IDL/vendor/x/Cargo.lock" "$IDL/target/debug/Cargo.lock"
run key idl; [ $RC = 1 ] && [ "$(errs)" = 1 ] && printf '%s\n' "$OUT" | grep -q 'idl.*no Cargo.lock' || bad "key of a repository with no lock file: want exit 1 and 1 ERROR naming idl, got exit $RC: $OUT"
run key nosuch; [ $RC != 0 ] && [ "$(errs)" -ge 1 ] || bad "key of an unknown repository: exit $RC: $OUT"
w "$IDL" Cargo.lock 'version = 3'


# ---- 5. usage ------------------------------------------------------------------
for args in "" "bogus" "check extra" "tag extra" "key" "key a b" "restore-key"; do
  # shellcheck disable=SC2086
  run $args; [ $RC = 2 ] && [ "$(errs)" = 1 ] || bad "usage '$args': want exit 2 and 1 ERROR line, got exit $RC: $OUT"
done
run bogus; printf '%s\n' "$OUT" | grep -q bogus || bad "unknown argument is not named: $OUT"

# ---- 6. the real repositories --------------------------------------------------
REAL_OS=$(cd "$SRC/.." && pwd -P)
if [ -f "$REAL_OS/tools/image/Containerfile" ]; then
  RUN_REAL() { OUT=$(cd "$FX" && env -i PATH="${PATH:-/usr/bin:/bin}" HOME="$FX" TMPDIR="$FX" "$SRC/toolchain-image.sh" "$@" 2>&1); RC=$?; }
  RUN_REAL check
  [ $RC = 0 ] && printf '%s\n' "$OUT" | grep -qx 'TOOLCHAIN-IMAGE: OK' || bad "real repositories: check: exit $RC: $(printf '%s\n' "$OUT" | head -n 5 | tr '\n' ' ')"
  RUN_REAL key os
  [ $RC = 0 ] && printf '%s\n' "$OUT" | grep -Eq '^silica-os-[A-Za-z0-9_]+-[0-9a-f]{12}-[0-9a-f]{16}$' || bad "real os: key: exit $RC: $OUT"
  RUN_REAL tag
  [ $RC = 0 ] && printf '%s\n' "$OUT" | grep -Eq '^[0-9a-f]{12}$' || bad "real os: tag: exit $RC: $OUT"
  # the real definition pins exactly the channel of os/rust-toolchain.toml and names QEMU and both firmwares
  want=$(sed -n 's/^channel *= *"\(.*\)"/\1/p' "$REAL_OS/rust-toolchain.toml" | head -n 1)
  [ -n "$want" ] && grep -q "^ARG RUST_CHANNEL=$want\$" "$REAL_OS/tools/image/Containerfile" || bad "real Containerfile: ARG RUST_CHANNEL is not '$want'"
  for p in qemu-system-x86 qemu-system-arm ovmf qemu-efi-aarch64; do
    grep -Eq "(^|[[:space:]])$p([[:space:]\\\\]|\$)" "$REAL_OS/tools/image/Containerfile" || bad "real Containerfile: package $p is not named"
  done
else
  bad "real repositories: tools/image/Containerfile does not exist"
fi

[ $fails = 0 ] && echo "TOOLCHAIN-IMAGE TEST: OK"
exit $((fails > 0))
