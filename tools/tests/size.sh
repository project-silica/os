#!/usr/bin/env bash
# Test for tools/size.sh (component A02; spec/ARCHITECTURE.md
# section 2). Runs a private copy of the tool suite in a disposable fake
# workshop with a fake kernel repository, fake ELF/image artifacts and fake
# kernel sources, and checks every budget and bloat ceiling at, just under and
# just over its limit: a missing artifact is a SKIP before its milestone and
# an ERROR from it on; an artifact over its budget is an ERROR at every
# milestone. Nothing real is built. One "ERROR:" line per failed check.
set -uo pipefail
SRC=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd -P)
BASE=${SILICA_RUN:-${TMPDIR:-/tmp}}; mkdir -p "$BASE"
FX=$(mktemp -d "$BASE/sizetest.XXXX") || exit 2
FX=$(cd "$FX" && pwd -P)
trap 'rm -rf "${FX:?}"' EXIT
fails=0
bad() { echo "ERROR: size-test: $1"; fails=$((fails + 1)); }

WS=$FX/ws; OS=$WS/os; K=$WS/kernel
mkdir -p "$OS/tools" "$K"
echo x >"$WS/bootstrap.pins"
cp -r "$SRC/lib" "$SRC/size.sh" "$OS/tools/"
printf '# fake manifest\n' >"$OS/manifest.toml"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.invalid
(cd "$K" && git init -q . && git commit -qm fake --allow-empty) ||
  { echo "ERROR: size-test: cannot create the fake kernel repository"; exit 2; }
ART=$WS/target/cache/kernel-$(printf '%s' "$K" | sha256sum | cut -c1-16)/artifacts/x86_64

# ---- fixtures -----------------------------------------------------------------
bytes() { head -c "$1" /dev/zero >"$2"; }
mkelf() { # mkelf <text> <rodata> <fast> [allocator]: ELF whose section sizes are exactly these
  local t=$FX/t.bin args=() out=$ART/kernel.elf
  mkdir -p "$ART"; bytes "$1" "$t"
  objcopy -I binary -O elf64-x86-64 -B i386:x86-64 --rename-section .data=.text,alloc,load,readonly,code "$t" "$FX/k.o" || return 1
  if [ "$2" -gt 0 ]; then bytes "$2" "$FX/ro.bin"; args+=(--add-section ".rodata=$FX/ro.bin" --set-section-flags .rodata=alloc,load,readonly,data); fi
  if [ "$3" -gt 0 ]; then bytes "$3" "$FX/f.bin"; args+=(--add-section ".text.fast=$FX/f.bin" --set-section-flags .text.fast=alloc,load,readonly,code); fi
  [ -n "${4:-}" ] && args+=(--add-symbol "__rust_alloc=.text:0,global,function")
  objcopy "${args[@]}" "$FX/k.o" "$out" || return 1
}
lines() { # lines <n> <file>: n code lines plus blanks and comments that must not count
  mkdir -p "$(dirname "$2")"
  { echo "// comment"; echo; for ((i = 0; i < $1; i++)); do echo "let x$i = $i;"; done; echo "    // indented comment"; } >"$2"
}
enum_of() { # enum_of <name> <count> <file>: an enum with that many variants (some with data); a second enum must not count
  mkdir -p "$(dirname "$3")"
  { echo "pub enum $1 {"; for ((i = 0; i < $2; i++)); do
      case $((i % 3)) in 0) echo "    V$i,";; 1) echo "    V$i = $i,";; 2) echo "    V$i { a: u32, b: u32 },";; esac; done
    echo "}"; echo "pub enum Other { A, B, C }"; } >"$3"
}
fresh() { # fresh <milestone>: default kernel sources, no artifacts, then the milestone
  rm -rf "${WS:?}/target" "${K:?}/kernel" "${K:?}/kernel-core"
  mkdir -p "$K/kernel/arch/x86_64" "$ART"
  lines 100 "$K/kernel-core/src/lib.rs"; lines 100 "$K/kernel/src/main.rs"; lines 100 "$K/kernel/arch/x86_64/a.rs"
  enum_of Syscall 10 "$K/kernel-core/src/syscall.rs"; enum_of ObjectType 5 "$K/kernel-core/src/object.rs"
  echo "$1" >"$WS/MILESTONE"
}
good() { mkelf 100000 100000 20000; }  # a compliant x86_64 kernel image
run() { # run: size.sh in the fake workshop; output in $OUT, status in $RC
  OUT=$(cd "$FX" && env -i PATH="${PATH:-/usr/bin:/bin}" HOME="$FX" TMPDIR="$FX" SILICA_WS="$WS" \
    bash "$OS/tools/size.sh" 2>&1)
  RC=$?
}
src_lines() { # src_lines <n>: make the counted kernel source exactly n lines (adjusts kernel-core/src/lib.rs)
  local base
  lines 0 "$K/kernel-core/src/lib.rs"; run
  base=$(printf '%s\n' "$OUT" | sed -n 's/^size: kernel source lines[^:]*: \([0-9]*\)\/.*/\1/p')
  lines $(($1 - base)) "$K/kernel-core/src/lib.rs"
}
errs() { printf '%s\n' "$OUT" | grep -c '^ERROR:'; }
skips() { printf '%s\n' "$OUT" | grep -c '^SKIP:'; }
has() { printf '%s\n' "$OUT" | grep -qE -- "$1"; }
expect_pass() { # expect_pass <case> [skips wanted]
  run
  [ "$RC" = 0 ] || bad "$1: exit $RC, want 0: $OUT"
  [ "$(errs)" = 0 ] || bad "$1: unexpected ERROR: $OUT"
  has '^SIZE: PASS$' || bad "$1: no SIZE: PASS line: $OUT"
  [ -z "${2:-}" ] || [ "$(skips)" = "$2" ] || bad "$1: want $2 SKIP lines, got $(skips): $OUT"
}
expect_fail() { # expect_fail <case> <regex the one ERROR must match>
  run
  [ "$RC" = 1 ] || bad "$1: exit $RC, want 1: $OUT"
  [ "$(errs)" = 1 ] || bad "$1: want exactly one ERROR line, got $(errs): $OUT"
  printf '%s\n' "$OUT" | grep '^ERROR:' | grep -qE -- "$2" || bad "$1: ERROR does not match '$2': $OUT"
  has '^SIZE: FAIL$' || bad "$1: no SIZE: FAIL line: $OUT"
  has '^SIZE: PASS$' && bad "$1: printed SIZE: PASS despite an error"
}

