#!/usr/bin/env bash
# Headless QEMU boot (component A04).
#   qemu.sh --image <disk.img> [--arch x86_64|aarch64] [--el2] [--cpu <model>] [--serial <file>] [--timeout <s>] [--quiet <s>]
#           [--screendump <file.ppm> [--screendump-after <s>]] [--smp <n>] [--mem <MiB>]
#           [--pin <host cpu list>] [--stamp <file>] [--no-iommu] [--device <qemu -device argument>]...
#           [--until <extended regex>] [--no-exit-device] [--reboot] [--nvme <disk image>] [--disk <disk image>]
#           [--net user[:<host port>-<guest port>,...]|tap:<interface>] [--nic virtio|e1000e[,<prop>=<v>...]] [--hotplug <disk image>] [--emulator <host cpu list>] [--disk-props <k=v,...>]
#           [--nvme-disk <disk image>] [--nvme-props <k=v,...>] [--nvme-ns <k=v,...>]... [--drive <id>=<disk image>]...
#           [--on '<extended regex>=<monitor command>']... [--type '<extended regex>=<text>']...
#           [--console-port <file>] [--port-type '<extended regex>=<text>']...
#           [--trace <QEMU trace event>]... [--vars <file>]
# The x86_64 machine has an IOMMU (Intel VT-d) and its boot disk does its
# DMA through it, which is the machine Silica confines drivers on;
# --no-iommu boots the machine without one. --device adds a device, --object
# an object one may name (a backend: rng-random,id=zero,filename=/dev/zero).
# --maxcpus <n> has the firmware describe n processors, --smp of them present
# (the rest hot-plug slots, listed but not enabled).
# --cpu <model> boots an emulated processor of that model (TCG) instead of
# the host's or QEMU's most capable one: the CPUs the kernel must run on
# that this host is not (x86_64 without AVX; Armv8.0 cores without PAN).
# --nvme adds an NVMe controller (QEMU's model, id nvme0) whose namespace 1
# is a snapshot of the given disk image (--nvme-disk: the image itself,
# written for real, for the host to read afterwards); --nvme-props gives it properties
# (msix_qsize=1: one interrupt vector; logical_block_size=4096,
# physical_block_size=4096: 4 KiB blocks); --nvme-ns gives it another
# namespace (`nvme-ns` properties: drive=, nsid=, ms= ...), and with no
# --nvme its namespaces are only those. --drive <id>=<image> is a snapshot
# of the image for a device to use (--nvme-ns, --device, --on device_add).
# --net adds a virtio network device on QEMU's user-mode network (the guest is 10.0.2.15, the gateway 10.0.2.2,
# which answers ARP and ping), or on the host's tap interface (vhost-net); --nic e1000e makes it an Intel 82574.
# user:<host port>-<guest port>[,...] also forwards those TCP ports of the host's loopback to the guest
# (a test's client reaches a server in the guest). --capture <file> records the user network's packets there
# (pcap, each packet's first 96 bytes).
# --hotplug gives the machine an empty PCI Express root port with native
# hot-plug (id hp0; QEMU's ACPI hot-plug off) and a disk image ready to be
# hot-added there: `--on '<regex>=device_add virtio-blk-pci,bus=hp0,drive=hot,disable-legacy=on,iommu_platform=on'`.
# --disk adds a second virtio disk that
# is written for real (not a snapshot): the host reads it afterwards.
# --trace <event> records a QEMU trace event: its lines, as the emulator
# printed them, land in <serial>.trace once it has stopped (what a device
# was told to do, seen from the device's side).
# --reboot lets a reset start the machine again (a guest that resets after a
# panic boots once more), where normally a reset ends the emulator.
# --no-exit-device leaves out the debug-exit device (x86_64): the guest
# must turn the machine off itself (ACPI), and exit status 0 then means the
# emulator stopped because the guest turned it off or reset it.
# --console-port gives the machine a virtio console (port 0 of a
# virtio-serial device, behind the IOMMU): what the guest sends there is
# written to <file>. --port-type types <text> there (printf escapes: \r)
# once the serial line matches the regex: the firmware reads the port too,
# and would swallow what was typed before the system listens (x86_64).
# --on sends a command to QEMU's monitor (system_powerdown: the power
# button) the first time a serial line matches the expression. --type types
# the text on the keyboard the same way, a key at a time ('\n' is Enter;
# letters, digits, space and - . / : _ are understood).
# --until ends the run, as a success, when a serial line matches: for a
# system that stays up (it does not turn the machine off when it is ready).
# --pin runs the emulator on the given host processors (taskset), for
# benchmarks; with --emulator as well, as a tuned virtualization host does
# (libvirt's vcpupin and emulatorpin): virtual processor n on the nth
# processor of --pin alone, the disk's I/O thread alone on the first
# --emulator processor, the network's (vhost-net) on the second, and the
# emulator's other threads (the main loop, its workers) on the rest, so a
# guest that watches for work on a virtual processor never takes the host
# processor the emulator needs to finish that work. --disk-props adds
# properties to the boot disk's virtio device (x86_64), as a host tuned for
# a benchmark sets them. --stamp writes one line per serial line, "<host
# time in seconds with microseconds> <text>", after a first line "<time>
# QEMU START", so boot times are measured by the host.
# Serial goes to a file; a hard timeout kills the guest (counted from the
# firmware's hand-over to the loader; the firmware has its own allowance).
# --quiet <s> kills it sooner if its serial output stops growing for that
# long: a test whose time depends on the machine (emulated, on a slow host)
# says how far it got every few seconds, and then a hang is found as soon on
# a slow machine as on a fast one, while a slow run is not one. The processors'
# registers at every reset go to qemu-reset.log beside it, so a guest that
# dies by triple fault says where. Exit status: 0 when
# the guest wrote the success code to the debug-exit device, 1 for any other
# exit code, 124 on timeout, 2 on a usage or setup error.
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"
# The hostfwd options of --net user:<host port>-<guest port>,...: the host's
# loopback only, never every address of the host.
user_forwards() {
  local spec=${1#user} f out=""
  spec=${spec#:}
  [ -n "$spec" ] || return 0
  for f in ${spec//,/ }; do
    [[ "$f" =~ ^[0-9]+-[0-9]+$ ]] || die "--net user: a forward is <host port>-<guest port>, not $f"
    out+=",hostfwd=tcp:127.0.0.1:${f%-*}-:${f#*-}"
  done
  printf '%s' "$out"
}

orig_args=("$@")
nvme_props="" nvme_ns=() drives=() nvme_snapshot=on
traced=()
varsfile="" cport="" maxcpus="" cpu_model="" disk_props="" emulator="" hotplug="" net="" capture="" arch=x86_64 el2="" image="" serial="" timeout=60 quiet=0 nic=virtio shot="" shot_after=5 smp=1 mem=256 pin="" stamp="" iommu=1 devices=() until="" exitdev=1 noreboot=-no-reboot nvme="" disk2="" on=() typing=() port_typing=()
while [ $# -gt 0 ]; do
  case "$1" in
    --arch|--image|--serial|--timeout|--quiet|--nic|--screendump|--screendump-after|--smp|--mem|--pin|--stamp|--device|--object|--until|--nvme|--disk|--on|--type|--net|--capture|--hotplug|--emulator|--disk-props|--console-port|--port-type|--cpu|--maxcpus|--vars)
      [ $# -ge 2 ] || die "$1 needs a value" ;;
  esac
  case "$1" in
    --arch) arch=$2; shift 2 ;;
    --el2) el2=1; shift ;;
    --cpu) cpu_model=$2; shift 2 ;;
    --maxcpus) maxcpus=$2; shift 2 ;;
    --image) image=$2; shift 2 ;;
    --serial) serial=$2; shift 2 ;;
    --timeout) timeout=$2; shift 2 ;;
    --quiet) quiet=$2; shift 2 ;;
    --nic) nic=$2; shift 2 ;;
    --screendump) shot=$2; shift 2 ;;
    --screendump-after) shot_after=$2; shift 2 ;;
    --smp) smp=$2; shift 2 ;;
    --mem) mem=$2; shift 2 ;;
    --pin) pin=$2; shift 2 ;;
    --stamp) stamp=$2; shift 2 ;;
    --no-iommu) iommu=""; shift ;;
    --no-exit-device) exitdev=""; shift ;;
    --reboot) noreboot=""; shift ;;
    --device) devices+=(-device "$2"); shift 2 ;;
    --object) devices+=(-object "$2"); shift 2 ;;
    --until) until=$2; shift 2 ;;
    --nvme) nvme=$2; shift 2 ;;
    --net) net=$2; shift 2 ;;
    --capture) capture=$2; shift 2 ;;
    --hotplug) hotplug=$2; shift 2 ;;
    --console-port) cport=$2; shift 2 ;;
    --vars) varsfile=$2; shift 2 ;;
    --port-type) port_typing+=("$2"); shift 2 ;;
    --emulator) emulator=$2; shift 2 ;;
    --disk-props) disk_props=$2; shift 2 ;;
    --disk) disk2=$2; shift 2 ;;
    --nvme-disk) [ $# -ge 2 ] || die "$1 needs a value"; nvme=$2 nvme_snapshot=off; shift 2 ;;
    --nvme-props) [ $# -ge 2 ] || die "$1 needs a value"; nvme_props=$2; shift 2 ;;
    --nvme-ns) [ $# -ge 2 ] || die "$1 needs a value"; nvme_ns+=("$2"); shift 2 ;;
    --drive) [ $# -ge 2 ] && [[ $2 == ?*=?* ]] || die "--drive needs <id>=<disk image>"; drives+=("$2"); shift 2 ;;
    --on) on+=("$2"); shift 2 ;;
    --trace) traced+=("$2"); shift 2 ;;
    --type) typing+=("$2"); shift 2 ;;
    *) die "unknown argument $1" ;;
  esac
