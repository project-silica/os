# Build helpers shared by test.sh, size.sh and qemu.sh. Sourced after common.sh.
#
# build_kernel <arch> <log>   kernel ELF for targets/<arch>-silica.json
# build_loader <log>          the x86_64 UEFI loader (BOOTX64.EFI)
# build_root <arch> <log>     the root task (root.elf), packed into the ramdisk as "root"
# build_image <arch> <log> [cmdline]
#                             GPT disk image with the loader and kernel; a
#                             cmdline (kernel command line, one line) is stored
#                             as SILICA/CMDLINE.TXT and the image is disk-cmdline.img
# Each prints the artifact path on success. Artifacts live in the kernel
# checkout's private cache, never in a source tree.

BUILD_STD=(-Zbuild-std=core,compiler_builtins -Zbuild-std-features=compiler-builtins-mem)

# strip_debug <in> <out> <log>: the copy that goes into the image. The file
# with debug information stays beside it for symbolize.sh.
strip_debug() {
  local t
  for t in llvm-objcopy objcopy; do
    command -v "$t" >/dev/null 2>&1 || continue
    "$t" --strip-debug "$1" "$2" >>"$3" 2>&1; return
  done
  echo "error: neither llvm-objcopy nor objcopy is installed" >>"$3"; return 1
}

art_dir() { local d; d=$(cache_of kernel)/artifacts/$1; mkdir -p "$d"; echo "$d"; }

build_kernel() {
  local arch=$1 log=$2 dir vend out
  dir=$(checkout_of kernel); vend=$(merged_vendor kernel); out=$(art_dir "$arch")
  [ -f "$dir/targets/$arch-silica.json" ] || { echo "no target spec targets/$arch-silica.json" >"$log"; return 1; }
  cargo_run kernel "$log" build --release -p kernel --target "$dir/targets/$arch-silica.json" \
    -Zjson-target-spec "${BUILD_STD[@]}" --config "source.vendored-sources.directory=\"$vend\"" || return 1
  cp "$(cache_of kernel)/target/$arch-silica/release/kernel" "$out/kernel.elf" || return 1
  strip_debug "$out/kernel.elf" "$out/kernel.stripped" "$log" || return 1
  echo "$out/kernel.elf"
}

build_root() { # the root task the kernel starts: the in-OS test program until the system repository exists
  local arch=$1 log=$2 dir vend out
  dir=$(checkout_of kernel); vend=$(merged_vendor kernel); out=$(art_dir "$arch")
  [ -f "$dir/targets/$arch-silica-user.json" ] || { echo "no target spec targets/$arch-silica-user.json" >"$log"; return 1; }
  cargo_run kernel "$log" build --release -p roottest --target "$dir/targets/$arch-silica-user.json" \
    -Zjson-target-spec "${BUILD_STD[@]}" --config "source.vendored-sources.directory=\"$vend\"" || return 1
  cp "$(cache_of kernel)/target/$arch-silica-user/release/roottest" "$out/root.debug.elf" || return 1
  strip_debug "$out/root.debug.elf" "$out/root.elf" "$log" || return 1
  echo "$out/root.elf"
}

build_loader() {
  local log=$1 vend out e
  # lld-link stamps the PE header with the build time and, with debug info, a GUID
  # that differs between builds even for identical code: no debug directory, fixed
  # timestamp. Added to RUSTFLAGS from the caller's CARGO_ENV, if any.
  local rf=""; local -a keep=()
  for e in "${CARGO_ENV[@]+"${CARGO_ENV[@]}"}"; do
    case $e in RUSTFLAGS=*) rf=${e#RUSTFLAGS=} ;; *) keep+=("$e") ;; esac
  done
  local -a CARGO_ENV=("${keep[@]+"${keep[@]}"}" "RUSTFLAGS=${rf:+$rf }-C link-arg=/debug:none -C link-arg=/timestamp:1")
  vend=$(merged_vendor kernel); out=$(art_dir x86_64)
  cargo_run kernel "$log" build --release -p boot-uefi --target x86_64-unknown-uefi \
    "${BUILD_STD[@]}" --config "source.vendored-sources.directory=\"$vend\"" || return 1
  cp "$(cache_of kernel)/target/x86_64-unknown-uefi/release/boot-uefi.efi" "$out/BOOTX64.EFI" || return 1
  echo "$out/BOOTX64.EFI"
}

build_image_tool() {
  local log=$1
  cargo_run os "$log" build --release -q -p silica-image || return 1
  echo "$(cache_of os)/target/release/silica-image"
}

build_image() {
  local arch=$1 log=$2 cmdline=${3:-} k l t r out
  [ "$arch" = x86_64 ] || { echo "no image layout for $arch before B05" >"$log"; return 1; }
  k=$(build_kernel "$arch" "$log.kernel") || { cat "$log.kernel" >"$log"; return 1; }
  l=$(build_loader "$log.loader") || { cat "$log.loader" >"$log"; return 1; }
  # A kernel checkout with a user target spec has a root task to pack.
  local -a root=()
  if [ -f "$(checkout_of kernel)/targets/$arch-silica-user.json" ]; then
    r=$(build_root "$arch" "$log.root") || { cat "$log.root" >"$log"; return 1; }
    root=(--ramdisk-entry "root=$r")
  fi
  t=$(build_image_tool "$log.tool") || { cat "$log.tool" >"$log"; return 1; }
  out=$(art_dir "$arch")/disk.img
  local -a extra=()
  if [ -n "$cmdline" ]; then
    out=$(art_dir "$arch")/disk-cmdline.img
    printf '%s\n' "$cmdline" >"$(dirname "$out")/CMDLINE.TXT" || return 1
    extra=("SILICA/CMDLINE.TXT=$(dirname "$out")/CMDLINE.TXT")
  fi
  cp "$t" "$(dirname "$out")/silica-image" || return 1
  "$(dirname "$out")/silica-image" --out "$out" "EFI/BOOT/BOOTX64.EFI=$l" "SILICA/KERNEL.ELF=${k%.elf}.stripped" \
    "${root[@]+"${root[@]}"}" "${extra[@]+"${extra[@]}"}" >"$log" 2>&1 || return 1
  echo "$out"
}
