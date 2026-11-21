#!/usr/bin/env bash
# Test for tools/qemu.sh (component A04). Runs a private copy of
# the tool suite in a disposable fake workshop with a fake firmware tree and a
# fake `qemu-system-x86_64` first on PATH, so every outcome (success, guest
# failure, silent exit, hang, screendump) is exercised without a guest. A last
# group runs the real QEMU with a non-bootable disk when it is installed.
# One "ERROR:" line per failed check.
set -uo pipefail
SRC=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd -P)
BASE=${SILICA_RUN:-${TMPDIR:-/tmp}}; mkdir -p "$BASE"
FX=$(mktemp -d "$BASE/qemutest.XXXX") || exit 2
FX=$(cd "$FX" && pwd -P)
trap 'rm -rf "${FX:?}"' EXIT
fails=0
bad() { echo "ERROR: qemu-test: $1"; fails=$((fails + 1)); }

WS=$FX/ws; OS=$WS/os; BIN=$FX/bin; FW=$FX/fw
mkdir -p "$OS/tools" "$BIN"
echo x >"$WS/bootstrap.pins"
cp -r "$SRC/lib" "$SRC/qemu.sh" "$OS/tools/"
printf '# fake manifest\n' >"$OS/manifest.toml"
fw_files() { mkdir -p "$FW/usr/share/OVMF"; echo code >"$FW/usr/share/OVMF/OVMF_CODE_4M.fd"; echo vars >"$FW/usr/share/OVMF/OVMF_VARS_4M.fd"; }
fw_files
echo disk >"$FX/disk.img"

# The fake QEMU. FAKE_MODE: exit:<n> | silent | hang (after the firmware
# started the loader) | fwhang (in the firmware) | shot:<n> (serves one
# monitor "screendump <file>" command, then exits with <n>). It records its
# argument vector in $FAKE_ARGV and writes a line to the serial file.
cat >"$BIN/qemu-system-x86_64" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$FAKE_ARGV"
serial="" mon=""
while [ $# -gt 0 ]; do
  case "$1" in
    -serial) serial=${2#file:}; shift 2 ;;
    -monitor) mon=${2#unix:}; mon=${mon%%,*}; shift 2 ;;
    *) shift ;;
  esac
done
echo "hello from the fake guest" >>"$serial"
case "$FAKE_MODE" in
  exit:*) exit "${FAKE_MODE#exit:}" ;;
  silent) exit 0 ;;
  hang) echo "BdsDxe: starting Boot0001" >>"$serial"; echo $$ >"$FAKE_PID"; exec sleep 300 ;;
  fwhang) echo $$ >"$FAKE_PID"; exec sleep 300 ;;
  shot:*)
    line=$(socat -T10 "UNIX-LISTEN:$mon" - 2>/dev/null | head -1)
    f=${line#screendump }
    printf 'P6\n1 1\n255\n\0\0\0' >"${f%$'\r'}"
    exit "${FAKE_MODE#shot:}" ;;
esac
FAKE
chmod +x "$BIN/qemu-system-x86_64"

run() { # run <mode> <args...>: qemu.sh with the fake QEMU; output in $OUT, status in $RC, seconds in $SECS
  local mode=$1; shift
  local t0=$SECONDS
  OUT=$(cd "$FX" && env -i PATH="$BIN:${PATH:-/usr/bin:/bin}" HOME="$FX" TMPDIR="$FX" SILICA_WS="$WS" \
    SILICA_FW_ROOT="$FW" SILICA_FW_TIMEOUT="${SILICA_FW_TIMEOUT:-}" FAKE_MODE="$mode" FAKE_ARGV="$FX/argv" FAKE_PID="$FX/pid" \
    bash "$OS/tools/qemu.sh" "$@" 2>&1)
  RC=$?; SECS=$((SECONDS - t0))
}
nerr() { printf '%s\n' "$OUT" | grep -c '^ERROR:'; }
expect() { # expect <name> <rc> <ERROR lines>
  [ "$RC" = "$2" ] || bad "$1: exit status $RC, expected $2 (output: $(printf '%s' "$OUT" | head -c 500))"
  [ "$(nerr)" = "$3" ] || bad "$1: $(nerr) ERROR lines, expected $3 (output: $(printf '%s' "$OUT" | head -c 500))"
}

# ---- outcomes ---------------------------------------------------------------
S=$FX/serial.log
echo "stale" >"$S"
run exit:33 --image "$FX/disk.img" --serial "$S" --timeout 20
expect "success (debug-exit 0x10)" 0 0
grep -qx 'hello from the fake guest' "$S" || bad "serial output not in the serial file"
grep -qx stale "$S" && bad "the serial file was not truncated at start"
[ -z "$OUT" ] || bad "success printed output: $OUT"

run exit:3 --image "$FX/disk.img" --serial "$S" --timeout 20
expect "guest failure (debug-exit 0x1)" 1 1
case "$OUT" in *"$S"*) ;; *) bad "guest failure ERROR does not name the serial file" ;; esac
case "$OUT" in *"exit status 3"*|*"code 1"*|*"0x1"*) ;; *) bad "guest failure ERROR does not give the exit status" ;; esac

