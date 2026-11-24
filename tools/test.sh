#!/usr/bin/env bash
# Host tests, target builds, QEMU guest tests and size checks.
#   test.sh [--fast | --full | --deep] [--repo <repo>] [--fresh] [--plan]
#   test.sh --guest NAME [--guest NAME]...
# A tier says what must hold; what runs is the part of it whose inputs
# changed since it last passed (lib/evidence.sh, spec/TESTING.md section 2).
# Each check names what it is a function of (the sources it builds, the
# harness that runs it, the emulator), and one that passed on exactly these
# inputs is read back instead of run: a second run of an unchanged tree
# takes seconds whatever the tier, and a change to the shell does not run
# the kernel's Miri again. What does run, runs at once where it can.
#   --fast   lint, host tests, builds, a boot and the system's guest tests
#   --full   every guest test on both architectures, the boot matrix, Miri,
#            loom and the tools' own tests
#   --deep   fuzzing, the benchmarks (tools/bench.sh) and the Kani proofs
#   --repo   limits the scope to one repository
#   --fresh  holds nothing: every check of the tier runs (a milestone's
#            exit; a doubt about the store)
#   --plan   runs nothing: what would run, how long it took the last time
#            and which of its inputs changed
#   --guest  runs just the named x86_64 guest test (repeatable), always: a
#            kernel test, or one of the system image's (SYSTEM_TESTS below,
#            faults or a reported fault case, svcload and systest; panic_backtrace, null_object_faults
#            and panic_screen)
# A check that judges a time (a scheduling latency, a recovery deadline) is
# contaminated by anything running beside it, so those run first, one at a
# time, before the rest run at once ("quiet": a test's line in the kernel's
# manifest says so, QUIET_SYSTEM below for the system image's).
# Output: one line per suite, one ERROR: line per failure, what ran and what
# was held, last line RESULT: pass=<n> fail=<n> skipped=<n> time=<s>.
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"
. "$TOOLS/lib/build.sh"
. "$TOOLS/lib/evidence.sh"
. "$TOOLS/lib/tests.sh"

tier=fast repo="" guests=()
while [ $# -gt 0 ]; do
  case "$1" in
    --fast) tier=fast; shift ;;
    --full) tier=full; shift ;;
    --deep) tier=deep; shift ;;
    --repo) repo=$2; shift 2 ;;
    --fresh) FRESH=1; shift ;;
    --plan) PLAN=1; shift ;;
    --guest) [ $# -ge 2 ] || die "--guest needs a test name"; guests+=("$2"); shift 2 ;;
    *) die "unknown argument $1" ;;
  esac
done
start=$(date +%s)
new_run
RES=$RUN/results.tsv; : >"$RES"
ms=$(milestone)
# One set of sources for the whole run: an image's pieces are built once.
PIECES_ONCE=1
evidence_init
# A test asked for by name is run: someone wants to see it.
[ "${#guests[@]}" -gt 0 ] && FRESH=1
# The Cargo [patch] file every checkout's builds read, written before
# anything runs at once.
[ "$PLAN" = 1 ] || { patch_config "${TMPDIR:-/tmp}/silica-patch.$$.toml"; PATCH_DONE=1; }

# The system image's guest tests (run_<name> in lib/tests.sh), and those of
# them that judge a time.
SYSTEM_TESTS=(system unconfined rogue rogue_tcg rogue_net dhcp ntp http power recovery entropy console_port shutdown console typeahead nvme net net_e1000e
  dhcp_e1000e ntp_e1000e http_e1000e net_recovery net_recovery_e1000e hotplug partitions
  recovery_nvme nvme_one_vector nvme_4k nvme_namespaces nvme_unservable hotplug_nvme_one_vector hotplug_nvme_4k hotplug_nvme_namespaces)
QUIET_SYSTEM=" recovery recovery_nvme net_recovery net_recovery_e1000e svcload http_restart "
# unit <quiet|any> <unit> <input>... -- <command>: a guest test. The run has
# two phases: the units that judge a time, one after another with nothing
# beside them; then all the others at once.
PHASE=rest
unit() {
  local q=$1; shift
  if [ "$q" = quiet ]; then [ "$PHASE" != quiet ] || held "$@"
  else [ "$PHASE" != rest ] || held_bg "$@"; fi
  return 0
}

# What every unit that builds or boots is a function of, beside its sources.
LIB=(path:os:tools/lib/common.sh path:os:tools/lib/build.sh)
# gin <arch> [system]: sets GIN, the inputs of a guest test on that
# architecture: the kernel (and the system's programs), the image tool, the
# emulator with its firmware, and the tools that boot it and read its log.
gin() {
  GIN=(repo+:kernel crate:os:silica-image "${LIB[@]}" path:os:tools/qemu.sh path:os:tools/symbolize.sh "host:qemu-$1" env:SILICA_QEMU_TIMEOUT env:SILICA_FW_TIMEOUT env:SILICA_NO_KVM)
  [ -z "${2:-}" ] || GIN+=(repo+:system env:SILICA_SYSTEST_TIMEOUT)
}

if [ -n "$repo" ]; then
  all_repos | grep -xF "$repo" >/dev/null || die "unknown repo $repo"
  [ -d "$(checkout_of "$repo")" ] || die "no checkout of $repo"
fi
in_scope() { [ -z "$repo" ] || [ "$repo" = "$1" ]; }

suite_fmt() {
  local r=$1 s="$1.fmt" log; log=$(logfile "$s" fmt)
  if cargo_run "$r" "$log" fmt --all --check; then record pass "$s" fmt
  else record fail "$s" fmt "cargo fmt --check: $(grep -m1 '^Diff in' "$log" | cut -c1-140)"; fi
}

