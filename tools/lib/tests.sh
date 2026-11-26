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
      # A scratch directory of its own: scripts run at once.
      name=$RUN/named/$(basename "$id" .sh); mkdir -p "$name"
      (cd "$dir" && env SILICA_WS="$WS" SILICA_RUN="$name" bash "$dir/$id") >"$log" 2>&1
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

# run_panic_screen <arch> <suite>: a kernel panic is on the screen (C30),
# for a machine whose serial port nobody reads. The machine has a display
# and no debug-exit device, so it stays up after panic=test; once the
# panic's last line is on the serial port the host takes a screendump, and
# the cells of the screen's second text row must be, pixel for pixel, the
# font's glyphs of "PANIC: deliberate panic" in white on black.
run_panic_screen() {
  local arch=$1 suite=$2 log img serial rc shot bad
  log=$(logfile "$suite" build.panic_screen)
  img=$(build_image "$arch" "$log" "panic=test") || { record fail "$suite" panic_screen "image build failed (log: $log)"; return 1; }
  serial=$(logfile "$suite" panic_screen)
  shot=$(cd "$(dirname "$serial")" && pwd)/panic_screen.ppm
  rm -f "$shot"
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp 1 --timeout "${SILICA_QEMU_TIMEOUT:-60}" --no-exit-device \
    --screendump "$shot" --screendump-after 60 --on "^  kernel slide=screendump $shot" --until '^  kernel slide' >"$serial.qemu" 2>&1
  rc=$?
  if [ $rc != 0 ] || [ ! -s "$shot" ]; then record fail "$suite" panic_screen "no screen taken after the panic (exit status $rc; serial: $serial)"; return 1; fi
  local screen
  screen=$(host_tool screen "$log") || { record fail "$suite" panic_screen "the screen check did not build: $(first_error "$log") (log: $log)"; return 1; }
  if bad=$("$screen" text "$shot" "$(checkout_of kernel)/formats/src/font.rs" 1 'PANIC: deliberate panic'); then record pass "$suite" panic_screen
  else record fail "$suite" panic_screen "${bad:-the screen check failed with no reason} (screen: $shot)"; fi
}

# run_boot_error <arch> <suite> <label> <expected text> <silica-image arguments...>
# A boot that cannot succeed must say why on the serial port and leave with
# the failure code. The image is built from the given ESP contents; $K, $L and
# $R in them stand for the stripped kernel, the loader and the root task.
run_boot_error() {
  local arch=$1 suite=$2 label=$3 want=$4 log dir serial rc a; shift 4
  log=$(logfile "$suite" "build.$label")
  build_image "$arch" "$log" >/dev/null || { record fail "$suite" "$label" "image build failed (log: $log)"; return 1; }
  # The pieces build_image just assembled: this run's copy, or the artifacts.
  local k l r tool out
  dir=$(art_dir "$arch"); k=$dir/kernel.stripped l=$dir/BOOTX64.EFI r=$dir/root.elf tool=$dir/silica-image
  if [ -n "${PIECES_ONCE:-}" ]; then dir=${PIECES_DIR:-$RUN}/pieces-kernel-$arch; k=$dir/kernel.stripped l=$dir/loader.efi r=$dir/root.elf tool=$dir/silica-image; fi
  out=${UNIT_DIR:-$dir}/error.img
  local -a args=()
  for a in "$@"; do
    a=${a//\$K/$k}; a=${a//\$L/$l}; a=${a//\$R/$r}
    args+=("$a")
  done
  "$tool" --out "$out" "${args[@]}" >"$log" 2>&1 || { record fail "$suite" "$label" "image build failed (log: $log)"; return 1; }
  serial=$(logfile "$suite" "$label")
  "$TOOLS/qemu.sh" --arch "$arch" --image "$out" --serial "$serial" --timeout "${SILICA_QEMU_TIMEOUT:-60}" >"$serial.qemu" 2>&1
  rc=$?
  if [ $rc != 1 ] || ! grep -q 'guest exit code 17' "$serial.qemu"; then
    record fail "$suite" "$label" "a boot that cannot succeed did not leave with the failure code (exit status $rc; serial: $serial)"; return 1
  fi
  if ! grep -aqF -- "$want" "$serial"; then
    record fail "$suite" "$label" "the serial log does not say: $want (serial: $serial)"; return 1
  fi
  record pass "$suite" "$label"
}

# run_cpu <arch> <suite> <label> <cpu model> [<refusal message>]: the test
# image on two emulated processors of that model (TCG). With a message, a
# processor Silica must refuse: the boot leaves with the failure code and
# says why. Without, one it must run on: the in-OS `fpu` test passes there
# (system calls, switches and the vector state, through a user program
# built for the baseline).
run_cpu() {
  local arch=$1 suite=$2 label=$3 model=$4 want=${5:-} log img serial rc
  log=$(logfile "$suite" "build.$label")
  img=$(build_image "$arch" "$log" "$([ -n "$want" ] || echo test=fpu)") || { record fail "$suite" "$label" "image build failed (log: $log)"; return 1; }
  serial=$(logfile "$suite" "$label")
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --cpu "$model" --smp 2 --timeout "${SILICA_QEMU_TIMEOUT:-120}" >"$serial.qemu" 2>&1
  rc=$?
  if [ -n "$want" ]; then
    if [ $rc != 1 ] || ! grep -q 'guest exit code 17' "$serial.qemu"; then
      record fail "$suite" "$label" "a processor Silica cannot run on was not refused with the failure code (exit status $rc; serial: $serial)"; return 1
    fi
    grep -aqF -- "$want" "$serial" || { record fail "$suite" "$label" "the serial log does not say: $want (serial: $serial)"; return 1; }
  elif [ $rc != 0 ] || ! grep -aqx 'TEST fpu PASS' <(tr -d '\r' <"$serial"); then
    record fail "$suite" "$label" "the fpu test did not pass on $model (exit status $rc; serial: $serial)"; return 1
  fi
  record pass "$suite" "$label"
}

# run_system <arch> <suite>: the system image (root task: the system
# repository's init) boots on two processors, starts its programs and
# reports BOOT OK through the debug-exit device.
run_system() {
  local arch=$1 suite=$2 log img serial rc t0 t1 wall at
  log=$(logfile "$suite" build.boot)
  img=$(build_system_image "$arch" "$log") || { record fail "$suite" boot "image build failed: $(first_error "$log") (log: $log)"; return 1; }
  serial=$(logfile "$suite" boot)
  t0=$(date -u +%s)
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp 2 --timeout "${SILICA_QEMU_TIMEOUT:-60}" >"$serial.qemu" 2>&1
  rc=$?
  t1=$(date -u +%s)
  # The wall clock from the hardware clock, before any network (M4): the
  # emulator's clock is the host's, so the system's must fall within the
  # boot (2 s either way: the firmware's clock counts whole seconds).
  wall=$(tr -d '\r' <"$serial" | sed -n "s/^init: the wall clock is \([0-9T:-]*Z\) (the firmware's)$/\1/p" | head -1)
  at=$( [ -n "$wall" ] && date -u -d "$wall" +%s 2>/dev/null)
  if [ -n "$at" ] && [ "$at" -ge $((t0 - 2)) ] && [ "$at" -le $((t1 + 2)) ]; then record pass "$suite" wall_clock
  else record fail "$suite" wall_clock "the wall clock at boot was '${wall:-not said}', the host's between $(date -u -d @$t0 +%H:%M:%S) and $(date -u -d @$t1 +%H:%M:%S) (serial: $serial)"; fi
  if [ $rc = 0 ] && serial_has "$serial" -x 'BOOT OK'; then
    # The x86_64 machine has an IOMMU: the system must not call itself unconfined there.
    if [ "$arch" = x86_64 ] && grep -aq '^devmgr: this machine cannot confine DMA' "$serial"; then
      record fail "$suite" boot "the device manager says it cannot confine DMA on a machine with an IOMMU (serial: $serial)"; return 1
    fi
    record pass "$suite" boot; return 0
  fi
  [ -x "$TOOLS/symbolize.sh" ] && "$TOOLS/symbolize.sh" --arch "$arch" "$serial" >"$serial.symbolized" 2>&1
  record fail "$suite" boot "$(tr -d '\r' <"$serial" | grep -m1 -aE '^(ERROR|PANIC)' | cut -c1-140) (exit status $rc; serial: $serial)"
  return 1
}

# run_unconfined <arch> <suite>: the same image on a machine without an
# IOMMU (spec/MILESTONES.md M3: "the same image booting on a machine without
# an IOMMU and saying that it is unconfined"). The device manager must say
# that every driver it starts is trusted with all of memory, the drivers
# must still work (blkcheck's five checks on the disk), the system must come
# up, and nothing may say ERROR.
run_unconfined() {
  local arch=$1 suite=$2 log img serial rc text bad=""
  log=$(logfile "$suite" build.unconfined)
  img=$(build_system_image "$arch" "$log") || { record fail "$suite" unconfined "image build failed: $(first_error "$log") (log: $log)"; return 1; }
  serial=$(logfile "$suite" unconfined)
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp 2 --timeout "${SILICA_QEMU_TIMEOUT:-60}" --no-iommu >"$serial.qemu" 2>&1
  rc=$?
  text=$(tr -d '\r\0' <"$serial")
  { [ $rc = 0 ] && grep -qx 'BOOT OK' <<<"$text"; } || bad="the system did not come up (exit status $rc)"
  [ -n "$bad" ] || grep -q '^devmgr: this machine cannot confine DMA: every driver started here is trusted with all of memory$' <<<"$text" ||
    bad="the device manager did not say that the drivers are unconfined"
  [ -n "$bad" ] || [ "$(grep -c '^TEST virtio-blk\.[a-z_]* PASS$' <<<"$text")" = 5 ] || bad="blkcheck did not pass every check on the disk"
  [ -n "$bad" ] || ! grep -q '^ERROR' <<<"$text" || bad="$(grep -m1 '^ERROR' <<<"$text" | cut -c1-140)"
  if [ -z "$bad" ]; then record pass "$suite" unconfined
  else record fail "$suite" unconfined "$bad (serial: $serial)"; fi
}

# nvme_machine <config> <image>: an NVMe controller the NVMe driver is
# tested on (spec/ARCHITECTURE.md section 7), its namespaces snapshots of
# <image> (a system image: a GPT disk). Sets NVME_MACHINE (qemu.sh
# arguments), NVME_SAYS (extended expressions the serial log must match:
# what the driver found, so a configuration QEMU ignored fails the test),
# and for the same controller hot-added at port hp0, NVME_HOT (monitor
# commands; its namespace 1 the drive `hot`), NVME_HOT_MACHINE (qemu.sh
# arguments it needs beside --hotplug) and NVME_HOT_SAYS.
#   ""          one namespace of 512-byte blocks, a vector per queue
#   one_vector  one MSI-X vector, both queues interrupting on it
#   4k          a namespace of 4 KiB blocks
#   namespaces  namespace 1's format carries metadata (not served), 2 is
#               served, 3 has 4 KiB blocks (not served: one disk per
#               controller). Hot-added: namespace 1 is served and a second
#               is added while the driver starts (seen when next started).
nvme_machine() {
  local config=$1 img=$2 dev="nvme,id=hotdisk,bus=hp0,drive=hot,serial=silica-hot" k4=logical_block_size=4096,physical_block_size=4096
  local served='^nvme: [^:]*: namespace 1, [0-9]+ blocks of 512 bytes, [0-9]+ I/O entries, MSI-X 0 and 1,'
  NVME_MACHINE=(--nvme "$img") NVME_SAYS=("$served") NVME_HOT=("device_add $dev") NVME_HOT_MACHINE=() NVME_HOT_SAYS=("$served")
  case "$config" in
    "") ;;
    one_vector)
      NVME_MACHINE+=(--nvme-props msix_qsize=1) NVME_HOT=("device_add $dev,msix_qsize=1")
      NVME_SAYS=('^nvme: [^:]*: namespace 1, [0-9]+ blocks of 512 bytes, [0-9]+ I/O entries, MSI-X 0 only,') NVME_HOT_SAYS=("${NVME_SAYS[@]}") ;;
    4k)
      NVME_MACHINE+=(--nvme-props "$k4") NVME_HOT=("device_add $dev,$k4")
      NVME_SAYS=('^nvme: [^:]*: namespace 1, [0-9]+ blocks of 4096 bytes, [0-9]+ I/O entries, MSI-X 0 and 1,') NVME_HOT_SAYS=("${NVME_SAYS[@]}") ;;
    namespaces)
      NVME_MACHINE=(--drive "ns1=$img" --nvme-ns drive=ns1,nsid=1,ms=8 --drive "ns2=$img" --nvme-ns drive=ns2,nsid=2
        --drive "ns3=$img" --nvme-ns "drive=ns3,nsid=3,$k4")
      NVME_SAYS=('^nvme: namespace 1: not served: its format carries metadata$'
        '^nvme: namespace 3: [0-9]+ blocks of 4096 bytes, not served: one disk per controller$'
        '^nvme: [^:]*: namespace 2, [0-9]+ blocks of 512 bytes, ')
      NVME_HOT+=("device_add nvme-ns,bus=hotdisk,drive=hot2,nsid=2,$k4") NVME_HOT_MACHINE=(--drive "hot2=$img") ;;
    *) die "nvme_machine: no configuration $config" ;;
  esac
}

