#!/usr/bin/env bash
# Test for the host harness of kernel-core (component A05;
# spec/TESTING.md section 3): kernel-core builds and tests on the host
# with std for tests; `test.sh --full` runs Miri on it and every loom model
# (tests that exist only under cfg(loom)), each as its own suite with the
# standard output rules (one summary line per suite, one ERROR line per
# failure, details under target/logs/<suite>/, RESULT last).
#
# Runs a private copy of the tool suite in a disposable fake workshop with a
# fake kernel repository holding a tiny real kernel-core crate (no external
# crates). Real cargo builds and runs its tests, including the cfg(loom)
# models; fmt, clippy and the Miri interpreter are replaced by a shim that
# records the calls (the real Miri runs in tests/fixture_host_harness.sh, which
# only --full runs). One "ERROR:" line per failed check.
set -uo pipefail
SRC=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd -P)
BASE=${SILICA_RUN:-${TMPDIR:-/tmp}}; mkdir -p "$BASE"
FX=$(mktemp -d "$BASE/hosttest.XXXX") || exit 2
FX=$(cd "$FX" && pwd -P)
trap 'rm -rf "${FX:?}"' EXIT
fails=0
bad() { echo "ERROR: host-harness: $1"; fails=$((fails + 1)); }

REAL_CARGO=$(command -v cargo) || { echo "ERROR: host-harness: no cargo on PATH"; exit 2; }
RUSTUP_HOME=${RUSTUP_HOME:-${HOME:-/root}/.rustup}
WS=$FX/ws; OS=$WS/os; K=$WS/kernel; CALLS=$FX/calls.log
mkdir -p "$FX/bin" "$OS/tools" "$K/kernel-core/src" "$K/kernel-core/tests"
echo x >"$WS/bootstrap.pins"; echo 0 >"$WS/MILESTONE"
cp -r "$SRC/lib" "$SRC/test.sh" "$SRC/size.sh" "$SRC/qemu.sh" "$OS/tools/"
printf '[repos.kernel]\nurl = "https://example.invalid/kernel"\nmilestone = 0\ncommit = "x"\n' >"$OS/manifest.toml"
# A cargo shim: fmt and clippy succeed, `miri setup`
# prints a fake sysroot, `miri test` is an ordinary `cargo test` (the runner
# below fails when $FX/miri_fail exists); everything else is the real cargo. Every call is logged
# with the variables the harness must set.
cat >"$FX/bin/cargo" <<'EOF'
#!/bin/bash
a=("$@")
while [ "${a[0]:-}" = --config ]; do a=("${a[@]:2}"); done
echo "cwd=$(basename "$PWD") RUSTFLAGS=${RUSTFLAGS:-} MIRI_SYSROOT=${MIRI_SYSROOT:-} CARGO_HOME=${CARGO_HOME:-} :: ${a[*]}" >>"$FAKE_CALLS"
case "${a[0]}" in
  fmt | clippy) exit 0 ;;
  miri)
    case "${a[1]:-}" in
      setup) echo "Preparing a sysroot" >&2; echo "$FAKE_FX/fake-sysroot"; exit 0 ;;
      test) exec "$REAL_CARGO" test "${a[@]:2}" ;;
    esac ;;
esac
exec "$REAL_CARGO" "$@"
EOF
chmod +x "$FX/bin/cargo"
# Miri's runner, as the harness calls it for each test (`cargo-miri runner
# <test binary> <arguments>`): the test binary itself, natively, or the
# undefined behaviour Miri reports when $FX/miri_fail exists.
cat >"$FX/bin/fake-cargo-miri" <<'EOF'
#!/bin/bash
[ "$1" = runner ] || exit 2
if [ -e "$FAKE_FX/miri_fail" ] && [ "${3:-}" != --list ]; then echo "error: Undefined Behavior: fake"; exit 1; fi
exec "$2" "${@:3}"
EOF
chmod +x "$FX/bin/fake-cargo-miri"
export SILICA_MIRI_RUNNER=$FX/bin/fake-cargo-miri