# ---- 1. M0, nothing built: only SKIP lines (kernel image, fast path, 3 images) ----
fresh 0; rm -rf "${ART:?}"
expect_pass "m0-nothing" 4
has '^SKIP: size: kernel image' || bad "m0-nothing: no SKIP for the kernel image: $OUT"

# ---- 2. missing artifacts: SKIP before the milestone, one ERROR from it ----------
fresh 1; rm -rf "${ART:?}"
expect_fail "m1-no-kernel" 'kernel image \(x86_64\).*missing'
fresh 2; mkelf 100000 100000 0
expect_fail "m2-no-fast-section" 'fast path section'
fresh 1; mkelf 100000 100000 0
expect_pass "m1-no-fast-section-skips"
has '^SKIP: size: IPC fast path section' || bad "m1-no-fast-section-skips: no SKIP for .text.fast: $OUT"
fresh 1; good
expect_pass "m1-good"

# ---- 3. kernel image 256 KB text+rodata, from M1 --------------------------------
fresh 1; mkelf 131072 131072 0
expect_pass "image-at-budget"
has 'kernel text\+rodata \(x86_64\): 262144/262144' || bad "image-at-budget: wrong measurement: $OUT"
fresh 1; mkelf 131072 131073 0
expect_fail "image-over-budget" 'kernel text\+rodata.*262145 over budget 262144'
fresh 0; mkelf 131072 131073 0
expect_fail "image-over-budget-at-m0" 'kernel text\+rodata'
# Non-code sections are not counted.
fresh 1; mkelf 262144 0 0; bytes 100000 "$FX/d.bin"
objcopy --add-section ".data=$FX/d.bin" --set-section-flags .data=alloc,load,data "$ART/kernel.elf" "$FX/k2.elf" && cp "$FX/k2.elf" "$ART/kernel.elf"
expect_pass "data-section-not-counted"

