#!/usr/bin/env bash
# Test for tools/init.sh (component A02). Runs init.sh against a
# disposable fake environment: a private PATH holding symlinks to the real
# basic utilities plus stubs for the checked tools, a fake workshop with fake
# repositories, and a fake firmware tree (SILICA_FW_ROOT). Nothing is
# installed or changed. One "ERROR:" line per failed check.
set -uo pipefail
SRC=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd -P)
BASE=${SILICA_RUN:-${TMPDIR:-/tmp}}; mkdir -p "$BASE"
FX=$(mktemp -d "$BASE/inittest.XXXX") || exit 2
trap 'rm -rf "$FX"' EXIT
fails=0
bad() { echo "ERROR: init-test: $1"; fails=$((fails + 1)); }

TC=nightly-2026-10-01
REAL_WS=${SILICA_WS:-$(cd "$SRC/../.." && pwd -P)}

# ---- build a fake environment: $FX/<name>/{bin,ws,fw} ----------------------
# Real utilities init.sh and its library need, linked into the private PATH.
REAL_UTILS="bash env dirname basename readlink sed awk cat mkdir grep git head tr sort cut wc rm mktemp date sleep jq sha256sum find ls id uname true false test printf tee xargs"
stub() { printf '#!/bin/bash\nexit 0\n' >"$1"; chmod +x "$1"; }
mkenv() { # mkenv <name> [milestone]  (everything present, aarch64 included)
  local e=$FX/$1 t r
  mkdir -p "$e/bin" "$e/ws/kernel" "$e/fw/usr/share/OVMF" "$e/fw/usr/share/AAVMF"
  for t in $REAL_UTILS; do p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$e/bin/$t"; done
  for t in cargo size nm socat setpriv qemu-system-x86_64 qemu-system-aarch64; do stub "$e/bin/$t"; done
  cat >"$e/bin/rustup" <<'EOF'
#!/bin/bash
# fake: rustup component list --installed --toolchain <tc>
[ -f "$FAKE_TC_DIR/toolchain-missing" ] && exit 1
cat "$FAKE_TC_DIR/components"
EOF
  chmod +x "$e/bin/rustup"
  printf 'rust-src-x86_64\nclippy-x86_64\nrustfmt-x86_64\nmiri-x86_64\ncargo-x86_64\n' >"$e/components"
  printf '[toolchain]\nchannel = "%s"\n' "$TC" >"$e/ws/kernel/rust-toolchain.toml"
  echo "${2:-0}" >"$e/ws/MILESTONE"
  : >"$e/fw/usr/share/OVMF/OVMF_CODE_4M.fd"
  : >"$e/fw/usr/share/AAVMF/AAVMF_CODE.fd"
  cp "$REAL_WS/bootstrap.pins" "$e/ws/" 2>/dev/null || echo x >"$e/ws/bootstrap.pins"

  for r in $(sed -n 's/^\[repos\.\("\{0,1\}\)\([^]"]*\)\1\]$/\2/p' "$SRC/../manifest.toml") os; do
    mkdir -p "$e/ws/$r/.git"
  done
}
run() { # run <name>: init.sh in env <name>; output in $OUT, status in $RC
  local e=$FX/$1
  OUT=$(cd "$e" && env -i PATH="$e/bin" HOME="$e" SILICA_WS="$e/ws" SILICA_FW_ROOT="$e/fw" \
    FAKE_TC_DIR="$e" TMPDIR="$FX" "$e/bin/bash" "$SRC/init.sh" 2>&1)
  RC=$?
}
errs() { grep -c '^ERROR:' <<<"$OUT"; }
expect_one_error() { # expect_one_error <case> <text the ERROR must contain> <fix text it must contain>
  run "$1"
  [ "$RC" = 1 ] || bad "$1: exit $RC, want 1"
  [ "$(errs)" = 1 ] || bad "$1: want exactly one ERROR line, got: $OUT"
  grep '^ERROR:' <<<"$OUT" | grep -q -- "$2" || bad "$1: ERROR does not mention '$2': $OUT"
  grep '^ERROR:' <<<"$OUT" | grep -q "fix: .*$3" || bad "$1: ERROR carries no fix mentioning '$3': $OUT"
  grep -q '^INIT: OK' <<<"$OUT" && bad "$1: printed INIT: OK despite an error"
}

# ---- 1. nothing missing: OK, silent about errors, quick, idempotent ----------
mkenv ok
t0=$SECONDS; run ok; t1=$SECONDS
[ "$RC" = 0 ] || bad "ok: exit $RC, want 0: $OUT"
grep -q '^INIT: OK$' <<<"$OUT" || bad "ok: no INIT: OK line: $OUT"
[ "$(errs)" = 0 ] || bad "ok: unexpected ERROR: $OUT"
grep -q '^SKIP:' <<<"$OUT" && bad "ok: aarch64 is present, nothing to SKIP: $OUT"
[ $((t1 - t0)) -lt 10 ] || bad "ok: took $((t1 - t0)) s, want under 10"
first=$OUT; run ok
[ "$OUT" = "$first" ] && [ "$RC" = 0 ] || bad "ok: second run differs from the first (not idempotent)"
before=$(cd "$FX/ok" && find . -type f -o -type d | sort | sha256sum)
run ok
after=$(cd "$FX/ok" && find . -type f -o -type d | sort | sha256sum)
[ "$before" = "$after" ] || bad "ok: init.sh changed the environment it checks"

