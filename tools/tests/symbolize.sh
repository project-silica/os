#!/usr/bin/env bash
# Test for tools/symbolize.sh (component A09, feature A09.01): addresses in a
# serial log (panic messages, register dumps, backtraces) decode to function,
# file and line using the kernel ELF test.sh booted.
#
# Runs a private copy of the tool suite in a disposable fake workshop. The ELF is
# a real one built here from a small Rust program with known functions (linked
# in the kernel's high half and, for the plain case, low), so a known address
# decodes to a known symbol and source line; the expected lines are read from
# markers in the program's source. One "ERROR:" line per failed check.
set -uo pipefail
SRC=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd -P)
BASE=${SILICA_RUN:-${TMPDIR:-/tmp}}; mkdir -p "$BASE"
FX=$(mktemp -d "$BASE/symtest.XXXX") || exit 2
FX=$(cd "$FX" && pwd -P)
trap 'rm -rf "${FX:?}"' EXIT
fails=0
bad() { echo "ERROR: symbolize-test: $1"; fails=$((fails + 1)); }

WS=$FX/ws; OS=$WS/os; K=$WS/kernel
mkdir -p "$WS/state" "$OS/tools" "$K"
echo x >"$WS/bootstrap.pins"; echo 0 >"$WS/MILESTONE"
cp -r "$SRC/lib" "$SRC/symbolize.sh" "$OS/tools/"
printf '[repos.kernel]\nurl = "https://example.invalid/kernel"\nmilestone = 0\ncommit = "x"\n' >"$OS/manifest.toml"

# ---- the test ELFs ----------------------------------------------------------
PROG=$FX/prog.rs
cat >"$PROG" <<'EOF'
#![no_std]
#![no_main]
#[panic_handler]
fn on_panic(_: &core::panic::PanicInfo<'_>) -> ! {
    loop {}
}
#[unsafe(no_mangle)]
pub extern "C" fn rust_eh_personality() {}
#[unsafe(no_mangle)]
#[inline(never)]
pub extern "C" fn known_leaf(x: u64) -> u64 { // MARK-LEAF
    core::hint::black_box(x) + 1
}
#[unsafe(no_mangle)]
#[inline(never)]
pub extern "C" fn known_caller(x: u64) -> u64 {
    known_leaf(x) // MARK-CALL
} // MARK-AFTER-CALL
#[unsafe(no_mangle)]
pub extern "C" fn _start() -> ! {
    let _ = known_caller(3);
    loop {}
}
EOF
line_of() { grep -n "$1" "$PROG" | head -1 | cut -d: -f1; }
L_LEAF=$(line_of MARK-LEAF); L_CALL=$(line_of MARK-CALL); L_AFTER=$(line_of MARK-AFTER-CALL)

build_elf() { # build_elf <out> <image base or empty>
  local out=$1 base=$2 extra=()
  [ -n "$base" ] && extra=(-C code-model=kernel -C "link-arg=-Wl,--image-base=$base")
  (cd "$FX" && rustc --edition 2024 -g -C opt-level=0 -C panic=abort -C relocation-model=static \
    -C link-arg=-nostartfiles -C link-arg=-static -C link-arg=-no-pie "${extra[@]}" "$PROG" -o "$out") >"$out.log" 2>&1
}
HIGH=$FX/high.elf; LOW=$FX/low.elf
build_elf "$HIGH" 0xffffffff80000000 || { bad "cannot build the high-half test ELF: $(grep -m1 -E 'error' "$HIGH.log")"; exit 1; }
build_elf "$LOW" "" || { bad "cannot build the low test ELF: $(grep -m1 -E 'error' "$LOW.log")"; exit 1; }

sym_addr() { nm "$1" | awk -v s="$2" '$3 == s { print "0x" $1 }'; }
LEAF=$(sym_addr "$HIGH" known_leaf); CALLER=$(sym_addr "$HIGH" known_caller)
[ -n "$LEAF" ] && [ -n "$CALLER" ] || { bad "test ELF lacks known_leaf or known_caller"; exit 1; }
# The return address of the call to known_leaf inside known_caller: the
# instruction after the call, which belongs to the closing-brace line.
C4=$(printf "0x%x" $((CALLER + 4)))
RET=$(objdump -d --no-show-raw-insn "$HIGH" --disassemble=known_caller |
  awk '/call.*<known_leaf>/ { f = 1; next } f { sub(/:.*/, "", $1); print "0x" $1; exit }')
[ -n "$RET" ] || { bad "cannot find the return address in known_caller"; exit 1; }
LOWLEAF=$(sym_addr "$LOW" known_leaf)
off() { printf '0x%x' $(($1 + $2)); }

