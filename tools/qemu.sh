#!/usr/bin/env bash
# Headless QEMU boot (component A04).
#   qemu.sh --image <disk.img> [--arch x86_64|aarch64] [--el2] [--serial <file>] [--timeout <s>]
#           [--screendump <file.ppm> [--screendump-after <s>]] [--smp <n>] [--mem <MiB>]
#           [--pin <host cpu list>] [--stamp <file>] [--no-iommu] [--device <qemu -device argument>]...
#           [--until <extended regex>] [--no-exit-device] [--nvme <disk image>]
# The x86_64 machine has an IOMMU (Intel VT-d) and its boot disk does its
# DMA through it, which is the machine Silica confines drivers on;
# --no-iommu boots the machine without one. --device adds a device.
# --nvme adds an NVMe controller (QEMU's model) whose one namespace is a
# snapshot of the given disk image.
# --no-exit-device leaves out the debug-exit device (x86_64): the guest
# must turn the machine off itself (ACPI), and exit status 0 then means the
# emulator stopped because the guest turned it off or reset it.
# --until ends the run, as a success, when a serial line matches: for a
# system that stays up (it does not turn the machine off when it is ready).
# --pin runs the emulator on the given host processors (taskset), for
# benchmarks. --stamp writes one line per serial line, "<host time in seconds
# with microseconds> <text>", after a first line "<time> QEMU START", so boot
# times are measured by the host.
# Serial goes to a file; a hard timeout kills the guest (counted from the
# firmware's hand-over to the loader; the firmware has its own allowance). The processors'
# registers at every reset go to qemu-reset.log beside it, so a guest that
# dies by triple fault says where. Exit status: 0 when
# the guest wrote the success code to the debug-exit device, 1 for any other
# exit code, 124 on timeout, 2 on a usage or setup error.
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"