suite_clippy() {
  local r=$1 s="$1.clippy" log; log=$(logfile "$s" clippy)
  if cargo_run "$r" "$log" clippy --all-targets -- -D warnings; then record pass "$s" clippy
  else record fail "$s" clippy "$({ grep -m1 -E '^error' "$log" || grep -m1 -E '^warning' "$log"; } | cut -c1-140)"; fi
  # The documentation is the interface (a driver or an application is
  # written from it alone): it builds with no broken links or warnings.
  log=$(logfile "$s" docs)
  if RUSTDOCFLAGS="-D warnings" cargo_run "$r" "$log" doc --no-deps; then record pass "$s" docs
  else record fail "$s" docs "$({ grep -m1 -E '^error' "$log" || grep -m1 -E '^warning' "$log"; } | cut -c1-140)"; fi
  # The system repository's programs only build for Silica: lint them there.
  if [ "$r" = system ] && [ -f "$(checkout_of kernel)/targets/x86_64-silica-user.json" ]; then
    local vend; log=$(logfile "$s" programs)
    if vend=$(merged_vendor system) && cargo_run system "$log" clippy --workspace --bins \
        --target "$(checkout_of kernel)/targets/x86_64-silica-user.json" -Zjson-target-spec "${BUILD_STD_USER[@]}" \
        --config "source.vendored-sources.directory=\"$vend\"" -- -D warnings; then record pass "$s" programs
    else record fail "$s" programs "$({ grep -m1 -E '^error' "$log" || grep -m1 -E '^warning' "$log"; } | cut -c1-140)"; fi
  fi
}

# spec/UNSAFE_MODULES.md: unsafe blocks and impls only in the paths its
# table lists for each repository (comments and `unsafe fn` declarations,
# which state a contract, are not uses).
suite_unsafe() {
  local s=unsafe table="$WS/spec/UNSAFE_MODULES.md" r dir f bad="" n=0
  [ -f "$table" ] || { record fail "$s" table "no $table"; return; }
  for r in $(all_repos); do
    dir=$(checkout_of "$r"); [ -d "$dir" ] || continue
    local -a allowed=()
    while IFS= read -r p; do allowed+=("$p"); done < <(awk -F'|' -v r="$r" '{ gsub(/ /, "", $2) } $2 == r { print $3 }' "$table" | grep -o '`[^`]*`' | tr -d '`')
    while IFS= read -r f; do
      n=$((n + 1))
      local rel=${f#"$dir"/} ok=0
      for p in "${allowed[@]}"; do case "$rel" in "$p"*) ok=1; break ;; esac; done
      [ $ok = 1 ] || bad="$bad $r/$rel"
    # (Build output and vendored crates are left out by their place in the
    # checkout, not by the checkout's own path: filtered on the whole path,
    # every file of a worktree kept under target/ was left out, and the
    # check passed there whatever the code held.)
    done < <(grep -rlE --include='*.rs' --exclude-dir=target --exclude-dir=vendor '^[^/]*(unsafe *\{|unsafe impl)' "$dir" 2>/dev/null)
  done
  if [ -z "$bad" ]; then record pass "$s" modules
  else record fail "$s" modules "unsafe code outside spec/UNSAFE_MODULES.md:$bad"; fi
}

# The project is Rust, with shell for the tools that drive builds and
# emulators: no Python anywhere in it, tests and tools included (a program
# the tests run on the host is a Rust program of os/host-tools). Every file
# of the workshop and of each repository, committed or not yet (vendored
# crates left out), is checked: no Python source, compiled code or notebook
# by its name, and no text that names the interpreter (a shebang, a
# command, a package to install). Prose about the Python programs Silica
# runs for its users says "Python", which is allowed.
NO_PY_NAMES='\.(py|pyc|pyo|pyw|pyi|pyz|ipynb)$|(^|/)__pycache__/'
NO_PY_TEXT='pyth[o]n[0-9.]*'
own_files() { # own_files <dir>: what Git there tracks or would add, vendored crates left out
  git -C "$1" ls-files --cached --others --exclude-standard 2>/dev/null | grep -vE '(^|/)vendor/'
}
ws_files() { # the workshop's own files (the repositories are checked out inside it)
  local r skip=""
  for r in $(all_repos); do skip="$skip|${r//./\\.}"; done
  own_files "$WS" | grep -vE "^(${skip#|}|tools)(/|\$)"
}
suite_no_python() {
  local s=no_python r dir f bad=""
  for r in . $(all_repos); do
    if [ "$r" = . ]; then dir=$WS; else dir=$(checkout_of "$r"); fi
    [ -d "$dir" ] || continue
    local -a files=()
    if [ "$r" = . ]; then mapfile -t files < <(ws_files); else mapfile -t files < <(own_files "$dir"); fi
    while IFS= read -r f; do [ -n "$f" ] && bad="$bad $r/$f"; done < <(printf '%s\n' "${files[@]}" | grep -E "$NO_PY_NAMES")
    while IFS= read -r f; do bad="$bad $r/$f"; done < <(cd "$dir" && printf '%s\0' "${files[@]}" | xargs -0 -r grep -lIwE -e "$NO_PY_TEXT" -- 2>/dev/null)
  done
  if [ -z "$bad" ]; then record pass "$s" files
  else record fail "$s" files "Python in the project (the tests' host programs are Rust, os/host-tools):$bad"; fi
}

suite_host() { # every host test of the repo's default members
  local r=$1 s="$1.host" n d def log
  while IFS=$'\t' read -r n d def; do
    [ "$def" = 1 ] || continue
    log=$(logfile "$s" "$d")
    cargo_run "$r" "$log" test -p "$n" --no-fail-fast
    local rc=$? got
    got=$(parse_cargo_tests "$d" "$log")
    if [ -n "$got" ]; then
      while IFS=$'\t' read -r st id why; do
        case "$st" in ignored) st=skip ;; esac
        record "$st" "$s" "$id" "$why"
      done <<<"$got"
    fi
    if [ $rc != 0 ] && ! grep -q $'^fail\t' <<<"$got"; then
      record fail "$s" "$d" "cargo test failed: $(first_error "$log")"
    fi
  done < <(packages "$r")
}

