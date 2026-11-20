#!/usr/bin/env bash
# Build the current x86_64 image and print the guest's serial output.
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"
. "$TOOLS/lib/build.sh"
new_run
image=$(build_image x86_64 "$RUN/build.log") || { cat "$RUN/build.log" >&2; exit 1; }
"$TOOLS/qemu.sh" --arch x86_64 --image "$image" --serial "$RUN/serial.log"
rc=$?
[ ! -f "$RUN/serial.log" ] || cat "$RUN/serial.log"
exit "$rc"
