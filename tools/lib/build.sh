# Build helpers shared by test.sh, size.sh and qemu.sh. Sourced after common.sh.
#
# build_kernel <arch> <log>   kernel ELF for targets/<arch>-silica.json
# build_loader <log> [arch]   the UEFI loader (BOOTX64.EFI, BOOTAA64.EFI)
# build_root <arch> <log>     the root task (root.elf), packed into the ramdisk as "root"
# build_image <arch> <log> [cmdline]
#                             GPT disk image with the loader and kernel; a
#                             cmdline (kernel command line, one line) is stored
#                             as SILICA/CMDLINE.TXT and the image is disk-cmdline.img
# Each prints the artifact path on success. Artifacts live in the kernel
# checkout's private cache, never in a source tree.

BUILD_STD=(-Zbuild-std=core,compiler_builtins -Zbuild-std-features=compiler-builtins-mem)
# Programs have a heap (silica_rt::heap), so they also get Rust's alloc.
BUILD_STD_USER=(-Zbuild-std=core,alloc,compiler_builtins -Zbuild-std-features=compiler-builtins-mem)

# strip_debug <in> <out> <log>: the copy that goes into the image. The file
# with debug information stays beside it for symbolize.sh.
# The objcopy of the kernel's pinned toolchain (llvm-tools) reads every
# target; a distribution's binutils objcopy often reads only the host's.
strip_debug() {
  local t sysroot host
  sysroot=$(cd "$(checkout_of kernel)" && rustc --print sysroot 2>/dev/null)
  host=$(cd "$(checkout_of kernel)" && rustc -vV 2>/dev/null | sed -n 's/^host: //p')
  for t in "$sysroot/lib/rustlib/$host/bin/rust-objcopy" llvm-objcopy; do
    command -v "$t" >/dev/null 2>&1 || continue
    # The toolchain's tools find its libLLVM only through the library path.
    LD_LIBRARY_PATH="$sysroot/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$t" --strip-debug "$1" "$2" >>"$3" 2>&1; return
  done
  echo "error: no objcopy that reads every target: install the toolchain's llvm-tools component (rustup component add llvm-tools) or llvm-objcopy" >>"$3"; return 1
}

art_dir() { local d; d=$(cache_of kernel)/artifacts/$1; mkdir -p "$d"; echo "$d"; }

build_kernel() {
  local arch=$1 log=$2 dir vend out
  dir=$(checkout_of kernel); vend=$(merged_vendor kernel) || return 1; out=$(art_dir "$arch")
  [ -f "$dir/targets/$arch-silica.json" ] || { echo "no target spec targets/$arch-silica.json" >"$log"; return 1; }
  cargo_run kernel "$log" build --release -p kernel --target "$dir/targets/$arch-silica.json" \
    -Zjson-target-spec "${BUILD_STD[@]}" --config "source.vendored-sources.directory=\"$vend\"" || return 1
  cp "$(cache_of kernel)/target/$arch-silica/release/kernel" "$out/kernel.elf" || return 1
  strip_debug "$out/kernel.elf" "$out/kernel.stripped" "$log" || return 1
  echo "$out/kernel.elf"
}

build_root() { # the root task the kernel starts: the in-OS test program until the system repository exists
  local arch=$1 log=$2 dir vend out
  dir=$(checkout_of kernel); vend=$(merged_vendor kernel) || return 1; out=$(art_dir "$arch")
  [ -f "$dir/targets/$arch-silica-user.json" ] || { echo "no target spec targets/$arch-silica-user.json" >"$log"; return 1; }
  cargo_run kernel "$log" build --release -p roottest --target "$dir/targets/$arch-silica-user.json" \
    -Zjson-target-spec "${BUILD_STD[@]}" --config "source.vendored-sources.directory=\"$vend\"" || return 1
  cp "$(cache_of kernel)/target/$arch-silica-user/release/roottest" "$out/root.debug.elf" || return 1
  strip_debug "$out/root.debug.elf" "$out/root.elf" "$log" || return 1
  echo "$out/root.elf"
}