suite_builds() { # the kernel for all three targets and the UEFI loader
  local s=kernel.build a log
  for a in x86_64 aarch64 riscv64; do
    log=$(logfile "$s" "$a")
    if build_kernel "$a" "$log" >/dev/null; then record pass "$s" "$a"
    else record fail "$s" "$a" "build failed: $(first_error "$log")"; fi
  done
  log=$(logfile "$s" loader)
  if build_loader "$log" >/dev/null; then record pass "$s" loader
  else record fail "$s" loader "build failed: $(first_error "$log")"; fi
}

# inos_machine <arch> <test> <options> <manifest>: set INOS_QEMU to the
# machine a test's line in the manifest names (smp=<processors> mem=<MiB>),
# INOS_QUIET to "quiet" when the line says the test judges a time (else
# "any"), and INOS_NAMED to whether it named a machine. "progress": the test
# says how far it got every few seconds and fails itself when it stops
# getting anywhere, so the harness ends it after a minute of silence
# instead of a total time (on an emulated slow host it may take many).
inos_machine() {
  local o
  INOS_QEMU=() INOS_QUIET=any INOS_NAMED=""
  for o in $3; do
    case "$o" in
      smp=*) INOS_QEMU+=(--smp "${o#smp=}"); INOS_NAMED=1 ;;
      mem=*) INOS_QEMU+=(--mem "${o#mem=}"); INOS_NAMED=1 ;;
      progress) INOS_QEMU+=(--timeout 1800 --quiet 60) ;;
      quiet) INOS_QUIET=quiet ;;
      *) record fail "inos.$1" "$2" "unknown option $o in $4"; return 1 ;;
    esac
  done
}
# inos_on <arch> <suite> <test> <label> [qemu.sh arguments]: run_inos on a
# named machine, recorded as <label>.
inos_on() {
  local a=$1 s=$2 t=$3 rc
  INOS_LABEL=$4; shift 4; INOS_QEMU=("$@")
  [ "$INOS_LABEL" != "$t" ] || INOS_LABEL=""
  run_inos "$a" "$s" "$t"; rc=$?
  INOS_QEMU=() INOS_LABEL=""
  return $rc
}
# Every test the root task has is in the manifest: one left out would never
# run, and nothing would say so.
inos_manifest() {
  local a=$1 manifest name missing=""
  manifest="$(checkout_of kernel)/tests/inos-$a.txt"
  for name in $(awk '/^const TESTS/ { on = 1 } on && /^\];/ { exit } on' "$(checkout_of kernel)/roottest/src/main.rs" | grep -o '("[a-z0-9_]*",' | tr -d '(",'); do
    awk -v t="$name" '$1 == t { found = 1 } END { exit !found }' "$manifest" || missing="$missing $name"
  done
  if [ -n "$missing" ]; then record fail "inos.$a" manifest "roottest has tests tests/inos-$a.txt does not list, so they never run:$missing"
  else record pass "inos.$a" manifest; fi
}

suite_inos() { # in-OS tests on one architecture, each a unit; --fast boots boot_ok only
  local a=$1 t opts manifest
  manifest="$(checkout_of kernel)/tests/inos-$a.txt"
  gin "$a"
  unit any "inos.$a/boot_ok" "${GIN[@]}" -- run_inos "$a" "inos.$a" boot_ok
  [ ! -f "$manifest" ] || [ "$PHASE" != rest ] || held "inos.$a/manifest" path:kernel:roottest/src/main.rs "path:kernel:tests/inos-$a.txt" -- inos_manifest "$a"
  if [ "$tier" != fast ] && [ -f "$manifest" ]; then
    # One test per line: its name, then optionally the machine it needs
    # (smp=<processors> mem=<MiB>) and "quiet" if it judges a time.
    while read -r t opts; do
      case "$t" in ""|"#"*|boot_ok) continue ;; esac
      [ "$PHASE" = rest ] || case " $opts " in *" quiet "*) ;; *) continue ;; esac
      inos_machine "$a" "$t" "$opts" "$manifest" || continue
      unit "$INOS_QUIET" "inos.$a/$t" "${GIN[@]}" -- inos_on "$a" "inos.$a" "$t" "$t" "${INOS_QEMU[@]+"${INOS_QEMU[@]}"}"
      # A test that names no machine runs on one processor above and on
      # four here: the same paths with other processors present.
      [ -n "$INOS_NAMED" ] || unit "$INOS_QUIET" "inos.$a/$t.smp4" "${GIN[@]}" -- inos_on "$a" "inos.$a" "$t" "$t.smp4" --smp 4
    done <"$manifest"
    INOS_QEMU=()
  fi
}

suite_matrix() { # the boot matrix of spec/MILESTONES.md, and the panic path
  local c m
  gin x86_64
  for c in 1 2 8 64; do
    for m in 256 16384; do
      unit any "inos.x86_64/boot_ok.smp$c.mem$m" "${GIN[@]}" -- inos_on x86_64 inos.x86_64 boot_ok "boot_ok.smp$c.mem$m" --smp "$c" --mem "$m"
    done
  done
  unit any inos.x86_64/panic_backtrace "${GIN[@]}" -- run_panic x86_64 inos.x86_64
  unit any inos.x86_64/null_object_faults "${GIN[@]}" -- run_panic x86_64 inos.x86_64 null
  unit any inos.x86_64/panic_screen "${GIN[@]}" crate:os:silica-host -- run_panic_screen x86_64 inos.x86_64
  # Boots that cannot succeed say why.
  local e=inos.x86_64 boot='EFI/BOOT/BOOTX64.EFI=$L'
  boot_error() { local label=$1; shift; unit any "$e/$label" "${GIN[@]}" -- run_boot_error x86_64 $e "$label" "$@"; }
  boot_error error.no_kernel 'ERROR: loader: SILICA\KERNEL.ELF not found' "$boot"
  boot_error error.kernel_not_elf 'ERROR: loader: SILICA\KERNEL.ELF is not an x86_64 ELF image' "$boot" 'SILICA/KERNEL.ELF=$L'
  boot_error error.kernel_not_ours 'ERROR: loader: kernel image is not position-independent at the kernel base' "$boot" 'SILICA/KERNEL.ELF=$R'
  boot_error error.no_ramdisk 'ERROR: kernel: no root task' "$boot" 'SILICA/KERNEL.ELF=$K'
  boot_error error.no_root_entry 'ERROR: kernel: no root task' "$boot" 'SILICA/KERNEL.ELF=$K' --ramdisk-entry 'other=$R'
  boot_error error.root_not_elf 'ERROR: kernel: cannot start the root task: Image(NotElf)' "$boot" 'SILICA/KERNEL.ELF=$K' --ramdisk-entry 'root=$L'
}