# run_nvme <arch> <suite> [config]: the second block driver, written from
# the class protocol's documentation alone (spec/MILESTONES.md M3). The
# system image boots with an NVMe controller beside the virtio disk (one of
# nvme_machine's configurations), and blkcheck runs the same checks on each
# disk: every one of NVMe's must pass, the driver must say it found the
# controller as configured, and the system must come up.
run_nvme() {
  local arch=$1 suite=$2 config=${3:-} test=nvme${3:+_$3} log img serial rc text check say bad=""
  log=$(logfile "$suite" "build.$test")
  img=$(build_system_image "$arch" "$log") || { record fail "$suite" "$test" "image build failed: $(first_error "$log") (log: $log)"; return 1; }
  serial=$(logfile "$suite" "$test")
  nvme_machine "$config" "$img"
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp 2 --timeout "${SILICA_QEMU_TIMEOUT:-60}" "${NVME_MACHINE[@]}" >"$serial.qemu" 2>&1
  rc=$?
  text=$(tr -d '\r\0' <"$serial")
  for check in block_read block_write_read_back block_refusals block_in_flight block_many_pages; do
    if grep -qx "TEST nvme.$check PASS" <<<"$text"; then record pass "$suite" "$test.$check"
    else record fail "$suite" "$test.$check" "no PASS line: $(grep -m1 -aE "^(ERROR|PANIC)" <<<"$text" | cut -c1-140) (serial: $serial)"; fi
  done
  for say in "${NVME_SAYS[@]}"; do [ -n "$bad" ] || grep -qE "$say" <<<"$text" || bad="the driver never said: $say"; done
  [ -n "$bad" ] || { [ $rc = 0 ] && grep -qx 'BOOT OK' <<<"$text"; } || bad="the system did not come up (exit status $rc)"
  [ -n "$bad" ] || ! grep -q '^ERROR' <<<"$text" || bad="$(grep -m1 '^ERROR' <<<"$text" | cut -c1-140)"
  if [ -z "$bad" ]; then record pass "$suite" "$test"
  else record fail "$suite" "$test" "$bad (serial: $serial)"; fi
}
# run_nvme_unservable <arch> <suite>: an NVMe controller with no namespace
# the driver can serve (its only one's format carries metadata). The driver
# must say why and end well (status 0), the device manager must leave the
# controller alone rather than start the driver again, and the system must
# stay up: once the driver has ended the host presses the power button, and
# the system shuts down with nothing saying ERROR.
run_nvme_unservable() {
  local arch=$1 suite=$2 test=nvme_unservable log img serial rc text bad="" want
  log=$(logfile "$suite" "build.$test")
  img=$(build_system_image "$arch" "$log" "checks=") || { record fail "$suite" "$test" "image build failed: $(first_error "$log") (log: $log)"; return 1; }
  serial=$(logfile "$suite" "$test")
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp 2 --timeout "${SILICA_QEMU_TIMEOUT:-60}" \
    --drive "ns1=$img" --nvme-ns drive=ns1,nsid=1,ms=8 \
    --on '^devmgr: nvme for 00:02\.0 ended with status 0$=system_powerdown' >"$serial.qemu" 2>&1
  rc=$?
  text=$(tr -d '\r\0' <"$serial")
  [ $rc = 0 ] || bad="the machine was not turned off (exit status $rc)"
  for want in '^nvme: namespace 1: not served: its format carries metadata$' '^nvme: no namespace this driver can serve; leaving the controller alone$' \
              '^devmgr: nvme for 00:02\.0 ended with status 0$' '^init: shutting down'; do
    [ -n "$bad" ] || grep -qE "$want" <<<"$text" || bad="the serial log has no line matching: $want"
  done
  [ -n "$bad" ] || ! grep -q '^devmgr: nvme for .* started again' <<<"$text" || bad="the driver was started again"
  [ -n "$bad" ] || ! grep -q '^ERROR' <<<"$text" || bad="$(grep -m1 '^ERROR' <<<"$text" | cut -c1-140)"
  if [ -z "$bad" ]; then record pass "$suite" "$test"
  else record fail "$suite" "$test" "$bad (serial: $serial)"; fi
}
run_nvme_one_vector() { run_nvme "$1" "$2" one_vector; }
run_nvme_4k() { run_nvme "$1" "$2" 4k; }
run_nvme_namespaces() { run_nvme "$1" "$2" namespaces; }

# run_net <arch> <suite>: the network interface's driver and data path
# (spec/MILESTONES.md M3). The system image boots with a virtio network
# device on QEMU's user-mode network (behind the IOMMU) and netcheck runs:
# an ARP request for the gateway must be answered, then 200 pings, with
# frames built by hand and sent from, and received into, the program's own
# memory. The system must come up and nothing may report an error.
# run_net_e1000e: the same over an Intel 82574 (M4: "runs the same tests
# over an e1000e interface"), its driver e1000e.
run_net_e1000e() { run_net "$1" "$2" e1000e; }
run_net() {
  local arch=$1 suite=$2 nic=${3:-virtio} log img serial rc text name driver=virtio-net test=net
  [ "$nic" = e1000e ] && driver=e1000e test=net_e1000e
  log=$(logfile "$suite" "build.$test")
  img=$(build_system_image "$arch" "$log" "checks=net off=netd netcheck.link=cycle") || { record fail "$suite" "$test" "image build failed: $(first_error "$log") (log: $log)"; return 1; }
  serial=$(logfile "$suite" "$test")
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp 2 --timeout "${SILICA_QEMU_TIMEOUT:-60}" --net user --nic "$nic" \
    --on '^netcheck: ready for link down$=set_link net0 off' --on '^netcheck: confirmed link down$=set_link net0 on' >"$serial.qemu" 2>&1
  rc=$?
  text=$(tr -d '\r\0' <"$serial")
  for name in "$driver.link_cycle" "$driver.arp" "$driver.ping"; do
    if grep -qx "TEST $name PASS" <<<"$text"; then record pass "$suite" "$name"
    else record fail "$suite" "$name" "no PASS line: $(grep -m1 -aE "^(ERROR|PANIC)" <<<"$text" | cut -c1-140) (serial: $serial)"; fi
  done
  if [ $rc = 0 ] && grep -qx 'BOOT OK' <<<"$text" && ! grep -q '^ERROR' <<<"$text"; then record pass "$suite" "$test"
  else record fail "$suite" "$test" "$(grep -m1 -aE "^(ERROR|PANIC)" <<<"$text" | cut -c1-140) (exit status $rc; serial: $serial)"; fi
}

# run_net_recovery <arch> <suite>: the network interface's driver
# restarted under load (spec/MILESTONES.md M3). netload pings the user-mode
# gateway with eight requests in flight while the device manager restarts
# virtio-net every 200 ms for 3 s: no transmit may fail, no recovery may
# take over 250 ms, and once the restarts stop every ping must be answered.
# net_recovery_e1000e: the same with an Intel 82574 and its driver.
run_net_recovery_e1000e() { NIC=e1000e run_net_recovery "$@"; }
run_net_recovery() {
  local arch=$1 suite=$2 log img serial rc text nic=${NIC:-virtio} name=net_recovery
  [ "$nic" = virtio ] || name=net_recovery_$nic
  log=$(logfile "$suite" "build.$name")
  img=$(build_system_image "$arch" "$log" "checks=netload off=netd") || { record fail "$suite" "$name" "image build failed: $(first_error "$log") (log: $log)"; return 1; }
  serial=$(logfile "$suite" "$name")
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp 2 --timeout "${SILICA_QEMU_TIMEOUT:-60}" --net user --nic "$nic" >"$serial.qemu" 2>&1
  rc=$?
  text=$(tr -d '\r\0' <"$serial")
  if [ $rc = 0 ] && grep -qx 'NETLOAD OK' <<<"$text" && ! grep -q '^ERROR' <<<"$text"; then record pass "$suite" "$name"
  else record fail "$suite" "$name" "$(grep -m1 -aE '^(ERROR|PANIC)' <<<"$text" | cut -c1-140) (exit status $rc; serial: $serial)"; fi
}

# run_hotplug <arch> <suite> [nvme[_config]]: a disk put in while the
# system runs, used, and taken out (spec/MILESTONES.md M3). The machine has
# an empty PCI Express root port with native hot-plug (qemu.sh --hotplug)
# and a keyboard; once the device manager has armed the port the host adds
# a disk there (a virtio disk, or one of nvme_machine's NVMe controllers;
# a copy of the system image, so it has a partition table), types `start
# blkcheck` when the device manager says it arrived (blkcheck checks every
# disk: both must pass all five checks), and takes the disk out again once
# blkcheck has ended. The device manager must give it addresses and a
# driver, and end the driver when the disk is asked out; an NVMe driver must
# say it found the controller as configured; nothing may say ERROR.
run_hotplug() {
  local arch=$1 suite=$2 kind=${3:-virtio-blk} test=hotplug${3:+_$3} log img serial rc text hot bad="" driver id say cmd config want
  local -a add=() machine=() says=()
  log=$(logfile "$suite" "build.$test")
  img=$(build_system_image "$arch" "$log" "checks=") || { record fail "$suite" "$test" "image build failed: $(first_error "$log") (log: $log)"; return 1; }
  serial=$(logfile "$suite" "$test")
  hot=$(dirname "$serial")/$test.img
  cp "$img" "$hot" || { record fail "$suite" "$test" "cannot copy the image to $hot"; return 1; }
  case "$kind" in
    virtio-blk) driver=virtio-blk id='1af4:1042 class 01\.00\.00'
      add=('device_add virtio-blk-pci,id=hotdisk,bus=hp0,drive=hot,disable-legacy=on,iommu_platform=on') ;;
    nvme|nvme_*) driver=nvme id='1b36:0010 class 01\.08\.02'
      config=${kind#nvme}; nvme_machine "${config#_}" "$img"
      add=("${NVME_HOT[@]}") machine=("${NVME_HOT_MACHINE[@]+"${NVME_HOT_MACHINE[@]}"}") says=("${NVME_HOT_SAYS[@]}") ;;
    *) die "run_hotplug: no disk $kind" ;;
  esac
  for cmd in "${add[@]}"; do machine+=(--on "^devmgr: 00:02\.0 takes devices while the system runs\$=$cmd"); done
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp 2 --timeout "${SILICA_QEMU_TIMEOUT:-60}" \
    --hotplug "$hot" --device virtio-keyboard-pci,disable-legacy=on,iommu_platform=on "${machine[@]}" \
    --type "^devmgr: 01:00\\.0 $id arrived: $driver\$=start blkcheck\\n" \
    --on '^init: blkcheck ended$=device_del hotdisk' \
    --until "^devmgr: 01:00\\.0 was taken out; $driver ended\$" >"$serial.qemu" 2>&1
  rc=$?
  text=$(tr -d '\r\0' <"$serial")
  [ $rc = 0 ] || bad="the disk was not taken out (exit status $rc)"
  # Five checks on the boot disk (virtio) and five on the disk put in.
  want=5; [ $driver = virtio-blk ] && want=10
  [ -n "$bad" ] || { [ "$(grep -c '^TEST virtio-blk\.[a-z_]* PASS$' <<<"$text")" = $want ] && [ "$(grep -c "^TEST $driver\.[a-z_]* PASS\$" <<<"$text")" = $want ]; } \
    || bad="blkcheck did not pass every check on both disks"
  [ -n "$bad" ] || grep -q "^blkcheck: disk 0x100, driven by $driver\$" <<<"$text" || bad="blkcheck did not check the disk put in"
  for say in "${says[@]+"${says[@]}"}"; do [ -n "$bad" ] || grep -qE "$say" <<<"$text" || bad="the driver never said: $say"; done
  [ -n "$bad" ] || ! grep -q '^ERROR' <<<"$text" || bad="$(grep -m1 '^ERROR' <<<"$text" | cut -c1-140)"
  if [ -z "$bad" ]; then record pass "$suite" "$test"
  else record fail "$suite" "$test" "$bad (serial: $serial)"; fi
}
run_hotplug_nvme_one_vector() { run_hotplug "$1" "$2" nvme_one_vector; }
run_hotplug_nvme_4k() { run_hotplug "$1" "$2" nvme_4k; }
run_hotplug_nvme_namespaces() { run_hotplug "$1" "$2" nvme_namespaces; }