# ---- the fake kernel repository: a real std-for-tests no_std crate -----------
cat >"$K/Cargo.toml" <<'EOF'
[workspace]
resolver = "3"
members = ["kernel-core"]
default-members = ["kernel-core"]

[workspace.package]
version = "0.0.0"
edition = "2024"
publish = false

[profile.release]
panic = "abort"
EOF
cat >"$K/kernel-core/Cargo.toml" <<'EOF'
[package]
name = "kernel-core"
version.workspace = true
edition.workspace = true
publish.workspace = true

[lints.rust]
unexpected_cfgs = { level = "warn", check-cfg = ['cfg(loom)'] }
EOF
write_lib() { # write_lib [model]: the lib, with a lib-level loom model when $1 is "model"
  {
    echo '#![no_std]'
    echo 'pub fn add(a: u32, b: u32) -> u32 { a + b }'
    echo '#[cfg(test)] extern crate std;'
    echo '#[cfg(test)] mod tests { #[test] fn adds() { std::println!("{}", std::vec![1, 2].len()); assert_eq!(super::add(1, 2), 3); } }'
    [ "${1:-}" = model ] && echo '#[cfg(loom)] mod models { #[test] fn lib_model() { assert!(cfg!(loom)); } }'
  } >"$K/kernel-core/src/lib.rs"
}
write_models() { # write_models <extra test code>: tests/loom_models.rs, compiled only under cfg(loom)
  { echo '#![cfg(loom)]'; echo '#[test] fn queue_model() { assert!(cfg!(loom)); }'; printf '%s\n' "$1"; } >"$K/kernel-core/tests/loom_models.rs"
}
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.invalid
(cd "$K" && git init -q . && git commit -qm fake --allow-empty) ||
  { echo "ERROR: host-harness: cannot create the fake kernel repository"; exit 2; }

# run <args...>: test.sh from the fake os; output in $OUT, status in $RC.
run() {
  : >"$CALLS"
  OUT=$(cd "$FX" && env -i PATH="$FX/bin:${PATH:-/usr/bin:/bin}" HOME="$FX" TMPDIR="$FX" RUSTUP_HOME="$RUSTUP_HOME" \
    SILICA_WS="$WS" FAKE_CALLS="$CALLS" FAKE_FX="$FX" REAL_CARGO="$REAL_CARGO" SILICA_MIRI_RUNNER="$SILICA_MIRI_RUNNER" \
    bash "$OS/tools/test.sh" "$@" 2>&1)
  RC=$?
}
nlines() { printf '%s\n' "$OUT" | wc -l; }
errs() { printf '%s\n' "$OUT" | grep -c '^ERROR:'; }
last() { printf '%s\n' "$OUT" | tail -n 1; }
has() { printf '%s\n' "$OUT" | grep -qE -- "$1"; }
called() { grep -qE -- "$1" "$CALLS"; }
shape() { # shape <case>: summary lines, ERROR lines and RESULT last; one summary line per suite
  local l seen=" " s
  while IFS= read -r l; do
    case "$l" in
      RESULT:* | ERROR:*) ;;
      *)
        printf '%s\n' "$l" | grep -qE '^[A-Za-z0-9_.-]+: pass=[0-9]+ fail=[0-9]+ skipped=[0-9]+$' ||
          { bad "$1: line is neither a suite summary, ERROR nor RESULT: $l"; continue; }
        s=${l%%:*}
        case "$seen" in *" $s "*) bad "$1: more than one summary line for suite $s" ;; esac
        seen+="$s " ;;
    esac
  done <<<"$OUT"
  [ "$(last | cut -c1-7)" = "RESULT:" ] || bad "$1: RESULT is not the final line: $(last)"
}

