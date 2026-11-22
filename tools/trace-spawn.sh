#!/usr/bin/env bash
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"
. "$TOOLS/lib/build.sh"
img=$(build_system_image x86_64 "$WS/target/trace-build.log" "checks=spawn bench") || { echo build failed; cat "$WS/target/trace-build.log" | tail; exit 1; }
"$TOOLS/qemu.sh" --image "$img" --serial "$WS/target/trace.log" --smp 8 --mem 512 --pin 0,2,4,6,8,10,12,14 --emulator 15,13,17,18 --no-iommu --timeout 120 >/dev/null 2>&1
tr -d '\r' < "$WS/target/trace.log" | grep -a "BENCH\|ERROR" | tr '\n' ' '; echo