# ---- 4. fast path 32 KB, from M2 -----------------------------------------------
fresh 2; mkelf 1000 1000 32768
expect_pass "fast-at-budget"
has 'IPC fast path.*: 32768/32768' || bad "fast-at-budget: wrong measurement: $OUT"
fresh 2; mkelf 1000 1000 32769
expect_fail "fast-over-budget-m2" 'IPC fast path.*32769 over budget 32768'
fresh 1; mkelf 1000 1000 32769
# Over budget fails before its milestone too: a measured artifact is never let through.
expect_fail "fast-over-budget-m1" 'IPC fast path.*32769 over budget 32768'

# ---- 5. kernel heap ceiling (linked allocator) ----------------------------------
fresh 1; mkelf 1000 1000 0 alloc
expect_fail "linked-allocator" 'kernel heap.*allocator'

# ---- 6. images: required-from milestones and sizes ----------------------------------
img() { truncate -s "$2" "$ART/$1"; [ "$1" != server.img ] || echo "$2" >"$ART/server.img.files"; }   # img <file> <bytes> (sparse; the server image with its files' size)
for spec in "core-text.bin:2097152:5:kernel \+ core servers" "server.img:16777216:4:minimal server image" "desktop.img:134217728:6:desktop image"; do
  IFS=: read -r f lim from name <<<"$spec"
  fresh $((from - 1)); good
  img core-text.bin 1000; img server.img 1000; img desktop.img 1000; rm -f "${ART:?}/$f" "${ART:?}/$f.files"
  run
  [ "$RC" = 0 ] && [ "$(errs)" = 0 ] || bad "$f-missing-before-m$from: want no ERROR, exit 0: $OUT"
  has "^SKIP: size: $name.*required from M$from" || bad "$f-missing-before-m$from: no SKIP naming M$from: $OUT"
  fresh "$from"; good
  img core-text.bin 1000; img server.img 1000; img desktop.img 1000; rm -f "${ART:?}/$f" "${ART:?}/$f.files"
  expect_fail "$f-missing-at-m$from" "$name.*artifact missing \(required from M$from\)"
  img "$f" "$lim"
  expect_pass "$f-at-budget"
  has "$name.*: $lim/$lim bytes" || bad "$f-at-budget: wrong measurement: $OUT"
  img "$f" $((lim + 1))
  expect_fail "$f-over-budget" "$name.*$((lim + 1)) over budget $lim"
  fresh $((from - 1)); good; img core-text.bin 1000; img server.img 1000; img desktop.img 1000; img "$f" $((lim + 1))
  expect_fail "$f-over-before-m$from" "$name.*$((lim + 1)) over budget $lim"
done
fresh 9; good; img core-text.bin 2097152; img server.img 16777216; img desktop.img 134217728
expect_pass "all-in-budget-m9" 0

# ---- 7. bloat ceilings (enforced from M1, and so at M0 too) -----------------------------
fresh 1; good
src_lines 11999
expect_pass "source-lines-below-limit"   # blanks and comments must not count
has "kernel source lines.*: 11999/12000" || bad "source-lines-below-limit: wrong count: $OUT"
src_lines 12000
expect_pass "source-lines-exactly-12000"
has 'kernel source lines.*: 12000/12000' || bad "source-lines-exactly-12000: wrong count: $OUT"
src_lines 12001
expect_fail "source-lines-over" 'kernel source lines.*12001 over budget 12000'
# Tests, benches and arch code do not count towards the 12,000.
src_lines 12000
lines 5000 "$K/kernel-core/tests/t.rs"; lines 5000 "$K/kernel/benches/b.rs"; lines 5000 "$K/kernel-core/src/tests/u.rs"
lines 3000 "$K/kernel/arch/x86_64/b.rs"
expect_pass "tests-and-arch-excluded"
# Arch directories: 4000 lines each, Rust and assembly, one count per directory.
fresh 1; good
lines 3900 "$K/kernel/arch/x86_64/a.rs"; lines 100 "$K/kernel/arch/x86_64/asm.S"
expect_pass "arch-at-limit"
has 'arch x86_64 lines.*: 4000/4000' || bad "arch-at-limit: wrong count: $OUT"
lines 101 "$K/kernel/arch/x86_64/asm.S"
expect_fail "arch-over" 'arch x86_64 lines.*4001 over budget 4000'
fresh 1; good
lines 3000 "$K/kernel/arch/x86_64/a.rs"; lines 3000 "$K/kernel/arch/aarch64/a.rs"; lines 4001 "$K/kernel/arch/riscv64/a.rs"
expect_fail "arch-each-checked-separately" 'arch riscv64 lines.*4001'