write_lib
cat >>"$K/kernel-core/src/lib.rs" <<'RS'
#[test]
#[ignore]
fn ignored_case() {}
RS
run --fast --repo kernel
[ "$RC" = 0 ] && has '^kernel\.host: pass=[0-9]+ fail=0 skipped=1$' || bad "an ignored test must count as skipped: $OUT"
# ---- 1. green: host std build, Miri, and every loom model as its own suite ---
write_lib model; write_models ''
run --full --repo kernel
[ "$RC" = 0 ] || bad "green: exit $RC, want 0: $OUT"
[ "$(errs)" = 0 ] || bad "green: unexpected ERROR: $OUT"
[ "$(nlines)" -le 30 ] || bad "green: $(nlines) lines, want at most 30"
shape green
has '^kernel\.host: pass=1 fail=0 skipped=0$' || bad "green: kernel-core must build and test on the host (std for tests); no 'kernel.host: pass=1': $OUT"
has '^kernel\.miri: pass=1 fail=0 skipped=0$' || bad "green: Miri must be its own suite 'kernel.miri: pass=1': $OUT"
has '^kernel\.loom\.queue_model: pass=1 fail=0 skipped=0$' || bad "green: model queue_model must be its own suite: $OUT"
has '^kernel\.loom\.models\.lib_model: pass=1 fail=0 skipped=0$' || bad "green: model models::lib_model must be its own suite: $OUT"
has '^kernel\.loom: ' && bad "green: with models present there must be no aggregate kernel.loom line: $OUT"
has '^RESULT: pass=8 fail=0 skipped=0 time=[0-9]+$' || bad "green: RESULT wrong (fmt, clippy, docs, host, miri, 2 models, size): $(last)"
called 'RUSTFLAGS=[^ ]*--cfg loom.* :: test .*-p kernel-core.* --list' || bad "green: models are not found with --cfg loom: $(cat "$CALLS")"
called ':: miri test .*-p kernel-core' || bad "green: Miri was not run on kernel-core: $(cat "$CALLS")"
called 'MIRI_SYSROOT=[^ ]*fake-sysroot .*:: miri test' || bad "green: the Miri sysroot prepared by 'miri setup' is not used: $(cat "$CALLS")"
called 'CARGO_HOME=[^ ]+ :: miri setup' || bad "green: 'miri setup' must run with the vendored-source CARGO_HOME: $(cat "$CALLS")"
called 'cwd=kernel .*:: miri setup' && bad "green: 'miri setup' must not run inside the checkout (it would read the checkout's vendor path, not the merged one)"
called 'RUSTFLAGS=[^ ]*--cfg loom.* :: test .*--release.* --exact queue_model' || bad "green: each model must be run by itself (release, cfg loom): $(cat "$CALLS")"
[ -s "$WS/target/logs/kernel.loom.queue_model/kernel-core_tests_loom_models.rs__queue_model.log" ] ||
  bad "green: no log for model queue_model under target/logs/kernel.loom.queue_model/: $(ls "$WS/target/logs" 2>&1 | tr '\n' ' ')"
