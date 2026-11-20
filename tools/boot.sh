#!/usr/bin/env bash
# Build an image and boot it in QEMU, serial console to standard output.
#   boot.sh [--arch x86_64|aarch64] [--system [--root <program>]] [--cmdline "<kernel command line>"] [--test <in-OS test>] [--smp <n>] [--mem <MiB>] [--timeout <s>]
# --test NAME is short for --cmdline test=NAME. --system boots the system
# image (root task: the system repository's init) instead of the kernel's
# test image; --root names another program of that repository as the root
# task (systest: the tests between programs). Exit status is qemu.sh's:
# 0 when the guest reported success through the debug-exit device.
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"
. "$TOOLS/lib/build.sh"
cmdline="" pass=() builder=build_image root=init arch=x86_64
while [ $# -gt 0 ]; do
  case "$1" in
    --cmdline) [ $# -ge 2 ] || die "--cmdline needs a value"; cmdline=$2; shift 2 ;;
    --test) [ $# -ge 2 ] || die "--test needs a name"; cmdline="test=$2"; shift 2 ;;
    --arch) [ $# -ge 2 ] || die "--arch needs a value"; arch=$2; shift 2 ;;
    --system) builder=build_system_image; shift ;;
    --root) [ $# -ge 2 ] || die "--root needs a program name"; root=$2; shift 2 ;;
    --smp|--mem|--timeout) [ $# -ge 2 ] || die "$1 needs a value"; pass+=("$1" "$2"); shift 2 ;;
    *) die "unknown argument $1" ;;
  esac
done
new_run
log=$RUN/build.log
img=$($builder "$arch" "$log" "$cmdline" "$root") || {
  for f in "$log" "$log".*; do [ -f "$f" ] && grep -E -A12 '^(error|warning)' "$f" | head -80; done
  die "image build failed (logs: $log*)"
}
"$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$RUN/serial.log" "${pass[@]+"${pass[@]}"}"; rc=$?
cat "$RUN/serial.log"
exit $rc