done
[ -n "$image" ] || die "--image is required"
[ -f "$image" ] || die "image $image not found"
for n in "$timeout" "$quiet" "$shot_after" "$smp" "$mem"; do
  case "$n" in ''|*[!0-9]*) die "not a number: $n" ;; esac
done
[ "$timeout" -ge 1 ] && [ "$smp" -ge 1 ] && [ "$mem" -ge 1 ] || die "--timeout, --smp and --mem must be at least 1"
new_run
[ -n "$serial" ] || serial=$RUN/serial.log
# SILICA_STAMP=1: every run times its serial lines (<serial>.stamps), so a
# test's slow step can be found without changing the test.
[ -n "$stamp" ] || [ -z "${SILICA_STAMP:-}" ] || stamp=$serial.stamps

code=$(firmware_of "$arch" code) || die "no UEFI firmware for $arch (run tools/init.sh)"
vars=$(firmware_of "$arch" vars) || die "no UEFI variable store for $arch"
# --vars <file>: the machine's UEFI variable store is <file>, kept across
# runs (made from the firmware's empty one the first time): a machine that
# boots again, as the loader's machine secret needs.
if [ -n "$varsfile" ]; then
  [ -f "$varsfile" ] || cp "$vars" "$varsfile" || die "cannot make the variable store $varsfile"
  ln -sf "$(realpath "$varsfile")" "$RUN/vars.fd"