grep -Rq 'queue_model' "$WS/target/logs/kernel.loom.queue_model" 2>/dev/null || bad "green: the model's log does not hold its test output"
grep -q 'lib_model' "$WS/target/logs/kernel.host"/* 2>/dev/null && bad "green: a cfg(loom) model ran in the plain host suite"

# ---- 2. a failing model: one ERROR naming its suite, the others still pass ---
write_models '#[test] fn lost_wakeup_model() { panic!("lost wakeup"); }'
write_lib model
run --full --repo kernel
[ "$RC" != 0 ] || bad "failing model: exit 0"
[ "$(errs)" = 1 ] || bad "failing model: want exactly 1 ERROR line, got $(errs): $OUT"
has '^ERROR: kernel\.loom\.lost_wakeup_model::[^ ]*lost_wakeup_model: .*panicked' || bad "failing model: ERROR is not 'ERROR: <suite>::<test>: <reason>' for the model: $OUT"
has '^kernel\.loom\.lost_wakeup_model: pass=0 fail=1 skipped=0$' || bad "failing model: its suite must count the failure: $OUT"
has '^kernel\.loom\.queue_model: pass=1 fail=0 skipped=0$' || bad "failing model: the other models still run and pass: $OUT"
has '^kernel\.host: pass=1 fail=0 skipped=0$' || bad "failing model: the host suite must stay green: $OUT"
has '^kernel\.miri: pass=1 fail=0 skipped=0$' || bad "failing model: Miri suite unaffected: $OUT"
has '^RESULT: pass=8 fail=1 skipped=0 time=[0-9]+$' || bad "failing model: RESULT wrong: $(last)"
shape failing-model
grep -Rq 'lost wakeup' "$WS/target/logs/kernel.loom.lost_wakeup_model" 2>/dev/null || bad "failing model: the panic message is not kept under target/logs/kernel.loom.lost_wakeup_model/"

# ---- 3. Miri reports a failure: one ERROR in kernel.miri, loom still runs ----
write_lib model; write_models ''; : >"$FX/miri_fail"
run --full --repo kernel
rm -f "$FX/miri_fail"
[ "$RC" != 0 ] && [ "$(errs)" = 1 ] || bad "miri failure: want exactly one ERROR and non-zero exit, got $(errs) (exit $RC): $OUT"
has '^ERROR: kernel\.miri::[^ ]+: .*Undefined Behavior' || bad "miri failure: ERROR must name suite kernel.miri and carry Miri's message: $OUT"
has '^kernel\.miri: pass=0 fail=1 skipped=0$' || bad "miri failure: summary wrong: $OUT"
has '^kernel\.loom\.queue_model: pass=1 ' || bad "miri failure: loom models must still run: $OUT"
shape miri-failure
grep -Rq 'Undefined Behavior' "$WS/target/logs/kernel.miri" 2>/dev/null || bad "miri failure: Miri's output is not kept under target/logs/kernel.miri/"

# ---- 4. no models: nothing to report before M2, an error from M2 on ----------
write_lib; rm -f "$K/kernel-core/tests/loom_models.rs"
run --full --repo kernel
[ "$RC" = 0 ] && [ "$(errs)" = 0 ] || bad "no models: exit $RC, $(errs) ERROR: $OUT"
has '^kernel\.loom' && bad "no models before M2: no kernel.loom line is expected: $OUT"
has '^kernel\.miri: pass=1 fail=0 skipped=0$' || bad "no models: Miri must still run: $OUT"
shape no-models
echo 2 >"$WS/MILESTONE"
run --full --repo kernel
rm -f "$WS/MILESTONE"
[ "$RC" != 0 ] || bad "no models at M2: must fail: $OUT"
has '^ERROR: kernel\.loom::models: no loom models \(required from M2\)' || bad "no models at M2: want an ERROR naming the missing models: $OUT"

# ---- 5. a model that does not compile: one ERROR, the host build stays green -
write_lib model; write_models 'fn broken() { let x: u32 = "no"; }'
run --full --repo kernel
[ "$RC" != 0 ] && [ "$(errs)" = 1 ] || bad "model build error: want exactly one ERROR and non-zero exit, got $(errs) (exit $RC): $OUT"
has '^ERROR: kernel\.loom::[^ ]+: .*error' || bad "model build error: ERROR must name suite kernel.loom and carry the compiler error: $OUT"
has '^kernel\.host: pass=1 fail=0 skipped=0$' || bad "model build error: the host suite must be unaffected: $OUT"
shape model-build-error

# ---- 6. --fast runs neither Miri nor loom ------------------------------------
write_lib model; write_models ''
run --fast --repo kernel
[ "$RC" = 0 ] && [ "$(errs)" = 0 ] || bad "fast: exit $RC: $OUT"
has 'miri|loom' && bad "fast: Miri or loom suites ran in --fast: $OUT"
called 'miri|--cfg loom' && bad "fast: Miri or loom was invoked in --fast: $(cat "$CALLS")"
has '^kernel\.host: pass=1 fail=0 skipped=0$' || bad "fast: kernel-core host tests must still run: $OUT"
shape fast

[ "$fails" = 0 ]