# suite_arch_entry <arch>: the loader and kernel entry on their own: the
# image boots from firmware at EL1 and at EL2 (as on most servers) to the
# kernel's report line, without a panic.
suite_arch_entry() {
  local a=$1 s="entry.$1" v log img
  log=$(logfile "$s" build)
  img=$(build_image "$a" "$log") || { record fail "$s" build "image build failed: $(first_error "$log")"; return; }
  record pass "$s" build
  for v in el1 el2; do
    log=$(logfile "$s" "$v")
    local -a at=(); [ "$v" = el2 ] && at=(--el2)
    "$TOOLS/qemu.sh" --arch "$a" --image "$img" --serial "$log.serial" --timeout 60 "${at[@]+"${at[@]}"}" >"$log" 2>&1
    if grep -aq "^silica: $a" "$log.serial" && ! grep -aq PANIC "$log.serial"; then record pass "$s" "$v"
    else record fail "$s" "$v" "no kernel report line, or a panic (serial: $log.serial)"; fi
  done
  return 0
}

suite_required_arch() { # an architecture required by milestone that cannot boot is an error
  local a=$1
  case "$a" in
    aarch64) [ "$ms" -ge 2 ] || return 0 ;;
    riscv64) [ "$ms" -ge 8 ] || return 0 ;;
    *) return 0 ;;
  esac
  # aarch64 with a target spec has run above.
  if [ "$a" = aarch64 ] && [ -f "$(checkout_of kernel)/targets/aarch64-silica.json" ]; then return 0; fi
  suite_inos "$a"
}

# Kani proofs in kernel-core (src/proofs.rs): no-forge. Revoke completeness
# is proved by exhaustion instead (src/exhaustive.rs, run with the host
# tests): Kani did not finish it for three slots in 30 minutes.
suite_kani() {
  local s=kernel.kani log dir; dir=$(checkout_of kernel); log=$(logfile "$s" kani)
  if ! command -v cargo-kani >/dev/null 2>&1; then
    if [ "$ms" -ge 2 ]; then record fail "$s" kani "Kani is not installed (cargo install --locked kani-verifier && cargo kani setup)"
    else record skip "$s" kani "Kani is not installed"; fi
    return 0
  fi
  (cd "$dir" && timeout 1800 cargo kani -p kernel-core --output-format terse) >"$log" 2>&1
  local n; n=$(grep -c 'VERIFICATION:- SUCCESSFUL' "$log")
  if grep -q '^Complete - [0-9]* successfully verified harnesses, 0 failures' "$log"; then record pass "$s" "proofs ($n)"
  else record fail "$s" proofs "a proof failed or did not finish (log: $log)"; fi
  return 0
}

# The proofs are compiled only by Kani (cfg(kani)), so nothing else notices
# when a kernel change stops them building: every tier builds them (about a
# second), and --deep runs them.
suite_kani_build() {
  local s=kernel.kani log dir; dir=$(checkout_of kernel); log=$(logfile "$s" build)
  if ! command -v cargo-kani >/dev/null 2>&1; then
    if [ "$ms" -ge 2 ]; then record fail "$s" build "Kani is not installed (cargo install --locked kani-verifier && cargo kani setup)"
    else record skip "$s" build "Kani is not installed"; fi
    return 0
  fi
  if (cd "$dir" && timeout 600 cargo kani -p kernel-core --only-codegen) >"$log" 2>&1; then record pass "$s" build
  else record fail "$s" build "the proofs do not build: $(first_error "$log")"; fi
  return 0
}

suite_size() {
  local s=size log; log=$(logfile "$s" size)
  "$TOOLS/size.sh" >"$log" 2>&1
  local rc=$? n=0
  while IFS= read -r l; do record fail "$s" "${l#ERROR: size: }" ""; n=$((n + 1)); done < <(grep '^ERROR:' "$log")
  if [ $rc != 0 ] && [ $n = 0 ]; then record fail "$s" size "size.sh failed (log: $log)"; fi
  [ $rc = 0 ] && record pass "$s" size
}

