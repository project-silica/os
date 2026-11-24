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
    # Written beside and moved into place: another tool reading the old
    # file meanwhile reads all of it.
    LD_LIBRARY_PATH="$sysroot/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$t" --strip-debug "$1" "$2.new.$BASHPID" >>"$3" 2>&1 && mv "$2.new.$BASHPID" "$2"; return
  done
  echo "error: no objcopy that reads every target: install the toolchain's llvm-tools component (rustup component add llvm-tools) or llvm-objcopy" >>"$3"; return 1
}

art_dir() { local d; d=$(cache_of kernel)/artifacts/$1; mkdir -p "$d"; echo "$d"; }
# put <from> <to>: copy an artifact into place whole (see strip_debug).
put() { cp "$1" "$2.new.$BASHPID" && mv "$2.new.$BASHPID" "$2"; }

build_kernel() {
  local arch=$1 log=$2 dir vend out
  dir=$(checkout_of kernel); vend=$(merged_vendor kernel) || return 1; out=$(art_dir "$arch")
  [ -f "$dir/targets/$arch-silica.json" ] || { echo "no target spec targets/$arch-silica.json" >"$log"; return 1; }
  cargo_run kernel "$log" build --release -p kernel --target "$dir/targets/$arch-silica.json" \
    -Zjson-target-spec "${BUILD_STD[@]}" --config "source.vendored-sources.directory=\"$vend\"" || return 1
  put "$(cache_of kernel)/target/$arch-silica/release/kernel" "$out/kernel.elf" || return 1
  strip_debug "$out/kernel.elf" "$out/kernel.stripped" "$log" || return 1
  echo "$out/kernel.elf"
}

build_root() { # the root task the kernel starts: the in-OS test program until the system repository exists
  local arch=$1 log=$2 dir vend out
  dir=$(checkout_of kernel); vend=$(merged_vendor kernel) || return 1; out=$(art_dir "$arch")
  [ -f "$dir/targets/$arch-silica-user.json" ] || { echo "no target spec targets/$arch-silica-user.json" >"$log"; return 1; }
  cargo_run kernel "$log" build --release -p roottest --target "$dir/targets/$arch-silica-user.json" \
    -Zjson-target-spec "${BUILD_STD[@]}" --config "source.vendored-sources.directory=\"$vend\"" || return 1
  put "$(cache_of kernel)/target/$arch-silica-user/release/roottest" "$out/root.debug.elf" || return 1
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
    put "$(cache_of system)/target/$arch-silica-user/release/$n" "$out/$n.debug.elf" || return 1
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
      + (if $s.seed then ["seed"] else [] end)
      + (if $s.keeps then ["keeps"] else [] end)
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
  put "$(cache_of kernel)/target/$arch-unknown-uefi/release/boot-uefi.efi" "$out/$name" || return 1
  echo "$out/$name"
}

build_image_tool() {
  local log=$1
  cargo_run os "$log" build --release -q -p silica-image || return 1
  echo "$(cache_of os)/target/release/silica-image"
}

