#!/usr/bin/env bash
# Headless QEMU boot (component A04).
#   qemu.sh --image <disk.img> [--arch x86_64] [--serial <file>] [--timeout <s>]
#           [--screendump <file.ppm> [--screendump-after <s>]] [--smp <n>] [--mem <MiB>]
#           [--pin <host cpu list>] [--stamp <file>]
# --pin runs the emulator on the given host processors (taskset), for
# benchmarks. --stamp writes one line per serial line, "<host time in seconds
# with microseconds> <text>", after a first line "<time> QEMU START", so boot
# times are measured by the host.
# Serial goes to a file; a hard timeout kills the guest. The processors'
# registers at every reset go to qemu-reset.log beside it, so a guest that
# dies by triple fault says where. Exit status: 0 when
# the guest wrote the success code to the debug-exit device, 1 for any other
# exit code, 124 on timeout, 2 on a usage or setup error.
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"

arch=x86_64 image="" serial="" timeout=60 shot="" shot_after=5 smp=1 mem=256 pin="" stamp=""
while [ $# -gt 0 ]; do
  case "$1" in
    --arch|--image|--serial|--timeout|--screendump|--screendump-after|--smp|--mem|--pin|--stamp)
      [ $# -ge 2 ] || die "$1 needs a value" ;;
  esac
  case "$1" in
    --arch) arch=$2; shift 2 ;;
    --image) image=$2; shift 2 ;;
    --serial) serial=$2; shift 2 ;;
    --timeout) timeout=$2; shift 2 ;;
    --screendump) shot=$2; shift 2 ;;
    --screendump-after) shot_after=$2; shift 2 ;;
    --smp) smp=$2; shift 2 ;;
    --mem) mem=$2; shift 2 ;;
    --pin) pin=$2; shift 2 ;;
    --stamp) stamp=$2; shift 2 ;;
    *) die "unknown argument $1" ;;
  esac
done
[ -n "$image" ] || die "--image is required"
[ -f "$image" ] || die "image $image not found"
for n in "$timeout" "$shot_after" "$smp" "$mem"; do
  case "$n" in ''|*[!0-9]*) die "not a number: $n" ;; esac
done
[ "$timeout" -ge 1 ] && [ "$smp" -ge 1 ] && [ "$mem" -ge 1 ] || die "--timeout, --smp and --mem must be at least 1"
new_run
[ -n "$serial" ] || serial=$RUN/serial.log

FW=${SILICA_FW_ROOT:-}   # prefix for firmware paths; the test points it at a fake tree
firmware() { # firmware() <code|vars> for the architecture
  local f
  case "$arch:$1" in
    x86_64:code) for f in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2-ovmf/x64/OVMF_CODE.fd; do [ -f "$FW$f" ] && { echo "$FW$f"; return; }; done ;;
    x86_64:vars) for f in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/edk2-ovmf/x64/OVMF_VARS.fd; do [ -f "$FW$f" ] && { echo "$FW$f"; return; }; done ;;
    aarch64:code) for f in /usr/share/AAVMF/AAVMF_CODE.fd /usr/share/edk2/aarch64/QEMU_EFI-pflash.raw /usr/share/qemu-efi-aarch64/QEMU_EFI.fd; do [ -f "$FW$f" ] && { echo "$FW$f"; return; }; done ;;
    aarch64:vars) for f in /usr/share/AAVMF/AAVMF_VARS.fd /usr/share/edk2/aarch64/vars-template-pflash.raw; do [ -f "$FW$f" ] && { echo "$FW$f"; return; }; done ;;
  esac
  return 1
}