suite_tools() { # tool self-tests (os/tools/tests/*.sh), each a unit: they take minutes, so --full and --deep only
  local s=os.tools t alone=$1
  local -a in
  for t in "$(checkout_of os)"/tools/tests/*.sh; do
    [ -f "$t" ] || continue
    # A self-test is a function of the tools. One that builds the real
    # kernel says so in a line "# inputs: kernel"; one that builds or boots
    # the real system, "# inputs: system", and is a function of the kernel,
    # the system and the emulators as well. One that judges a
    # time says "# alone" and runs when nothing else does.
    in=(path:os:tools path:os:bench crate:os:silica-image)
    grep -q '^# inputs: kernel$' "$t" && in+=(repo:os repo+:kernel)
    grep -q '^# inputs: system$' "$t" && in+=(repo:os repo+:system repo+:kernel host:qemu-x86_64 host:qemu-aarch64)
    if grep -q '^# alone$' "$t"; then
      [ "$alone" = alone ] && held "$s/$(basename "$t")" "${in[@]}" -- tool_test "$(basename "$t")"
    elif [ "$alone" != alone ]; then
      held_bg "$s/$(basename "$t")" "${in[@]}" -- tool_test "$(basename "$t")"
    fi
  done
}
# Each self-test builds a fake workshop with its own MILESTONE file; the
# override for this run (SILICA_MILESTONE) must not leak into it, nor this
# run's evidence (a self-test's fake checkouts are not the real ones).
tool_test() { (unset SILICA_MILESTONE SILICA_EVIDENCE SILICA_FRESH; run_named os "tools/tests/$1" os.tools >/dev/null); }

miri_error() { # the line that says why Miri failed, else the first error
  local l; l=$(grep -m1 -E "Undefined Behavior|memory leaked|unsupported operation|panicked" "$1" | cut -c1-160)
  if [ -n "$l" ]; then echo "$l"; else first_error "$1"; fi
}

# Miri on kernel-core: suite kernel.miri, one result per test. Miri builds its
# own sysroot from a directory outside the checkout, so the checkout's
# .cargo/config.toml (vendored sources) does not apply to that step: a private
# CARGO_HOME carries the replacement, pointing at the merged vendor directory
# (which also holds the library's own crates). The sysroot is prepared once per
# run and handed to `cargo miri test` through MIRI_SYSROOT.
suite_miri() {
  local s=kernel.miri log vend c tc sys got rc st id why
  log=$(logfile "$s" setup); vend=$(merged_vendor kernel); c=$(cache_of kernel)
  mkdir -p "$c/cargo-home" "$c/xdg" "$c/miri-setup"
  printf '[source.crates-io]\nreplace-with = "vendored-sources"\n[source.vendored-sources]\ndirectory = "%s"\n' "$vend" >"$c/cargo-home/config.toml"
  tc=$(sed -n 's/^channel *= *"\(.*\)".*/\1/p' "$(checkout_of kernel)/rust-toolchain.toml" 2>/dev/null | head -n 1)
  sys=$(cd "$c/miri-setup" && env CARGO_HOME="$c/cargo-home" XDG_CACHE_HOME="$c/xdg" \
    ${tc:+RUSTUP_TOOLCHAIN="$tc"} cargo miri setup --print-sysroot 2>"$log" | tail -n 1)
  if [ "${sys#/}" = "$sys" ]; then
    record fail "$s" setup "miri sysroot setup failed: $(first_error "$log")"; return
  fi
  log=$(logfile "$s" kernel-core)
  CARGO_ENV=(CARGO_HOME="$c/cargo-home" XDG_CACHE_HOME="$c/xdg" MIRI_SYSROOT="$sys")
  # Built once; then every test runs in a Miri process of its own, many at
  # a time (Miri interprets a test binary's tests one after another, and
  # the slowest few decide the run): the same tests, an hour shorter.
  cargo_run kernel "$log.build" miri test -p kernel-core --no-run; rc=$?
  CARGO_ENV=()
  local runner jobs dir=$RUN/miri
  runner=${SILICA_MIRI_RUNNER:-$(env ${tc:+RUSTUP_TOOLCHAIN="$tc"} rustup which cargo-miri 2>/dev/null)}
  mkdir -p "$dir"; : >"$log"
  if [ $rc = 0 ] && [ -x "$runner" ]; then
    # Half the processors: the guest tests run beside it.
    jobs=${SILICA_MIRI_JOBS:-$(( $(nproc) > 4 ? $(nproc) / 2 : 2 ))}
    sed -n 's/^ *Executable \(.*\) (\(.*\))$/\1\t\2/p' "$log.build" | while IFS=$'\t' read -r kind exe; do
      env CARGO_HOME="$c/cargo-home" XDG_CACHE_HOME="$c/xdg" MIRI_SYSROOT="$sys" ${tc:+RUSTUP_TOOLCHAIN="$tc"} \
        "$runner" runner "$exe" --list 2>/dev/null | sed -n 's/: test$//p' | while read -r name; do printf '%s\t%s\t%s\n' "$kind" "$exe" "$name"; done
    done >"$dir/tests"
    # One output file per test, numbered in the order listed. The tests are
    # started longest first, by how long each took the last time (kept in
    # the evidence store; a test never timed goes first): a run is as long
    # as its longest test or its total over the processors, whichever is
    # more, and a nine-minute test started fourth made it thirteen.
    local times; times=$(ev_dir kernel.miri.times)/seconds; mkdir -p "$(dirname "$times")"; [ -f "$times" ] || : >"$times"
    awk -F'\t' 'FILENAME == ARGV[1] { took[$1] = $2; next }
        { printf "%d\t%s\t%s\t%s\t%d\n", (($3 in took) ? took[$3] : 1000000), $1, $2, $3, FNR }' "$times" "$dir/tests" | sort -t$'\t' -k1,1nr -k5,5n | cut -f2- | tr '\n' '\0' |
      xargs -0 -P "$jobs" -I{} env CARGO_HOME="$c/cargo-home" XDG_CACHE_HOME="$c/xdg" MIRI_SYSROOT="$sys" ${tc:+RUSTUP_TOOLCHAIN="$tc"} \
        bash -c 'IFS=$(printf "\t") read -r kind exe name n <<<"$1"; "$2" runner "$exe" --exact "$name" >"$3/$n.out" 2>&1; printf "%s\t%s\n" "$name" "$SECONDS" >"$3/$n.time"' _ {} "$runner" "$dir"
    cat "$dir"/*.time >"$times.new" 2>/dev/null && mv "$times.new" "$times"
    # As cargo would have printed it, binary by binary.
    awk -F'\t' -v d="$dir" '{ if ($1 != last) { printf "     Running %s (%s)\n", $1, $2; last = $1 }
        f = d "/" NR ".out"; seen = 0
        while ((getline l < f) > 0) { print l; if (index(l, "test " $3 " ... ") == 1 || index(l, "test " $3 " - should panic ... ") == 1) seen = 1 }
        close(f)
        # A test Miri stopped (undefined behaviour) prints no result: a failure.
        if (!seen) printf "test %s ... FAILED\n", $3 }' "$dir/tests" >"$log"
    grep -q '^test .* \.\.\. FAILED' "$log" && rc=1
  fi
  got=$(parse_cargo_tests kernel-core "$log")
  # No tests at all is a failure, never a quiet pass.
  if [ -z "$got" ]; then
    record fail "$s" kernel-core "no Miri test ran: $(first_error "$log.build") (runner: ${runner:-none})"; return
  fi
  if [ -n "$got" ]; then
    while IFS=$'\t' read -r st id why; do
      case "$st" in ignored) st=skip ;; fail) why=$(miri_error "$log") ;; esac
      record "$st" "$s" "$id" "$why"
    done <<<"$got"
  fi
  if [ $rc != 0 ] && ! grep -q $'^fail\t' <<<"$got"; then
    record fail "$s" kernel-core "miri failed: $(miri_error "$log")"
  fi
}

# Loom: every model of the kernel's host crates is its own suite
# kernel.loom.<test path>. A model is a test that exists only under cfg(loom):
# the tests listed with --cfg loom minus the tests listed without it. Each runs
# by itself in release mode. A crate that does not build under cfg(loom) is one
# failure in kernel.loom; no models at all is one skipped line.
# LOOM_MAX_PREEMPTIONS and LOOM_MAX_BRANCHES pass through when set.
suite_loom() {
  local s=kernel.loom n d def log plain withloom id name models=0
  while IFS=$'\t' read -r n d def; do
    [ "$def" = 1 ] || continue
    log=$(logfile "$s" "$d.plain")
    cargo_run kernel "$log" test -p "$n" -- --list || continue # the host suite reports it
    plain=$(parse_cargo_list "$d" "$log")
    log=$(logfile "$s" "$d")
    CARGO_ENV=(RUSTFLAGS="--cfg loom" ${LOOM_MAX_PREEMPTIONS:+LOOM_MAX_PREEMPTIONS="$LOOM_MAX_PREEMPTIONS"}
      ${LOOM_MAX_BRANCHES:+LOOM_MAX_BRANCHES="$LOOM_MAX_BRANCHES"})
    if ! cargo_run kernel "$log" test --release -p "$n" -- --list; then
      CARGO_ENV=()
      record fail "$s" "$d" "build failed under cfg(loom): $(first_error "$log")"; continue
    fi
    withloom=$(parse_cargo_list "$d" "$log")
    TEST_ARGS=(--release)
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      case "$id" in */doc::*) continue ;; esac
      grep -qxF -- "$id" <<<"$plain" && continue
      models=$((models + 1))
      name=$(printf '%s' "${id#*::}" | sed 's/::/./g' | tr -c 'A-Za-z0-9_.\n-' '_')
      run_named kernel "$id" "$s.$name" >/dev/null
    done <<<"$withloom"
    TEST_ARGS=(); CARGO_ENV=()
  done < <(packages kernel)
  # Lock-free structures arrive with SMP at M2; from then on a kernel with no
  # loom model is an error. Before that there is nothing to model.
  if [ "$models" = 0 ] && [ "$ms" -ge 2 ] && ! grep -q "^fail"$'\t'"$s"$'\t' "$RES"; then
    record fail "$s" models "no loom models (required from M2)"
  fi
}