else
  cp "$vars" "$RUN/vars.fd"
fi
# The monitor socket is addressed relative to $RUN (QEMU and socat run there):
# a unix socket path is limited to about 100 bytes and deep run directories exceed it.
mon=monitor.sock
for v in image serial shot stamp nvme disk2 hotplug; do # the guest runs in $RUN, so every other path must be absolute
  case "${!v}" in ''|/*) ;; *) printf -v "$v" '%s' "$PWD/${!v}" ;; esac
done
for k in "${!drives[@]}"; do
  d=${drives[$k]#*=}; [ -f "$d" ] || die "--drive: image $d not found"
  case "$d" in /*) ;; *) drives[$k]="${drives[$k]%%=*}=$PWD/$d" ;; esac
done
# --nic <model>,<property>=<value>...: the model, with properties of its own
# (a test's MAC address).
nicprops=""; case "$nic" in *,*) nicprops=,${nic#*,}; nic=${nic%%,*} ;; esac
case "$nic" in
  virtio) nicdev=virtio-net-pci,netdev=net0,disable-legacy=on,iommu_platform=on ;;
  e1000e) nicdev=e1000e,netdev=net0 ;;
  *) die "--nic: virtio or e1000e, not $nic" ;;
esac
nicdev=$nicdev$nicprops
case "$arch" in
  x86_64)
    bin=qemu-system-x86_64
    # TCG needs -cpu max: the kernel requires x2APIC, the TSC-deadline timer and XSAVE.
    accel=(-machine q35 -cpu max); [ -w /dev/kvm ] && [ -z "${SILICA_NO_KVM:-}" ] && accel=(-machine q35,accel=kvm -cpu host)
    # --cpu: an emulated processor of that model (TCG), to boot on what
    # the host is not: one without AVX, without NX, without PCID.
    [ -z "$cpu_model" ] || accel=(-machine q35 -cpu "$cpu_model")
    extra=(); [ -z "$exitdev" ] || extra=(-device isa-debug-exit,iobase=0xf4,iosize=0x04)
    # The boot disk is a virtio 1.0 device; with the IOMMU it is told to do
    # its DMA through it (without that, QEMU's virtio devices bypass it).
    # The disk's requests are served by an I/O thread of its own (QEMU's
    # main loop serves it otherwise, between everything else it does), as
    # on a host tuned for its guests' disks, which also reads and writes the
    # host's file through io_uring (below; QEMU's default is a pool of
    # threads, a hand-off more per request).
    disk=(-object iothread,id=io0 -device "virtio-blk-pci,drive=boot,iothread=io0,disable-legacy=on${iommu:+,iommu_platform=on}${disk_props:+,$disk_props}")
    # Under TCG the disk is served by the main loop: QEMU's IOMMU raises its
    # fault interrupt from the thread that made the refused access, and an
    # emulated processor's interrupt from an I/O thread trips QEMU's own
    # assertion (system/cpus.c, cpu_interrupt: bql_locked()).
    [ "${accel[1]}" = q35 ] && disk=(-device "virtio-blk-pci,drive=boot,disable-legacy=on${iommu:+,iommu_platform=on}${disk_props:+,$disk_props}")
    # Interrupts are remapped too (a device raises only what its driver
    # bound); under KVM that needs the I/O APIC in QEMU (a split irqchip).
    if [ -n "$iommu" ]; then
      extra+=(-device intel-iommu,aw-bits=48,intremap=on,eim=on)
      [ "${accel[1]}" = q35,accel=kvm ] && accel[1]=q35,accel=kvm,kernel-irqchip=split
    fi
    [ -z "$cport" ] || extra+=(-chardev "pipe,id=cport,path=$RUN/cport"
      -device "virtio-serial-pci,disable-legacy=on${iommu:+,iommu_platform=on}" -device virtconsole,chardev=cport,nr=0)
    [ -z "$disk2" ] || extra+=(-drive "format=raw,file=$disk2,if=none,id=disk2" -device "virtio-blk-pci,drive=disk2,disable-legacy=on${iommu:+,iommu_platform=on}")
    [ -z "$hotplug" ] || extra+=(-global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off -device pcie-root-port,id=hp0,chassis=1,slot=1,mem-reserve=8M,pref64-reserve=64M
      -drive "format=raw,file=$hotplug,if=none,id=hot")
    case "$net" in
      "") ;;
      # The network device does its DMA through the platform's translation
      # (iommu_platform), as every real PCI device does, on both machines:
      # Linux's AF_XDP zero-copy, its fastest raw path, needs it.
      # (--nic e1000e: an Intel 82574 instead, its DMA through the IOMMU as
      # any PCI device's.)
      user|user:*) extra+=(-netdev "user,id=net0$(user_forwards "$net")" -device "$nicdev")
        # Each packet's first 96 bytes (Ethernet, IP and TCP headers): enough
        # to follow every connection, small enough to keep.
        [ -z "$capture" ] || extra+=(-object "filter-dump,id=capture,netdev=net0,file=$capture,maxlen=96") ;;
      tap:*) extra+=(-netdev "tap,id=net0,ifname=${net#tap:},script=no,downscript=no,vhost=on" -device "$nicdev") ;;
      *) die "--net: user[:<host port>-<guest port>,...] or tap:<interface>, not $net" ;;
    esac ;;
  aarch64)
    bin=qemu-system-aarch64
    # --el2: the firmware runs at EL2, as on most servers; the loader drops to EL1.
    accel=(-machine "virt,gic-version=3${el2:+,virtualization=on}" -cpu max)
    [ -z "$cpu_model" ] || accel=(-machine "virt,gic-version=3${el2:+,virtualization=on}" -cpu "$cpu_model")
    # Test images report their status through semihosting, from the kernel
    # (EL1) or the root task (EL0).
    extra=(-semihosting-config enable=on,target=native,userspace=on,chardev=con)
    disk=(-device virtio-blk-pci,drive=boot) ;;
  *) die "unsupported architecture $arch" ;;
esac
command -v "$bin" >/dev/null || die "$bin is not installed (run tools/init.sh)"
for d in "${drives[@]+"${drives[@]}"}"; do extra+=(-drive "format=raw,file=${d#*=},if=none,id=${d%%=*},snapshot=on"); done
# The NVMe controller: the same on every architecture.
[ -z "$nvme" ] || extra+=(-drive "format=raw,file=$nvme,if=none,id=nvm,snapshot=$nvme_snapshot")
[ -z "$nvme" ] && [ ${#nvme_ns[@]} = 0 ] || extra+=(-device "nvme,id=nvme0,serial=silica-nvme${nvme:+,drive=nvm}${nvme_props:+,$nvme_props}")
for ns in "${nvme_ns[@]+"${nvme_ns[@]}"}"; do extra+=(-device "nvme-ns,bus=nvme0,$ns"); done

vga=(-vga none); [ -n "$shot" ] && vga=(-vga std)
: >"$serial"
run=(); [ -n "$pin" ] && command -v taskset >/dev/null && run=(taskset -c "$pin${emulator:+,$emulator}")
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
# Why the emulator stops, in the same log: each shutdown request with its
# cause, each change of run state, and a watchdog acting.
# The console port: two pipes QEMU holds open (what is typed in, what the
# guest sends out), the second copied to the caller's file as it comes.
cport_copy=""
if [ -n "$cport" ]; then
  mkfifo "$RUN/cport.in" "$RUN/cport.out" || die "cannot make the console port's pipes"
  : >"$cport"
  { cat <"$RUN/cport.out" >>"$cport"; } &
  cport_copy=$!
fi
why_stopped=(-trace enable=qemu_system_shutdown_request -trace enable=runstate_set -trace enable=watchdog_perform_action -trace enable=tco_timer_expired)
for t in "${traced[@]+"${traced[@]}"}"; do why_stopped+=(-trace "enable=$t"); done
# The guest dies with this script, however it ends: the timeout below is
# this script's to enforce, and a harness killed mid-run (an interrupted
# test, a lost terminal) once left a guest running for nine hours, taking
# host processors from every measurement made after it. The kernel kills
# the emulator when its parent (this script) exits, by any signal.
command -v setpriv >/dev/null || die "setpriv (util-linux) is needed: the guest must die with its harness"
( cd "$RUN" && [ -z "$stamp" ] || exec >"$RUN/serial.fifo"
  cd "$RUN" && TMPDIR=$RUN exec setpriv --pdeathsig KILL "${run[@]+"${run[@]}"}" "$bin" -nodefaults ${noreboot} -display none -d cpu_reset -D "$RUN/qemu-reset.log" "${why_stopped[@]}" "${accel[@]}" -smp "$smp${maxcpus:+,maxcpus=$maxcpus}" -m "$mem" \
  "${serial_dev[@]}" -monitor "unix:$mon,server,nowait" \
  -drive "if=pflash,format=raw,readonly=on,file=$code" -drive "if=pflash,format=raw,file=$RUN/vars.fd" \
  -drive "format=raw,file=$image,if=none,id=boot,snapshot=on,aio=io_uring" "${disk[@]}" "${vga[@]}" "${extra[@]}" "${devices[@]+"${devices[@]}"}" ) 2>"$RUN/qemu.out" &
pid=$!

# Each virtual processor on its own host processor; of --emulator, the
# first takes the disk's I/O thread, the second the network's (vhost-net's
# worker, made when the guest starts its driver), the rest everything else
# of the emulator's. Threads are placed as they appear, for as long as the
# emulator runs.
if [ -n "$pin" ] && [ -n "$emulator" ]; then
  (
    read -ra cpus <<<"$(echo "$pin" | tr , ' ')"
    read -ra emu <<<"$(echo "$emulator" | tr , ' ')"
    io=${emu[0]} net=${emu[1]:-${emu[0]}} others=$(IFS=,; echo "${emu[*]:2}")
    others=${others:-$emulator}
    # This watch itself stays off the processors being measured.
    taskset -p -c "$others" "$BASHPID" >/dev/null 2>&1
    placed=" " n=0
    while kill -0 "$pid" 2>/dev/null; do
      for c in /proc/$pid/task/*/comm; do
        tid=$(basename "$(dirname "$c")")
        case "$placed" in *" $tid "*) continue ;; esac
        name=$(cat "$c" 2>/dev/null) || continue
        case "$name" in
          "CPU "*/KVM) v=${name#CPU }; v=${v%/KVM}; to=${cpus[$((v % ${#cpus[@]}))]} ;;
          "IO "*) to=$io ;;
          vhost-*) to=$net ;;
          *) to=$others ;;
        esac
        taskset -p -c "$to" "$tid" >/dev/null 2>&1 && placed+="$tid "
      done
      n=$((n + 1)); sleep "$([ $n -lt 100 ] && echo 0.02 || echo 0.2)"
    done
  ) </dev/null >/dev/null 2>&1 &