# run_partitions <arch> <suite>: the block server (spec/MILESTONES.md M3).
# partcheck opens the boot disk's first partition through it, as a disk of
# its own (a capability the driver narrowed to the partition), and checks
# its size, that its block 0 is the disk's block where it starts, that
# nothing past its end is reached, and that a write lands in the right
# place on the disk.
run_partitions() {
  local arch=$1 suite=$2 log img serial rc text name
  log=$(logfile "$suite" build.partitions)
  img=$(build_system_image "$arch" "$log" "checks=partitions") || { record fail "$suite" partitions "image build failed: $(first_error "$log") (log: $log)"; return 1; }
  serial=$(logfile "$suite" partitions)
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp 2 --timeout "${SILICA_QEMU_TIMEOUT:-60}" >"$serial.qemu" 2>&1
  rc=$?
  text=$(tr -d '\r\0' <"$serial")
  for name in size offset confined write; do
    if grep -qx "TEST partitions.$name PASS" <<<"$text"; then record pass "$suite" "partitions_$name"
    else record fail "$suite" "partitions_$name" "no PASS line: $(grep -m1 -aE "^(ERROR|PANIC)" <<<"$text" | cut -c1-140) (serial: $serial)"; fi
  done
}

# The system image has a 16 KiB GPT entry array. MDTS=1 on this NVMe
# controller permits 8 KiB per transfer. Give it a fixed PCI slot so
# finding the same partition on the virtio boot disk cannot pass the test.
run_partitions_small_transfer() {
  local arch=$1 suite=$2 name=partitions_small_transfer log img serial
  log=$(logfile "$suite" "build.$name")
  img=$(build_system_image "$arch" "$log" "checks=") || { record fail "$suite" "$name" "image build failed: $(first_error "$log")"; return 1; }
  serial=$(logfile "$suite" "$name")
  if "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp 2 --timeout "${SILICA_QEMU_TIMEOUT:-60}" \
      --nvme "$img" --nvme-props mdts=1,addr=0x4 --until '^partitions: disk 0x20:' >"$serial.qemu" 2>&1 \
      && serial_has "$serial" '^nvme: .* blocks of 512 bytes, .*max 16 blocks per request$' \
      && serial_has "$serial" '^partitions: disk 0x20: 1 partitions$'; then
    record pass "$suite" "$name"
  else
    record fail "$suite" "$name" "the partition on the transfer-limited NVMe namespace was not found (serial: $serial)"
  fi
}

# run_faults <arch> <suite>: a device that misbehaves (spec/MILESTONES.md
# M3, fault injection). One boot per fault and block driver, the driver
# committing the fault at its 50th request (inject=<driver>:<fault>@50,
# silica_driver::inject): for virtio-blk in the middle of blkcheck's 128
# reads in flight. Every check of blkcheck's on that disk must still pass
# (its requests are sent again to the driver started in place of one that
# gave up), the system must come up, and nothing but the driver may say
# ERROR. A completion of a request never offered, a request the device
# never sees and a device that resets itself end the driver (the device
# manager starts another); an interrupt with nothing done and a completion
# without an interrupt do not. NVMe runs on each of nvme_machine's
# configurations (nvme_<config>, the driver's name "nvme"), and must say it
# found the controller as configured.
run_faults() {
  local arch=$1 suite=$2 log img serial rc text token driver config fault restarts other want name say missing
  local -a faults=(garbage stuck spurious missed reset)
  if [ -n "${4:-}" ]; then faults=("$4"); fi
  local -a machine says
  # One driver's five boots when named (the drivers' run at once); the
  # network driver's are below.
  local -a block=() network=()
  for token in ${3:-virtio-blk nvme virtio-net e1000e}; do
    case "$token" in virtio-net | e1000e) network+=("$token") ;; *) block+=("$token") ;; esac
  done
  for token in "${block[@]+"${block[@]}"}"; do
    driver=${token%%_*} config=${token#*_}; [ "$config" != "$token" ] || config=""
    machine=() says=()
    if [ $driver = nvme ]; then
      nvme_machine "$config" "$(build_system_image "$arch" "$(logfile "$suite" build.faults_disk)")"
      machine=("${NVME_MACHINE[@]}") says=("${NVME_SAYS[@]}")
    fi
    for fault in "${faults[@]}"; do
      name=fault_${token//-/_}_$fault
      log=$(logfile "$suite" "build.$name")
      img=$(build_system_image "$arch" "$log" "checks=block inject=$driver:$fault@50") || { record fail "$suite" "$name" "image build failed: $(first_error "$log") (log: $log)"; continue; }
      serial=$(logfile "$suite" "$name")
      "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp 2 --timeout "${SILICA_QEMU_TIMEOUT:-60}" "${machine[@]}" >"$serial.qemu" 2>&1
      rc=$?
      text=$(tr -d '\r\0' <"$serial")
      restarts=$(grep -c "^devmgr: $driver for .* started again" <<<"$text")
      other=$(grep '^ERROR' <<<"$text" | grep -v "^ERROR: $driver: " | head -1 | cut -c1-140)
      case $fault in garbage|stuck|reset) want=1 ;; *) want=0 ;; esac
      missing=""; for say in "${says[@]+"${says[@]}"}"; do [ -n "$missing" ] || grep -qE "$say" <<<"$text" || missing=$say; done
      if [ $rc != 0 ] || ! grep -qx 'BOOT OK' <<<"$text"; then record fail "$suite" "$name" "$(grep -m1 -aE '^(ERROR|PANIC)' <<<"$text" | cut -c1-140) (exit status $rc; serial: $serial)"
      elif ! grep -Fxq "inject: ${fault^} committed" <<<"$text"; then record fail "$suite" "$name" "the driver never committed $fault (serial: $serial)"
      elif [ -n "$other" ]; then record fail "$suite" "$name" "outside the driver: $other (serial: $serial)"
      elif [ -n "$missing" ]; then record fail "$suite" "$name" "the driver never said: $missing (serial: $serial)"
      elif [ "$(grep -c "^TEST $driver\.[a-z_]* PASS" <<<"$text")" != 5 ]; then record fail "$suite" "$name" "blkcheck did not pass every check on the disk (serial: $serial)"
      elif [ "$restarts" != $want ]; then record fail "$suite" "$name" "the driver was started again $restarts times, not $want (serial: $serial)"
      else record pass "$suite" "$name"; fi
    done
  done
  # The network drivers (virtio-net, e1000e on an Intel 82574), under
  # netfault (eight pings in flight to the user-mode gateway, nothing
  # restarted on purpose): every ping after the driver's recovery must be
  # answered, the driver restarted at most once, and nothing but the driver
  # may say ERROR. Which request the fault lands on (a frame sent, or a
  # buffer offered for one to arrive in) decides whether the driver ends or
  # absorbs it.
  local nic
  for driver in "${network[@]+"${network[@]}"}"; do
    nic=virtio; [ "$driver" = e1000e ] && nic=e1000e
    for fault in "${faults[@]}"; do
      name=fault_${driver//-/_}_$fault
      log=$(logfile "$suite" "build.$name")
      img=$(build_system_image "$arch" "$log" "checks=netfault off=netd inject=$driver:$fault@50") || { record fail "$suite" "$name" "image build failed: $(first_error "$log") (log: $log)"; continue; }
      serial=$(logfile "$suite" "$name")
      "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp 2 --timeout "${SILICA_QEMU_TIMEOUT:-60}" --net user --nic "$nic" >"$serial.qemu" 2>&1
      rc=$?
      text=$(tr -d '\r\0' <"$serial")
      restarts=$(grep -c "^devmgr: $driver for .* started again" <<<"$text")
      other=$(grep '^ERROR' <<<"$text" | grep -v "^ERROR: $driver: " | head -1 | cut -c1-140)
      if [ $rc != 0 ] || ! grep -qx 'NETFAULT OK' <<<"$text"; then record fail "$suite" "$name" "$(grep -m1 -aE '^(ERROR|PANIC)' <<<"$text" | cut -c1-140) (exit status $rc; serial: $serial)"
      elif ! grep -Fxq "inject: ${fault^} committed" <<<"$text"; then record fail "$suite" "$name" "the driver never committed $fault (serial: $serial)"
      elif [ -n "$other" ]; then record fail "$suite" "$name" "outside the driver: $other (serial: $serial)"
      elif [ "$restarts" -gt 1 ]; then record fail "$suite" "$name" "the driver was started again $restarts times (serial: $serial)"
      else record pass "$suite" "$name"; fi
    done
  done
}

# run_recovery <arch> <suite> [nvme]: a driver killed under load
# (spec/MILESTONES.md M3). blkload writes every block of a scratch disk (a
# virtio disk, or with nvme namespace 1 of an NVMe controller) while the device manager
# restarts the disk's driver every 200 ms; it fails if a recovery took over
# 250 ms or a request was lost or failed. Then the host reads the scratch
# image: every block b must hold the words 4 << 40 | b << 16 | i (its last
# round's), so a write the guest was told had completed and was flushed,
# and was then lost or overtaken by an older one, fails it.
run_recovery() {
  local arch=$1 suite=$2 test=recovery${3:+_$3} log img serial rc scratch bad driver
  local -a disk
  log=$(logfile "$suite" "build.$test")
  img=$(build_system_image "$arch" "$log" "checks=load") || { record fail "$suite" "$test" "image build failed: $(first_error "$log") (log: $log)"; return 1; }
  serial=$(logfile "$suite" "$test")
  scratch=$(dirname "$serial")/$test.scratch.img
  rm -f "$scratch"; truncate -s 16M "$scratch" || { record fail "$suite" "$test" "cannot create $scratch"; return 1; }
  disk=(--disk "$scratch"); [ "${3:-}" != nvme ] || disk=(--nvme-disk "$scratch")
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp 2 --timeout "${SILICA_QEMU_TIMEOUT:-120}" "${disk[@]}" >"$serial.qemu" 2>&1
  rc=$?
  if [ $rc != 0 ] || ! serial_has "$serial" -x 'BLKLOAD OK'; then
    record fail "$suite" "$test" "$(tr -d '\r' <"$serial" | grep -m1 -aE '^(ERROR|PANIC)' | cut -c1-140) (exit status $rc; serial: $serial)"; return 1
  fi
  # The driver killed is the scratch disk's.
  driver=virtio-blk; [ "${3:-}" != nvme ] || driver=nvme
  if ! serial_has "$serial" "^devmgr: restarting $driver for "; then
    record fail "$suite" "$test" "blkload did not restart $driver (serial: $serial)"; return 1
  fi
  record pass "$suite" "$test"
  # Every block on the host's disk image, as written.
  bad=$(od -An -v -tx8 -w8 -N $((16384 * 512)) "$scratch" | awk '{ w = strtonum("0x" $1); b = int((NR - 1) / 64); i = (NR - 1) % 64; if (w != 4 * 2^40 + b * 65536 + i) { n++; if (n == 1) first = b } } END { if (n) printf "%d words wrong, the first in block %d", n, first }')
  if [ -z "$bad" ]; then record pass "$suite" "${test}_no_write_lost"
  else record fail "$suite" "${test}_no_write_lost" "the scratch disk read by the host: $bad ($scratch)"; fi
}
run_recovery_nvme() { run_recovery "$1" "$2" nvme; }