# Fuzzing (--deep): every fuzz target is one result of suite fuzz, from
# tools/fuzz.sh's own lines (it stores reproducers and coverage under
# target/fuzz/). No targets at all adds nothing.
suite_fuzz() { # suite_fuzz <repo>
  [ -x "$TOOLS/fuzz.sh" ] || return 0
  local s=fuzz log l id why rest rc n=0
  log=$(logfile "$s" "run.$1")
  # Ten minutes per target: every trust boundary runs 10 min clean (spec/MILESTONES.md).
  "$TOOLS/fuzz.sh" --repo "$1" --time "${SILICA_FUZZ_TIME:-600}" >"$log" 2>&1; rc=$?
  while IFS= read -r l; do
    case "$l" in
      "fuzz: "*": ok "*) id=${l#fuzz: }; record pass "$s" "${id%%: ok *}"; n=$((n + 1)) ;;
      "ERROR: fuzz: "*)
        rest=${l#ERROR: fuzz: }; id=${rest%%: *}; why=${rest#*: }
        case "$id" in *::*) ;; *) id=run; why=$rest ;; esac
        record fail "$s" "$id" "$why"; n=$((n + 1)) ;;
    esac
  done <"$log"
  if [ $rc != 0 ] && [ $n = 0 ]; then record fail "$s" run "fuzz.sh failed (log: $log)"; fi
}

# Benchmarks against Linux (--deep): every metric bench.sh prints is one result
# of suite bench. A metric not yet reported before its milestone is a skip
# that says so, and so is an open gap. bench.sh keeps what it measured under
# its own inputs, so this is not a unit: an unchanged tree boots nothing.
suite_bench() {
  in_scope kernel || return 0   # the benchmarks boot the kernel
  local s=bench log l rest id rc n=0
  local -a args=()
  # Holding nothing (a milestone's exit): Silica measured again. Linux is
  # locked (bench/reference.tsv) and is not booted by any tier.
  [ "$FRESH" != 1 ] || args=(--fresh)
  log=$(logfile "$s" run)
  "$TOOLS/bench.sh" "${args[@]+"${args[@]}"}" >"$log" 2>&1; rc=$?
  while IFS= read -r l; do
    case "$l" in
      "bench: "*": silica "*) rest=${l#bench: }; record pass "$s" "${rest%%: *}"; n=$((n + 1)) ;;
      "SKIP: bench: "*) rest=${l#SKIP: bench: }; record skip "$s" "${rest%%: *}" "${rest#*: }"; n=$((n + 1)) ;;
      "OPEN: bench: "*) rest=${l#OPEN: bench: }; record skip "$s" "${rest%%: *}" "open gap: ${rest#*: }"; n=$((n + 1)) ;;
      "ERROR: bench::"*) rest=${l#ERROR: bench::}; record fail "$s" "${rest%%: *}" "${rest#*: }"; n=$((n + 1)) ;;
    esac
  done <"$log"
  if [ $rc != 0 ] && ! grep -q "^fail"$'\t'"$s"$'\t' "$RES"; then record fail "$s" run "bench.sh exited $rc (log: $log)"; fi
}