# ---- running the tool ---------------------------------------------------------
run() { # run <args...>: output in $OUT, status in $RC
  OUT=$(cd "$FX" && env -i PATH="${PATH:-/usr/bin:/bin}" HOME="$FX" TMPDIR="$FX" SILICA_WS="$WS" \
    ${A2L:+SILICA_ADDR2LINE="$A2L"} bash "$OS/tools/symbolize.sh" "$@" 2>&1)
  RC=$?
}
runin() { # runin <stdin file> <args...>
  local in=$1; shift
  OUT=$(cd "$FX" && env -i PATH="${PATH:-/usr/bin:/bin}" HOME="$FX" TMPDIR="$FX" SILICA_WS="$WS" \
    ${A2L:+SILICA_ADDR2LINE="$A2L"} bash "$OS/tools/symbolize.sh" "$@" <"$in" 2>&1)
  RC=$?
}
nerr() { printf '%s\n' "$OUT" | grep -c '^ERROR:'; }
has() { printf '%s\n' "$OUT" | grep -qE -- "$1"; }
expect() { # expect <name> <rc> <ERROR lines>
  [ "$RC" = "$2" ] || bad "$1: exit status $RC, expected $2 (output: $(printf '%s' "$OUT" | head -c 400))"
  [ "$(nerr)" = "$3" ] || bad "$1: $(nerr) ERROR lines, expected $3 (output: $(printf '%s' "$OUT" | head -c 400))"
}
at() { printf 'at .*prog\\.rs:%s$' "$1"; } # a decoded line ends with the file and line

for A2L in "" addr2line; do
  tag=${A2L:-default}
  # ---- --addr mode ------------------------------------------------------------
  run --elf "$HIGH" --addr "$LEAF"
  expect "$tag: known address" 0 0
  [ "$(printf '%s\n' "$OUT" | wc -l)" = 1 ] || bad "$tag: --addr printed more than one line: $OUT"
  has "^$LEAF known_leaf $(at "$L_LEAF")" || bad "$tag: known_leaf did not decode to its function and line $L_LEAF: $OUT"

  run --elf "$HIGH" --addr "$(off "$LEAF" 4)" "$CALLER"
  expect "$tag: two addresses" 0 0
  has "known_leaf at " || bad "$tag: an address inside known_leaf did not decode to it: $OUT"
  has "^$CALLER known_caller " || bad "$tag: known_caller not decoded: $OUT"

  run --elf "$HIGH" --addr "${LEAF#0x}"
  expect "$tag: address without 0x" 0 0
  has "known_leaf " || bad "$tag: address without the 0x prefix not decoded: $OUT"

  run --elf "$HIGH" --addr 0xffffffffdead0000
  expect "$tag: address outside the image" 1 1
  case "$OUT" in *0xffffffffdead0000*) ;; *) bad "$tag: the ERROR does not name the address: $OUT" ;; esac

  run --elf "$HIGH" --addr "$LEAF" 0x10
  expect "$tag: one bad address among good ones" 1 1
  has "known_leaf " || bad "$tag: the good address was not decoded next to a bad one: $OUT"

  run --elf "$LOW" --addr "$LOWLEAF"
  expect "$tag: low-linked ELF" 0 0
  has "known_leaf " || bad "$tag: low-linked ELF not decoded: $OUT"

  run --elf "$LOW" --bias 0x1000 --addr "$(off "$LOWLEAF" 0x1000)"
  expect "$tag: load bias" 0 0
  has "^$(off "$LOWLEAF" 0x1000) known_leaf " || bad "$tag: --bias not applied (the decoded line keeps the address as given): $OUT"
done
A2L=""

# ---- log mode -----------------------------------------------------------------
LOG=$FX/serial.log
cat >"$LOG" <<EOF
BOOT start
kernel panic: assertion failed at kernel/src/x.rs:10:5
rip=$LEAF rsp=0xffff800000001000 rflags=0x00000246 code=0x10
backtrace:
#0 $LEAF
#1 $RET
#2: ${C4#0x}
  frame 0x1 is not an address and neither is 0x0
no addresses on this line
EOF
run --elf "$HIGH" "$LOG"
expect "log" 0 0
# Every original line is still there, in order, and nothing else changed.
printf '%s\n' "$OUT" | grep -vE '^    (0x)?[0-9a-f]+ .* at ' | cmp -s - "$LOG" || bad "log: the log lines were not preserved around the decoded lines: $OUT"
decoded=$(printf '%s\n' "$OUT" | grep -cE '^    (0x)?[0-9a-f]+ .* at ')
[ "$decoded" = 4 ] || bad "log: $decoded decoded lines, expected 4 (rip, #0, #1, #2): $OUT"
printf '%s\n' "$OUT" | awk '/^rip=/ { getline; print; exit }' | grep -qE "^    $LEAF known_leaf $(at "$L_LEAF")" ||
  bad "log: the line with rip= is not followed by its decoding: $OUT"