# run_svcload <arch> <suite>: services killed under their clients' load
# (spec/MILESTONES.md M3). svcload restarts partitions, logd, console and
# shell ten times each, 200 ms apart, while it and the shell use them, and
# fails if a recovery took over 250 ms, a read of a partition failed, a
# service failed, or the service manager has less memory to give out after
# than before. Besides its SVCLOAD OK: every numbered line it wrote while
# the log service restarted reached the console, in order and none missing,
# and the shell's banner is there once per start of it (the first and ten).
run_svcload() {
  local arch=$1 suite=$2 log img serial rc text n want
  log=$(logfile "$suite" build.svcload)
  img=$(build_system_image "$arch" "$log" "checks=services") || { record fail "$suite" svcload "image build failed: $(first_error "$log") (log: $log)"; return 1; }
  serial=$(logfile "$suite" svcload)
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp 2 --timeout "${SILICA_QEMU_TIMEOUT:-90}" >"$serial.qemu" 2>&1
  rc=$?
  text=$(tr -d '\r\0' <"$serial")
  if [ $rc = 0 ] && grep -qx 'SVCLOAD OK' <<<"$text" && ! grep -q '^ERROR' <<<"$text"; then record pass "$suite" svcload
  else record fail "$suite" svcload "$(grep -m1 -aE '^(ERROR|PANIC)' <<<"$text" | cut -c1-140) (exit status $rc; serial: $serial)"; fi
  want=$(sed -n 's/^svcload: \([0-9]*\) numbered lines written$/\1/p' <<<"$text")
  n=$(grep -cE '^svcload: line [0-9]+$' <<<"$text")
  if [ -n "$want" ] && [ "$n" = "$want" ] && grep -oE '^svcload: line [0-9]+$' <<<"$text" | awk '{ if ($3 != NR - 1) exit 1 }'; then
    record pass "$suite" svcload_no_line_lost
  else record fail "$suite" svcload_no_line_lost "${n} numbered lines reached the console, ${want:-an unknown number} were written (serial: $serial)"; fi
  # (After a prompt, on its line: the console's text reaches the serial line
  # through the log, which ends another writer's unfinished line first.)
  n=$(grep -c 'Silica\. Type help for the commands\.$' <<<"$text")
  if [ "$n" = 11 ]; then record pass "$suite" svcload_shell_restarts
  else record fail "$suite" svcload_shell_restarts "the shell's banner is there $n times, not 11 (serial: $serial)"; fi
}

# run_entropy <arch> <suite>: the entropy service (D14) on a machine with a
# virtio entropy device behind the IOMMU (virtio-rng, its driver): the
# service mixed the device in, and entropycheck's checks pass (answers not
# lopsided, never repeated, not across a restart of the service either).
run_entropy() {
  local arch=$1 suite=$2 log img serial rc text name
  log=$(logfile "$suite" build.entropy)
  img=$(build_system_image "$arch" "$log" "checks=entropy") || { record fail "$suite" entropy "image build failed: $(first_error "$log") (log: $log)"; return 1; }
  serial=$(logfile "$suite" entropy)
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp 2 --timeout "${SILICA_QEMU_TIMEOUT:-60}" \
    --device virtio-rng-pci,disable-legacy=on,iommu_platform=on >"$serial.qemu" 2>&1
  rc=$?
  text=$(tr -d '\r\0' <"$serial")
  for name in seeded_from_the_device answers_are_not_lopsided_and_never_repeat a_large_request_gets_the_most_there_is a_restarted_service_repeats_nothing; do
    if grep -qx "TEST entropy.$name PASS" <<<"$text"; then record pass "$suite" "entropy_$name"
    else record fail "$suite" "entropy_$name" "$(grep -m1 -a '^ERROR' <<<"$text" | cut -c1-140) (no PASS line; serial: $serial)"; fi
  done
  if [ $rc = 0 ] && grep -qx 'ENTROPY OK' <<<"$text" && grep -q '^virtio-rng: an entropy source, DMA confined by the IOMMU$' <<<"$text" && ! grep -q '^ERROR' <<<"$text"; then
    record pass "$suite" entropy
  else record fail "$suite" entropy "$(grep -m1 -aE '^(ERROR|PANIC)' <<<"$text" | cut -c1-140) (exit status $rc; serial: $serial)"; fi
}

# run_console_port <arch> <suite>: the shell through a virtual machine's
# console port (virtio-console, port 0, behind the IOMMU). The host types
# into the port once the console says it uses it (`echo through the port`,
# then twenty more lines in one burst while the shell is busy, then
# `shutdown`); what the port sends back must hold the shell's prompt and
# the echo, line ends as a terminal wants them; of the burst at most 16
# lines wait for the shell (the rest are dropped, and said: before, every
# line typed ahead was kept, without bound, and later run); and the machine
# must turn itself off when told to there.
run_console_port() {
  local arch=$1 suite=$2 log img serial rc port out
  log=$(logfile "$suite" build.console_port)
  img=$(build_system_image "$arch" "$log" "checks=") || { record fail "$suite" console_port "image build failed: $(first_error "$log") (log: $log)"; return 1; }
  serial=$(logfile "$suite" console_port)
  port=${serial%.log}.port
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp 2 --timeout "${SILICA_QEMU_TIMEOUT:-60}" --console-port "$port" \
    --port-type '^console: .* and the console port=\recho through the port\recho ta' \
    --port-type '^through the port$=01\recho ta02\recho ta03\recho ta04\recho ta05\recho ta06\recho ta07\recho ta08\recho ta09\recho ta10\recho ta11\recho ta12\recho ta13\recho ta14\recho ta15\recho ta16\recho ta17\recho ta18\recho ta19\recho ta20\r' --port-type '^ta16$=shutdown\r' >"$serial.qemu" 2>&1
  rc=$?
  out=$(tr -d '\0' <"$port")
  if [ $rc != 0 ]; then record fail "$suite" console_port "$(tr -d '\r' <"$serial" | grep -m1 -aE '^(ERROR|PANIC)' | cut -c1-140) (exit status $rc; serial: $serial)"
  elif ! grep -q '^virtio-console: port 0, DMA confined by the IOMMU' <(tr -d '\r' <"$serial"); then record fail "$suite" console_port "the driver did not say it runs confined (serial: $serial)"
  elif [[ "$out" != *$'silica> \r\nsilica> echo through the port\r\nthrough the port\r\nsilica> echo ta01\r\n'* ]]; then record fail "$suite" console_port "the empty line or queued command did not follow its prompt (port output: $port)"
  elif [[ "$out" != *$'\r\nta16\r\n'* || "$out" == *$'\r\nta18\r\n'* || "$out" != *"a line typed ahead was dropped"* ]]; then record fail "$suite" console_port "of twenty lines typed ahead, more than 16 waited for the shell, or none was said dropped (port output: $port)"
  elif ! grep -q '^init: shutting down' <(tr -d '\r' <"$serial"); then record fail "$suite" console_port "shutdown typed at the port did not shut down (serial: $serial)"
  else record pass "$suite" console_port; fi
}

# run_http <arch> <suite> [<name> <requests>]: TCP for programs. The
# system runs httpd as a check (`checks=http`) on QEMU's user-mode network
# with a host port forwarded to the guest's port 80; once it listens, the
# host sends <requests> (default 640: ten on each connection) requests of
# 1 KiB to 1 MiB over 64 kept-alive connections at once (host-tools' httpload),
# checking every body byte, then asks it to end. Every answer must be
# right, and httpd must end in order (`init: httpd passed`).
# run_http_load: the same with M4's exit test's 10,000 requests (2.3 GB:
# seconds under KVM, minutes emulated, so not in the fast tier).
run_http_load() { run_http "$1" "$2" http_load 10000; }
# The same two over an Intel 82574 (M4).
run_http_e1000e() { NIC=e1000e run_http "$1" "$2" http_e1000e; }
run_http_load_e1000e() { NIC=e1000e run_http "$1" "$2" http_load_e1000e 10000; }
# run_http_restart: M4's "killing the network stack under load": once httpd
# has answered 2,000 of 6,000 requests the host types `restart netd` at the
# shell (a keyboard, the console's); the connections then open are reset,
# the program's listener is set up again on the new stack (its events), and
# the load goes on. Judged: no answer ever wrong, every failure a
# connection's, at most 1 s without an answer, httpd ends in order. The
# second is a time, so it runs alone (QUIET_SYSTEM). (Its gaps of 1.1 to
# 5.9 s in one run of three to seven were netd's: a reset without ACK of a
# connection whose peer still waited in SYN-SENT, which the peer rightly
# dropped, 2026-11-24.)
run_http_restart() { run_http "$1" "$2" http_restart 6000 restart; }
# host_ports <n>: the first of <n> consecutive host ports that no TCP or UDP
# socket holds now, below the kernel's ephemeral range, so that no outbound
# connection of the host's can take one before QEMU or a host tool binds it
# (drawn from 20000-39999, a run once failed with QEMU unable to forward a
# port inside that range, 2026-11-24). Random, so that runs in parallel
# rarely draw the same ones.
host_ports() {
  local n=$1 low used p i k
  read -r low _ </proc/sys/net/ipv4/ip_local_port_range
  used=" $(ss -Htanu 2>/dev/null | awk '{k=split($5,a,":"); printf "%s ", a[k]}') "
  for i in $(seq 100); do
    p=$((10000 + (RANDOM * 32768 + RANDOM) % (low - 10000 - n)))
    for ((k = 0; k < n; k++)); do [[ $used == *" $((p + k)) "* ]] && continue 2; done
    echo "$p"; return 0
  done
  return 1
}
run_http() {
  local arch=$1 suite=$2 name=${3:-http} requests=${4:-640} mode=${5:-} log img serial rc port qemu load i httpload
  local -a extra=()
  [ "$name" = http ] && mode=pipeline
  [ "$mode" = restart ] && extra=(--device virtio-keyboard-pci,disable-legacy=on,iommu_platform=on --type '^httpd: 2000 answers$=restart netd\n')
  log=$(logfile "$suite" "build.$name")
  img=$(build_system_image "$arch" "$log" "checks=http httpd.quit=allowed") || { record fail "$suite" "$name" "image build failed: $(first_error "$log") (log: $log)"; return 1; }
  httpload=$(host_tool httpload "$log") || { record fail "$suite" "$name" "httpload did not build: $(first_error "$log") (log: $log)"; return 1; }
  serial=$(logfile "$suite" "$name")
  # A host port of this run's own (runs in parallel must not share one).
  port=$(host_ports 1) || { record fail "$suite" "$name" "no free host port below the ephemeral range"; return 1; }
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp 2 --timeout "${SILICA_QEMU_TIMEOUT:-180}" \
    --net "user:$port-80" --nic "${NIC:-virtio}" ${SILICA_HTTP_CAPTURE:+--capture "$SILICA_HTTP_CAPTURE"} "${extra[@]+"${extra[@]}"}" >"$serial.qemu" 2>&1 &
  qemu=$!
  for i in $(seq 600); do
    serial_has "$serial" '^httpd: listening on port 80' && break
    kill -0 $qemu 2>/dev/null || break
    sleep 0.1
  done
  if ! serial_has "$serial" '^httpd: listening on port 80'; then
    kill $qemu 2>/dev/null; wait $qemu
    record fail "$suite" "$name" "httpd never listened: $(tr -d '\r' <"$serial" | grep -m1 -aE '^(ERROR|PANIC)' | cut -c1-140) (serial: $serial)"
    return 1
  fi
  load=$("$httpload" "$port" "$requests" 64 $mode 2>&1); local lrc=$?
  printf '%s\n' "$load" >"${serial%.log}.load"
  wait $qemu; rc=$?
  if [ $lrc != 0 ]; then record fail "$suite" "$name" "$(head -2 <<<"$load" | tr '\n' ' ' | cut -c1-200) (serial: $serial)"
  elif [ $rc != 0 ] || ! serial_has "$serial" '^init: httpd passed'; then
    record fail "$suite" "$name" "httpd did not end in order: $(tr -d '\r' <"$serial" | grep -m1 -aE '^(ERROR|PANIC|httpd)' | cut -c1-140) (exit status $rc; serial: $serial)"
  elif [ "$mode" = restart ] && ! serial_has "$serial" '^init: netd restarted, as asked'; then
    record fail "$suite" "$name" "netd was never restarted (serial: $serial)"
  elif serial_has "$serial" '^ERROR'; then record fail "$suite" "$name" "$(tr -d '\r' <"$serial" | grep -m1 -a '^ERROR' | cut -c1-140)"
  else record pass "$suite" "$name"; fi
}

