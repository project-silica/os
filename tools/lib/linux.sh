# The Linux baseline image for bench.sh. Sourced after common.sh and build.sh.
#
# build_linux <log> [server]   prints the path of a UEFI-bootable disk image
#                     whose kernel (EFI stub, initramfs built in) runs
#                     bench/linux/init.c as /init: the benchmarks, or with
#                     `server` its HTTP server (init.c built with
#                     -DSILICA_SERVER; the same kernel configuration).
# Everything is derived from files in the os repository: the pinned version
# and checksum (bench/linux/VERSION), the config fragment, the benchmark
# program and the initramfs list. The source archive is downloaded once into
# the cache and verified; the build is keyed by the hash of its inputs, so it
# is redone exactly when one of them changes. Returns 3 when the archive is
# not cached and cannot be downloaded (no network): the baseline is unavailable.
# $SILICA_LINUX_IMG names a ready-made image instead (used by the tool's own test).
linux_field() { sed -n "s/^$1=//p" "$(checkout_of os)/bench/linux/VERSION" | head -n 1; }

build_linux() {
  local log=$1 mode=${2:-bench} src dir ver url sum tar key b jobs t define=""
  [ "$mode" = server ] && define=-DSILICA_SERVER
  if [ -n "${SILICA_LINUX_IMG:-}" ]; then
    [ -f "$SILICA_LINUX_IMG" ] || { echo "SILICA_LINUX_IMG=$SILICA_LINUX_IMG does not exist" >"$log"; return 1; }
    echo "$SILICA_LINUX_IMG"; return 0
  fi
  src=$(checkout_of os)/bench/linux
  ver=$(linux_field version); url=$(linux_field url); sum=$(linux_field sha256)
  [ -n "$ver" ] && [ -n "$url" ] && [ -n "$sum" ] || { echo "bench/linux/VERSION is incomplete" >"$log"; return 1; }
  dir=$OUTBASE/cache/linux; mkdir -p "$dir"
  key=$({ cat "$src/VERSION" "$src/config" "$src/init.c" "$src/initramfs.list"; echo "$define"; } | sha256sum | cut -c1-16)
  b=$dir/build-$key
  if [ -f "$b/linux.img" ]; then echo "$b/linux.img"; return 0; fi
  tar=$dir/linux-$ver.tar.xz
  : >"$log"
  if [ ! -f "$tar" ] || [ "$(sha256sum "$tar" | cut -d' ' -f1)" != "$sum" ]; then
    command -v curl >/dev/null || { echo "curl is not installed and $tar is not cached" >>"$log"; return 3; }
    curl -sSfL --max-time 1800 -o "$tar.part" "$url" >>"$log" 2>&1 || { echo "cannot download $url" >>"$log"; return 3; }
    [ "$(sha256sum "$tar.part" | cut -d' ' -f1)" = "$sum" ] || { echo "checksum of $url does not match bench/linux/VERSION" >>"$log"; return 1; }
    mv "$tar.part" "$tar"
  fi
  for t in gcc make flex bison bc tar xz; do
    command -v "$t" >/dev/null || { echo "error: $t is needed to build the Linux baseline" >>"$log"; return 1; }
  done
  mkdir -p "$b" || return 1
  [ -d "$b/linux-$ver" ] || tar -C "$b" -xf "$tar" >>"$log" 2>&1 || return 1
  jobs=$(nproc 2>/dev/null || echo 4)
  (
    set -e
    cd "$b/linux-$ver"
    make -s tinyconfig
    make -s headers_install INSTALL_HDR_PATH="$b/hdr"
    gcc -static -nostdlib -nostdinc -O2 -mavx2 -fno-stack-protector -fno-pic -no-pie $define \
      -I tools/include/nolibc -I "$b/hdr/include" -include nolibc.h -o "$b/init" "$src/init.c" -lgcc
    sed "s|@INIT@|$b/init|" "$src/initramfs.list" >"$b/initramfs.list"
    grep -v '^#' "$src/config" >"$b/fragment"
    echo "CONFIG_INITRAMFS_SOURCE=\"$b/initramfs.list\"" >>"$b/fragment"
    ./scripts/kconfig/merge_config.sh -m .config "$b/fragment"
    make -s olddefconfig
    # Every option the baseline asks for must be in the result: kconfig
    # drops one whose dependencies are unmet without a word (that is how
    # the baseline once ran without MSI and without its IOMMU).
    while IFS= read -r line; do
      case "$line" in
        CONFIG_*=n) grep -qx "# ${line%=n} is not set" .config || ! grep -q "^${line%=n}=" .config ;;
        CONFIG_*=*) grep -qxF "$line" .config ;;
        *) true ;;
      esac || { echo "error: the Linux baseline's config asks for $line, which kconfig dropped (an unmet dependency)"; exit 1; }
    done <"$b/fragment"
    make -s -j"$jobs" bzImage
  ) >>"$log" 2>&1 || return 1
  t=$(build_image_tool "$log.tool") || { cat "$log.tool" >>"$log"; return 1; }
  "$t" --out "$b/linux.img.tmp" "EFI/BOOT/BOOTX64.EFI=$b/linux-$ver/arch/x86/boot/bzImage" >>"$log" 2>&1 || return 1
  mv "$b/linux.img.tmp" "$b/linux.img" && echo "$b/linux.img"
}