run exit:35 --image "$FX/disk.img" --serial "$S" --timeout 20
expect "guest failure (debug-exit 0x11)" 1 1

run silent --image "$FX/disk.img" --serial "$S" --timeout 20
expect "qemu exited without the debug-exit device" 1 1

run exit:2 --image "$FX/disk.img" --serial "$S" --timeout 20
expect "qemu itself failed" 1 1

run hang --image "$FX/disk.img" --serial "$S" --timeout 2
expect "timeout" 124 1
case "$OUT" in *timeout*) ;; *) bad "timeout ERROR does not say timeout" ;; esac
case "$OUT" in *"$S"*) ;; *) bad "timeout ERROR does not name the serial file" ;; esac
[ "$SECS" -ge 2 ] && [ "$SECS" -le 8 ] || bad "timeout took ${SECS}s for --timeout 2"
# The firmware has its own allowance, and its timeout says where it stopped.
SILICA_FW_TIMEOUT=2 run fwhang --image "$FX/disk.img" --serial "$S" --timeout 60
expect "firmware timeout" 124 1
case "$OUT" in *"timeout after 2s in the firmware"*) ;; *) bad "a firmware stall must be reported as one, after the firmware's allowance: $OUT" ;; esac
case "$OUT" in *"booting once more"*) ;; *) bad "a firmware stall must be tried once more before it fails: $OUT" ;; esac
[ "$SECS" -le 14 ] || bad "a firmware stall tried twice took ${SECS}s for an allowance of 2"
if [ -f "$FX/pid" ] && kill -0 "$(cat "$FX/pid")" 2>/dev/null; then
  bad "the guest is still running after the timeout"; kill -9 "$(cat "$FX/pid")" 2>/dev/null
fi
grep -qx 'hello from the fake guest' "$S" || bad "serial output lost on timeout"

# ---- default serial file, arguments handed to QEMU ----------------------------
run exit:33 --image "$FX/disk.img" --timeout 20
expect "default serial file" 0 0
a=$(cat "$FX/argv")
for w in "-display" "none" "-no-reboot" "isa-debug-exit,iobase=0xf4,iosize=0x04" "-nodefaults"; do
  printf '%s\n' "$a" | grep -qxF -- "$w" || bad "qemu argument missing: $w"
done
printf '%s\n' "$a" | grep -q '^file:.*' || bad "serial is not handed to qemu as a file"
printf '%s\n' "$a" | grep -qx 'none' || bad "no -vga none without a screendump"
printf '%s\n' "$a" | grep -qx 'std' && bad "-vga std without a screendump"
printf '%s\n' "$a" | grep -q "file=$FX/disk.img.*snapshot=on" || bad "the image is not attached read-only (snapshot=on)"
run exit:33 --image "$FX/disk.img" --smp 3 --mem 512 --timeout 20
a=$(cat "$FX/argv")
printf '%s\n' "$a" | grep -qx 3 || bad "--smp not passed"
printf '%s\n' "$a" | grep -qx 512 || bad "--mem not passed"