# run_http_quit <arch> <suite>: `GET /quit` from any peer on a machine
# whose command line does not allow it (no `httpd.quit=allowed`): httpd
# answers 404, serves the same connection after it, and says once that it
# refused; then a key typed at the shell turns the machine off, httpd still
# running. (Before, any peer's `GET /quit` ended the service.)
run_http_quit() {
  local arch=$1 suite=$2 log img serial rc port qemu load i httpload
  log=$(logfile "$suite" build.http_quit)
  img=$(build_system_image "$arch" "$log" "checks=http") || { record fail "$suite" http_quit "image build failed: $(first_error "$log") (log: $log)"; return 1; }
  httpload=$(host_tool httpload "$log") || { record fail "$suite" http_quit "httpload did not build: $(first_error "$log") (log: $log)"; return 1; }
  serial=$(logfile "$suite" http_quit)
  port=$(host_ports 1) || { record fail "$suite" http_quit "no free host port below the ephemeral range"; return 1; }
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp 2 --timeout "${SILICA_QEMU_TIMEOUT:-60}" \
    --net "user:$port-80" --nic "${NIC:-virtio}" --device virtio-keyboard-pci,disable-legacy=on,iommu_platform=on \
    --type '^httpd: GET /quit refused=shutdown\n' >"$serial.qemu" 2>&1 &
  qemu=$!
  for i in $(seq 600); do
    serial_has "$serial" '^httpd: listening on port 80' && break
    kill -0 $qemu 2>/dev/null || break
    sleep 0.1
  done
  if ! serial_has "$serial" '^httpd: listening on port 80'; then
    kill $qemu 2>/dev/null; wait $qemu
    record fail "$suite" http_quit "httpd never listened: $(tr -d '\r' <"$serial" | grep -m1 -aE '^(ERROR|PANIC)' | cut -c1-140) (serial: $serial)"
    return 1
  fi
  load=$("$httpload" "$port" 0 0 quit-refused 2>&1); local lrc=$?
  wait $qemu; rc=$?
  if [ $lrc != 0 ]; then record fail "$suite" http_quit "$(head -2 <<<"$load" | tr '\n' ' ' | cut -c1-200) (serial: $serial)"
  elif serial_has "$serial" '^init: httpd (ended|passed)'; then record fail "$suite" http_quit "httpd ended on a peer's GET /quit (serial: $serial)"
  elif [ $rc != 0 ] || ! serial_has "$serial" '^init: shutting down'; then
    record fail "$suite" http_quit "the machine was not turned off from the shell after the refusal (exit status $rc; serial: $serial)"
  elif serial_has "$serial" '^ERROR'; then record fail "$suite" http_quit "$(tr -d '\r' <"$serial" | grep -m1 -a '^ERROR' | cut -c1-140)"
  else record pass "$suite" http_quit; fi
}