# run_pieces <kind> <arch> <log>: what a run's images are assembled from,
# built once per run, architecture and kind and copied into the run: the
# stripped kernel, the loader, the image tool, and the root task (kind
# "kernel") or the system repository's programs and lists (kind "system").
# Asked for by a tool that builds one set of sources for the whole run
# (PIECES_ONCE=1: test.sh; bench.sh builds several kernels in one run and
# does not). A warm build of the pieces still takes seconds, which every
# one of a run's hundreds of images paid; and with a copy of its own a run
# can assemble and boot its images at once, and a build another run starts
# meanwhile changes nothing under it. A build that failed fails every
# image of the run without being tried again. Prints the directory:
# kernel.stripped, loader.efi, silica-image, and root.elf or system/.
run_pieces() {
  local kind=$1 arch=$2 log=$3 d
  # ($PIECES_DIR: a tool that builds several kernels in one run, each for a
  # while, names a directory per kernel.)
  d=${PIECES_DIR:-$RUN}/pieces-$kind-$arch
  (
    flock 9
    [ -f "$d/.ok" ] && exit 0
    [ -f "$d/.failed" ] && { cat "$d/.failed" >"$log"; exit 1; }
    mkdir -p "$d" || exit 1
    failed() { cat "$1" >"$log"; cp "$log" "$d/.failed"; exit 1; }
    k=$(build_kernel "$arch" "$log.kernel") || failed "$log.kernel"
    l=$(build_loader "$log.loader" "$arch") || failed "$log.loader"
    t=$(build_image_tool "$log.tool") || failed "$log.tool"
    cp "${k%.elf}.stripped" "$d/kernel.stripped" && cp "$l" "$d/loader.efi" && cp "$t" "$d/silica-image" || failed "$log"
    if [ "$kind" = system ]; then
      sys=$(build_system "$arch" "$log.system") || failed "$log.system"
      mkdir -p "$d/system" && cp "$sys"/drivers.list "$sys"/services.list "$d/system/" || failed "$log"
      for f in "$sys"/*.elf; do case "$f" in *.debug.elf) ;; *) cp "$f" "$d/system/" || failed "$log" ;; esac; done
    elif [ -f "$(checkout_of kernel)/targets/$arch-silica-user.json" ]; then
      # A kernel checkout with a user target spec has a root task to pack.
      r=$(build_root "$arch" "$log.root") || failed "$log.root"
      cp "$r" "$d/root.elf" || failed "$log"
    fi
    : >"$d/.ok"
  ) 9>"$OUTBASE/build.lock" || return 1
  echo "$d"
}

# build_system_image <arch> <log> [cmdline] [root]: the image whose root task
# is the system repository's program <root> (default: init), with every other
# program of that repository in the ramdisk under its own name. Prints the
# image path (system.img, or system-<root>.img for another root task). The
# image is the caller's own where it has a place for one ($UNIT_DIR, a test
# unit's scratch directory; with a command line, the run's directory), so
# guest tests can build and boot at once.
build_system_image() {
  if [ -n "${PIECES_ONCE:-}" ]; then build_system_image_locked "$@"
  else ( flock 9; build_system_image_locked "$@" ) 9>"$OUTBASE/build.lock"; fi   # one build at a time: they share their artifacts
}

build_system_image_locked() {
  local arch=$1 log=$2 cmdline=${3:-} root=${4:-init} k l t sys out f n lp tag p
  lp=$(loader_path "$arch") || { echo "no image layout for $arch (no UEFI loader)" >"$log"; return 1; }
  # As for build_image: on aarch64 the harness hears the status through semihosting.
  [ "$arch" = aarch64 ] && cmdline="exit=semihosting${cmdline:+ $cmdline}"
  out=$(art_dir "$arch")
  if [ -n "${PIECES_ONCE:-}" ]; then
    p=$(run_pieces system "$arch" "$log") || return 1
    k=$p/kernel.stripped l=$p/loader.efi sys=$p/system t=$p/silica-image
  else
    k=$(build_kernel "$arch" "$log.kernel") || { cat "$log.kernel" >"$log"; return 1; }
    l=$(build_loader "$log.loader" "$arch") || { cat "$log.loader" >"$log"; return 1; }
    sys=$(build_system "$arch" "$log.system") || { cat "$log.system" >"$log"; return 1; }
    t=$(build_image_tool "$log.tool") || { cat "$log.tool" >"$log"; return 1; }
    k=${k%.elf}.stripped
    cp "$t" "$out/silica-image" || return 1; t=$out/silica-image
  fi
  [ -f "$sys/$root.elf" ] || { echo "the system repository has no program named $root" >"$log"; return 1; }
  local -a entries=(--ramdisk-entry "root=$sys/$root.elf") extra=()
  for f in "$sys"/*.elf; do
    n=$(basename "$f" .elf)
    case "$n" in "$root"|*.debug) continue ;; esac
    entries+=(--ramdisk-entry "$n=$f")
  done
  entries+=(--ramdisk-entry "drivers=$sys/drivers.list" --ramdisk-entry "services=$sys/services.list")
  n=system.img; [ "$root" = init ] || n=system-$root.img
  tag=$(printf '%s' "$cmdline" | cksum | cut -d' ' -f1)
  if [ -n "${UNIT_DIR:-}" ]; then out=$UNIT_DIR/image-$tag
  elif [ -n "$cmdline" ] && [ -n "${RUN:-}" ]; then out=$RUN/image-$tag; fi
  mkdir -p "$out" || return 1
  if [ -n "$cmdline" ]; then
    printf '%s\n' "$cmdline" >"$out/SYSTEM-CMDLINE.TXT" || return 1
    extra=("SILICA/CMDLINE.TXT=$out/SYSTEM-CMDLINE.TXT")
  fi
  "$t" --out "$out/$n" "$lp=$l" "SILICA/KERNEL.ELF=$k" "${entries[@]}" "${extra[@]+"${extra[@]}"}" >"$log" 2>&1 || return 1
  echo "$out/$n"
}

# The UEFI removable-media path of the loader for an architecture.
loader_path() {
  case $1 in x86_64) echo EFI/BOOT/BOOTX64.EFI ;; aarch64) echo EFI/BOOT/BOOTAA64.EFI ;; *) return 1 ;; esac
}

build_image() {
  local arch=$1 log=$2 cmdline=${3:-} k l t r out lp p
  lp=$(loader_path "$arch") || { echo "no image layout for $arch (no UEFI loader)" >"$log"; return 1; }
  # On aarch64 the test harness hears the exit status through semihosting,
  # which the loader and kernel use only when told to (on hardware without
  # a debugger the call is an exception).
  [ "$arch" = aarch64 ] && cmdline="exit=semihosting${cmdline:+ $cmdline}"
  out=$(art_dir "$arch")
  local -a root=() extra=()
  if [ -n "${PIECES_ONCE:-}" ]; then
    p=$(run_pieces kernel "$arch" "$log") || return 1
    k=$p/kernel.stripped l=$p/loader.efi t=$p/silica-image
    [ -f "$p/root.elf" ] && root=(--ramdisk-entry "root=$p/root.elf")
  else
    k=$(build_kernel "$arch" "$log.kernel") || { cat "$log.kernel" >"$log"; return 1; }
    l=$(build_loader "$log.loader" "$arch") || { cat "$log.loader" >"$log"; return 1; }
    # A kernel checkout with a user target spec has a root task to pack.
    if [ -f "$(checkout_of kernel)/targets/$arch-silica-user.json" ]; then
      r=$(build_root "$arch" "$log.root") || { cat "$log.root" >"$log"; return 1; }
      root=(--ramdisk-entry "root=$r")
    fi
    t=$(build_image_tool "$log.tool") || { cat "$log.tool" >"$log"; return 1; }
    k=${k%.elf}.stripped
  fi
  # An image is the caller's own where it has a place for one: a test
  # unit's scratch directory, or, with a command line, the run's (another
  # test with another command line may be building one at once).
  out=$out/disk.img
  if [ -n "${UNIT_DIR:-}" ]; then out=$UNIT_DIR/disk.img
  elif [ -n "$cmdline" ]; then out=${RUN:-$(art_dir "$arch")}/disk-cmdline.img; fi
  mkdir -p "$(dirname "$out")" || return 1
  if [ -n "$cmdline" ]; then
    printf '%s\n' "$cmdline" >"$(dirname "$out")/CMDLINE.TXT" || return 1
    extra=("SILICA/CMDLINE.TXT=$(dirname "$out")/CMDLINE.TXT")
  fi
  [ -n "${PIECES_ONCE:-}" ] || { cp "$t" "$(dirname "$out")/silica-image" || return 1; t=$(dirname "$out")/silica-image; }
  "$t" --out "$out" "$lp=$l" "SILICA/KERNEL.ELF=$k" \
    "${root[@]+"${root[@]}"}" "${extra[@]+"${extra[@]}"}" >"$log" 2>&1 || return 1
  echo "$out"
}