fi

shotpid=""
if [ -n "$shot" ]; then
  : >"$shot"   # empty until the monitor writes it
  ( cd "$RUN" && sleep "$shot_after"
    printf 'screendump %s\n' "$shot" | socat -T5 - "UNIX-CONNECT:$mon" >/dev/null 2>&1 ) >/dev/null 2>&1 &
  shotpid=$!
fi
stop_shot() { # a screendump still pending, or the console port's copy, must not outlive the run
  [ -z "$cport_copy" ] || { sleep 0.2; kill "$cport_copy" 2>/dev/null; wait "$cport_copy" 2>/dev/null; cport_copy=""; }
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
waited=0 fw=0 fw_limit=${SILICA_FW_TIMEOUT:-120} started=0 last_size=-1 still=0 silent=""
while kill -0 "$pid" 2>/dev/null; do
  if [ $started = 0 ]; then
    if [ $((fw % 10)) = 0 ] && grep -aq "BdsDxe: starting\|Booting\|silica:\|ERROR: loader" "$serial" 2>/dev/null; then started=1
    elif [ "$fw" -lt $((fw_limit * 10)) ]; then fw=$((fw + 1)); sleep 0.1; continue
    else started=1; waited=$((timeout * 10)); fi
  fi
  # --quiet: the seconds the serial log has not grown, counted once a second.
  if [ "$quiet" -gt 0 ] && [ $((waited % 10)) = 0 ]; then
    size=$(stat -c %s "$serial" 2>/dev/null || echo 0)
    if [ "$size" != "$last_size" ]; then last_size=$size still=0; else still=$((still + 1)); fi
    [ "$still" -lt "$quiet" ] || silent=1
  fi
  if [ "$waited" -ge $((timeout * 10)) ] || [ -n "$silent" ]; then
    # The serial log often ends before a firmware or kernel stall. Keep
    # where the guest is before destroying the VM: eight samples of the boot
    # processor's PC an eighth of a second apart (a spin shows the same few
    # PCs, a stop one), then with the VM stopped every processor's registers,
    # the code around the PC and around its caller, and the interrupt
    # controller's state where QEMU can show it (x86_64).
    # First the emulator's own threads, before the monitor disturbs them:
    # a monitor that does not answer means QEMU itself is stuck (its main
    # loop, or a processor's thread outside the guest), and this says where.
    # Each thread's name, state and kernel wait channel need no ptrace (a
    # host with Yama's ptrace scope above 0 refuses the stacks).
    { for t in /proc/$pid/task/*; do
        printf '%s %s %s %s\n' "${t##*/}" "$(tr ' ' _ <"$t/comm" 2>/dev/null)" \
          "$(awk '{print $3}' "$t/stat" 2>/dev/null)" "$(cat "$t/wchan" 2>/dev/null)"
      done
      command -v eu-stack >/dev/null && timeout 20 eu-stack -p "$pid" 2>&1; } >"$serial.stacks"
    if [ -S "$RUN/$mon" ] && command -v socat >/dev/null; then
      # (QEMU's monitor knows $pc on x86_64 only: on aarch64 the samples are
      # the same processor's registers, its PC among them.)
      sample='p/x $pc'; [ "$arch" = aarch64 ] && sample='info registers'
      (cd "$RUN" && {
        for _ in 1 2 3 4 5 6 7 8; do printf '%s\n' "$sample"; sleep 0.125; done
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
    if [ -n "$silent" ]; then echo "ERROR: qemu: $arch: no output for ${quiet}s$where (serial: $serial)"
    else echo "ERROR: qemu: $arch: timeout after ${after}s$where (serial: $serial)"; fi
    exit 124
  fi
  for k in "${!on[@]}"; do
    rule=${on[$k]}
    if serial_has "$serial" -E "${rule%%=*}"; then
      # What the monitor answered, beside the serial log: a refused
      # command is otherwise seen only as what did not happen.
      { printf '>>> %s\n' "${rule#*=}"; (cd "$RUN" && printf '%s\n' "${rule#*=}" | timeout 5 socat -t1 - "UNIX-CONNECT:$mon"); } >>"$serial.on" 2>&1
      unset "on[$k]"
    fi
  done
  for k in "${!port_typing[@]}"; do
    rule=${port_typing[$k]}
    if serial_has "$serial" -E "${rule%%=*}"; then
      unset "port_typing[$k]"
      printf '%b' "${rule#*=}" >"$RUN/cport.in"
    fi
  done
  for k in "${!typing[@]}"; do
    rule=${typing[$k]}
    if serial_has "$serial" -E "${rule%%=*}"; then
      unset "typing[$k]"
      text=${rule#*=} enter=""
      [ "${text: -2}" = '\n' ] && { text=${text%\\n}; enter=1; }
      # One monitor connection per command, a key every 15 ms held for 10:
      # QEMU's input queue sends each key's press and release in order (it
      # drops input past 100 queued events, which a key every 15 ms never
      # nears), and the keyboard driver keeps 64 event buffers (16 keys)
      # offered. A connection and a 60 ms pause per key took 12 of the
      # console check's 16 s (2026-11-24).
      # (From the run's directory: a socket's path is at most 108 bytes.)
      ( cd "$RUN" && {
          for ((c = 0; c < ${#text}; c++)); do
            ch=${text:c:1}
            case "$ch" in
              [a-z0-9]) key=$ch ;; [A-Z]) key=shift-${ch,,} ;; ' ') key=spc ;; '-') key=minus ;; '.') key=dot ;;
              '/') key=slash ;; ':') key=shift-semicolon ;; '_') key=shift-minus ;; '@') key=shift-2 ;; *) continue ;;
            esac
            printf 'sendkey %s 10\n' "$key"; sleep 0.015
          done
          [ -z "$enter" ] || printf 'sendkey ret 10\n'
          sleep 0.1
        } | timeout 30 socat -t1 - "UNIX-CONNECT:$mon" >/dev/null 2>&1 ) &
    fi
  done
  if [ -n "$until" ] && serial_has "$serial" -E "$until"; then
    kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; stop_shot
    [ -z "$stamper" ] || wait "$stamper" 2>/dev/null
    exit 0
  fi
  sleep 0.1; waited=$((waited + 1))