# Syscalls: 32. Object types: 10. Other enums do not count.
fresh 1; good
enum_of Syscall 32 "$K/kernel-core/src/syscall.rs"
expect_pass "syscalls-at-limit"
has 'syscalls: 32/32' || bad "syscalls-at-limit: wrong count: $OUT"
enum_of Syscall 33 "$K/kernel-core/src/syscall.rs"
expect_fail "syscalls-over" 'syscalls: 33 over budget 32'
fresh 1; good
enum_of ObjectType 10 "$K/kernel-core/src/object.rs"
expect_pass "object-types-at-limit"
has 'kernel object types: 10/10' || bad "object-types-at-limit: wrong count: $OUT"
enum_of ObjectType 11 "$K/kernel-core/src/object.rs"
expect_fail "object-types-over" 'kernel object types: 11 over budget 10'

# Heap allocation in kernel source: ceiling 0.
fresh 1; good
expect_pass "no-heap-in-source"
has 'kernel heap allocations: 0/0' || bad "no-heap-in-source: no 0/0 line: $OUT"
for pat in 'extern crate alloc;' '#[global_allocator]' 'let v = alloc::vec::Vec::new();'; do
  fresh 1; good
  printf '%s\n' "$pat" >>"$K/kernel/src/main.rs"
  expect_fail "heap-source '$pat'" 'kernel heap: allocation in kernel source'
done
fresh 1; good; printf 'extern crate alloc;\n' >>"$K/kernel/arch/x86_64/a.rs"
expect_fail "heap-in-arch-source" 'kernel heap: allocation in kernel source'
fresh 1; good; lines 1 "$K/kernel-core/src/tests/h.rs"; printf 'extern crate alloc;\n' >>"$K/kernel-core/src/tests/h.rs"
expect_pass "heap-in-tests-allowed"

# No kernel sources at all: the counts are zero; the tool must not scan its current directory.
fresh 1; good; rm -rf "${K:?}/kernel" "${K:?}/kernel-core"; mkdir -p "$K/kernel"; lines 20000 "$FX/stray.rs"
expect_pass "no-sources"
has 'kernel source lines.*: 0/12000' || bad "no-sources: want 0 source lines: $OUT"

# ---- 8. several failures: one ERROR line each, and the output stays short ----------------
fresh 1; mkelf 200000 100000 0 alloc
enum_of Syscall 40 "$K/kernel-core/src/syscall.rs"
run
[ "$RC" = 1 ] || bad "several: exit $RC, want 1"
[ "$(errs)" = 3 ] || bad "several: want 3 ERROR lines (image, allocator, syscalls), got $(errs): $OUT"
[ "$(printf '%s\n' "$OUT" | wc -l)" -le 20 ] || bad "several: output longer than 20 lines"
has '^SIZE: FAIL$' || bad "several: no SIZE: FAIL: $OUT"

# ---- 9. idempotent and read-only -------------------------------------------------------
fresh 1; good
before=$(cd "$WS" && find . -type f -not -path './kernel/.git/*' | sort | xargs sha256sum | sha256sum)
run; first=$OUT; run
[ "$OUT" = "$first" ] || bad "idempotent: second run differs"
after=$(cd "$WS" && find . -type f -not -path './kernel/.git/*' | sort | xargs sha256sum | sha256sum)
[ "$before" = "$after" ] || bad "read-only: size.sh changed files in the workshop"

if [ "$fails" = 0 ]; then echo "size-test: all checks passed"; exit 0; fi
exit 1
