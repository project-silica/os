#!/usr/bin/env bash
# Profile of one kernel path (spec/TESTING.md section 4.1).
#   profile.sh [--bench <name>] [--kvm] [--times <n>] [--per <n>] [--top <n>] [--lines]
#              [--kernel <dir>] [--count] [--out <dir>]
#
# Builds the x86_64 image whose root task runs "bench=<name>[:<times>]"
# (default ipc: only the IPC round trip; null, ctx, fault, timer), boots it,
# and attributes what the kernel did to the function containing each
# instruction (with --lines: to its source line).
#
# Default: instructions. One boot under QEMU TCG with icount (one
# instruction per translation block, so the counts are exact and repeat
# from run to run) and the plugin tools/profile/insncount.c, counting what
# ran on processor 0 (where the benchmarks run). The figures are divided by
# --per (default 22000, the samples plus warm-up of one benchmark), so they
# are per operation. Boot work (chiefly the timer calibration in kmain) is
# counted too and shows as a fixed amount per operation.
#
# --kvm: processor cycles. One boot under KVM with one virtual processor
# pinned to the host's fastest core (as bench.sh pins), the benchmark repeated --times times
# (default 300, so the run is long enough to sample); the host's perf samples
# the guest's instruction pointer every 10007 cycles spent in the guest.
# Figures are each function's share of the guest-kernel samples, in percent.
# Needs perf and passwordless sudo (guest samples are privileged).
#
# --kernel profiles another checkout of the kernel repository (an older
# commit, to compare one path before and after a change).
# --count (instructions only): print just "COUNT <n>", every kernel
# instruction processor 0 executed in the whole boot; bench.sh takes the
# difference between --times 2 and --times 1 as the exact count of one
# benchmark. --out puts the work files in <dir> (default target/profile), so
# several profiles can run at once.
# Output: the benchmark's own BENCH lines, then "<figure> <function>" lines,
# largest first, then "TOTAL <n>" (operations' instructions, or samples).
# Exit 0, or 2 on a setup error.
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"
. "$TOOLS/lib/build.sh"
mode=ipc per=22000 top=40 lines=0 kvm=0 times="" count=0 out=$OUTBASE/profile
while [ $# -gt 0 ]; do
  case "$1" in
    --bench) mode=$2; shift 2 ;;
    --kvm) kvm=1; shift ;;
    --times) times=$2; shift 2 ;;
    --per) per=$2; shift 2 ;;
    --top) top=$2; shift 2 ;;
    --lines) lines=1; shift ;;
    --kernel) SRC[kernel]=$(readlink -f "$2"); shift 2 ;;
    --count) count=1; shift ;;
    --out) out=$2; shift 2 ;;
    *) die "unknown argument $1" ;;
  esac
done
command -v qemu-system-x86_64 >/dev/null || die "qemu-system-x86_64 is not installed"
command -v addr2line >/dev/null && command -v nm >/dev/null || die "addr2line and nm (binutils) are not installed"
[ $count = 1 ] && [ $kvm = 1 ] && die "--count is for instruction counts, not --kvm"
[ -n "$times" ] || { [ $kvm = 1 ] && times=300 || times=1; }
mkdir -p "$out"
export RUN=$out/run; mkdir -p "$RUN"
rm -f "$out/serial" "$out/counts"

if [ $kvm = 1 ]; then
  command -v perf >/dev/null || die "perf is not installed"
  [ -w /dev/kvm ] || die "KVM is not available"
  sudo -n true 2>/dev/null || die "--kvm needs passwordless sudo for perf (guest samples are privileged)"
  img=$(build_image x86_64 "$out/build.log" "bench=$mode:$times") || die "image build failed (log: $out/build.log)"
  elf=$(art_dir x86_64)/kernel.elf
  cpu=$(fastest_cpus 1)
  "$TOOLS/qemu.sh" --image "$img" --serial "$out/serial" --timeout 600 --smp 1 ${cpu:+--pin "$cpu"} >"$out/qemu.log" 2>&1 &
  q=$!
  # qemu.sh starts QEMU itself; find that process among its children.
  pid=""
  for _ in $(seq 100); do
    pid=$(pgrep -P "$q" -f qemu-system-x86_64 || pgrep -f "qemu-system-x86_64.*$(basename "$img")" | head -n 1)
    [ -n "$pid" ] && break
    sleep 0.05
  done
  [ -n "$pid" ] || { wait "$q"; die "QEMU did not start (log: $out/qemu.log)"; }
  sudo -n perf record -q -e cycles:G -c 10007 -p "$pid" -o "$out/perf.data" >/dev/null 2>&1
  wait "$q"
  # Samples taken in the guest kernel carry the guest's address; one line
  # per sample, weight 1.
  sudo -n perf script -f -i "$out/perf.data" -D 2>/dev/null |
    sed -n 's/.*PERF_RECORD_SAMPLE(IP, 0x[0-9a-f]*): [0-9/]*: 0x\(ffff[0-9a-f]\{12\}\) period.*/\1 1/p' >"$out/counts"
  sudo -n rm -f "$out/perf.data"