done
wait "$pid"; rc=$?
for t in "${traced[@]+"${traced[@]}"}"; do grep -a "^$t" "$RUN/qemu-reset.log" 2>/dev/null; done >"$serial.trace"
stop_shot
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
    # The emulator's own last words, whole, beside the serial log: its
    # first lines are often warnings and the reason it died comes last.
    local_stderr=""
    [ -s "$RUN/qemu.out" ] && cp "$RUN/qemu.out" "$serial.stderr" && local_stderr=" (stderr: $serial.stderr)"
    # What asked it to stop (cause 6 is the guest's power-off, 4 a signal),
    # and a watchdog's doing.
    stopped=$( { grep -ahE '^(qemu_system_shutdown_request|watchdog_perform_action|tco_timer_expired)' "$RUN/qemu-reset.log" | head -3
      grep -ah '^runstate_set' "$RUN/qemu-reset.log" | tail -1; } 2>/dev/null | tr '\n' ' ')
    # A reset under -no-reboot is not a shutdown request: QEMU sets the
    # shutdown itself, traces nothing for it and resets no processor (so
    # the reset log has no registers). Stopped with nothing asked and no
    # signal, the guest reset itself: a triple fault, or a reset port.
    if [[ "$stopped" == *"new_state 11 (shutdown)"* && "$stopped" != *qemu_system_shutdown_request* ]] &&
      ! grep -aq 'terminating on signal' "$RUN/qemu.out" 2>/dev/null; then
      stopped+="(nothing asked it to stop and no signal came: the guest reset itself, a triple fault or a reset port) "
    fi
    why="qemu exited with status $rc, not through the debug-exit device: $(tail -c 200 "$RUN/qemu.out" | tr '\n' ' ')${stopped:+[$stopped] }${at:+(the machine reset; processors at $at; registers: $RUN/qemu-reset.log)}$local_stderr"
  fi
  echo "ERROR: qemu: $arch: $why (serial: $serial)"
  exit 1
fi
if [ -n "$shot" ] && [ ! -s "$shot" ]; then
  echo "ERROR: qemu: $arch: screendump $shot was not taken (guest exited before ${shot_after}s or the monitor failed)"
  exit 1
fi
exit 0
