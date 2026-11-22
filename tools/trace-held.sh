#!/usr/bin/env bash
# Scratch: Silica's block numbers over several boots on the held host.
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"
. "$TOOLS/lib/build.sh"
img=$(build_system_image x86_64 "$WS/target/trace-build.log" "checks=block bench") || { echo build failed; exit 1; }
pin=$(fastest_cpus 8); emu=15,13,17,18,19,20,21,22,23
pol=$WS/target/scratch/policy
host_tune "$pin,16" "$pol" || echo "not tuned"
trap 'host_restore "$pol"' EXIT
for i in $(seq 1 ${N:-6}); do
  "$TOOLS/qemu.sh" --image "$img" --serial "$WS/target/trace.log" --smp 8 --mem 512 --pin "$pin" --emulator "$emu" --no-iommu --disk-props event_idx=off ${NET:+--net $NET} --timeout 120 >/dev/null 2>&1
  tr -d '\r' < "$WS/target/trace.log" | grep -a "BENCH blk_read4k\|TRACE" | tr '\n' ' '; echo
done