# system_test <name>: one of the system image's guest tests (or the faults
# of one driver, "faults.<driver>"), a unit: each boots its own machine.
system_test() {
  local t=$1 q=any
  local -a host=()
  gin x86_64 system
  case "$QUIET_SYSTEM" in *" $t "*) q=quiet ;; esac
  # The checks that run a program of os/host-tools beside the guest (theirs
  # alone: GIN is shared by the units declared after this one).
  case "$t" in http | http_load | http_restart | ntp | console | http_e1000e | http_load_e1000e | ntp_e1000e) host=(crate:os:silica-host) ;; esac
  case "$t" in
    faults.*) unit any "system.x86_64/$t" "${GIN[@]}" -- run_faults x86_64 system.x86_64 "${t#faults.}" ;;
    *) unit "$q" "system.x86_64/$t" "${GIN[@]}" "${host[@]+"${host[@]}"}" -- "run_$t" x86_64 system.x86_64 ;;
  esac
}
FAULT_DRIVERS=(virtio-blk nvme nvme_one_vector nvme_4k nvme_namespaces virtio-net)
# One repository's lint and host tests, one after another (they share a
# build directory); the repositories' run at once.
repo_units() {
  local r=$1
  held "$r.fmt" "repo:$r" "${LIB[@]}" -- suite_fmt "$r"
  held "$r.clippy" "repo+:$r" "${LIB[@]}" -- suite_clippy "$r"
  held "$r.host" "repo+:$r" "${LIB[@]}" -- suite_host "$r"
}
have_kernel=""; [ -f "$(checkout_of kernel)/targets/x86_64-silica.json" ] && have_kernel=1
have_system=""; [ -f "$(checkout_of system)/Cargo.toml" ] && have_system=1
have_aarch64=""; [ -f "$(checkout_of kernel)/targets/aarch64-silica.json" ] && have_aarch64=1
# guests: every guest test of the tier, for the phase that is on.
guests() {
  local t
  if { in_scope kernel || in_scope os; } && [ -n "$have_kernel" ]; then
    suite_inos x86_64
    [ "$tier" != fast ] && suite_matrix
  fi
  # The system image: the kernel with the system repository's init as root task.
  if { in_scope kernel || in_scope os || in_scope system; } && [ -n "$have_system" ]; then
    for t in "${SYSTEM_TESTS[@]}"; do system_test "$t"; done
    if [ "$tier" != fast ]; then
      # One boot per fault and driver, so not in the fast tier; nor the
      # services restarted forty times under load, a quiet test of seconds.
      for t in "${FAULT_DRIVERS[@]}"; do system_test "faults.$t"; done
      system_test svcload
      system_test http_load
      system_test http_load_e1000e
      system_test http_restart
      unit any systest.x86_64/systest "${GIN[@]}" -- run_systest x86_64 systest.x86_64
      # The same system and the same tests on aarch64 (spec/MILESTONES.md M2:
      # "aarch64 boots to the same test"), emulated, so not in the fast tier.
      if [ -f "$(checkout_of kernel)/targets/aarch64-silica-user.json" ]; then
        gin aarch64 system
        unit any system.aarch64/system "${GIN[@]}" -- run_system aarch64 system.aarch64
        unit any systest.aarch64/systest "${GIN[@]}" -- run_systest aarch64 systest.aarch64
        # The NVMe driver where the processor reorders memory (its DMA barriers).
        unit any system.aarch64/nvme "${GIN[@]}" -- run_nvme aarch64 system.aarch64
      fi
    fi
  fi
  if [ "$tier" != fast ]; then
    # aarch64's in-OS tests run whenever the kernel has the architecture,
    # before the milestone that requires it, so what works stays working.
    if { in_scope kernel || in_scope os; } && [ -n "$have_aarch64" ]; then
      gin aarch64
      unit any entry.aarch64/entry "${GIN[@]}" -- suite_arch_entry aarch64
      unit any inos.aarch64/panic_backtrace "${GIN[@]}" -- run_panic aarch64 inos.aarch64
      unit any inos.aarch64/panic_backtrace_secondary "${GIN[@]}" -- run_panic aarch64 inos.aarch64 secondary
      unit any inos.aarch64/null_object_faults "${GIN[@]}" -- run_panic aarch64 inos.aarch64 null
      suite_inos aarch64
    fi
    suite_required_arch aarch64
    suite_required_arch riscv64
  fi
}

