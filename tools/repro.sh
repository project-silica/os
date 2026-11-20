#!/usr/bin/env bash
# Reproducible builds check (spec/ARCHITECTURE.md section 16 "Builds are
# reproducible"; component A10).
#   repro.sh
# Builds the x86_64 kernel, the UEFI loader and the disk image twice, each time
# from its own copy of the kernel and os checkouts (tracked files and files not
# ignored, so uncommitted work is checked too) in a different directory with its
# own build cache, and compares the artifacts byte for byte in the order kernel
# (kernel.elf), loader (BOOTX64.EFI), disk image (disk.img). The directory a
# build ran in must not show in its output, so every build remaps the paths of
# its copies, its caches and the workshop (--remap-path-prefix).
# Prints one line per artifact and a final "REPRO: OK". On the first artifact
# that differs, or a build that fails, prints one "ERROR: repro: ..." line and
# "REPRO: FAILED", and keeps both copies of a differing artifact under
# target/logs/repro/<artifact>/. Full build logs go to target/logs/repro/.
# Exit 0 reproducible, 1 not reproducible or a build failed, 2 usage error.
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"
. "$TOOLS/lib/build.sh"
[ $# = 0 ] || die "unknown argument $1 (usage: repro.sh)"
for r in kernel os; do [ -d "$(checkout_of "$r")" ] || die "no checkout of $r"; done

new_run
KSRC=$(checkout_of kernel); OSRC=$(checkout_of os)
OUT=$LOGS/repro
rm -rf "${OUT:?}"; mkdir -p "$OUT"
trap 'rm -rf "${RUN:?}"' EXIT

fail() { # one ERROR line, one verdict line
  err "$1"; echo "REPRO: FAILED"; exit 1
}
first_error() { # first error-looking line of a log, trimmed
  { grep -m1 -E '^(error|ERROR)' "$1" || tail -n 1 "$1"; } 2>/dev/null | cut -c1-160
}
copy_tree() { # copy_tree <checkout> <dir>: the working tree without ignored files and without .git
  mkdir -p "$2"
  git -C "$1" ls-files -z --cached --others --exclude-standard |
    tar -C "$1" --null -T - --ignore-failed-read -cf - 2>/dev/null | tar -C "$2" -xf -
}

# build <n> <dir-name>: builds in $RUN/<dir-name> and keeps the artifacts in $RUN/out<n>.
build() {
  local n=$1 base=$RUN/$2 sysroot flags p f
  SRC[kernel]=$base/kernel; SRC[os]=$base/os
  copy_tree "$KSRC" "$base/kernel"; copy_tree "$OSRC" "$base/os"
  sysroot=$(cd "$KSRC" && rustc --print sysroot 2>/dev/null)
  # Everything that differs between the two builds is mapped to the same name.
  # rustc uses the last matching mapping, so the broad ones come first.
  flags="--remap-path-prefix=$WS=/silica/workshop"
  [ -n "$sysroot" ] && flags+=" --remap-path-prefix=$sysroot=/rust"
  flags+=" --remap-path-prefix=$base/kernel=/silica/kernel --remap-path-prefix=$base/os=/silica/os"
  flags+=" --remap-path-prefix=$(cache_of kernel)=/silica/cache/kernel --remap-path-prefix=$(cache_of os)=/silica/cache/os"
  CARGO_ENV=("RUSTFLAGS=$flags")
  p=$(build_kernel x86_64 "$OUT/build$n.kernel.log") || fail "build $n: kernel: $(first_error "$OUT/build$n.kernel.log")"
  mkdir -p "$RUN/out$n"
  [ -f "$p" ] || fail "build $n: kernel.elf was not produced"
  cp "$p" "$RUN/out$n/kernel.elf"
  p=$(build_loader "$OUT/build$n.loader.log") || fail "build $n: loader: $(first_error "$OUT/build$n.loader.log")"
  [ -f "$p" ] || fail "build $n: BOOTX64.EFI was not produced"
  cp "$p" "$RUN/out$n/BOOTX64.EFI"
  p=$(build_image x86_64 "$OUT/build$n.image.log") || fail "build $n: disk image: $(first_error "$OUT/build$n.image.log")"
  [ -f "$p" ] || fail "build $n: disk.img was not produced"
  cp "$p" "$RUN/out$n/disk.img"
}

# The two builds run in directories that differ in name and in length.
build 1 build-one
build 2 build-two-in-another-directory

for name in kernel.elf BOOTX64.EFI disk.img; do
  a=$RUN/out1/$name; b=$RUN/out2/$name
  if cmp -s "$a" "$b"; then
    echo "repro: $name identical ($(stat -c %s "$a") bytes, sha256 $(sha256sum "$a" | cut -c1-16))"
  else
    mkdir -p "$OUT/$name"; cp "$a" "$OUT/$name/build1"; cp "$b" "$OUT/$name/build2"
    fail "$name differs between the two builds ($(cmp "$a" "$b" 2>&1 | sed -n '1s/^.*differ: //p'); sizes $(stat -c %s "$a") and $(stat -c %s "$b"); both kept in target/logs/repro/$name/)"
  fi
done
echo "REPRO: OK"
