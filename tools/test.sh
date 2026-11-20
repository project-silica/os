#!/usr/bin/env bash
# Host tests, target builds, QEMU guest tests and size checks.
# Use --fast, --full or --deep; --repo limits the scope. --guest NAME
# runs just the named x86_64 guest test (repeatable).
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"
. "$TOOLS/lib/build.sh"
. "$TOOLS/lib/tests.sh"

tier=fast repo="" guests=()
while [ $# -gt 0 ]; do
  case "$1" in
    --fast) tier=fast; shift ;;
    --full) tier=full; shift ;;
    --deep) tier=deep; shift ;;
    --repo) repo=$2; shift 2 ;;
    --guest) [ $# -ge 2 ] || die "--guest needs a test name"; guests+=("$2"); shift 2 ;;
    *) die "unknown argument $1" ;;
  esac
done
start=$(date +%s)
new_run
RES=$RUN/results.tsv; : >"$RES"
ms=$(milestone)

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
  else record fail "$s" clippy "$(grep -m1 -E '^(error|warning)' "$log" | cut -c1-140)"; fi
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

suite_inos() { # in-OS tests on one architecture; --fast boots boot_ok only
  local a=$1 t opts o manifest
  manifest="$(checkout_of kernel)/tests/inos-$a.txt"
  run_inos "$a" "inos.$a" boot_ok
  if [ "$tier" != fast ] && [ -f "$manifest" ]; then
    # One test per line: its name, then optionally the machine it needs
    # (smp=<processors> mem=<MiB>).
    while read -r t opts; do
      case "$t" in ""|"#"*|boot_ok) continue ;; esac
      INOS_QEMU=()
      for o in $opts; do
        case "$o" in
          smp=*) INOS_QEMU+=(--smp "${o#smp=}") ;;
          mem=*) INOS_QEMU+=(--mem "${o#mem=}") ;;
          *) record fail "inos.$a" "$t" "unknown option $o in $manifest"; continue 2 ;;
        esac
      done
      run_inos "$a" "inos.$a" "$t"
      # A test that names no machine runs on one processor above and on
      # four here: the same paths with other processors present.
      if [ -z "$opts" ]; then
        INOS_QEMU=(--smp 4); INOS_LABEL="$t.smp4"
        run_inos "$a" "inos.$a" "$t"
        INOS_LABEL=""
      fi
    done <"$manifest"
    INOS_QEMU=()
  fi
}

suite_matrix() { # the boot matrix of spec/MILESTONES.md, and the panic path
  local c m
  for c in 1 2 8 64; do
    for m in 256 16384; do
      INOS_QEMU=(--smp "$c" --mem "$m"); INOS_LABEL="boot_ok.smp$c.mem$m"
      run_inos x86_64 inos.x86_64 boot_ok
    done
  done
  INOS_QEMU=(); INOS_LABEL=""
  run_panic x86_64 inos.x86_64
  # Boots that cannot succeed say why.
  local e=inos.x86_64 boot='EFI/BOOT/BOOTX64.EFI=$L'
  run_boot_error x86_64 $e error.no_kernel 'ERROR: loader: SILICA\KERNEL.ELF not found' "$boot"
  run_boot_error x86_64 $e error.kernel_not_elf 'ERROR: loader: SILICA\KERNEL.ELF is not an x86_64 ELF image' "$boot" 'SILICA/KERNEL.ELF=$L'
  run_boot_error x86_64 $e error.kernel_not_ours 'ERROR: loader: kernel image is not position-independent at the kernel base' "$boot" 'SILICA/KERNEL.ELF=$R'
  run_boot_error x86_64 $e error.no_ramdisk 'ERROR: kernel: no root task' "$boot" 'SILICA/KERNEL.ELF=$K'
  run_boot_error x86_64 $e error.no_root_entry 'ERROR: kernel: no root task' "$boot" 'SILICA/KERNEL.ELF=$K' --ramdisk-entry 'other=$R'
  run_boot_error x86_64 $e error.root_not_elf 'ERROR: kernel: cannot start the root task: Image(NotElf)' "$boot" 'SILICA/KERNEL.ELF=$K' --ramdisk-entry 'root=$L'
}

suite_required_arch() { # an architecture required by milestone that cannot boot is an error
  local a=$1
  case "$a" in
    aarch64) [ "$ms" -ge 2 ] || return 0 ;;
    riscv64) [ "$ms" -ge 8 ] || return 0 ;;
    *) return 0 ;;
  esac
  suite_inos "$a"
}

suite_size() {
  local s=size log; log=$(logfile "$s" size)
  "$TOOLS/size.sh" >"$log" 2>&1
  local rc=$? n=0
  while IFS= read -r l; do record fail "$s" "${l#ERROR: size: }" ""; n=$((n + 1)); done < <(grep '^ERROR:' "$log")
  if [ $rc != 0 ] && [ $n = 0 ]; then record fail "$s" size "size.sh failed (log: $log)"; fi
  [ $rc = 0 ] && record pass "$s" size
}