orig_args=("$@")
arch=x86_64 el2="" image="" serial="" timeout=60 shot="" shot_after=5 smp=1 mem=256 pin="" stamp="" iommu=1 devices=() until="" exitdev=1 nvme=""
while [ $# -gt 0 ]; do
  case "$1" in
    --arch|--image|--serial|--timeout|--screendump|--screendump-after|--smp|--mem|--pin|--stamp|--device|--until|--nvme)
      [ $# -ge 2 ] || die "$1 needs a value" ;;
  esac
  case "$1" in
    --arch) arch=$2; shift 2 ;;
    --el2) el2=1; shift ;;
    --image) image=$2; shift 2 ;;
    --serial) serial=$2; shift 2 ;;
    --timeout) timeout=$2; shift 2 ;;
    --screendump) shot=$2; shift 2 ;;
    --screendump-after) shot_after=$2; shift 2 ;;
    --smp) smp=$2; shift 2 ;;
    --mem) mem=$2; shift 2 ;;
    --pin) pin=$2; shift 2 ;;
    --stamp) stamp=$2; shift 2 ;;
    --no-iommu) iommu=""; shift ;;
    --no-exit-device) exitdev=""; shift ;;
    --device) devices+=(-device "$2"); shift 2 ;;
    --until) until=$2; shift 2 ;;
    --nvme) nvme=$2; shift 2 ;;
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
for v in image serial shot stamp nvme; do # the guest runs in $RUN, so every other path must be absolute
  case "${!v}" in ''|/*) ;; *) printf -v "$v" '%s' "$PWD/${!v}" ;; esac
done
case "$arch" in
  x86_64)
    bin=qemu-system-x86_64
    # TCG needs -cpu max: the kernel requires x2APIC, the TSC-deadline timer and XSAVE.
    accel=(-machine q35 -cpu max); [ -w /dev/kvm ] && [ -z "${SILICA_NO_KVM:-}" ] && accel=(-machine q35,accel=kvm -cpu host)
    extra=(); [ -z "$exitdev" ] || extra=(-device isa-debug-exit,iobase=0xf4,iosize=0x04)
    # The boot disk is a virtio 1.0 device; with the IOMMU it is told to do
    # its DMA through it (without that, QEMU's virtio devices bypass it).
    disk=(-device "virtio-blk-pci,drive=boot,disable-legacy=on${iommu:+,iommu_platform=on}")
    [ -z "$iommu" ] || extra+=(-device intel-iommu,aw-bits=48)
    [ -z "$nvme" ] || extra+=(-drive "format=raw,file=$nvme,if=none,id=nvm,snapshot=on" -device nvme,serial=silica-nvme,drive=nvm) ;;
  aarch64)
    bin=qemu-system-aarch64
    # --el2: the firmware runs at EL2, as on most servers; the loader drops to EL1.
    accel=(-machine "virt,gic-version=3${el2:+,virtualization=on}" -cpu max)
    # Test images report their status through semihosting, from the kernel
    # (EL1) or the root task (EL0).
    extra=(-semihosting-config enable=on,target=native,userspace=on,chardev=con)
    disk=(-device virtio-blk-pci,drive=boot) ;;
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
# The serial port's output: on aarch64 a multiplexed character device that
# semihosting writes to as well, so a test program's semihosting console and
# the UART end up in one log, in order.
serial_dev=(-serial "$serial_arg")
if [ "$arch" = aarch64 ]; then
  case "$serial_arg" in
    file:*) backend="file,path=${serial_arg#file:}" ;;
    *) backend="stdio,signal=off" ;;
  esac
  # A second UART, connected to nothing: a device in memory space with an
  # interrupt line that a test drives from userspace (roottest irq); the
  # firmware describes it in the DSDT and the kernel keeps only the first.
  serial_dev=(-chardev "$backend,id=con,mux=on" -serial chardev:con -serial null)
fi
( cd "$RUN" && [ -z "$stamp" ] || exec >"$RUN/serial.fifo"
  cd "$RUN" && TMPDIR=$RUN exec "${run[@]+"${run[@]}"}" "$bin" -nodefaults -no-reboot -display none -d cpu_reset -D "$RUN/qemu-reset.log" "${accel[@]}" -smp "$smp" -m "$mem" \
  "${serial_dev[@]}" -monitor "unix:$mon,server,nowait" \
  -drive "if=pflash,format=raw,readonly=on,file=$code" -drive "if=pflash,format=raw,file=$RUN/vars.fd" \
  -drive "format=raw,file=$image,if=none,id=boot,snapshot=on" "${disk[@]}" "${vga[@]}" "${extra[@]}" "${devices[@]+"${devices[@]}"}" ) 2>"$RUN/qemu.out" &
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

# --timeout is Silica's budget: it starts when the firmware hands over to
# the loader. The firmware has its own allowance ($SILICA_FW_TIMEOUT, default
# 120 s): emulated UEFI start-up is slow and slower still on a busy host, and
# it is not what a test measures. The emulated aarch64 firmware sometimes
# hangs for good before it starts any boot option (spinning on an event, with
# several processors under TCG); such a boot is tried once more, and the
# output says so. Nothing of Silica had run.
waited=0 fw=0 fw_limit=${SILICA_FW_TIMEOUT:-120} started=0
while kill -0 "$pid" 2>/dev/null; do
  if [ $started = 0 ]; then
    if [ $((fw % 10)) = 0 ] && grep -aq "BdsDxe: starting\|Booting\|silica:\|ERROR: loader" "$serial" 2>/dev/null; then started=1
    elif [ "$fw" -lt $((fw_limit * 10)) ]; then fw=$((fw + 1)); sleep 0.1; continue
    else started=1; waited=$((timeout * 10)); fi
  fi
  if [ "$waited" -ge $((timeout * 10)) ]; then
    # The serial log often ends before a firmware or kernel stall. Keep
    # where the guest is before destroying the VM: eight samples of the boot
    # processor's PC an eighth of a second apart (a spin shows the same few
    # PCs, a stop one), then with the VM stopped every processor's registers,
    # the code around the PC and around its caller, and the interrupt
    # controller's state where QEMU can show it (x86_64).
    if [ -S "$RUN/$mon" ] && command -v socat >/dev/null; then
      (cd "$RUN" && {
        for _ in 1 2 3 4 5 6 7 8; do printf '%s\n' 'p/x $pc'; sleep 0.125; done
        printf '%s\n' 'stop' 'info registers -a' 'x/24i $pc-0x40' 'info pic'
        sleep 0.5
      } | timeout 5 socat -t2 - "UNIX-CONNECT:$mon") >"$serial.monitor" 2>/dev/null
      # The caller's code, from its return address (x30 on aarch64).
      lr=$(grep -m1 -o 'X30=[0-9a-f]*' "$serial.monitor" | cut -d= -f2)
      [ -n "$lr" ] && (cd "$RUN" && printf 'x/16i 0x%s-0x20\n' "$lr" |
        timeout 2 socat -t1 - "UNIX-CONNECT:$mon") >>"$serial.monitor" 2>/dev/null
      # The monitor echoes each command with line-editing escapes; keep the answers.
      sed -i '/\x1b\[K/d' "$serial.monitor"
    fi
    kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; stop_shot
    # Where the guest stopped: still in the firmware (it never started a
    # boot option), in the loader, or in the kernel or later.
    where="" after=$timeout
    if ! grep -aq "BdsDxe: starting\|Booting\|silica:\|ERROR: loader" "$serial" 2>/dev/null; then where=" in the firmware: it never started the loader"; after=$fw_limit
    elif ! grep -aq "^silica:" "$serial" 2>/dev/null; then where=" before the kernel's first line"; fi
    if [ "$after" = "$fw_limit" ] && [ -z "${SILICA_FW_RETRIED:-}" ]; then
      echo "qemu: $arch: the firmware stalled for ${fw_limit}s before starting the loader; booting once more"
      SILICA_FW_RETRIED=1 exec "$0" "${orig_args[@]}"
    fi
    echo "ERROR: qemu: $arch: timeout after ${after}s$where (serial: $serial)"
    exit 124
  fi
  if [ -n "$until" ] && tr -d '\r' <"$serial" 2>/dev/null | grep -aqE "$until"; then
    kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; stop_shot
    [ -z "$stamper" ] || wait "$stamper" 2>/dev/null
    exit 0
  fi
  sleep 0.1; waited=$((waited + 1))
done
wait "$pid"; rc=$?
[ -z "$stamper" ] || wait "$stamper" 2>/dev/null
stop_shot
# Without the exit device, the guest turned the machine off (or reset it,
# which -no-reboot also ends the emulator on).
if [ -z "$exitdev" ] && [ "$rc" = 0 ]; then exit 0; fi
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
