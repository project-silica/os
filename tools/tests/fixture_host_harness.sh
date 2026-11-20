#!/usr/bin/env bash
# Fixture for the host harness (component A05; run by `test.sh --full` only,
# because the real Miri interpreter and its sysroot build take a while).
# tools/tests/host_harness.sh checks the harness logic against a cargo shim;
# this one runs the real thing on a tiny kernel-core in a disposable fake
# workshop: the pinned nightly's Miri must build its sysroot offline (no
# network, vendored sources only), pass a clean crate, and report a test with
# undefined behavior as one ERROR in suite kernel.miri; a cfg(loom) model must
# run as its own suite. One "ERROR:" line per failed check.
set -uo pipefail
SRC=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd -P)
BASE=${SILICA_RUN:-${TMPDIR:-/tmp}}; mkdir -p "$BASE"
FX=$(mktemp -d "$BASE/hostfix.XXXX") || exit 2
FX=$(cd "$FX" && pwd -P)
trap 'rm -rf "${FX:?}"' EXIT
fails=0
bad() { echo "ERROR: host-fixture: $1"; fails=$((fails + 1)); }

TOOLCHAIN=${SILICA_WS:+$SILICA_WS/kernel/rust-toolchain.toml}
[ -f "${TOOLCHAIN:-}" ] || TOOLCHAIN=$SRC/../../kernel/rust-toolchain.toml
[ -f "$TOOLCHAIN" ] || { echo "ERROR: host-fixture: no kernel rust-toolchain.toml to take the pinned nightly from"; exit 2; }
RUSTUP_HOME=${RUSTUP_HOME:-${HOME:-/root}/.rustup}
WS=$FX/ws; OS=$WS/os; K=$WS/kernel
mkdir -p "$FX/bin" "$OS/tools" "$K/kernel-core/src"
echo x >"$WS/bootstrap.pins"; echo 0 >"$WS/MILESTONE"
cp -r "$SRC/lib" "$SRC/test.sh" "$SRC/size.sh" "$SRC/qemu.sh" "$OS/tools/"
printf '[repos.kernel]\nurl = "https://example.invalid/kernel"\nmilestone = 0\ncommit = "x"\n' >"$OS/manifest.toml"
cat >"$FX/bin/sandbox.sh" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done
shift
exec "$@"
EOF
printf '#!/bin/bash\nexit 0\n' >"$FX/bin/bwrap"
chmod +x "$FX/bin/sandbox.sh" "$FX/bin/bwrap"
cp "$TOOLCHAIN" "$K/rust-toolchain.toml"
cat >"$K/Cargo.toml" <<'EOF'
[workspace]
resolver = "3"
members = ["kernel-core"]
default-members = ["kernel-core"]

[workspace.package]
version = "0.0.0"
edition = "2024"
publish = false
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
good() {
  cat >"$K/kernel-core/src/lib.rs" <<'EOF'
#![no_std]

pub fn add(a: u32, b: u32) -> u32 {
    a + b
}

#[cfg(test)]
extern crate std;

#[cfg(test)]
mod tests {
    #[test]
    fn adds() {
        assert_eq!(super::add(1, 2), 3);
    }
}

#[cfg(loom)]
mod models {
    #[test]
    fn two_threads_model() {
        assert!(cfg!(loom));
    }
}
EOF
}
good
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.invalid
(cd "$K" && git init -q . && git commit -qm fake --allow-empty) ||
  { echo "ERROR: host-fixture: cannot create the fake kernel repository"; exit 2; }
run() {
  OUT=$(cd "$FX" && env -i PATH="$FX/bin:${PATH:-/usr/bin:/bin}" HOME="$FX" TMPDIR="$FX" RUSTUP_HOME="$RUSTUP_HOME" \
    SILICA_WS="$WS" SILICA_SANDBOX="$FX/bin/sandbox.sh" bash "$OS/tools/test.sh" --full --repo kernel 2>&1)
  RC=$?
}
has() { printf '%s\n' "$OUT" | grep -qE -- "$1"; }

run
[ "$RC" = 0 ] || bad "clean crate: exit $RC: $OUT"
has '^kernel\.miri: pass=1 fail=0 skipped=0$' || bad "clean crate: real Miri did not pass kernel-core (no 'kernel.miri: pass=1'): $OUT"
has '^kernel\.loom\.models\.two_threads_model: pass=1 fail=0 skipped=0$' || bad "clean crate: the cfg(loom) model did not run as its own suite: $OUT"
has '^kernel\.host: pass=1 fail=0 skipped=0$' || bad "clean crate: host std build and test did not pass: $OUT"

cat >>"$K/kernel-core/src/lib.rs" <<'EOF'

#[cfg(test)]
mod ub {
    #[test]
    fn reads_past_the_end() {
        let v = core::hint::black_box([1u8, 2]);
        let p = v.as_ptr();
        // SAFETY: deliberately wrong; one past the end. The test exists to
        // prove that the Miri suite reports undefined behavior.
        let x = unsafe { *p.add(2) };
        core::hint::black_box(x);
    }
}
EOF
run
[ "$RC" != 0 ] || bad "undefined behavior: exit 0, Miri did not fail the run: $OUT"
[ "$(printf '%s\n' "$OUT" | grep -c '^ERROR:')" = 1 ] || bad "undefined behavior: want exactly one ERROR line: $OUT"
has '^ERROR: kernel\.miri::[^ ]+: .*Undefined Behavior' || bad "undefined behavior: ERROR must be 'kernel.miri::<test>: ...Undefined Behavior': $OUT"
has '^kernel\.host: pass=2 fail=0 skipped=0$' || bad "undefined behavior: the plain host run does not see the UB and must pass: $OUT"

[ "$fails" = 0 ]