printf '%s\n' "$OUT" | grep -A1 '^#0 ' | grep -qE "^    $LEAF known_leaf " || bad "log: frame #0 not decoded under its line: $OUT"
# Frame #1 holds a return address: the call site (known_caller, the call line)
# is decoded, not the instruction after the call (the closing-brace line).
printf '%s\n' "$OUT" | grep -A1 '^#1 ' | grep -qE "^    $RET known_caller $(at "$L_CALL")" ||
  bad "log: frame #1 did not decode to the call site (line $L_CALL, not $L_AFTER): $OUT"
printf "%s\n" "$OUT" | grep -A1 "^#2: " | grep -qE "^    ${C4#0x} known_caller " || bad "log: frame #2 without 0x not decoded: $OUT"
case "$OUT" in *"rsp=0xffff800000001000"*) ;; *) bad "log: the register line was altered" ;; esac
printf "%s\n" "$OUT" | grep -E "^    " | grep -qF 0xffff800000001000 && bad "log: a stack address was decoded"
printf '%s\n' "$OUT" | grep -A1 '^  frame 0x1' | grep -qE '^    ' && bad "log: 0x1 or 0x0 was decoded"

# The same log on standard input, with "-" and without an argument.
runin "$LOG" --elf "$HIGH"
expect "stdin" 0 0
printf '%s\n' "$OUT" | grep -qE "^    $LEAF known_leaf " || bad "stdin: not decoded"
runin "$LOG" --elf "$HIGH" -
expect "stdin dash" 0 0
printf '%s\n' "$OUT" | grep -qE "^    $LEAF known_leaf " || bad "stdin dash: not decoded"

# A log with nothing to decode comes out unchanged, status 0.
printf 'BOOT OK\nhello 0x10 world\n' >"$FX/plain.log"
run --elf "$HIGH" "$FX/plain.log"
expect "plain log" 0 0
[ "$OUT" = "$(cat "$FX/plain.log")" ] || bad "plain log: output differs from the input: $OUT"
: >"$FX/empty.log"
run --elf "$HIGH" "$FX/empty.log"
expect "empty log" 0 0
[ -z "$OUT" ] || bad "empty log: output $OUT"

# Carriage returns from the serial line (CRLF) do not hide an address.
printf 'rip=%s\r\n#0 %s\r\n' "$LEAF" "$LEAF" >"$FX/crlf.log"
run --elf "$HIGH" "$FX/crlf.log"
expect "crlf log" 0 0
[ "$(printf '%s\n' "$OUT" | grep -cE '^    0x[0-9a-f]+ known_leaf ')" = 2 ] || bad "crlf log: both addresses not decoded: $OUT"

# ---- the ELF test.sh booted ----------------------------------------------------
# Without --elf the tool reads the kernel checkout's artifact cache, where
# test.sh leaves kernel.elf for each architecture.
CACHE=$WS/target/cache/kernel-$(printf '%s' "$K" | sha256sum | cut -c1-16)
mkdir -p "$CACHE/artifacts/x86_64"; cp "$HIGH" "$CACHE/artifacts/x86_64/kernel.elf"
run --addr "$LEAF"
expect "default ELF" 0 0
has "known_leaf " || bad "default ELF: the cached x86_64 kernel.elf was not used: $OUT"
run --arch aarch64 --addr "$LEAF"
expect "missing ELF for another architecture" 2 1
case "$OUT" in *artifacts/aarch64/kernel.elf*) ;; *) bad "missing ELF: the ERROR does not name the expected path: $OUT" ;; esac
mkdir -p "$CACHE/artifacts/aarch64"; cp "$LOW" "$CACHE/artifacts/aarch64/kernel.elf"
run --arch aarch64 --addr "$LOWLEAF"
expect "--arch selects the ELF" 0 0
has "known_leaf " || bad "--arch aarch64 did not use the aarch64 kernel.elf: $OUT"

# ---- usage errors (one ERROR line, status 2) ------------------------------------
run --elf "$HIGH" --bogus
expect "unknown option" 2 1
run --elf "$FX/none.elf" --addr "$LEAF"
expect "missing --elf file" 2 1
run --elf "$HIGH" "$FX/none.log"
expect "missing log file" 2 1
run --elf "$HIGH" --addr
expect "--addr without addresses" 2 1
run --elf "$HIGH" --addr zzzz
expect "--addr not hex" 2 1
run --elf "$HIGH" --bias xyz --addr "$LEAF"
expect "bad bias" 2 1
run --elf "$HIGH" "$LOG" --addr "$LEAF"
expect "log and --addr together" 2 1
run --elf "$HIGH" "$LOG" "$LOG"
expect "two logs" 2 1
run --elf "$HIGH" --arch
expect "--arch without a value" 2 1
A2L=no-such-addr2line-tool
run --elf "$HIGH" --addr "$LEAF"
expect "no addr2line installed" 2 1
A2L=

[ "$fails" = 0 ]
