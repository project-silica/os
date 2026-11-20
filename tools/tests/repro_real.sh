#!/usr/bin/env bash
# Test for tools/repro.sh against a real nondeterministic image builder
# (component A10; spec/ARCHITECTURE.md section 16 "Builds are
# reproducible"). tools/tests/repro.sh checks repro.sh against fakes; this one
# runs the real tools/repro.sh, with the real builds, in a disposable workshop:
#   1. an os checkout whose image builder takes the disk GUID from the
#      clock must give "REPRO: FAILED", one ERROR line naming disk.img, and
#      identical kernel and loader;
#   2. the same checkout with the plant removed must give "REPRO: OK" and three identical
#      artifacts.
# Both runs build twice (about a minute each, so --fast does not run this test;
# see suite_tools in test.sh). Nothing outside the disposable workshop is
# written. One "ERROR:" line per failed check.
set -uo pipefail
SRC_OS=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd -P)
find_ws() {
  if [ -n "${SILICA_WS:-}" ]; then (cd "$SILICA_WS" && pwd -P); return; fi
  local d=$SRC_OS
  while [ "$d" != / ]; do
    if [ -f "$d/bootstrap.pins" ]; then echo "$d"; return; fi
    d=$(dirname "$d")
  done
  return 1
}
REAL_WS=$(find_ws) || { echo "ERROR: repro-real: cannot find the workshop root"; exit 2; }
SRC_KERNEL=$REAL_WS/kernel
[ -d "$SRC_KERNEL" ] || { echo "ERROR: repro-real: no kernel checkout at $SRC_KERNEL"; exit 2; }
BASE=${SILICA_RUN:-$REAL_WS/target}; mkdir -p "$BASE"
FX=$(mktemp -d "$BASE/reproreal.XXXX") || exit 2
FX=$(cd "$FX" && pwd -P)
trap 'rm -rf "${FX:?}"' EXIT
fails=0
bad() { echo "ERROR: repro-real: $1"; fails=$((fails + 1)); }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.invalid
gx() { git -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"; }
copy_repo() { # copy_repo <source checkout> <dest>: tracked and not ignored files, as a fresh one-commit repository
  mkdir -p "$2"
  gx -C "$1" ls-files -z --cached --others --exclude-standard |
    tar -C "$1" --null -T - --ignore-failed-read -cf - 2>/dev/null | tar -C "$2" -xf -
  (cd "$2" && gx init -q -b main . && gx add -A && gx commit -qm base) >/dev/null 2>&1
}

# ---- disposable workshop with the real tools, the real os and the real kernel ----
W=$FX/ws; mkdir -p "$W"; touch "$W/bootstrap.pins"
copy_repo "$SRC_OS" "$W/os"
copy_repo "$SRC_KERNEL" "$W/kernel"
{ [ -f "$W/os/tools/repro.sh" ] && [ -f "$W/os/image-builder/src/lib.rs" ] && [ -f "$W/kernel/Cargo.toml" ]; } ||
  { echo "ERROR: repro-real: cannot create the disposable workshop"; exit 2; }

# The planted nondeterminism: the disk GUID from the clock.
LIB=$W/os/image-builder/src/lib.rs
CLOCK='\&std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos().to_le_bytes()'
sed -i "s|copy_from_slice(&DISK_GUID);|copy_from_slice($CLOCK);|" "$LIB"
grep -q 'SystemTime::now' "$LIB" || { echo "ERROR: repro-real: the plant did not apply to image-builder/src/lib.rs"; exit 2; }

repro() { # repro <out file> [args]: the real repro.sh of the disposable workshop; status in <out file>.rc
  local out=$1; shift
  (cd "$FX" && env TMPDIR="$FX" SILICA_WS="$W" \
    bash "$W/os/tools/repro.sh" "$@" >"$out" 2>&1; echo $? >"$out.rc")
}
# One after the other: both runs keep their logs under the workshop's target/logs/repro.
repro "$FX/planted.out"
cp -r "$W/target/logs/repro" "$FX/planted-logs" 2>/dev/null
gx -C "$W/os" checkout -q -- image-builder/src/lib.rs
[ -z "$(gx -C "$W/os" status --porcelain)" ] || bad "the plant was not removed from the os checkout"
repro "$FX/clean.out"

# ---- 1. the planted nondeterministic image builder ------------------------------------------
OUT=$(cat "$FX/planted.out"); RC=$(cat "$FX/planted.out.rc" 2>/dev/null)
[ "$RC" = 1 ] || bad "planted: exit ${RC:-none}, want 1: $OUT"
printf '%s\n' "$OUT" | grep -qx 'REPRO: FAILED' || bad "planted: no REPRO: FAILED line: $OUT"
printf '%s\n' "$OUT" | grep -qx 'REPRO: OK' && bad "planted: REPRO: OK printed for a nondeterministic image builder"
[ "$(printf '%s\n' "$OUT" | grep -c '^ERROR:')" = 1 ] || bad "planted: want exactly one ERROR line: $OUT"
printf '%s\n' "$OUT" | grep '^ERROR: repro: ' | grep -q 'disk\.img' || bad "planted: the ERROR line does not name disk.img: $OUT"
printf '%s\n' "$OUT" | grep '^ERROR:' | grep -q 'kernel\.elf\|BOOTX64' && bad "planted: the ERROR line names an artifact that is reproducible: $OUT"
printf '%s\n' "$OUT" | grep -q 'kernel\.elf identical' || bad "planted: kernel.elf was not reported identical: $OUT"
printf '%s\n' "$OUT" | grep -q 'BOOTX64\.EFI identical' || bad "planted: BOOTX64.EFI was not reported identical: $OUT"
[ -s "$FX/planted-logs/disk.img/build1" ] && [ -s "$FX/planted-logs/disk.img/build2" ] ||
  bad "planted: the two disk images are not kept under target/logs/repro/disk.img/"

# ---- 2. the unmodified checkout ----------------------------------------------------------------
OUT=$(cat "$FX/clean.out"); RC=$(cat "$FX/clean.out.rc" 2>/dev/null)
[ "$RC" = 0 ] || bad "unmodified: exit ${RC:-none}, want 0: $OUT"
printf '%s\n' "$OUT" | grep -qx 'REPRO: OK' || bad "unmodified: no REPRO: OK line: $OUT"
printf '%s\n' "$OUT" | grep -q 'REPRO: FAILED' && bad "unmodified: REPRO: FAILED printed: $OUT"
[ "$(printf '%s\n' "$OUT" | grep -c '^ERROR:')" = 0 ] || bad "unmodified: unexpected ERROR: $OUT"
for a in kernel.elf BOOTX64.EFI disk.img; do
  printf '%s\n' "$OUT" | grep -q "$a identical" || bad "unmodified: no line saying $a is identical: $OUT"
done

[ $fails = 0 ] && echo "repro-real: OK"
exit $((fails > 0))