# build_system <arch> <log>: the system repository's programs for the user
# target. Prints the directory holding one <name>.elf (stripped) per program,
# with <name>.debug.elf beside it. The root task is init.elf.
build_system() {
  local arch=$1 log=$2 k s vend out n
  k=$(checkout_of kernel); s=$(checkout_of system); out=$(art_dir "$arch")/system
  [ -f "$s/Cargo.toml" ] || { echo "no checkout of the system repository" >"$log"; return 1; }
  mkdir -p "$out"; vend=$(merged_vendor system) || return 1
  cargo_run system "$log" build --release --workspace --bins --target "$k/targets/$arch-silica-user.json" \
    -Zjson-target-spec "${BUILD_STD_USER[@]}" --config "source.vendored-sources.directory=\"$vend\"" || return 1
  local meta; meta=$(cd "$s" && cargo metadata --no-deps --format-version 1 --offline 2>/dev/null) || { echo "cargo metadata failed in $s" >>"$log"; return 1; }
  for n in $(jq -r '.packages[].targets[] | select(.kind[] == "bin") | .name' <<<"$meta"); do
    cp "$(cache_of system)/target/$arch-silica-user/release/$n" "$out/$n.debug.elf" || return 1
    strip_debug "$out/$n.debug.elf" "$out/$n.elf" "$log" || return 1
  done
  # The drivers list the device manager reads: "<match> <program>" for each
  # match a package declares ([package.metadata.silica] drivers), its
  # program being the package's binary.
  jq -r '.packages[] | select(.metadata.silica.drivers) | . as $p
    | ($p.targets[] | select(.kind[] == "bin") | .name) as $bin | $p.metadata.silica.drivers[] | "\(.) \($bin)"' <<<"$meta" >"$out/drivers.list" || return 1
  # The services list the service manager reads (init's manifest module):
  # one line per package declaring [package.metadata.silica.service].
  jq -r '.packages[] | select(.metadata.silica.service) | . as $p | .metadata.silica.service as $s
    | ($p.targets[] | select(.kind[] == "bin") | .name) as $bin
    | [$p.name, "program=\($bin)"]
      + (if $s.memory then ["memory=\($s.memory)"] else [] end)
      + (if $s.provides then ["provides=\($s.provides)"] else [] end)
      + (if ($s.needs // []) != [] then ["needs=\($s.needs | join(","))"] else [] end)
      + (if $s.machine then ["machine"] else [] end)
      + (if $s.start then ["start=\($s.start)"] else [] end)
      + (if $s.restart then ["restart=\($s.restart)"] else [] end)
    | join(" ")' <<<"$meta" >"$out/services.list" || return 1
  echo "$out"
}

build_loader() {
  local log=$1 arch=${2:-x86_64} vend out e name
  case $arch in x86_64) name=BOOTX64.EFI ;; aarch64) name=BOOTAA64.EFI ;; *) echo "error: no UEFI loader for $arch" >>"$log"; return 1 ;; esac
  # lld-link stamps the PE header with the build time and, with debug info, a GUID
  # that differs between builds even for identical code: no debug directory, fixed
  # timestamp. Added to RUSTFLAGS from the caller's CARGO_ENV, if any.
  local rf=""; local -a keep=()
  for e in "${CARGO_ENV[@]+"${CARGO_ENV[@]}"}"; do
    case $e in RUSTFLAGS=*) rf=${e#RUSTFLAGS=} ;; *) keep+=("$e") ;; esac
  done
  local -a CARGO_ENV=("${keep[@]+"${keep[@]}"}" "RUSTFLAGS=${rf:+$rf }-C link-arg=/debug:none -C link-arg=/timestamp:1")
  vend=$(merged_vendor kernel) || return 1; out=$(art_dir "$arch")
  cargo_run kernel "$log" build --release -p boot-uefi --target "$arch-unknown-uefi" \
    "${BUILD_STD[@]}" --config "source.vendored-sources.directory=\"$vend\"" || return 1
  cp "$(cache_of kernel)/target/$arch-unknown-uefi/release/boot-uefi.efi" "$out/$name" || return 1
  echo "$out/$name"
}

build_image_tool() {
  local log=$1
  cargo_run os "$log" build --release -q -p silica-image || return 1
  echo "$(cache_of os)/target/release/silica-image"
}

