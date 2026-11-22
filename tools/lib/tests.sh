# Test ids:
#   <crate dir>/<target source>::<test path>   a Rust test, for example
#       kernel-core/tests/stub.rs::banner_is_boot_ok   (integration test file)
#       kernel-core/src/lib.rs::cap::tests::derive     (unit test in the lib)
#   inos/<arch>::<name>                          an in-OS test booted in QEMU
#   tools/tests/<name>.sh                        a tool self-test script in os
# Paths are relative to the root of the test's repository.

# Results are appended to $RES as "<status>\t<suite>\t<test>\t<reason>",
# status one of pass, fail, skip.
record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >>"$RES"; }
logfile() {
  local suite=$1 filename link_dir
  filename="$(printf '%s' "$2" | tr '/: ' '___').log"
  mkdir -p "$LOGS/$suite"
  if [ "$LOGS" != "$OUTBASE/logs" ]; then
    # Stable path to the latest log; each run also keeps its own private copy.
    link_dir=$OUTBASE/logs/$suite
    mkdir -p "$link_dir"
    ln -sfnT "$LOGS/$suite/$filename" "$link_dir/$filename"
  fi
  echo "$LOGS/$suite/$filename"
}

# Cargo packages of a checkout: "<name>\t<crate dir relative to repo>\t<default member 0|1>"
packages() {
  local dir; dir=$(checkout_of "$1")
  (cd "$dir" && cargo metadata --no-deps --format-version 1 --offline 2>/dev/null) | jq -r --arg root "$dir/" '
    (.workspace_default_members // .workspace_members) as $def
    | .packages[] | [.name, (.manifest_path | ltrimstr($root) | rtrimstr("/Cargo.toml") | if . == "Cargo.toml" then "." else . end),
      (if (.id as $i | $def | index($i)) then 1 else 0 end)] | @tsv'
}

# Parse `cargo test` output: "<status>\t<id>\t<reason>" per test.
parse_cargo_tests() { # parse_cargo_tests <crate dir> <log>
  awk -v cd="$1" '
    /^ *Running unittests / { t = $3; next }
    /^ *Running / { t = $2; next }
    /^ *Doc-tests / { t = "doc"; next }
    /^test .* \.\.\. / {
      line = $0; sub(/^test /, "", line); res = line; sub(/.* \.\.\. /, "", res); name = line; sub(/ \.\.\. .*/, "", name)
      sub(/ - should panic$/, "", name)
      id = cd "/" t "::" name
      if (res ~ /^ok/) print "pass\t" id "\t"
      else if (res ~ /^ignored/) print "ignored\t" id "\tignored"
      else print "fail\t" id "\tfailed"
    }' "$2"
}

# Parse `cargo test -- --list` output: one test id per line, ids as in parse_cargo_tests.
parse_cargo_list() { # parse_cargo_list <crate dir> <log>
  awk -v cd="$1" '
    /^ *Running unittests / { t = $3; next }
    /^ *Running / { t = $2; next }
    /^ *Doc-tests / { t = "doc"; next }
    /: test$/ { name = $0; sub(/: test$/, "", name); print cd "/" t "::" name }' "$2"
}

# The first line of a log that says what failed; failing that, its last line.
first_error() {
  local l
  l=$(grep -m1 -E '^(error|ERROR)|panicked|assertion' "$1")
  [ -n "$l" ] || l=$(grep -v '^[[:space:]]*$' "$1" | tail -n 1)
  printf '%s\n' "$l" | cut -c1-160
}

# TEST_ARGS: extra `cargo test` arguments for run_named (loom models run with --release).
TEST_ARGS=()

# run_named <repo> <test id> <suite> [expect-fail]
# Records the outcome; returns 0 pass, 1 fail, 3 missing, 4 ignored.
run_named() {
  local repo=$1 id=$2 suite=$3 log path name dir crate rel pkg sel
  log=$(logfile "$suite" "$id")
  case "$id" in
    inos/*::*)
      local arch=${id%%::*}; arch=${arch#inos/}; name=${id#*::}
      run_inos "$arch" "$suite" "$name"; return $? ;;
    *.sh)
      dir=$(checkout_of "$repo")
      [ -f "$dir/$id" ] || { record fail "$suite" "$id" "missing"; return 3; }
      mkdir -p "$RUN/named"
      (cd "$dir" && env SILICA_WS="$WS" SILICA_RUN="$RUN/named" bash "$dir/$id") >"$log" 2>&1
      if [ $? = 0 ]; then record pass "$suite" "$id"; return 0; fi
      record fail "$suite" "$id" "$(first_error "$log")"; return 1 ;;
  esac
  path=${id%%::*}; name=${id#*::}
  [ "$path" != "$id" ] && [ -n "$name" ] || { record fail "$suite" "$id" "malformed test id"; return 3; }
  dir=$(checkout_of "$repo")
  [ -f "$dir/$path" ] || { record fail "$suite" "$id" "missing: no file $path"; return 3; }
  # The crate is the deepest package directory that contains the file.
  local best="" bestlen=-1 n d _
  while IFS=$'\t' read -r n d _; do
    if [ "$d" = . ] || [ "${path#"$d"/}" != "$path" ]; then
      [ ${#d} -gt $bestlen ] && { best=$n; crate=$d; bestlen=${#d}; }
    fi
  done < <(packages "$repo")
  [ -n "$best" ] || { record fail "$suite" "$id" "missing: no crate contains $path"; return 3; }
  pkg=$best; rel=${path#"$crate"/}; [ "$crate" = . ] && rel=$path
  case "$rel" in
    tests/*.rs) sel=(--test "$(basename "$rel" .rs)") ;;
    src/lib.rs) sel=(--lib) ;;
    src/main.rs) sel=(--bin "$pkg") ;;
    src/bin/*.rs) sel=(--bin "$(basename "$rel" .rs)") ;;
    *) record fail "$suite" "$id" "unsupported test path $rel"; return 3 ;;
  esac
  cargo_run "$repo" "$log" test "${TEST_ARGS[@]+"${TEST_ARGS[@]}"}" -p "$pkg" "${sel[@]}" -- --exact "$name"
  local out; out=$(parse_cargo_tests "$crate" "$log" | awk -F'\t' -v id="$id" '$2 == id')
  case "$out" in
    pass*) record pass "$suite" "$id"; return 0 ;;
    ignored*) record skip "$suite" "$id" "ignored"; return 4 ;;
    fail*) record fail "$suite" "$id" "$(grep -m1 -E 'panicked|assert' "$log" | cut -c1-160)"; return 1 ;;
  esac
  if grep -q 'could not compile' "$log"; then record fail "$suite" "$id" "build failed: $(first_error "$log")"; return 1; fi
  record fail "$suite" "$id" "missing: no test named $name"; return 3
}

# run_inos <arch> <suite> [name]: boots the image and records one result.
# boot_ok is the plain boot: the stub writes BOOT OK and exits through the
# debug-exit device. Any other name is an in-OS test: the kernel command line
# (SILICA/CMDLINE.TXT on the ESP) carries test=<name>, the kernel prints one
# line "TEST <name> PASS" or "TEST <name> FAIL <reason>" on serial and exits
# through the debug-exit device. A name that is empty or has a character
# outside A-Za-z0-9_.:- never boots. A missing line, a line for another name,
# both PASS and FAIL, a PASS with a failing exit status, or a timeout is a failure.
# INOS_QEMU (array) adds qemu.sh arguments (--smp, --mem); INOS_LABEL, when
# set, is the name the result is recorded under (the same test on another machine).
INOS_QEMU=() INOS_LABEL=""
run_inos() {
  local arch=$1 suite=$2 name=${3-boot_ok} log img serial cmdline="" rc label
  case "$name" in ''|*[!A-Za-z0-9_.:-]*) record fail "$suite" "$name" "malformed in-OS test name"; return 3 ;; esac
  [ "$name" = boot_ok ] || cmdline="test=$name"
  label=${INOS_LABEL:-$name}
  log=$(logfile "$suite" "build.$label")
  img=$(build_image "$arch" "$log" "$cmdline") || { record fail "$suite" "$label" "image build failed (log: $log)"; return 1; }
  serial=$(logfile "$suite" "$label")
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --timeout "${SILICA_QEMU_TIMEOUT:-60}" \
    "${INOS_QEMU[@]+"${INOS_QEMU[@]}"}" >"$serial.qemu" 2>&1
  rc=$?
  local lines npass nfail nother why
  lines=$(tr -d '\r' <"$serial" 2>/dev/null)
  if [ "$name" = boot_ok ]; then
    if [ $rc = 0 ] && grep -qx 'BOOT OK' <<<"$lines"; then record pass "$suite" "$label"; return 0; fi
  else
    npass=$(grep -cxF "TEST $name PASS" <<<"$lines")
    nfail=$(grep -cE "^TEST ${name//./\\.} FAIL( .*)?\$" <<<"$lines")
    nother=$(grep -E '^TEST ' <<<"$lines" | grep -vcE "^TEST ${name//./\\.} (PASS|FAIL( .*)?)\$")
    if [ $rc = 0 ] && [ "$npass" = 1 ] && [ "$nfail" = 0 ] && [ "$nother" = 0 ]; then record pass "$suite" "$label"; return 0; fi
  fi
  # The log of a failed boot, decoded against the kernel ELF just booted.
  [ -x "$TOOLS/symbolize.sh" ] && "$TOOLS/symbolize.sh" --arch "$arch" "$serial" >"$serial.symbolized" 2>&1
  if [ $rc = 124 ]; then record fail "$suite" "$label" "timeout (serial: $serial)"; return 1; fi
  if [ "$name" = boot_ok ]; then
    record fail "$suite" "$label" "no BOOT OK or bad exit status $rc (serial: $serial)"; return 1
  fi
  if [ "$nfail" -gt 0 ]; then
    why=$(grep -m1 -E "^TEST ${name//./\\.} FAIL" <<<"$lines" | sed "s/^TEST [^ ]* FAIL *//" | cut -c1-140)
    [ "$npass" = 0 ] && [ "$nfail" = 1 ] || why="both PASS and FAIL lines or repeated: $why"
    record fail "$suite" "$label" "${why:-failed} (serial: $serial)"
  elif [ "$nother" -gt 0 ]; then record fail "$suite" "$label" "TEST line for another test (serial: $serial)"
  elif [ "$npass" -gt 1 ]; then record fail "$suite" "$label" "TEST $name PASS printed $npass times (serial: $serial)"
  elif [ "$npass" = 1 ]; then record fail "$suite" "$label" "TEST $name PASS but bad exit status $rc (serial: $serial)"
  else record fail "$suite" "$label" "no TEST $name PASS/FAIL line, exit status $rc (serial: $serial)"; fi
  return 1
}

# run_panic <arch> <suite>: the kernel is asked to panic (panic=test). The
# boot must fail through the debug-exit device, the serial log must carry the
# panic message and a backtrace, and symbolize.sh must decode the frame of the
# function that panicked to a function name, a source file and a line.
run_panic() {
  local arch=$1 suite=$2 mode=${3:-test} label=panic_backtrace cpus=1 log img serial rc sym want=deliberate_panic
  if [ "$mode" = secondary ]; then label=panic_backtrace_secondary; cpus=2; fi
  # panic=null: the kernel reaches an object through the null address,
  # which must fault (physical page 0 is never mapped for it).
  if [ "$mode" = null ]; then label=null_object_faults; want=deliberate_null_access; fi
  log=$(logfile "$suite" "build.$label")
  img=$(build_image "$arch" "$log" "panic=$mode") || { record fail "$suite" "$label" "image build failed (log: $log)"; return 1; }
  serial=$(logfile "$suite" "$label")
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp "$cpus" --timeout "${SILICA_QEMU_TIMEOUT:-60}" >"$serial.qemu" 2>&1
  rc=$?
  sym=$serial.symbolized
  "$TOOLS/symbolize.sh" --arch "$arch" "$serial" >"$sym" 2>&1
  if [ $rc != 1 ] || ! grep -q 'guest exit code 17' "$serial.qemu"; then
    record fail "$suite" "$label" "a panicking kernel did not leave with the failure code (exit status $rc)"; return 1
  fi
  if [ "$mode" = null ]; then
    if ! grep -aq '^PANIC: kernel exception' "$serial"; then
      record fail "$suite" "$label" "a null object address did not fault: $(grep -am1 '^PANIC' "$serial" | cut -c1-120) (serial: $serial)"; return 1
    fi
  elif ! grep -aq '^PANIC: deliberate panic' "$serial"; then
    record fail "$suite" "$label" "no panic message on the serial port (serial: $serial)"; return 1
  fi
  if [ "$mode" = secondary ] && ! grep -aq '^PANIC: deliberate panic on processor 1' "$serial"; then
    record fail "$suite" "$label" "the secondary processor did not report its panic (serial: $serial)"; return 1
  fi
  if ! grep -aqE "$want at .+\.rs:[1-9][0-9]*" "$sym"; then
    record fail "$suite" "$label" "the backtrace does not decode to function, file and line (see $sym)"; return 1
  fi
  record pass "$suite" "$label"
}

# run_boot_error <arch> <suite> <label> <expected text> <silica-image arguments...>
# A boot that cannot succeed must say why on the serial port and leave with
# the failure code. The image is built from the given ESP contents; $K, $L and
# $R in them stand for the stripped kernel, the loader and the root task.
run_boot_error() {
  local arch=$1 suite=$2 label=$3 want=$4 log dir serial rc a; shift 4
  log=$(logfile "$suite" "build.$label")
  build_image "$arch" "$log" >/dev/null || { record fail "$suite" "$label" "image build failed (log: $log)"; return 1; }
  dir=$(art_dir "$arch")
  local -a args=()
  for a in "$@"; do
    a=${a//\$K/$dir/kernel.stripped}; a=${a//\$L/$dir/BOOTX64.EFI}; a=${a//\$R/$dir/root.elf}
    args+=("$a")
  done
  "$dir/silica-image" --out "$dir/error.img" "${args[@]}" >"$log" 2>&1 || { record fail "$suite" "$label" "image build failed (log: $log)"; return 1; }
  serial=$(logfile "$suite" "$label")
  "$TOOLS/qemu.sh" --arch "$arch" --image "$dir/error.img" --serial "$serial" --timeout "${SILICA_QEMU_TIMEOUT:-60}" >"$serial.qemu" 2>&1
  rc=$?
  if [ $rc != 1 ] || ! grep -q 'guest exit code 17' "$serial.qemu"; then
    record fail "$suite" "$label" "a boot that cannot succeed did not leave with the failure code (exit status $rc; serial: $serial)"; return 1
  fi
  if ! grep -aqF -- "$want" "$serial"; then
    record fail "$suite" "$label" "the serial log does not say: $want (serial: $serial)"; return 1
  fi
  record pass "$suite" "$label"
}

# run_system <arch> <suite>: the system image (root task: the system
# repository's init) boots on two processors, starts its programs and
# reports BOOT OK through the debug-exit device.
run_system() {
  local arch=$1 suite=$2 log img serial rc
  log=$(logfile "$suite" build.boot)
  img=$(build_system_image "$arch" "$log") || { record fail "$suite" boot "image build failed: $(first_error "$log") (log: $log)"; return 1; }
  serial=$(logfile "$suite" boot)
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp 2 --timeout "${SILICA_QEMU_TIMEOUT:-60}" >"$serial.qemu" 2>&1
  rc=$?
  if [ $rc = 0 ] && tr -d '\r' <"$serial" | grep -qx 'BOOT OK'; then record pass "$suite" boot; return 0; fi
  [ -x "$TOOLS/symbolize.sh" ] && "$TOOLS/symbolize.sh" --arch "$arch" "$serial" >"$serial.symbolized" 2>&1
  record fail "$suite" boot "$(tr -d '\r' <"$serial" | grep -m1 -aE '^(ERROR|PANIC)' | cut -c1-140) (exit status $rc; serial: $serial)"
  return 1
}

# run_recovery <arch> <suite>: a driver killed under load (spec/MILESTONES.md
# M3). blkload writes every block of a scratch disk while the device manager
# restarts the disk's driver every 200 ms; it fails if a recovery took over
# 250 ms or a request was lost or failed. Then the host reads the scratch
# image: every block b must hold the words 4 << 40 | b << 16 | i (its last
# round's), so a write the guest was told had completed and was flushed,
# and was then lost or overtaken by an older one, fails it.
run_recovery() {
  local arch=$1 suite=$2 log img serial rc scratch bad
  log=$(logfile "$suite" build.recovery)
  img=$(build_system_image "$arch" "$log" "checks=load") || { record fail "$suite" recovery "image build failed: $(first_error "$log") (log: $log)"; return 1; }
  serial=$(logfile "$suite" recovery)
  scratch=$(dirname "$serial")/scratch.img
  rm -f "$scratch"; truncate -s 16M "$scratch" || { record fail "$suite" recovery "cannot create $scratch"; return 1; }
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp 2 --timeout "${SILICA_QEMU_TIMEOUT:-120}" --disk "$scratch" >"$serial.qemu" 2>&1
  rc=$?
  if [ $rc != 0 ] || ! tr -d '\r' <"$serial" | grep -qx 'BLKLOAD OK'; then
    record fail "$suite" recovery "$(tr -d '\r' <"$serial" | grep -m1 -aE '^(ERROR|PANIC)' | cut -c1-140) (exit status $rc; serial: $serial)"; return 1
  fi
  record pass "$suite" recovery
  # Every block on the host's disk image, as written.
  bad=$(od -An -v -tx8 -w8 -N $((16384 * 512)) "$scratch" | awk '{ w = strtonum("0x" $1); b = int((NR - 1) / 64); i = (NR - 1) % 64; if (w != 4 * 2^40 + b * 65536 + i) { n++; if (n == 1) first = b } } END { if (n) printf "%d words wrong, the first in block %d", n, first }')
  if [ -z "$bad" ]; then record pass "$suite" recovery_no_write_lost
  else record fail "$suite" recovery_no_write_lost "the scratch disk read by the host: $bad ($scratch)"; fi
}

# run_shutdown <arch> <suite>: the power button shuts the system down in
# order. The system stays up (no checks); once it says BOOT OK the host
# presses the button (QEMU's system_powerdown, an ACPI fixed event); the
# device manager hears it and asks the service manager to shut down, which
# stops the services last-started first and turns the machine off.
run_shutdown() {
  local arch=$1 suite=$2 log img serial rc
  log=$(logfile "$suite" build.shutdown)
  img=$(build_system_image "$arch" "$log" "checks=") || { record fail "$suite" shutdown "image build failed: $(first_error "$log") (log: $log)"; return 1; }
  serial=$(logfile "$suite" shutdown)
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp 2 --timeout "${SILICA_QEMU_TIMEOUT:-60}" \
    --on '^BOOT OK$=system_powerdown' >"$serial.qemu" 2>&1
  rc=$?
  if [ $rc = 0 ] && tr -d '\r' <"$serial" | grep -q '^init: shutting down' && tr -d '\r' <"$serial" | grep -q '^init: devmgr stopped' \
      && ! tr -d '\r' <"$serial" | grep -q '^ERROR'; then record pass "$suite" shutdown
  else record fail "$suite" shutdown "$(tr -d '\r' <"$serial" | grep -m1 -aE '^(ERROR|PANIC)' | cut -c1-140) (exit status $rc; serial: $serial)"; fi
}

# run_console <arch> <suite>: someone at the machine. It boots with a
# display and a keyboard (virtio, behind the IOMMU) and no checks; the host
# types on the keyboard: `services`, `devices`, then restarts the keyboard's
# driver and the display's from the shell (each time waiting for the
# console to say it found the new one), types `echo back`, takes a picture
# of the screen and types `shutdown`. The shell's answers must name the
# console and both drivers, the screen must hold the same lines (one row
# of text per line, the first as wide as the banner, nothing below:
# everything from before the display's driver was replaced is back), and
# the machine must turn itself off. The console draws before it echoes, so
# a line on the serial line is on the screen.
run_console() {
  local arch=$1 suite=$2 log img serial rc shot text bad
  log=$(logfile "$suite" build.console)
  img=$(build_system_image "$arch" "$log" "checks=") || { record fail "$suite" console "image build failed: $(first_error "$log") (log: $log)"; return 1; }
  serial=$(logfile "$suite" console)
  shot=$(cd "$(dirname "$serial")" && pwd)/console.ppm
  rm -f "$shot"
  # The machine: 00:01.0 the disk, 00:02.0 the display, 00:03.0 the keyboard.
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp 2 --timeout "${SILICA_QEMU_TIMEOUT:-60}" --no-exit-device \
    --device VGA --device virtio-keyboard-pci,disable-legacy=on,iommu_platform=on \
    --type '^silica> $=services\n' --type '^  shell +running=devices\n' \
    --type '^  00:03\.0 input +virtio-input$=restart-driver 00:03.0\n' \
    --type "^console: the keyboard's driver ended; reading its successor\$=restart-driver 00:02.0\n" \
    --type "^console: the display's driver ended; showing on its successor\$=echo back\n" \
    --on "^back\$=screendump $shot" --type '^back$=shutdown\n' >"$serial.qemu" 2>&1
  rc=$?
  text=$(tr -d '\r\0' <"$serial")
  bad=""
  [ $rc = 0 ] || bad="the machine was not turned off (exit status $rc)"
  for want in '^console: on the display and the serial line, reading the keyboard$' '^silica> services$' '^  console +running +failures 0  silica\.console\.Terminal$' \
              '^silica> devices$' '^  00:02\.0 display +fbdisplay$' '^  00:03\.0 input +virtio-input$' \
              '^restart-driver: 00:03\.0: done$' '^restart-driver: 00:02\.0: done$' '^back$' '^silica> shutdown$' '^init: shutting down'; do
    [ -n "$bad" ] || grep -qE "$want" <<<"$text" || bad="the serial log has no line matching: $want"
  done
  [ -n "$bad" ] || ! grep -q '^ERROR' <<<"$text" || bad="$(grep -m1 '^ERROR' <<<"$text" | cut -c1-140)"
  # The picture: rows of 16 pixels; a row holds text if any pixel differs
  # from the top-right corner's (the background). The banner, five commands
  # and eleven lines of answers, maybe the next prompt.
  [ -n "$bad" ] || bad=$(python3 -I - "$shot" 17 <<'PY'
import sys
try:
    d = open(sys.argv[1], 'rb').read()
except OSError:
    print("no picture of the screen was taken"); sys.exit()
lines = int(sys.argv[2])
head = d.split(b'\n', 3); w, h = map(int, head[1].split()); px = head[3]
bg = px[(w - 1) * 3:w * 3]
rows = []
for r in range(h // 16):
    xs = [x for y in range(r * 16, r * 16 + 16) for x in range(w) if px[(y * w + x) * 3:(y * w + x) * 3 + 3] != bg]
    rows.append(max(xs) + 1 if xs else 0)
text = [i for i, n in enumerate(rows) if n]
if text[:lines] != list(range(lines)) or len(text) > lines + 1 or text[-1] != len(text) - 1:
    print(f"the screen's rows of text are {text}, not the first {lines} or {lines + 1}"); sys.exit()
if not 34 * 8 < rows[0] <= 35 * 8:
    print(f"the first row of text ends at pixel {rows[0]}, not in the banner's 35th cell")
PY
)
  if [ -z "$bad" ]; then record pass "$suite" console
  else record fail "$suite" console "$bad (serial: $serial)"; fi
}

# run_power <arch> <suite>: the machine is turned off, and reset, by the
# system itself. The system image boots without the harness's exit device,
# so nothing ends the emulator but the guest turning the machine off (ACPI
# S5) or resetting it (the FADT's reset register; -no-reboot ends the
# emulator on a reset). A reset that failed would say so on the console and
# turn the machine off instead: no ERROR line may appear.
run_power() {
  local arch=$1 suite=$2 log img serial rc name halt
  for name in power_off power_reset; do
    halt=""; [ $name = power_reset ] && halt=" halt=reboot"
    log=$(logfile "$suite" "build.$name")
    img=$(build_system_image "$arch" "$log" "checks=block$halt") || { record fail "$suite" $name "image build failed: $(first_error "$log") (log: $log)"; continue; }
    serial=$(logfile "$suite" $name)
    "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --timeout "${SILICA_QEMU_TIMEOUT:-60}" --no-exit-device >"$serial.qemu" 2>&1
    rc=$?
    if [ $rc = 0 ] && tr -d '\r' <"$serial" | grep -qx 'BOOT OK' && ! tr -d '\r' <"$serial" | grep -q '^ERROR'; then record pass "$suite" $name
    else record fail "$suite" $name "$(tr -d '\r' <"$serial" | grep -m1 -aE '^(ERROR|PANIC)' | cut -c1-140) (exit status $rc; serial: $serial)"; fi
  done
}

# run_rogue <arch> <suite>: what a driver cannot do. The system image boots
# with a hostile driver in place of the disk's (driver=...=virtio-rogue), on
# the machine with an IOMMU. One result per check: the driver's own `TEST
# <name> PASS` lines, and three it cannot see for itself, taken from who
# enforces them: the kernel's line for each access the IOMMU refused, and
# the device manager's line for the fault on writing configuration space.
# The system must have come up (BOOT OK) and nothing may have failed.
run_rogue() {
  local arch=$1 suite=$2 log img serial rc name text want
  log=$(logfile "$suite" build.rogue)
  img=$(build_system_image "$arch" "$log" "driver=1af4:1042=virtio-rogue checks=") || { record fail "$suite" rogue "image build failed: $(first_error "$log") (log: $log)"; return 1; }
  serial=$(logfile "$suite" rogue)
  # The system stays up; the run ends when the driver's second run is over.
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp 2 --timeout "${SILICA_QEMU_TIMEOUT:-60}" \
    --until '^devmgr: virtio-rogue for 00:01\.0 ended with status 0' >"$serial.qemu" 2>&1
  rc=$?
  text=$(tr -d '\r' <"$serial")
  for name in rogue_other_device rogue_other_interrupt rogue_physical_address rogue_address_above_the_top \
              rogue_write_read_only rogue_recovers rogue_restart; do
    if grep -qx "TEST $name PASS" <<<"$text"; then record pass "$suite" "$name"
    else record fail "$suite" "$name" "$(grep -m1 -a "^ERROR: virtio-rogue: $name" <<<"$text" | cut -c1-160) (no PASS line; serial: $serial)"; fi
  done
  while IFS='|' read -r name want; do
    if grep -qE "$want" <<<"$text"; then record pass "$suite" "$name"
    else record fail "$suite" "$name" "the serial log has no line matching: $want (serial: $serial)"; fi
  done <<'CHECKS'
rogue_write_unmapped|^kernel: device 00:01\.0 was refused a write at 0x100000 
rogue_read_unmapped|^kernel: device 00:01\.0 was refused a read at 0x200000 
rogue_config_space|^devmgr: virtio-rogue for 00:01\.0 touched memory it may not \(page fault\)
CHECKS
  if [ $rc = 0 ] && grep -qx 'BOOT OK' <<<"$text" && ! grep -q '^ERROR' <<<"$text"; then record pass "$suite" rogue_system_survives; return 0; fi
  record fail "$suite" rogue_system_survives "$(grep -m1 -aE '^(ERROR|PANIC)' <<<"$text" | cut -c1-140) (exit status $rc; serial: $serial)"
  return 1
}

# run_systest <arch> <suite>: the tests of what programs do to each other
# (root task: the system repository's systest) on eight processors. Each
# `TEST <name> PASS` line is one result; an `ERROR: systest: <name>: ...`
# line is that test's failure; a run that does not end with SYSTEST OK and
# status 0 is a failure of its own.
run_systest() {
  local arch=$1 suite=$2 log img serial rc l name expected=""
  local -A seen=()
  local plan='^systest: ([0-9]+) processors, ([1-9][0-9]*) tests$'
  local passed='^TEST ([^[:space:]]+) PASS( \([0-9]+ ms\))?$'
  log=$(logfile "$suite" build.systest)
  img=$(build_system_image "$arch" "$log" "" systest) || { record fail "$suite" systest "image build failed: $(first_error "$log") (log: $log)"; return 1; }
  serial=$(logfile "$suite" systest)
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp 8 --timeout "${SILICA_SYSTEST_TIMEOUT:-600}" >"$serial.qemu" 2>&1
  rc=$?
  while IFS= read -r l; do
    if [[ "$l" =~ $plan ]]; then
      expected=${BASH_REMATCH[2]}
      if [ "${BASH_REMATCH[1]}" != 8 ]; then record fail "$suite" systest "guest did not start eight processors (serial: $serial)"; fi
      continue
    fi
    if [[ "$l" =~ $passed ]]; then
      name=${BASH_REMATCH[1]}
      if [ -n "${seen[$name]:-}" ]; then
        record fail "$suite" "$name" "duplicate result (serial: $serial)"
      else
        seen[$name]=1
        record pass "$suite" "$name"
      fi
      continue
    fi
    case "$l" in
      "TEST "*) record fail "$suite" systest "malformed result: $l (serial: $serial)" ;;
      "ERROR: systest: "*": "*) name=${l#ERROR: systest: }; record fail "$suite" "${name%%: *}" "${name#*: } (serial: $serial)" ;;
    esac
  done < <(tr -d '\r' <"$serial")
  if [ $rc = 0 ] && tr -d '\r' <"$serial" | grep -qx 'SYSTEST OK'; then
    [ "${#seen[@]}" = "$expected" ] && return 0
    record fail "$suite" systest "guest announced ${expected:-no} tests and reported ${#seen[@]} distinct passes (serial: $serial)"; return 1
  fi
  [ -x "$TOOLS/symbolize.sh" ] && "$TOOLS/symbolize.sh" --arch "$arch" "$serial" >"$serial.symbolized" 2>&1
  record fail "$suite" systest "the run did not end with SYSTEST OK: $(tr -d '\r' <"$serial" | grep -m1 -aE '^(ERROR|PANIC)' | cut -c1-140) (exit status $rc; serial: $serial)"
  return 1
}