# run_remote <arch> <suite>: remote management (M4: "accepts a remote
# management session that can inspect, restart and update any service").
# The image is provisioned as an installer would: a machine key and one
# owner (remote.key, remote.owners); the system stays up and the host's
# silica-remote, holding the owner's key, does everything over QEMU's
# user-mode network: lists the services, describes one, reads a log,
# restarts the log service; starts httpd, updates it while it serves to a
# program that differs in its bytes (served, checked by its hash), then to
# bytes that are no program (refused) and to one that faults at its first
# instruction (on trial: the program before it is put back by itself), and
# reverts it to the boot archive's; a stranger's key and a wrong machine key
# get nothing. Then it shuts the machine down. Each step's failure is said.
run_remote() {
  local arch=$1 suite=$2 log img serial rc port web qemu dir rmt owner machine stranger httpd out why="" i probe watcher prober n0
  log=$(logfile "$suite" build.remote)
  rmt=$(host_tool silica-remote "$log") && httpload=$(host_tool httpload "$log") && probe=$(host_tool remoteprobe "$log") || { record fail "$suite" remote "the host's tools did not build: $(first_error "$log") (log: $log)"; return 1; }
  dir=${UNIT_DIR:-$RUN}/remote; rm -rf "$dir"; mkdir -p "$dir"
  owner=$("$rmt" keygen "$dir/owner.key") && machine=$("$rmt" keygen "$dir/machine.key") && stranger=$("$rmt" keygen "$dir/stranger.key") && watcher=$("$rmt" keygen "$dir/watcher.key") \
    || { record fail "$suite" remote "silica-remote keygen failed"; return 1; }
  printf '# who may manage this machine\n%s test-owner\n%s watcher observe\n' "$owner" "$watcher" >"$dir/owners"
  img=$(SYSTEM_FILES="remote.key=$dir/machine.key remote.owners=$dir/owners" build_system_image "$arch" "$log" "checks= httpd.quit=allowed remote.idle=6") \
    && httpd=$(system_program "$arch" httpd "$log") || { record fail "$suite" remote "image build failed: $(first_error "$log") (log: $log)"; return 1; }
  # Two new programs for httpd: the same code with bytes after it (an ELF
  # file's loader reads only what its headers name), and one whose entry
  # point is an address nothing is mapped at.
  { cat "$httpd"; printf 'a new version of httpd, for the remote management test\n'; } >"$dir/httpd-new.elf"
  cp "$httpd" "$dir/httpd-faults.elf" && printf '\000\020\000\000\000\000\000\000' | dd of="$dir/httpd-faults.elf" bs=1 seek=24 conv=notrunc status=none
  printf 'not a program\n' >"$dir/notes.txt"
  serial=$(logfile "$suite" remote)
  port=$(host_ports 2) || { record fail "$suite" remote "no free host ports below the ephemeral range"; return 1; }
  web=$((port + 1))
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp 2 --timeout "${SILICA_QEMU_TIMEOUT:-180}" \
    --net "user:$port-22,$web-80" --nic "${NIC:-virtio}" --console-port "$serial.port" \
    --port-type '^remote: test-owner asks the service manager to start httpd=log remote\r' >"$serial.qemu" 2>&1 &
  qemu=$!
  for i in $(seq 600); do
    serial_has "$serial" '^remote: listening on port 22' && break
    kill -0 $qemu 2>/dev/null || break
    sleep 0.1
  done
  if ! serial_has "$serial" '^remote: listening on port 22'; then
    kill $qemu 2>/dev/null; wait $qemu
    record fail "$suite" remote "the remote service never listened: $(tr -d '\r' <"$serial" | grep -m1 -aE '^(ERROR|PANIC|remote)' | cut -c1-140) (serial: $serial)"
    return 1
  fi
  R() { "$rmt" -i "$dir/owner.key" -m "$machine" "127.0.0.1:$port" "$@" 2>&1; }
  # until <pattern> [<n>]: wait (at most 30 s) for the serial line to appear
  # <n> times.
  until_seen() { local k; for k in $(seq 300); do [ "$(tr -d '\r' <"$serial" | grep -acE "$1")" -ge "${2:-1}" ] && return 0; sleep 0.1; done; return 1; }
  step() { [ -n "$why" ] || why=$1; }
  hash_of() { "$rmt" hash "$1" | cut -c1-16; }
  # lone_cr <text>: whether a carriage return in it ends no line (a command's
  # output lost its last line end to $(...)).
  lone_cr() { local t="$1"$'\n'; t=${t//$'\r\n'/}; [[ $t == *$'\r'* ]]; }
  out=$(R services); printf '%s\n' "$out" >"$dir/services.1"
  grep -qE '^remote +running' <<<"$out" && grep -qE '^netd +running .* silica.net.Tcp' <<<"$out" || step "services did not list remote and netd running: $(head -3 <<<"$out" | tr '\n' ' ')"
  grep -qE "^httpd +stopped .* $(hash_of "$httpd")\$" <<<"$out" || step "services did not show httpd stopped with the boot archive's program $(hash_of "$httpd")"
  out=$(R describe netd); grep -q '^process netd: ' <<<"$out" || step "describe netd said: $(head -1 <<<"$out")"
  out=$(R log remote); grep -q 'listening on port 22' <<<"$out" || step "log remote said: $(head -1 <<<"$out")"
  out=$(R logs); grep -q '^netd ' <<<"$out" || step "logs did not name netd: $(head -1 <<<"$out")"
  out=$(R memory); grep -q '^free [0-9]* KiB' <<<"$out" || step "memory said: $out"
  R restart logd >/dev/null && until_seen '^init: logd restarted, as asked' && serial_has "$serial" '^remote: test-owner asks the service manager to restart logd' \
    || step "restart logd: not seen restarted, or not in the log as the owner's"
  # Strangers: an owner the machine does not know, and a machine that is not
  # the one whose key the owner holds.
  out=$("$rmt" -i "$dir/stranger.key" -m "$machine" "127.0.0.1:$port" services 2>&1) && step "a stranger's key was served: $out"
  until_seen "is no owner's" || step "the machine did not say that it closed on a stranger's key"
  out=$("$rmt" -i "$dir/owner.key" -m "$stranger" "127.0.0.1:$port" services 2>&1) && step "a session to a wrong machine key was served: $out"
  until_seen 'its handshake did not open' || step "the machine did not say that a handshake for another key did not open"
  # Someone who recorded an owner's first message replays it on nine
  # connections, each then trickling a frame that never ends: the owner is
  # still served, nobody is said to have connected but the owner, and the
  # machine answers no replay with a byte, closing each at once: as a
  # replay (its time is no later than the last taken from the owner), or as
  # a stranger making room for newer ones (before: each replay was answered
  # and an open session, held an hour by any byte, eight of them locking
  # the owners out).
  n0=$(tr -d '\r' <"$serial" | grep -ac '^remote: test-owner connected from')
  "$probe" -i "$dir/owner.key" -m "$machine" "127.0.0.1:$port" replay 9 14 >"$dir/replay.out" 2>&1 &
  prober=$!
  sleep 1
  out=$(R services) || step "the owner was not served while nine replayed handshakes were held: $out"
  wait $prober || step "replayed handshakes: $(tail -1 "$dir/replay.out")"
  [ "$(tr -d '\r' <"$serial" | grep -ac 'made no later than the last taken from them')" -ge 1 ] \
    || step "the machine did not refuse the replayed handshakes as replays: $(tail -1 "$dir/replay.out")"
  [ "$(tr -d '\r' <"$serial" | grep -ac '^remote: test-owner connected from')" = $((n0 + 1)) ] \
    || step "a replayed handshake was taken for the owner connecting (the log says so more than once)"
  # An owner the owners file gives `observe` alone sees, and changes nothing.
  W() { "$rmt" -i "$dir/watcher.key" -m "$machine" "127.0.0.1:$port" "$@" 2>&1; }
  out=$(W services); grep -qE '^logd +running' <<<"$out" || step "an owner who may observe did not see the services: $(head -1 <<<"$out")"
  out=$(W log remote); grep -q "may not make call\\|test-owner connected" <<<"$out" || step "an owner who may observe did not read a log: $(head -1 <<<"$out" | cat -v)"
  out=$(W restart logd) && step "an owner who may only observe restarted logd: $out"
  grep -q 'Refused' <<<"$out" || step "an owner who may only observe was refused a restart, but not as refused: $out"
  until_seen '^remote: watcher may not make call' || step "the machine did not say it refused the watcher's call"
  # Connections that never say a word, nine of them, and an owner's own
  # session that, once proven, starts a frame it never finishes: the owner
  # is still served, and the machine closes each (the silent ones within the
  # 10 s to prove an owner, the trickling session at its idle limit, 6 s on
  # this machine's command line: bytes are not messages).
  "$probe" -i "$dir/owner.key" -m "$machine" "127.0.0.1:$port" silent 9 14 >"$dir/silent.out" 2>&1 &
  prober=$!
  "$probe" -i "$dir/owner.key" -m "$machine" "127.0.0.1:$port" trickle-session 10 >"$dir/trickle.out" 2>&1 &
  local trickler=$!
  sleep 1
  out=$(R memory) || step "the owner was not served while nine silent connections were held: $out"
  wait $prober || step "silent connections: $(tail -1 "$dir/silent.out")"
  wait $trickler || step "an owner's session trickling a frame: $(tail -1 "$dir/trickle.out")"
  until_seen "^remote: test-owner's session from .* closed: no message for 6 s" || step "the machine did not say it closed the trickling session"
  # A service's name with a terminal's escapes, an OSC title and a carriage
  # return in it: what the machine logs of it reaches no terminal as
  # anything but text, checked on the bytes each sends: the serial console
  # (logd), the console port (the shell's `log remote`, typed there when the
  # line is logged, through the console) and the owner's terminal (the host
  # tool's `log`).
  out=$(R start $'httpd\e]0;owned\a\rforged line') && step "a service named with escapes was started: $out"
  until_seen 'asks the service manager to start httpd\?\]0;owned\?\?forged line' || step "the machine did not log the escaped name as text"
  [ "$(grep -a 'service manager to start httpd' "$serial" | sed 's/\r$//' | grep -ac $'\e\|\a\|\r')" = 0 ] \
    || step "an escape or a carriage return a session sent reached the machine's serial console"
  out=$(R log remote); grep -qF 'start httpd?]0;owned??forged line' <<<"$out" && ! grep -q $'\e\|\a' <<<"$out" && ! lone_cr "$out" \
    || step "the remote log reached the owner's terminal with its escapes: $(grep -a 'owned' <<<"$out" | cat -v | head -1)"
  # httpd: started, then updated while it serves.
  R start httpd >/dev/null && until_seen '^httpd: listening on port 80' || step "start httpd: it never listened"
  out=$(R update httpd "$dir/httpd-new.elf") || step "update httpd: $out"
  until_seen '^init: httpd started on its new program' && until_seen '^httpd: listening on port 80' 2 || step "httpd was not started on its new program"
  out=$("$httpload" "$web" 64 4 2>&1) || step "the updated httpd did not serve: $out"
  until_seen '^init: httpd ended' || step "the updated httpd did not end in order"
  out=$(R services); grep -qE "^httpd +stopped .* $(hash_of "$dir/httpd-new.elf") \(updated\)\$" <<<"$out" || step "services did not show httpd on its new program: $(grep '^httpd' <<<"$out")"
  # Bytes that are no program: refused, nothing changes. Sent while another
  # session holds on after a piece of its own was refused: a refused piece
  # takes no staging lock (before, it kept every other owner from sending
  # a program until its session ended).
  "$probe" -i "$dir/owner.key" -m "$machine" "127.0.0.1:$port" stage-hold 20 >"$dir/stage.out" 2>&1 &
  prober=$!
  for i in $(seq 100); do grep -q 'was refused' "$dir/stage.out" && break; kill -0 $prober 2>/dev/null || break; sleep 0.1; done
  grep -q 'was refused' "$dir/stage.out" || step "a piece past the largest program: $(tail -1 "$dir/stage.out")"
  out=$(R update httpd "$dir/notes.txt") && step "a text file was installed as httpd"
  grep -q 'NotAProgram' <<<"$out" || step "a text file as httpd was refused, but not as no program: $out"
  kill $prober 2>/dev/null; wait $prober 2>/dev/null
  # A program that faults at once: the one before it comes back.
  R update httpd "$dir/httpd-faults.elf" >/dev/null || step "update httpd to the faulting program was refused"
  R start httpd >/dev/null
  until_seen "^init: httpd's new program failed within 10 s of its update" && until_seen '^init: httpd started again on the program before its update' \
    && until_seen '^httpd: listening on port 80' 3 || step "the faulting update of httpd was not undone"
  out=$(R services); grep -qE "^httpd +running .* $(hash_of "$dir/httpd-new.elf") \(updated\)\$" <<<"$out" || step "after the faulting update, httpd does not run the program before it: $(grep '^httpd' <<<"$out")"
  out=$("$httpload" "$web" 64 4 2>&1) || step "httpd did not serve after its faulting update was undone: $out"
  until_seen '^init: httpd ended' 2 || step "httpd did not end in order after the undone update"
  R revert httpd >/dev/null || step "revert httpd was refused"
  out=$(R services); grep -qE "^httpd +stopped .* $(hash_of "$httpd")\$" <<<"$out" || step "after revert, httpd does not have the boot archive's program: $(grep '^httpd' <<<"$out")"
  # The session's own service: its update ends the session that asked for
  # it, and the client asks a new one what runs.
  { cat "$(system_program "$arch" remote "$log")"; printf 'a new version of remote\n'; } >"$dir/remote-new.elf"
  out=$(R update remote "$dir/remote-new.elf") && grep -q '^remote runs the program sent' <<<"$out" || step "update remote (the session's own service): $out"
  until_seen '^init: remote started on its new program' || step "remote was not started on its new program"
  R shutdown >/dev/null
  wait $qemu; rc=$?
  # What the shell's `log remote` sent to the console port: the escaped
  # name as text, and from the command on no escape, bell or lone carriage
  # return (the firmware's own escapes come before it).
  out=$(tr -d '\0' <"$serial.port"); out=${out#*silica> log remote}
  [[ $out == *'start httpd?]0;owned??forged line'* && $out != *$'\e'* && $out != *$'\a'* ]] && ! lone_cr "$out" \
    || step "the shell's log reached the console port with its escapes: $(grep -a 'owned' <<<"$out" | cat -v | head -1) (port: $serial.port)"
  if [ -n "$why" ]; then record fail "$suite" remote "$why (serial: $serial)"
  elif [ $rc != 0 ] || ! serial_has "$serial" '^init: shutting down' || ! serial_has "$serial" '^remote: test-owner asks the service manager to shut down the machine'; then
    record fail "$suite" remote "the machine was not shut down from the session (exit status $rc; serial: $serial)"
  elif serial_has "$serial" -E '^(ERROR|PANIC)'; then record fail "$suite" remote "$(tr -d '\r' <"$serial" | grep -m1 -aE '^(ERROR|PANIC)' | cut -c1-140) (serial: $serial)"
  else record pass "$suite" remote; fi
}

# run_interop <arch> <suite>: TCP between the host's own Linux stack and
# netd's (M4: "interop suite green against the host Linux stack";
# spec/TESTING.md: "interop against the host Linux stack over TAP"). The
# guest has a static address on a tap interface of this run's own, the host
# the other end of it, and httpd runs as the check; host-tools' tcpinterop
# drives every case three times: on a plain path; with the host's route
# advertising a 536-byte MSS and an 8 KiB window (`ip route ... advmss
# window`, so netd must segment small and wait for the window); and with
# both directions delayed 1 ms, 2% lost, 1% duplicated and 10% reordered
# (netem, the guest's direction through an ifb). Then httpd is asked to end
# and the machine turns off. Needs passwordless sudo, as the benchmark's tap
# does; without it the test fails and says so.
run_interop() {
  local arch=$1 suite=$2 log img serial rc qemu tool n host guest tap ifb why="" out i
  log=$(logfile "$suite" build.interop)
  sudo -n true 2>/dev/null || { record fail "$suite" interop "needs passwordless sudo for its tap interface and the impairments on it"; return 1; }
  tool=$(host_tool tcpinterop "$log") || { record fail "$suite" interop "tcpinterop did not build: $(first_error "$log") (log: $log)"; return 1; }
  n=$((20 + ($$ + RANDOM) % 200)); host=10.211.$n.1; guest=10.211.$n.2; tap=siop$n; ifb=sifb$n
  img=$(build_system_image "$arch" "$log" "checks=http httpd.quit=allowed netd.address=$guest/24 netd.router=$host") \
    || { record fail "$suite" interop "image build failed: $(first_error "$log") (log: $log)"; return 1; }
  iop_down() {
    sudo -n tc qdisc del dev "$tap" root 2>/dev/null; sudo -n tc qdisc del dev "$tap" ingress 2>/dev/null
    sudo -n ip link del "$ifb" 2>/dev/null; sudo -n ip link del "$tap" 2>/dev/null
  }
  iop_down
  sudo -n ip tuntap add dev "$tap" mode tap user "$(id -un)" && sudo -n ip addr add "$host/24" dev "$tap" \
    && sudo -n ip link set "$tap" up && sudo -n sysctl -q -w "net.ipv6.conf.$tap.disable_ipv6=1" \
    || { iop_down; record fail "$suite" interop "could not make the tap interface $tap"; return 1; }
  serial=$(logfile "$suite" interop)
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp 2 --timeout "${SILICA_QEMU_TIMEOUT:-600}" \
    --net "tap:$tap" --nic "${NIC:-virtio}" >"$serial.qemu" 2>&1 &
  qemu=$!
  for i in $(seq 600); do
    serial_has "$serial" '^httpd: listening on port 80' && break
    kill -0 $qemu 2>/dev/null || break
    sleep 0.1
  done
  if ! serial_has "$serial" '^httpd: listening on port 80'; then
    kill $qemu 2>/dev/null; wait $qemu; iop_down
    record fail "$suite" interop "httpd never listened: $(tr -d '\r' <"$serial" | grep -m1 -aE '^(ERROR|PANIC)' | cut -c1-140) (serial: $serial)"
    return 1
  fi
  phase() { out=$("$tool" "$guest" "$1" 2>&1); printf '%s\n' "$out" >>"${serial%.log}.interop"; [ -n "$why" ] || why=$(grep -m1 '^ERROR' <<<"$out"); return 0; }
  phase plain
  sudo -n ip route replace "$guest/32" dev "$tap" advmss 536 window 8192 && phase small_mss_and_window \
    || why=${why:-"could not set the route's MSS and window"}
  sudo -n ip route del "$guest/32" dev "$tap" 2>/dev/null
  local impair=(delay 1ms loss 2% duplicate 1% reorder 10% 50%)
  if sudo -n tc qdisc add dev "$tap" root netem "${impair[@]}" && sudo -n ip link add "$ifb" type ifb && sudo -n ip link set "$ifb" up \
      && sudo -n tc qdisc add dev "$tap" handle ffff: ingress \
      && sudo -n tc filter add dev "$tap" parent ffff: matchall action mirred egress redirect dev "$ifb" \
      && sudo -n tc qdisc add dev "$ifb" root netem "${impair[@]}"; then
    phase lossy
  else why=${why:-"could not impair the path (tc netem, ifb)"}; fi
  sudo -n tc qdisc del dev "$tap" root 2>/dev/null; sudo -n tc qdisc del dev "$tap" ingress 2>/dev/null
  phase quit
  wait $qemu; rc=$?
  iop_down
  if [ -n "$why" ]; then record fail "$suite" interop "$why (serial: $serial; cases: ${serial%.log}.interop)"
  elif [ $rc != 0 ] || ! serial_has "$serial" '^init: httpd passed'; then
    record fail "$suite" interop "httpd did not end in order (exit status $rc; serial: $serial)"
  elif serial_has "$serial" -E '^(ERROR|PANIC)'; then record fail "$suite" interop "$(tr -d '\r' <"$serial" | grep -m1 -aE '^(ERROR|PANIC)' | cut -c1-140) (serial: $serial)"
  else record pass "$suite" interop; fi
}

# run_idle <arch> <suite>: the idle server makes no periodic wake-ups (M4;
# spec/TESTING.md: "Idle wakeups over 60 s: 0 on the server image", observed
# from the host as the virtual processors' wake-ups from halt). The system
# boots with its services and the network (netd has its lease and the
# router answers), settles for 10 s, and KVM's count of halt wake-ups for the
# machine (debugfs, read with sudo) must not move over the next 60 s. On
# 2026-11-24 it moved by 200 a second: every device client looked every
# 10 ms for its driver's end; the kernel now tells it (CapNotice).
run_idle() {
  local arch=$1 suite=$2 log img serial qemu pid dir a b i
  log=$(logfile "$suite" build.idle)
  img=$(build_system_image "$arch" "$log" "checks=") || { record fail "$suite" idle "image build failed: $(first_error "$log") (log: $log)"; return 1; }
  serial=$(logfile "$suite" idle)
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp 2 --timeout 180 --net user >"$serial.qemu" 2>&1 &
  qemu=$!
  for i in $(seq 600); do
    serial_has "$serial" '^netd: the router 10\.0\.2\.2 answers a ping' && break
    kill -0 $qemu 2>/dev/null || break
    sleep 0.1
  done
  # The machine is ended by ending QEMU itself: qemu.sh then sees its
  # emulator gone and returns (killing qemu.sh alone left the emulator
  # running, the guest idling for ever; two were found an hour on).
  stop() { pkill -f "qemu-system-[a-z0-9_]*.*$serial" 2>/dev/null; wait $qemu 2>/dev/null; }
  if ! serial_has "$serial" '^netd: the router 10\.0\.2\.2 answers a ping'; then
    stop
    record fail "$suite" idle "the network never came up: $(tr -d '\r' <"$serial" | grep -m1 -aE '^(ERROR|PANIC)' | cut -c1-140) (serial: $serial)"; return 1
  fi
  sleep 10
  pid=$(pgrep -f "qemu-system-[a-z0-9_]*.*$serial" | head -1)
  dir=$(sudo -n ls /sys/kernel/debug/kvm/ 2>/dev/null | grep "^$pid-" | head -1)
  if [ -z "$pid" ] || [ -z "$dir" ]; then
    stop
    record fail "$suite" idle "cannot read KVM's statistics of the machine (needs KVM and sudo for /sys/kernel/debug/kvm; pid '${pid}')"; return 1
  fi
  a=$(sudo -n cat "/sys/kernel/debug/kvm/$dir/halt_wakeup"); sleep 60; b=$(sudo -n cat "/sys/kernel/debug/kvm/$dir/halt_wakeup")
  stop
  echo "idle: $((b - a)) wake-ups from halt in 60 s" >>"$serial.qemu"
  if [ "$((b - a))" = 0 ]; then record pass "$suite" idle
  else record fail "$suite" idle "$((b - a)) wake-ups from halt in 60 s of an idle system, not 0 (serial: $serial)"; fi
}

# run_ntp <arch> <suite>: the wall clock set from a time server (M4: "syncs
# time"). A server on the host's loopback (host-tools' sntpd), reached from the
# guest as 10.0.2.2, answers with the host's time plus 1,000 s; the system
# is booted with `netd.ntp=10.0.2.2:<port>`. The network stack must say it
# set the clock, by about +1,000 s, to the server's time (within 3 s).
run_ntp_e1000e() { NIC=e1000e run_ntp "$@"; }
run_ntp() {
  local arch=$1 suite=$2 log img serial rc port server line at want moved sntpd nic=${NIC:-virtio} name=ntp
  [ "$nic" = virtio ] || name=ntp_$nic
  port=$(host_ports 1) || { record fail "$suite" "$name" "no free host port below the ephemeral range"; return 1; }
  log=$(logfile "$suite" "build.$name")
  img=$(build_system_image "$arch" "$log" "checks= netd.ntp=10.0.2.2:$port") || { record fail "$suite" "$name" "image build failed: $(first_error "$log") (log: $log)"; return 1; }
  sntpd=$(host_tool sntpd "$log") || { record fail "$suite" "$name" "sntpd did not build: $(first_error "$log") (log: $log)"; return 1; }
  serial=$(logfile "$suite" "$name")
  "$sntpd" "$port" 1000 >"${serial%.log}.sntpd" 2>&1 &
  server=$!
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp 2 --timeout "${SILICA_QEMU_TIMEOUT:-60}" --net user --nic "$nic" \
    --until "^netd: the wall clock is .* from 10\\.0\\.2\\.2:$port " >"$serial.qemu" 2>&1
  rc=$?
  kill $server 2>/dev/null; wait $server 2>/dev/null
  want=$(( $(date -u +%s) + 1000 ))
  line=$(tr -d '\r' <"$serial" | grep -m1 -a "^netd: the wall clock is .* from 10\\.0\\.2\\.2:$port ")
  at=$(sed -n 's/^netd: the wall clock is \([0-9T:-]*Z\) from .*/\1/p' <<<"$line"); at=$( [ -n "$at" ] && date -u -d "$at" +%s 2>/dev/null)
  moved=$(sed -n 's/.*(moved \([-+][0-9]*\) ms.*/\1/p' <<<"$line")
  if [ $rc != 0 ] || [ -z "$at" ]; then record fail "$suite" "$name" "the clock was never set from the server: $(tr -d '\r' <"$serial" | grep -m1 -aE '^(ERROR|netd: )' | cut -c1-120) (exit status $rc; serial: $serial)"
  elif [ $((at - want)) -gt 3 ] || [ $((want - at)) -gt 3 ] || [ "${moved#+}" -lt 997000 ] || [ "${moved#+}" -gt 1003000 ]; then
    record fail "$suite" "$name" "set to $at, moved ${moved} ms, against the server's $want and +1000000 ms (serial: $serial)"
  elif serial_has "$serial" '^ERROR'; then record fail "$suite" "$name" "$(tr -d '\r' <"$serial" | grep -m1 -a '^ERROR' | cut -c1-140)"
  else record pass "$suite" "$name"; fi
}

# run_shutdown <arch> <suite>: the power button shuts the system down in
# order. The system stays up (no checks); once the device manager says the
# button is armed the host presses it (QEMU's system_powerdown, an ACPI
# fixed event; a press before that is cleared with the button's old status,
# as a machine keeps the press that turned it on); the
# device manager hears it and asks the service manager to shut down, which
# stops the services last-started first and turns the machine off.
run_shutdown() {
  local arch=$1 suite=$2 log img serial rc
  log=$(logfile "$suite" build.shutdown)
  img=$(build_system_image "$arch" "$log" "checks=") || { record fail "$suite" shutdown "image build failed: $(first_error "$log") (log: $log)"; return 1; }
  serial=$(logfile "$suite" shutdown)
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp 2 --timeout "${SILICA_QEMU_TIMEOUT:-60}" \
    --on '^devmgr: the power button is armed$=system_powerdown' >"$serial.qemu" 2>&1
  rc=$?
  if [ $rc = 0 ] && serial_has "$serial" '^init: shutting down' && serial_has "$serial" '^init: devmgr stopped' \
      && ! serial_has "$serial" '^ERROR'; then record pass "$suite" shutdown
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
  local arch=$1 suite=$2 log img serial rc shot text bad lines
  log=$(logfile "$suite" build.console)
  img=$(build_system_image "$arch" "$log" "checks=") || { record fail "$suite" console "image build failed: $(first_error "$log") (log: $log)"; return 1; }
  serial=$(logfile "$suite" console)
  shot=$(cd "$(dirname "$serial")" && pwd)/console.ppm
  rm -f "$shot"
  # The machine: 00:01.0 the disk, 00:02.0 the display, 00:03.0 the keyboard.
  # (Another program's line may fall between a prompt and what is typed:
  # the prompt is shown again below it, so the command still reads whole.)
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp 2 --timeout "${SILICA_QEMU_TIMEOUT:-60}" --no-exit-device \
    --device VGA --device virtio-keyboard-pci,disable-legacy=on,iommu_platform=on \
    --type '^silica> $=log console\n' --type '^  silica> log console$=services\n' \
    --type '^  shell +running=caps console\n' --type '^  thread .* on processor=log devmgr\n' --type '^  devmgr: 00:01\.0 =caps 00:01.0\n' \
    --type '^process virtio-blk@00:01\.0: [0-9]+ capabilities, [0-9]+ threads$=trace\n' \
    --type '^           seen by this client +[0-9]+ ns$=devices\n' \
    --type '^  00:03\.0 input +virtio-input$=restart-driver 0001:00:03.0\n' \
    --type '^restart-driver: 0001:00:03\.0: Error\(NoSuchDevice\)$=restart-driver 00:03.0\n' \
    --type "^console: the keyboard's driver ended; reading its successor\$=restart-driver 0000:00:02.0\n" \
    --type "^console: the display's driver ended; showing on its successor\$=echo back\n" \
    --on "^back\$=screendump $shot" --type '^back$=log devmgr/fbdisplay@00:02.0\n' \
    --type '^  fbdisplay: [0-9]+x[0-9]+, =shutdown\n' >"$serial.qemu" 2>&1
  rc=$?
  text=$(tr -d '\r\0' <"$serial")
  bad=""
  [ $rc = 0 ] || bad="the machine was not turned off (exit status $rc)"
  for want in '^console: on the display and the serial line, reading the keyboard$' '^silica> services$' '^  console +running +failures 0  silica\.console\.Terminal$' \
              '^silica> log console$' '^  silica> log console$' '^silica> caps console$' '^process console: [0-9]+ capabilities, 1 threads$' '^  slot [0-9]+: Endpoint rights ' \
              '^silica> log devmgr$' '^  devmgr: 00:01\.0 1af4:1042 class 01\.00\.00' \
              '^silica> caps 00:01\.0$' '^process virtio-blk@00:01\.0: [0-9]+ capabilities, [0-9]+ threads$' \
              '^silica> trace$' '^  partition 0x800 \(EFI System\) opened through the block server' '^           taken by the driver +[0-9]+ ns$' \
              '^silica> devices$' '^  00:02\.0 display +fbdisplay$' '^  00:03\.0 input +virtio-input$' \
              '^restart-driver: 0001:00:03\.0: Error\(NoSuchDevice\)$' '^restart-driver: 00:03\.0: done$' \
              '^restart-driver: 0000:00:02\.0: done$' '^back$' '^silica> log devmgr/fbdisplay@00:02\.0$' \
              '^silica> shutdown$' '^init: shutting down'; do
    [ -n "$bad" ] || grep -qE "$want" <<<"$text" || bad="the serial log has no line matching: $want"
  done
  # A driver's log is one source across its restarts: the display's has
  # what both its drivers said, read in the shell (indented).
  [ -n "$bad" ] || [ "$(grep -cE '^  fbdisplay: [0-9]+x[0-9]+, ' <<<"$text")" = 2 ] ||
    bad="the display drivers' log, read in the shell, does not hold both drivers' first line: $(grep -E 'fbdisplay: [0-9]+x' <<<"$text" | tr '\n' '|')"
  [ -n "$bad" ] || ! grep -q '^ERROR' <<<"$text" || bad="$(grep -m1 '^ERROR' <<<"$text" | cut -c1-140)"
  # The picture (screen rows): the screen holds the shell's lines from the
  # banner to "back" (the serial line has the other programs' lines among
  # them, and a prompt they cut short shown again after them, so the line
  # it was cut from is one the screen lacks), maybe the next prompt.
  lines=$(sed -n '/^Silica\. Type help/,/^back$/p' <<<"$text" | grep -cvE '^((devmgr|virtio-input|fbdisplay|console|kernel|init|partitions|logd): |silica> $)')
  local screen
  if [ -z "$bad" ]; then
    if ! screen=$(host_tool screen "$log"); then bad="the screen check did not build: $(first_error "$log") (log: $log)"
    elif ! bad=$("$screen" rows "$shot" "$lines"); then bad=${bad:-the screen check failed with no reason}
    fi
  fi
  if [ -z "$bad" ]; then record pass "$suite" console
  else record fail "$suite" console "$bad (serial: $serial)"; fi
}

# run_typeahead <arch> <suite>: keys typed before the console has attached
# to the keyboard are not lost. The command is typed the moment the
# keyboard's driver says it is up, before the console can have connected
# (in CI the first key of a command typed then was lost, 2026-11-23: the
# driver dropped keys while it had no client); the shell must run it whole.
# The window is the guest's time from the driver's start to the console's
# connection against the harness's first key (it polls the serial log and
# types through the monitor): on a slow host, as the CI runner where it
# was seen, the keys land in it; on the reference host the console is
# there first, under KVM and under emulation alike, and the old driver
# passed 7 of 7 here. It is not a deterministic guard there.
run_typeahead() {
  local arch=$1 suite=$2 log img serial rc text bad=""
  log=$(logfile "$suite" build.typeahead)
  img=$(build_system_image "$arch" "$log" "checks=") || { record fail "$suite" typeahead "image build failed: $(first_error "$log") (log: $log)"; return 1; }
  serial=$(logfile "$suite" typeahead)
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp 2 --timeout "${SILICA_QEMU_TIMEOUT:-60}" --no-exit-device \
    --device virtio-keyboard-pci,disable-legacy=on,iommu_platform=on \
    --type '^virtio-input: =echo early\n' --type '^early$=shutdown\n' >"$serial.qemu" 2>&1
  rc=$?
  text=$(tr -d '\r\0' <"$serial")
  [ $rc = 0 ] || bad="the machine was not turned off (exit status $rc): $(grep -m1 '^ERROR' "$serial.qemu" | cut -c1-140)"
  [ -n "$bad" ] || grep -qx 'early' <<<"$text" || bad="the command typed before the console attached did not run whole: $(grep -E 'silica> .*(echo|cho|ho|early)' <<<"$text" | head -2 | tr '\n' '|')"
  [ -n "$bad" ] || ! grep -q '^ERROR' <<<"$text" || bad="$(grep -m1 '^ERROR' <<<"$text" | cut -c1-140)"
  if [ -z "$bad" ]; then record pass "$suite" typeahead
  else record fail "$suite" typeahead "$bad (serial: $serial)"; fi
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
    # Which condition failed, said: on 2026-11-23 CI failed power_reset with
    # nothing to say (status 0, and the uploaded serial log passed every
    # condition when read again).
    local why=""
    if [ $rc != 0 ]; then why="the machine did not turn itself off (exit status $rc)"
    elif ! grep -aExq $'BOOT OK\r?' "$serial"; then why="no BOOT OK line when the emulator had ended ($(wc -c <"$serial") bytes of serial; last: $(tr -d '\r' <"$serial" | grep -a . | tail -1 | cut -c1-80))"
    elif grep -aq '^ERROR' "$serial"; then why="$(grep -am1 '^ERROR' "$serial" | tr -d '\r' | cut -c1-140)"
    fi
    if [ -z "$why" ]; then record pass "$suite" $name
    else record fail "$suite" $name "$why (serial: $serial)"; fi
  done
}

# run_rogue <arch> <suite>: what a driver cannot do. The system image boots
# with a hostile driver in place of the disk's (driver=...=virtio-rogue), on
# the machine with an IOMMU. One result per check: the driver's own `TEST
# <name> PASS` lines, and three it cannot see for itself, taken from who
# enforces them: the kernel's line for each access and each interrupt
# message the IOMMU refused, and
# the device manager's line for the fault on writing configuration space.
# The system must have come up (BOOT OK) and nothing may have failed.
run_rogue() {
  rogue_on "$1" "$2" "" 1af4:1042 '00:01\.0'
}

# run_rogue_tcg <arch> <suite>: the hostile disk driver again under QEMU's
# emulated processor, where its device's forged interrupt message (one
# naming the I/O APIC's remapping entry) takes the device's ordinary path
# and the IOMMU must refuse it as from the wrong device: under KVM, QEMU's
# virtio-pci asserts on that refusal instead (hw/pci/msix.c), so that run
# does not try it.
run_rogue_tcg() {
  local SILICA_NO_KVM=1; export SILICA_NO_KVM
  rogue_on "$1" "$2" _tcg 1af4:1042 '00:01\.0'
}

# run_dhcp <arch> <suite>: the server's first step (M4). The system boots
# on QEMU's user-mode network with no checks; the network stack (netd)
# must take the interface, get 10.0.2.15/24 from the user-mode DHCP server
# with its router and DNS server, and find the router answering a ping.
# NIC=e1000e: the same over an Intel 82574 (recorded as dhcp_e1000e), as
# for the time server and HTTP checks below (M4: "runs the same tests over
# an e1000e interface").
run_dhcp_e1000e() { NIC=e1000e run_dhcp "$@"; }
run_dhcp() {
  local arch=$1 suite=$2 log img serial rc text bad="" nic=${NIC:-virtio} name=dhcp
  [ "$nic" = virtio ] || name=dhcp_$nic
  log=$(logfile "$suite" "build.$name")
  img=$(build_system_image "$arch" "$log" "checks=") || { record fail "$suite" "$name" "image build failed: $(first_error "$log") (log: $log)"; return 1; }
  serial=$(logfile "$suite" "$name")
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp 2 --timeout "${SILICA_QEMU_TIMEOUT:-60}" --net user --nic "$nic" \
    --until '^netd: the router 10\.0\.2\.2 answers a ping in [0-9]+ us$' >"$serial.qemu" 2>&1
  rc=$?
  text=$(tr -d '\r' <"$serial")
  [ $rc = 0 ] || bad="the router was never pinged: $(grep -m1 -E '^(ERROR|netd: )' <<<"$text" | tail -1 | cut -c1-140) (exit status $rc)"
  [ -n "$bad" ] || grep -qx 'netd: 10\.0\.2\.15/24 from DHCP server 10\.0\.2\.2, router 10\.0\.2\.2, DNS 10\.0\.2\.3, lease 86400 s' <<<"$text" ||
    bad="no lease of 10.0.2.15/24 with router 10.0.2.2 and DNS 10.0.2.3: $(grep -m1 '^netd: .* from DHCP' <<<"$text")"
  [ -n "$bad" ] || ! grep -q '^ERROR' <<<"$text" || bad="$(grep -m1 '^ERROR' <<<"$text" | cut -c1-140)"
  if [ -z "$bad" ]; then record pass "$suite" "$name"
  else record fail "$suite" "$name" "$bad (serial: $serial)"; fi
}

# run_rogue_net <arch> <suite>: the same hostile driver in the network
# device's place (on QEMU's user-mode network, behind the IOMMU): the
# network device's DMA must be confined as the disk's is.
run_rogue_net() {
  rogue_on "$1" "$2" _net 1af4:1041 '00:02\.0' --net user
}

# rogue_on <arch> <suite> <suffix> <vendor:device> <address regex> [qemu.sh arguments]
rogue_on() {
  local arch=$1 suite=$2 sfx=$3 id=$4 at=$5 log img serial rc name text want
  shift 5
  log=$(logfile "$suite" "build.rogue$sfx")
  img=$(build_system_image "$arch" "$log" "driver=$id=virtio-rogue checks=") || { record fail "$suite" "rogue$sfx" "image build failed: $(first_error "$log") (log: $log)"; return 1; }
  serial=$(logfile "$suite" "rogue$sfx")
  # The system stays up; the run ends when the driver's second run is over.
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp 2 --timeout "${SILICA_QEMU_TIMEOUT:-60}" \
    --until "^devmgr: virtio-rogue for $at ended with status 0" "$@" >"$serial.qemu" 2>&1
  rc=$?
  text=$(tr -d '\r\0' <"$serial")
  for name in rogue_other_device rogue_other_interrupt rogue_physical_address rogue_address_above_the_top \
              rogue_write_read_only rogue_recovers rogue_restart; do
    if grep -qx "TEST $name PASS" <<<"$text"; then record pass "$suite" "$name$sfx"
    else record fail "$suite" "$name$sfx" "$(grep -m1 -a "^ERROR: virtio-rogue: $name" <<<"$text" | cut -c1-160) (no PASS line; serial: $serial)"; fi
  done
  while IFS='|' read -r name want; do
    # The forged remapped interrupt is sent under TCG only (run_rogue_tcg).
    [ "$name" = rogue_interrupt_other_entry_refused ] && [ "$sfx" != _tcg ] && continue
    want=${want//%/$at}
    if grep -qE "$want" <<<"$text"; then record pass "$suite" "$name$sfx"
    else record fail "$suite" "$name$sfx" "the serial log has no line matching: $want (serial: $serial)"; fi
  done <<'CHECKS'
rogue_write_unmapped|^kernel: device % was refused a write at 0x100000 
rogue_read_unmapped|^kernel: device % was refused a read at 0x200000 
rogue_log_ring|^logd: the log ring of devmgr/virtio-rogue@% made no sense; what it held is skipped$
rogue_config_space|^devmgr: virtio-rogue for % touched memory it may not \(page fault\)
rogue_interrupt_other_entry_refused|^kernel: device % was refused interrupt entry 9 \(IOMMU fault reason 0x26\)$
CHECKS
  if [ $rc = 0 ] && grep -qx 'BOOT OK' <<<"$text" && ! grep -q '^ERROR' <<<"$text"; then record pass "$suite" "rogue_system_survives$sfx"; return 0; fi
  record fail "$suite" "rogue_system_survives$sfx" "$(grep -m1 -aE '^(ERROR|PANIC)' <<<"$text" | cut -c1-140) (exit status $rc; serial: $serial)"
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
  # A hang is a minute without a line (systest says every 10 s that it still
  # waits, and fails a program itself at its limits, which follow the
  # machine's pace); the total is only a backstop.
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --smp 8 --timeout "${SILICA_SYSTEST_TIMEOUT:-3600}" --quiet 60 >"$serial.qemu" 2>&1
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
  if [ $rc = 0 ] && serial_has "$serial" -x 'SYSTEST OK'; then
    [ "${#seen[@]}" = "$expected" ] && return 0
    record fail "$suite" systest "guest announced ${expected:-no} tests and reported ${#seen[@]} distinct passes (serial: $serial)"; return 1
  fi
  [ -x "$TOOLS/symbolize.sh" ] && "$TOOLS/symbolize.sh" --arch "$arch" "$serial" >"$serial.symbolized" 2>&1
  record fail "$suite" systest "the run did not end with SYSTEST OK: $(tr -d '\r' <"$serial" | grep -m1 -aE '^(ERROR|PANIC)' | cut -c1-140) (exit status $rc; serial: $serial)"
  return 1
}