fn_hashes   # before anything forks: every unit's command is one of its inputs
if [ "${#guests[@]}" -gt 0 ]; then
  # Each on the machine its line in the manifest names; those that judge a
  # time first, one at a time.
  manifest="$(checkout_of kernel)/tests/inos-x86_64.txt"
  for PHASE in quiet rest; do
    for guest in "${guests[@]}"; do
      if [[ $guest == fault_* ]]; then
        for driver in "${FAULT_DRIVERS[@]}"; do
          prefix=fault_${driver//-/_}_
          fault=${guest#"$prefix"}
          case "$fault" in
            garbage|stuck|spurious|missed|reset)
              gin x86_64 system
              unit any "system.x86_64/$guest" "${GIN[@]}" -- run_faults x86_64 system.x86_64 "$driver" "$fault"
              continue 2 ;;
          esac
        done
      fi
      # The system image's own tests, by name.
      case " ${SYSTEM_TESTS[*]} faults systest svcload http_load http_load_e1000e http_restart " in
        *" $guest "*)
          if [ "$guest" = faults ]; then for t in "${FAULT_DRIVERS[@]}"; do system_test "faults.$t"; done
          elif [ "$guest" = systest ]; then
            [ "$PHASE" = rest ] && { gin x86_64 system; unit any systest.x86_64/systest "${GIN[@]}" -- run_systest x86_64 systest.x86_64; }
          else system_test "$guest"; fi
          continue ;;
      esac
      # The kernel's panic tests, by name.
      case "$guest" in
        panic_backtrace | null_object_faults | panic_screen)
          if [ "$PHASE" = rest ]; then
            gin x86_64
            case "$guest" in
              panic_backtrace) unit any inos.x86_64/panic_backtrace "${GIN[@]}" -- run_panic x86_64 inos.x86_64 ;;
              null_object_faults) unit any inos.x86_64/null_object_faults "${GIN[@]}" -- run_panic x86_64 inos.x86_64 null ;;
              panic_screen) unit any inos.x86_64/panic_screen "${GIN[@]}" crate:os:silica-host -- run_panic_screen x86_64 inos.x86_64 ;;
            esac
          fi
          continue ;;
      esac
      opts=$(awk -v t="$guest" '$1 == t { $1 = ""; print; exit }' "$manifest" 2>/dev/null)
      inos_machine x86_64 "$guest" "$opts" "$manifest" || continue
      gin x86_64
      unit "$INOS_QUIET" "inos.x86_64/$guest" "${GIN[@]}" -- inos_on x86_64 inos.x86_64 "$guest" "$guest" "${INOS_QEMU[@]+"${INOS_QEMU[@]}"}"
    done
  done
  INOS_QEMU=()
  wait
else
  for r in $(all_repos); do
    in_scope "$r" || continue
    [ -f "$(checkout_of "$r")/Cargo.toml" ] || continue
    repo_units "$r" &
  done
  wait
  if [ -z "$repo" ]; then
    in=(); for r in $(all_repos); do in+=("repo:$r"); done
    held unsafe "${in[@]}" ws:spec/UNSAFE_MODULES.md -- suite_unsafe
    while IFS= read -r f; do in+=("ws:$f"); done < <(ws_files)
    held no_python "${in[@]}" -- suite_no_python
  fi
  if { in_scope kernel || in_scope os; } && [ -n "$have_kernel" ]; then
    held kernel.build repo+:kernel "${LIB[@]}" -- suite_builds
    in_scope kernel && held kernel.kani/build crate:kernel:kernel-core host:kani "ms:$ms" -- suite_kani_build
  fi
  # The guest tests that judge a time, with the host to themselves.
  PHASE=quiet; guests
  PHASE=rest
  # Then everything else at once, the long ones first: Miri (its longest
  # test decides how long it takes), loom and the tools' own tests.
  if [ "$tier" != fast ]; then
    if in_scope kernel; then
      held_bg kernel.miri crate:kernel:kernel-core "${LIB[@]}" env:SILICA_MIRI_RUNNER env:SILICA_MIRI_JOBS -- suite_miri
      held_bg kernel.loom repo+:kernel "${LIB[@]}" "ms:$ms" env:LOOM_MAX_PREEMPTIONS env:LOOM_MAX_BRANCHES -- suite_loom
    fi
    in_scope os && suite_tools together
  fi
  guests
  # The hosted CI definitions test themselves (every workflow parses).
  if in_scope .github && [ -d "$(checkout_of .github)/tests" ]; then
    for t in "$(checkout_of .github)"/tests/*.sh; do held ".github.tests/${t##*/}" repo:.github host:actionlint -- run_named .github "tests/${t##*/}" .github.tests; done
  fi
  wait
  [ "$tier" != fast ] && in_scope os && suite_tools alone
  # The budgets measure the kernel and the images this run built: nothing to
  # measure when neither is in scope (--repo idl, --repo .github).
  if in_scope kernel || in_scope os || in_scope system; then
    held size repo+:kernel repo+:system crate:os:silica-image "${LIB[@]}" path:os:tools/size.sh ws:spec/ARCHITECTURE.md "ms:$ms" -- suite_size
  fi
  if [ "$tier" = deep ]; then
    # Fuzzing, a repository at a time: a target is fuzzed again when the
    # code it reaches may have changed.
    for r in $(all_repos); do
      in_scope "$r" || continue
      [ -d "$(checkout_of "$r")" ] || continue
      held "fuzz.$r" "repo+:$r" "${LIB[@]}" path:os:tools/fuzz.sh "time:${SILICA_FUZZ_TIME:-600}" env:SILICA_FUZZ_UNIT_TIMEOUT -- suite_fuzz "$r"
    done
    in_scope kernel && held_bg kernel.kani/proofs crate:kernel:kernel-core host:kani "ms:$ms" -- suite_kani
    # The benchmarks hold the host still: nothing else runs beside them.
    wait
    suite_bench
  fi
fi

if [ "$PLAN" = 1 ]; then
  plan_summary
  exit 0
fi
awk -F'\t' '
  { s = $2; seen[s] = 1; if (!(s in order)) { order[s] = ++n; name[n] = s }
    if ($1 == "pass") p[s]++; else if ($1 == "fail") f[s]++; else k[s]++ }
  END { for (i = 1; i <= n; i++) { s = name[i]; printf "%s: pass=%d fail=%d skipped=%d\n", s, p[s], f[s], k[s] } }' "$RES" | sort | head -40
awk -F'\t' '$1 == "fail" { r = $4; if (r == "") r = "failed"; printf "ERROR: %s::%s: %s\n", $2, $3, r }' "$RES"
read -r P F K < <(awk -F'\t' '{ if ($1 == "pass") p++; else if ($1 == "fail") f++; else k++ } END { print p+0, f+0, k+0 }' "$RES")
units_summary
echo "RESULT: pass=$P fail=$F skipped=$K time=$(($(date +%s) - start))"
[ "$F" = 0 ]