else
  command -v pkg-config >/dev/null && pkg-config --exists glib-2.0 && [ -f /usr/include/qemu-plugin.h ] || die "the QEMU plugin header or glib is missing"
  plugin=$out/libinsncount.so
  if [ ! -f "$plugin" ] || [ "$TOOLS/profile/insncount.c" -nt "$plugin" ]; then
    gcc -O2 -shared -fPIC -o "$plugin" "$TOOLS/profile/insncount.c" $(pkg-config --cflags --libs glib-2.0) || die "cannot build the plugin"
  fi
  code=""; for f in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/OVMF/OVMF_CODE.fd; do [ -f "$f" ] && { code=$f; break; }; done
  vars=""; for f in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/OVMF/OVMF_VARS.fd; do [ -f "$f" ] && { vars=$f; break; }; done
  [ -n "$code" ] && [ -n "$vars" ] || die "no x86_64 UEFI firmware (run tools/init.sh)"
  img=$(build_image x86_64 "$out/build.log" "bench=$mode:$times") || die "image build failed (log: $out/build.log)"
  elf=$(art_dir x86_64)/kernel.elf
  cp "$vars" "$out/vars.fd"
  timeout 1800 qemu-system-x86_64 -nodefaults -no-reboot -display none -machine q35 -cpu max \
    -accel tcg,one-insn-per-tb=on -icount shift=0,sleep=off -smp 2 -m 512 -serial "file:$out/serial" \
    -plugin "$plugin,out=$out/counts,cpu=0" \
    -drive "if=pflash,format=raw,readonly=on,file=$code" -drive "if=pflash,format=raw,file=$out/vars.fd" \
    -drive "format=raw,file=$img,if=virtio,snapshot=on" -device isa-debug-exit,iobase=0xf4,iosize=0x04 >"$out/qemu.log" 2>&1
fi

tr -d '\r' <"$out/serial" | grep -qx 'BENCH DONE' || die "the benchmark did not finish (serial: $out/serial)"
slide=$(tr -d '\r' <"$out/serial" | sed -n 's/.*kernel slide \(0x[0-9a-f]*\).*/\1/p' | head -n 1)
[ -n "$slide" ] || die "no kernel slide in the serial log"
[ -s "$out/counts" ] || die "nothing was counted (see $out/qemu.log)"
if [ $count = 1 ]; then
  awk '{ t += $2 } END { printf "COUNT %d\n", t }' "$out/counts"
  exit 0
fi
tr -d '\r' <"$out/serial" | grep -a '^BENCH ' | grep -v DONE | sort | uniq -c | sort -rn | head -n 5
# Symbolize: link-time address = runtime - slide. awk's numbers are doubles,
# exact only below 2^53, so the arithmetic is on the low 48 bits; every
# kernel address has the same upper 16 bits (ffff) and the slide is far
# smaller than 2^48.
awk -v s="$slide" 'BEGIN { s = strtonum(s) } { a = strtonum("0x" substr($1, length($1) - 11)) - s; printf "ffff%012x %s\n", a, $2 }' "$out/counts" >"$out/linked"
# Attribute each instruction to the function symbol that contains it (the
# outermost function, not an inlined helper), or with --lines to its source
# line (innermost, file:line).
if [ "$lines" = 1 ]; then
  cut -d' ' -f1 "$out/linked" | sed 's/^/0x/' | addr2line -C -e "$elf" | sed 's/ (discriminator.*//' >"$out/funcs"
else
  nm -n -C --defined-only "$elf" | awk '$2 ~ /^[tTwW]$/ { a = $1; $1 = ""; $2 = ""; sub(/^  /, ""); print a "\t" $0 }' >"$out/syms"
  cut -d' ' -f1 "$out/linked" | awk -F'\t' 'NR == FNR { a[n] = strtonum("0x" substr($1, 5)); f[n++] = $2; next }
    { x = strtonum("0x" substr($1, 5)); lo = 0; hi = n - 1; r = "??"
      while (lo <= hi) { m = int((lo + hi) / 2); if (a[m] <= x) { r = f[m]; lo = m + 1 } else hi = m - 1 }
      gsub(/ /, "_", r); print r }' "$out/syms" - >"$out/funcs"
fi
if [ $kvm = 1 ]; then
  paste -d' ' "$out/linked" "$out/funcs" | awk '{ c[$3] += $2; t += $2 } END { for (f in c) if (c[f] * 1000 >= t) printf "%.1f %s\n", 100 * c[f] / t, f; printf "TOTAL %d\n", t > "/dev/stderr" }' 2>"$out/total" |
    sort -rn | head -n "$top"
else
  paste -d' ' "$out/linked" "$out/funcs" | awk -v p="$per" '{ c[$3] += $2 } END { for (f in c) { t += c[f]; if (c[f] >= p) printf "%d %s\n", c[f] / p, f } ; printf "TOTAL %d\n", t / p > "/dev/stderr" }' 2>"$out/total" |
    sort -rn | head -n "$top"
fi
cat "$out/total"