code=$(firmware code) || die "no UEFI firmware for $arch (run tools/init.sh)"
vars=$(firmware vars) || die "no UEFI variable store for $arch"
cp "$vars" "$RUN/vars.fd"
# The monitor socket is addressed relative to $RUN (QEMU and socat run there):
# a unix socket path is limited to about 100 bytes and deep run directories exceed it.
mon=monitor.sock
for v in image serial shot stamp; do # the guest runs in $RUN, so every other path must be absolute
  case "${!v}" in ''|/*) ;; *) printf -v "$v" '%s' "$PWD/${!v}" ;; esac
done
case "$arch" in
  x86_64)
    bin=qemu-system-x86_64
    # TCG needs -cpu max: the kernel requires x2APIC, the TSC-deadline timer and XSAVE.
    accel=(-machine q35 -cpu max); [ -w /dev/kvm ] && [ -z "${SILICA_NO_KVM:-}" ] && accel=(-machine q35,accel=kvm -cpu host)
    extra=(-device isa-debug-exit,iobase=0xf4,iosize=0x04) ;;
  aarch64)
    bin=qemu-system-aarch64
    accel=(-machine virt -cpu max)
    extra=(-semihosting-config enable=on,target=native) ;;
  *) die "unsupported architecture $arch" ;;
esac
command -v "$bin" >/dev/null || die "$bin is not installed (run tools/init.sh)"

vga=(-vga none); [ -n "$shot" ] && vga=(-vga std)
: >"$serial"
run=(); [ -n "$pin" ] && command -v taskset >/dev/null && run=(taskset -c "$pin")
serial_arg="file:$serial" stamper=""
if [ -n "$stamp" ]; then
  # The serial port goes through a pipe to a reader that notes when each line arrived.
  mkfifo "$RUN/serial.fifo" || die "cannot create a fifo in $RUN"
  ( while IFS= read -r line || [ -n "$line" ]; do
      printf '%s %s\n' "$EPOCHREALTIME" "$line" >>"$stamp"; printf '%s\n' "$line" >>"$serial"
    done <"$RUN/serial.fifo" ) &
  stamper=$!
  serial_arg=stdio
  printf '%s QEMU START\n' "$EPOCHREALTIME" >"$stamp"
fi
( cd "$RUN" && [ -z "$stamp" ] || exec >"$RUN/serial.fifo"
  cd "$RUN" && TMPDIR=$RUN exec "${run[@]+"${run[@]}"}" "$bin" -nodefaults -no-reboot -display none -d cpu_reset -D "$RUN/qemu-reset.log" "${accel[@]}" -smp "$smp" -m "$mem" \
  -serial "$serial_arg" -monitor "unix:$mon,server,nowait" \
  -drive "if=pflash,format=raw,readonly=on,file=$code" -drive "if=pflash,format=raw,file=$RUN/vars.fd" \
  -drive "format=raw,file=$image,if=virtio,snapshot=on" "${vga[@]}" "${extra[@]}" ) 2>"$RUN/qemu.out" &
pid=$!

shotpid=""
if [ -n "$shot" ]; then
  : >"$shot"   # empty until the monitor writes it
  ( cd "$RUN" && sleep "$shot_after"
    printf 'screendump %s\n' "$shot" | socat -T5 - "UNIX-CONNECT:$mon" >/dev/null 2>&1 ) >/dev/null 2>&1 &
  shotpid=$!
fi
stop_shot() { # a screendump still pending must not outlive the run
  [ -n "$shotpid" ] || return 0
  pkill -P "$shotpid" 2>/dev/null; kill "$shotpid" 2>/dev/null; wait "$shotpid" 2>/dev/null; return 0
}

waited=0
while kill -0 "$pid" 2>/dev/null; do
  if [ "$waited" -ge $((timeout * 10)) ]; then
    kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; stop_shot
    echo "ERROR: qemu: $arch: timeout after ${timeout}s (serial: $serial)"
    exit 124
  fi
  sleep 0.1; waited=$((waited + 1))
done
wait "$pid"; rc=$?
[ -z "$stamper" ] || wait "$stamper" 2>/dev/null
stop_shot
# isa-debug-exit returns (value << 1) | 1; the success value is 0x10.
if [ "$rc" != 33 ]; then
  if [ "$rc" != 1 ] && [ $((rc & 1)) = 1 ]; then why="guest exit code $((rc >> 1)) via debug-exit (exit status $rc)"
  else
    # A guest that reset itself (a triple fault): where each processor was
    # is the last register dump of the reset log.
    at=$(grep -a '^RIP=' "$RUN/qemu-reset.log" 2>/dev/null | tail -n "$smp" | awk '{ print $1 }' | sort | uniq -c | awk '{ printf "%s x%s ", $2, $1 }')
    why="qemu exited with status $rc, not through the debug-exit device: $(head -c 200 "$RUN/qemu.out" | tr '\n' ' ')${at:+(the machine reset; processors at $at; registers: $RUN/qemu-reset.log)}"
  fi
  echo "ERROR: qemu: $arch: $why (serial: $serial)"
  exit 1
fi
if [ -n "$shot" ] && [ ! -s "$shot" ]; then
  echo "ERROR: qemu: $arch: screendump $shot was not taken (guest exited before ${shot_after}s or the monitor failed)"
  exit 1
fi
exit 0