m=$(printf '%s\n' "$a" | grep '^unix:' | head -1); m=${m#unix:}; m=${m%%,*}
[ -n "$m" ] && [ "${#m}" -le 60 ] || bad "the monitor socket path '$m' is not short (unix socket paths are limited to about 100 bytes)"
# relative serial and image paths still work (the guest runs in its own directory)
(cd "$FX" && cp disk.img rel.img)
run exit:33 --image rel.img --serial rel-serial.log --timeout 20
expect "relative paths" 0 0
[ -s "$FX/rel-serial.log" ] || bad "a relative --serial path was not honoured"
printf '%s\n' "$(cat "$FX/argv")" | grep -q "file=$FX/rel.img" || bad "a relative --image path was not made absolute"

# ---- screendump ---------------------------------------------------------------
P=$FX/shot.ppm
run shot:33 --image "$FX/disk.img" --serial "$S" --timeout 20 --screendump "$P" --screendump-after 1
expect "screendump" 0 0
head -c 2 "$P" 2>/dev/null | grep -q P6 || bad "no screendump written"
printf '%s\n' "$(cat "$FX/argv")" | grep -qx 'std' || bad "-vga std missing with --screendump"

rm -f "$P"
run exit:33 --image "$FX/disk.img" --serial "$S" --timeout 20 --screendump "$P" --screendump-after 30
[ "$SECS" -le 10 ] || bad "qemu.sh waited ${SECS}s for a screendump after the guest had exited"
[ "$(nerr)" = 1 ] || bad "a requested screendump that was never taken gave $(nerr) ERROR lines, expected 1"
[ "$RC" != 0 ] || bad "a requested screendump that was never taken still exited 0"

# ---- usage and setup errors -----------------------------------------------------
run exit:33 --timeout 5
expect "no --image" 2 1
run exit:33 --image "$FX/nonexistent.img"
expect "missing image" 2 1
run exit:33 --image "$FX/disk.img" --bogus
expect "unknown argument" 2 1
run exit:33 --image "$FX/disk.img" --arch sparc
expect "unsupported architecture" 2 1
run exit:33 --image "$FX/disk.img" --timeout abc
expect "non-numeric timeout" 2 1
run exit:33 --image "$FX/disk.img" --timeout
expect "option without a value" 2 1
run exit:33 --image "$FX/disk.img" --smp 0
expect "--smp 0" 2 1
rm -f "$FW/usr/share/OVMF/OVMF_VARS_4M.fd"
run exit:33 --image "$FX/disk.img"
expect "no firmware variable store" 2 1
rm -f "$FW/usr/share/OVMF/OVMF_CODE_4M.fd"
run exit:33 --image "$FX/disk.img"
expect "no firmware" 2 1
fw_files

# ---- real QEMU, when installed: a disk that cannot boot ---------------------------
fw=""
for f in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2-ovmf/x64/OVMF_CODE.fd; do
  [ -f "$f" ] && fw=$f
done
if command -v qemu-system-x86_64 >/dev/null && command -v socat >/dev/null && [ -n "$fw" ]; then
  head -c 1048576 /dev/zero >"$FX/blank.img"
  P=$FX/real.ppm
  OUT=$(cd "$FX" && env -i PATH="${PATH:-/usr/bin:/bin}" HOME="$FX" TMPDIR="$FX" SILICA_WS="$WS" SILICA_FW_TIMEOUT=12 SILICA_FW_RETRIED=1 \
    bash "$OS/tools/qemu.sh" --image "$FX/blank.img" --serial "$FX/real.log" --timeout 12 \
    --screendump "$P" --screendump-after 4 2>&1); RC=$?
  expect "real qemu, non-bootable disk" 124 1
  [ -f "$FX/real.log" ] || bad "real qemu: no serial file"
  head -c 2 "$P" 2>/dev/null | grep -q P6 || bad "real qemu: no PPM screendump"
  pgrep -f "$FX/blank.img" >/dev/null && bad "real qemu still running after the timeout"
fi

exit $((fails > 0 ? 1 : 0))