suite_tools() { # tool self-tests (os/tools/tests/*.sh): they take minutes, so --full and --deep only
  local s=os.tools t
  for t in "$(checkout_of os)"/tools/tests/*.sh; do
    [ -f "$t" ] || continue
    run_named os "tools/tests/$(basename "$t")" "$s" >/dev/null
  done
}

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
  cargo_run kernel "$log" miri test -p kernel-core --no-fail-fast; rc=$?
  CARGO_ENV=()
  got=$(parse_cargo_tests kernel-core "$log")
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
suite_fuzz() {
  [ -x "$TOOLS/fuzz.sh" ] || return 0
  local s=fuzz log l id why rest rc n=0
  log=$(logfile "$s" run)
  "$TOOLS/fuzz.sh" ${repo:+--repo "$repo"} --time "${SILICA_FUZZ_TIME:-60}" >"$log" 2>&1; rc=$?
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
# of suite bench. A gate missed before its milestone is a skip that says so.
suite_bench() {
  in_scope kernel || return 0   # the benchmarks boot the kernel
  local s=bench log l rest id rc n=0
  log=$(logfile "$s" run)
  "$TOOLS/bench.sh" >"$log" 2>&1; rc=$?
  while IFS= read -r l; do
    case "$l" in
      "bench: behind Linux:"*|"bench: results in"*|"bench: ratchet"*) ;;
      "bench: "*": "*) rest=${l#bench: }; record pass "$s" "${rest%%: *}"; n=$((n + 1)) ;;
      "SKIP: bench: "*) rest=${l#SKIP: bench: }; record skip "$s" "${rest%%: *}" "${rest#*: }"; n=$((n + 1)) ;;
      "ERROR: bench::"*) rest=${l#ERROR: bench::}; record fail "$s" "${rest%%: *}" "${rest#*: }"; n=$((n + 1)) ;;
    esac
  done <"$log"
  if [ $rc != 0 ] && ! grep -q "^fail"$'\t'"$s"$'\t' "$RES"; then record fail "$s" run "bench.sh exited $rc (log: $log)"; fi
}

if [ "${#guests[@]}" -gt 0 ]; then
  for guest in "${guests[@]}"; do run_inos x86_64 inos.x86_64 "$guest"; done
else
  for r in $(all_repos); do
    in_scope "$r" || continue
    [ -f "$(checkout_of "$r")/Cargo.toml" ] || continue
    suite_fmt "$r"; suite_clippy "$r"; suite_host "$r"
  done
  if { in_scope kernel || in_scope os; } && [ -f "$(checkout_of kernel)/targets/x86_64-silica.json" ]; then
    suite_builds
    suite_inos x86_64
    [ "$tier" != fast ] && suite_matrix
  fi
  # The system image: the kernel with the system repository's init as root task.
  if { in_scope kernel || in_scope os || in_scope system; } && [ -f "$(checkout_of system)/Cargo.toml" ]; then
    run_system x86_64 system.x86_64
    [ "$tier" != fast ] && run_systest x86_64 systest.x86_64
  fi
  [ "$tier" != fast ] && in_scope os && suite_tools
  suite_size
  if [ "$tier" != fast ]; then
    suite_required_arch aarch64
    suite_required_arch riscv64
    if in_scope kernel; then suite_miri; suite_loom; fi
  fi
  if [ "$tier" = deep ]; then
    suite_fuzz
    suite_bench
    # Proofs of no-forge and revoke-completeness are due at M2 (spec/MILESTONES.md).
    [ "$ms" -lt 2 ] || record fail kani proofs "no Kani proofs (required from M2)"
  fi
fi

awk -F'\t' '
  { s = $2; seen[s] = 1; if (!(s in order)) { order[s] = ++n; name[n] = s }
    if ($1 == "pass") p[s]++; else if ($1 == "fail") f[s]++; else k[s]++ }
  END { for (i = 1; i <= n; i++) { s = name[i]; printf "%s: pass=%d fail=%d skipped=%d\n", s, p[s], f[s], k[s] } }' "$RES" | head -24
awk -F'\t' '$1 == "fail" { r = $4; if (r == "") r = "failed"; printf "ERROR: %s::%s: %s\n", $2, $3, r }' "$RES"
read -r P F K < <(awk -F'\t' '{ if ($1 == "pass") p++; else if ($1 == "fail") f++; else k++ } END { print p+0, f+0, k+0 }' "$RES")
echo "RESULT: pass=$P fail=$F skipped=$K time=$(($(date +%s) - start))"
[ "$F" = 0 ]