# build_system_image <arch> <log> [cmdline] [root]: the image whose root task
# is the system repository's program <root> (default: init), with every other
# program of that repository in the ramdisk under its own name. Prints the
# image path (system.img, or system-<root>.img for another root task).
build_system_image() {
  local arch=$1 log=$2 cmdline=${3:-} root=${4:-init} k l t sys out f n lp
  lp=$(loader_path "$arch") || { echo "no image layout for $arch (no UEFI loader)" >"$log"; return 1; }
  # As for build_image: on aarch64 the harness hears the status through semihosting.
  [ "$arch" = aarch64 ] && cmdline="exit=semihosting${cmdline:+ $cmdline}"
  k=$(build_kernel "$arch" "$log.kernel") || { cat "$log.kernel" >"$log"; return 1; }
  l=$(build_loader "$log.loader" "$arch") || { cat "$log.loader" >"$log"; return 1; }
  sys=$(build_system "$arch" "$log.system") || { cat "$log.system" >"$log"; return 1; }
  t=$(build_image_tool "$log.tool") || { cat "$log.tool" >"$log"; return 1; }
  out=$(art_dir "$arch")/system.img
  [ "$root" = init ] || out=$(art_dir "$arch")/system-$root.img
  [ -f "$sys/$root.elf" ] || { echo "the system repository has no program named $root" >"$log"; return 1; }
  local -a entries=(--ramdisk-entry "root=$sys/$root.elf") extra=()
  for f in "$sys"/*.elf; do
    n=$(basename "$f" .elf)
    case "$n" in "$root"|*.debug) continue ;; esac
    entries+=(--ramdisk-entry "$n=$f")
  done
  entries+=(--ramdisk-entry "drivers=$sys/drivers.list" --ramdisk-entry "services=$sys/services.list")
  if [ -n "$cmdline" ]; then
    # This run's alone, as for build_image.
    [ -n "${RUN:-}" ] && out=$RUN/$(basename "$out")
    printf '%s\n' "$cmdline" >"$(dirname "$out")/SYSTEM-CMDLINE.TXT" || return 1
    extra=("SILICA/CMDLINE.TXT=$(dirname "$out")/SYSTEM-CMDLINE.TXT")
  fi
  cp "$t" "$(dirname "$out")/silica-image" || return 1
  "$(dirname "$out")/silica-image" --out "$out" "$lp=$l" "SILICA/KERNEL.ELF=${k%.elf}.stripped" \
    "${entries[@]}" "${extra[@]+"${extra[@]}"}" >"$log" 2>&1 || return 1
  echo "$out"
}

# The UEFI removable-media path of the loader for an architecture.
loader_path() {
  case $1 in x86_64) echo EFI/BOOT/BOOTX64.EFI ;; aarch64) echo EFI/BOOT/BOOTAA64.EFI ;; *) return 1 ;; esac
}

build_image() {
  local arch=$1 log=$2 cmdline=${3:-} k l t r out lp
  lp=$(loader_path "$arch") || { echo "no image layout for $arch (no UEFI loader)" >"$log"; return 1; }
  # On aarch64 the test harness hears the exit status through semihosting,
  # which the loader and kernel use only when told to (on hardware without
  # a debugger the call is an exception).
  [ "$arch" = aarch64 ] && cmdline="exit=semihosting${cmdline:+ $cmdline}"
  k=$(build_kernel "$arch" "$log.kernel") || { cat "$log.kernel" >"$log"; return 1; }
  l=$(build_loader "$log.loader" "$arch") || { cat "$log.loader" >"$log"; return 1; }
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
    # An image with its own command line is this run's alone: another run
    # (another test, another command line) may be building one at once.
    out=${RUN:-$(art_dir "$arch")}/disk-cmdline.img
    printf '%s\n' "$cmdline" >"$(dirname "$out")/CMDLINE.TXT" || return 1
    extra=("SILICA/CMDLINE.TXT=$(dirname "$out")/CMDLINE.TXT")
  fi
  cp "$t" "$(dirname "$out")/silica-image" || return 1
  "$(dirname "$out")/silica-image" --out "$out" "$lp=$l" "SILICA/KERNEL.ELF=${k%.elf}.stripped" \
    "${root[@]+"${root[@]}"}" "${extra[@]+"${extra[@]}"}" >"$log" 2>&1 || return 1
  echo "$out"
}
