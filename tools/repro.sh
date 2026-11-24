#!/usr/bin/env bash
# Reproducible builds check (spec/ARCHITECTURE.md section 16 "Builds are
# reproducible"; component A10).
#   repro.sh [--system]
# With --system, also build and compare the bootable image containing init,
# the services, their drivers and the manifests (from the same copies).
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
# The os workspace names idl and system crates (its host tools), so cargo
# loads it only with them beside it: every build copies all four.
repos=(kernel os idl system)
artifacts=(kernel.elf BOOTX64.EFI disk.img)
case "$#:${1:-}" in
  0:) ;;
  1:--system) artifacts+=(system.img) ;;
  *) die "unknown argument $1 (usage: repro.sh [--system])" ;;
esac
for r in "${repos[@]}"; do [ -d "$(checkout_of "$r")" ] || die "no checkout of $r"; done

new_run
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
build() (
  local n=$1 base=$RUN/$2 sysroot flags p r
  # These cold builds have no later cache consumer. Removing the run
  # reclaims their caches as well as their source copies.
  OUTBASE=$base
  unset PIECES_ONCE PIECES_DIR UNIT_DIR PATCH_DONE
  for r in "${repos[@]}"; do
    copy_tree "$(checkout_of "$r")" "$base/$r" || fail "build $n: cannot copy $r"
    SRC[$r]=$base/$r
  done
  sysroot=$(cd "$base/kernel" && rustc --print sysroot 2>/dev/null)
  # Everything that differs between the two builds is mapped to the same name.
  # rustc uses the last matching mapping, so the broad ones come first.
  flags="--remap-path-prefix=$WS=/silica/workshop"
  [ -n "$sysroot" ] && flags+=" --remap-path-prefix=$sysroot=/rust"
  for r in "${repos[@]}"; do
    flags+=" --remap-path-prefix=$base/$r=/silica/$r --remap-path-prefix=$(cache_of "$r")=/silica/cache/$r"
  done
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
  cp "$p" "$RUN/out$n/disk.img" || fail "build $n: cannot keep disk.img"
  if [ -n "${SRC[system]:-}" ]; then
    p=$(build_system_image x86_64 "$OUT/build$n.system.log") || fail "build $n: system image: $(first_error "$OUT/build$n.system.log")"
    cp "$p" "$RUN/out$n/system.img" || fail "build $n: cannot keep system.img"
  fi
)

# The two builds run in directories that differ in name and in length.
build 1 build-one || exit 1
build 2 build-two-in-another-directory || exit 1

for name in "${artifacts[@]}"; do
  a=$RUN/out1/$name; b=$RUN/out2/$name
  if cmp -s "$a" "$b"; then
    echo "repro: $name identical ($(stat -c %s "$a") bytes, sha256 $(sha256sum "$a" | cut -c1-16))"
  else
    mkdir -p "$OUT/$name"; cp "$a" "$OUT/$name/build1"; cp "$b" "$OUT/$name/build2"
    fail "$name differs between the two builds ($(cmp "$a" "$b" 2>&1 | sed -n '1s/^.*differ: //p'); sizes $(stat -c %s "$a") and $(stat -c %s "$b"); both kept in target/logs/repro/$name/)"
  fi
done
echo "REPRO: OK"