# ---- 2. SKIP for later-milestone pieces, ERROR once the milestone needs them -
mkenv later 0; rm -f "$FX/later/fw/usr/share/AAVMF/AAVMF_CODE.fd"
run later
[ "$RC" = 0 ] || bad "later: M0 without aarch64 firmware must still pass, exit $RC: $OUT"
[ "$(errs)" = 0 ] || bad "later: M0 without aarch64 must not ERROR: $OUT"
grep '^SKIP:' <<<"$OUT" | grep -q 'aarch64' || bad "later: no SKIP line for aarch64: $OUT"
grep '^SKIP:' <<<"$OUT" | grep -q 'fix:' || bad "later: SKIP line carries no fix: $OUT"
grep -q '^INIT: OK' <<<"$OUT" || bad "later: no INIT: OK at M0: $OUT"
mkenv m2 2; rm -f "$FX/m2/fw/usr/share/AAVMF/AAVMF_CODE.fd"
expect_one_error m2 aarch64 'aarch64'
grep -q '^SKIP:' <<<"$OUT" && bad "m2: aarch64 is needed at M2, must not SKIP: $OUT"
mkenv m2q 2; rm -f "$FX/m2q/bin/qemu-system-aarch64"
expect_one_error m2q aarch64 'aarch64'

# ---- 3. one ERROR line, with the fix, per missing piece ---------------------
for tool in git jq cargo rustup sha256sum size nm socat; do
  mkenv "no-$tool"; rm -f "$FX/no-$tool/bin/$tool"
  case $tool in git | jq | sha256sum) # also used by the library or the test shell; init.sh must still report it
    run "no-$tool"
    [ "$RC" != 0 ] || bad "no-$tool: exit 0 with $tool missing: $OUT"
    grep '^ERROR:' <<<"$OUT" | grep -q "$tool" || bad "no-$tool: no ERROR naming $tool: $OUT" ;;
    *) expect_one_error "no-$tool" "$tool" "install $tool" ;;
  esac
done
mkenv no-qemu; rm -f "$FX/no-qemu/bin/qemu-system-x86_64"
expect_one_error no-qemu qemu-system-x86_64 'QEMU'
mkenv no-ovmf; rm -f "$FX/no-ovmf/fw/usr/share/OVMF/OVMF_CODE_4M.fd"
expect_one_error no-ovmf OVMF 'edk2-ovmf'
mkenv no-toolchain; touch "$FX/no-toolchain/toolchain-missing"
expect_one_error no-toolchain "$TC" "rustup toolchain install $TC"
mkenv no-pin; : >"$FX/no-pin/ws/kernel/rust-toolchain.toml"
expect_one_error no-pin 'pinned toolchain' 'sync.sh'
for c in rust-src clippy rustfmt miri; do
  mkenv "no-$c"; grep -v "^$c" "$FX/no-$c/components" >"$FX/no-$c/c2" && mv "$FX/no-$c/c2" "$FX/no-$c/components"
  expect_one_error "no-$c" "component $c" "rustup component add $c --toolchain $TC"
done
mkenv no-repo; rm -rf "$FX/no-repo/ws/os/.git"
expect_one_error no-repo 'repository os' 'sync.sh'

# ---- 4. several missing pieces: one ERROR line each, exit 1 -----------------
mkenv many
rm -f "$FX/many/bin/socat" "$FX/many/bin/nm" "$FX/many/fw/usr/share/OVMF/OVMF_CODE_4M.fd"
grep -v '^miri' "$FX/many/components" >"$FX/many/c2" && mv "$FX/many/c2" "$FX/many/components"
run many
[ "$RC" = 1 ] || bad "many: exit $RC, want 1"
[ "$(errs)" = 4 ] || bad "many: want 4 ERROR lines (socat, nm, OVMF, miri), got $(errs): $OUT"
while IFS= read -r l; do
  case "$l" in ERROR:*"(fix: "*")") ;; ERROR:*) bad "many: ERROR line has no '(fix: ...)': $l" ;; esac
done <<<"$OUT"
grep -q '^INIT: OK' <<<"$OUT" && bad "many: printed INIT: OK despite errors"

# ---- 5. failing run is as quick as a passing one ----------------------------
t0=$SECONDS; run many; t1=$SECONDS
[ $((t1 - t0)) -lt 10 ] || bad "many: took $((t1 - t0)) s, want under 10"

[ $fails = 0 ] && echo "init-test: ok"
exit $((fails > 0))
