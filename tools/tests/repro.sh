#!/usr/bin/env bash
# Test for tools/repro.sh (component A10, feature A10.01; spec/ARCHITECTURE.md
# section 11 "Builds are reproducible"): the kernel, the loader and the disk
# image are built twice in different directories (copies of the checkouts, own
# caches, original untouched, uncommitted work included, ignored files not),
# and the tool fails with the first differing artifact unless every artifact
# is byte-identical. Also checks that build_loader makes the PE header
# deterministic without losing the caller's flags.
#
# Runs a private copy of the tool suite in a disposable fake workshop whose
# lib/build.sh is replaced by fakes that record where they ran and write
# artifacts that differ on request. Nothing real is built. One "ERROR:" line
# per failed check.
set -uo pipefail
SRC=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd -P)
BASE=${SILICA_RUN:-${TMPDIR:-/tmp}}; mkdir -p "$BASE"
FX=$(mktemp -d "$BASE/reprotest.XXXX") || exit 2
FX=$(cd "$FX" && pwd -P)
trap 'rm -rf "${FX:?}"' EXIT
fails=0
bad() { echo "ERROR: repro-test: $1"; fails=$((fails + 1)); }

WS=$FX/ws; OS=$WS/os; K=$WS/kernel; CALLS=$FX/calls.log
mkdir -p "$WS/state" "$OS/tools" "$K/kernel/src" "$K/target" "$FX/bin" "$FX/home"
echo x >"$WS/bootstrap.pins"; echo 0 >"$WS/MILESTONE"
printf '[repos.kernel]\nurl = "https://example.invalid/kernel"\nmilestone = 0\ncommit = "x"\n' >"$OS/manifest.toml"
cp -r "$SRC/lib" "$SRC/repro.sh" "$OS/tools/"
echo "fn main() {}" >"$K/kernel/src/main.rs"; echo "target/" >"$K/.gitignore"
echo "ignored build output" >"$K/target/junk.bin"
echo "fn tool() {}" >"$OS/tool.rs"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.invalid
for r in "$K" "$OS"; do
  (cd "$r" && git init -q . && git add -A && git commit -qm fake) || { echo "ERROR: repro-test: cannot create the fake repositories"; exit 2; }
done
printf '#!/bin/sh\necho /fake/sysroot\n' >"$FX/bin/rustc"; chmod +x "$FX/bin/rustc"

# Fakes: every build records "<what> <n> kernel=<dir> os=<dir> cache=<dir> flags=<RUSTFLAGS>" and writes an
# artifact whose content is the same for every run, except as told by FAKE_DIFF (a space separated list of
# kernel, loader, image: that artifact embeds the directory it was built in) and FAKE_FAIL (<stage>:<n>:
# that stage fails in build number n, stage kernel, loader or image).
cat >"$OS/tools/lib/build.sh" <<'EOF2'
art_dir() { local d; d=$(cache_of kernel)/artifacts/$1; mkdir -p "$d"; echo "$d"; }
fake_build() { # fake_build <stage> <log> <file> <content-extra>
  local stage=$1 log=$2 file=$3 n flags
  n=$(grep -c "^$stage " "$FAKE_FX/calls.log"); n=$((n + 1))
  flags=$(printf '%s\n' "${CARGO_ENV[@]+"${CARGO_ENV[@]}"}" | sed -n 's/^RUSTFLAGS=//p')
  echo "$stage $n kernel=$(checkout_of kernel) os=$(checkout_of os) cache=$(cache_of kernel) pwd=$PWD flags=$flags" >>"$FAKE_FX/calls.log"
  { echo "main: $(cat "$(checkout_of kernel)/kernel/src/main.rs")"; echo "tool: $(cat "$(checkout_of os)/tool.rs")"
    ls "$(checkout_of kernel)/kernel/src" "$(checkout_of kernel)/target" 2>&1; } >>"$FAKE_FX/seen.log"
  echo "fake $stage log" >"$log"
  case " ${FAKE_FAIL:-} " in *" $stage:$n "*) echo "error: fake $stage failure in build $n" >"$log"; return 1 ;; esac
  local out; out=$(art_dir x86_64)/$file
  { echo "fake $stage"; cat "$(checkout_of kernel)/kernel/src/main.rs" "$(checkout_of os)/tool.rs"
    case " ${FAKE_DIFF:-} " in *" $stage "*) echo "built in $(checkout_of kernel)" ;; esac; } >"$out"
  [ -n "${FAKE_NOFILE:-}" ] && [ "$FAKE_NOFILE" = "$stage:$n" ] && rm -f "$out"
  echo "$out"
}
build_kernel() { fake_build kernel "$2" kernel.elf; }
build_loader() { fake_build loader "$1" BOOTX64.EFI; }
build_image() { fake_build image "$2" disk.img; }
EOF2

ORIG_STATUS=$(cd "$K" && git status --porcelain --ignored; cd "$OS" && git status --porcelain --ignored)

run() { # run <args...>: repro.sh in the fake workshop; output in $OUT, status in $RC
  : >"$CALLS"
  OUT=$(cd "$FX" && env -i PATH="$FX/bin:${PATH:-/usr/bin:/bin}" HOME="$FX/home" TMPDIR="$FX" SILICA_WS="$WS" FAKE_FX="$FX" \
    "${ENVX[@]+"${ENVX[@]}"}" bash "$OS/tools/repro.sh" "$@" 2>&1)
  RC=$?
}
ENVX=()
errs() { printf '%s\n' "$OUT" | grep -c '^ERROR:'; }
field() { # field <stage> <n> <name>: value recorded for that build
  if [ "$3" = flags ]; then grep "^$1 $2 " "$CALLS" | sed -n 's/^.* flags=//p'; return; fi
  grep "^$1 $2 " "$CALLS" | sed -n "s/^.* $3=\([^ ]*\).*/\1/p"
}

# ---- 1. identical builds -----------------------------------------------------
run
[ $RC = 0 ] || bad "reproducible: exit $RC, want 0: $OUT"
[ "$(errs)" = 0 ] || bad "reproducible: unexpected ERROR: $OUT"
printf '%s\n' "$OUT" | grep -q '^REPRO: OK$' || bad "reproducible: no REPRO: OK line: $OUT"
printf '%s\n' "$OUT" | grep -q 'REPRO: FAILED' && bad "reproducible: REPRO: FAILED printed"
for a in kernel.elf BOOTX64.EFI disk.img; do
  printf '%s\n' "$OUT" | grep -q "$a identical" || bad "reproducible: no line saying $a is identical: $OUT"
done
[ "$(wc -l <<<"$OUT")" -le 8 ] || bad "reproducible: output is long ($(wc -l <<<"$OUT") lines)"
for s in kernel loader image; do
  [ "$(grep -c "^$s " "$CALLS")" = 2 ] || bad "reproducible: $s built $(grep -c "^$s " "$CALLS") times, want 2"
done

# ---- 2. the two builds run in different directories, never in the original ---------
for s in kernel loader image; do
  k1=$(field $s 1 kernel); k2=$(field $s 2 kernel)
  o1=$(field $s 1 os); o2=$(field $s 2 os)
  c1=$(field $s 1 cache); c2=$(field $s 2 cache)
  [ -n "$k1" ] && [ -n "$k2" ] && [ "$k1" != "$k2" ] || bad "$s: both builds used the kernel directory '$k1' / '$k2'"
  [ "$o1" != "$o2" ] || bad "$s: both builds used the os directory '$o1'"
  [ "$c1" != "$c2" ] || bad "$s: both builds used the build cache '$c1'"
  for d in "$k1" "$k2"; do [ "$d" != "$K" ] || bad "$s: built in the original kernel checkout"; done
  for d in "$o1" "$o2"; do [ "$d" != "$OS" ] || bad "$s: built in the original os checkout"; done
  [ "${#k1}" != "${#k2}" ] || bad "$s: the two directories have the same path length (a length-dependent output would go unseen)"
done
[ "$(field kernel 1 kernel)" = "$(field loader 1 kernel)" ] && [ "$(field loader 1 kernel)" = "$(field image 1 kernel)" ] ||
  bad "build 1 used different directories for its stages"
[ "$(field kernel 2 kernel)" = "$(field loader 2 kernel)" ] && [ "$(field loader 2 kernel)" = "$(field image 2 kernel)" ] ||
  bad "build 2 used different directories for its stages"
[ ! -e "$(field kernel 1 kernel)" ] && [ ! -e "$(field kernel 2 kernel)" ] || bad "the build copies are left behind"
AFTER_STATUS=$(cd "$K" && git status --porcelain --ignored; cd "$OS" && git status --porcelain --ignored)
[ "$AFTER_STATUS" = "$ORIG_STATUS" ] || bad "the original checkouts were changed: $AFTER_STATUS"

# ---- 3. the copies hold the working tree: uncommitted edits yes, ignored files no ---
echo "fn main() { edited(); }" >"$K/kernel/src/main.rs"; echo "fn untracked() {}" >"$K/kernel/src/new.rs"
: >"$FX/seen.log"
run
[ $RC = 0 ] || bad "edited tree: exit $RC: $OUT"
grep -q 'main: fn main() { edited(); }' "$FX/seen.log" || bad "the build did not see the uncommitted edit of a tracked file"
grep -q '^new.rs$' "$FX/seen.log" || bad "the build did not see an untracked, not ignored file"
grep -q 'junk.bin' "$FX/seen.log" && bad "an ignored file (target/junk.bin) was copied into the build directory"
(cd "$K" && git checkout -q -- kernel/src/main.rs && rm -f kernel/src/new.rs)

# ---- 4. paths of the copies are remapped the same way in both builds ------------------
run
for s in kernel loader image; do
  for n in 1 2; do
    fl=$(field $s $n flags); kd=$(field $s $n kernel); od=$(field $s $n os); cd_=$(field $s $n cache)
    for d in "$kd" "$od" "$cd_" "$WS" /fake/sysroot; do
      grep -q -- "--remap-path-prefix=$d=" <<<"$fl" || bad "$s build $n: RUSTFLAGS do not remap $d: '$fl'"
    done
  done
  m1=$(field $s 1 flags | grep -o -- "--remap-path-prefix=$(field $s 1 kernel)=[^ ]*" | sed 's/^[^=]*=[^=]*=//')
  m2=$(field $s 2 flags | grep -o -- "--remap-path-prefix=$(field $s 2 kernel)=[^ ]*" | sed 's/^[^=]*=[^=]*=//')
  [ -n "$m1" ] && [ "$m1" = "$m2" ] || bad "$s: the kernel directories map to different names ('$m1' and '$m2')"
  m1=$(field $s 1 flags | grep -o -- "--remap-path-prefix=$(field $s 1 cache)=[^ ]*" | sed 's/^[^=]*=[^=]*=//')
  m2=$(field $s 2 flags | grep -o -- "--remap-path-prefix=$(field $s 2 cache)=[^ ]*" | sed 's/^[^=]*=[^=]*=//')
  [ -n "$m1" ] && [ "$m1" = "$m2" ] || bad "$s: the caches map to different names ('$m1' and '$m2')"
done

# ---- 5. a differing artifact: exit 1, one ERROR naming the first one ----------------------
expect_diff() { # expect_diff <case> <FAKE_DIFF> <artifact that must be named> <artifacts that must not be named>
  local c=$1 want=$3 a
  ENVX=(FAKE_DIFF="$2"); run; ENVX=()
  [ $RC = 1 ] || bad "$c: exit $RC, want 1: $OUT"
  [ "$(errs)" = 1 ] || bad "$c: want exactly one ERROR line, got $(errs): $OUT"
  printf '%s\n' "$OUT" | grep '^ERROR: repro: ' | grep -q -- "$want" || bad "$c: the ERROR line does not name $want: $OUT"
  for a in $4; do printf '%s\n' "$OUT" | grep '^ERROR:' | grep -q -- "$a" && bad "$c: the ERROR line names $a"; done
  printf '%s\n' "$OUT" | grep -q '^REPRO: FAILED$' || bad "$c: no REPRO: FAILED line: $OUT"
  printf '%s\n' "$OUT" | grep -q '^REPRO: OK$' && bad "$c: REPRO: OK printed for a differing build"
  [ -s "$FX/ws/target/logs/repro/$want/build1" ] && [ -s "$FX/ws/target/logs/repro/$want/build2" ] ||
    bad "$c: the two copies of $want are not kept under target/logs/repro/$want/"
}
expect_diff "kernel-differs" "kernel" "kernel.elf" "BOOTX64.EFI disk.img"
expect_diff "loader-differs" "loader" "BOOTX64.EFI" "kernel.elf disk.img"
expect_diff "image-differs" "image" "disk.img" "kernel.elf BOOTX64.EFI"
expect_diff "all-differ-first-named" "image loader kernel" "kernel.elf" "BOOTX64.EFI disk.img"
expect_diff "loader-and-image-differ" "image loader" "BOOTX64.EFI" "kernel.elf disk.img"
# The pass and the failure leave no stale copies of an earlier failure.
run
[ $RC = 0 ] && [ ! -e "$WS/target/logs/repro/kernel.elf" ] || bad "a later passing run keeps the earlier failure's artifacts"

# ---- 6. a build that fails: exit 1, one ERROR naming build and stage ----------------------
for spec in kernel:1 kernel:2 loader:1 loader:2 image:1 image:2; do
  st=${spec%:*}; n=${spec#*:}
  ENVX=(FAKE_FAIL="$spec"); run; ENVX=()
  [ $RC = 1 ] || bad "$spec-fails: exit $RC, want 1: $OUT"
  [ "$(errs)" = 1 ] || bad "$spec-fails: want exactly one ERROR line, got $(errs): $OUT"
  printf '%s\n' "$OUT" | grep '^ERROR: repro: ' | grep -q "build $n" || bad "$spec-fails: the ERROR line does not name build $n: $OUT"
  printf '%s\n' "$OUT" | grep '^ERROR: repro: ' | grep -qi "$st\|disk image" || bad "$spec-fails: the ERROR line does not name the stage $st: $OUT"
  printf '%s\n' "$OUT" | grep '^ERROR: repro: ' | grep -q "fake $st failure" || bad "$spec-fails: the ERROR line does not carry the build's own error: $OUT"
  printf '%s\n' "$OUT" | grep -q '^REPRO: OK$' && bad "$spec-fails: REPRO: OK printed"
  [ "$spec" != kernel:1 ] || [ "$(grep -c '^' "$CALLS")" = 1 ] || bad "kernel:1-fails: kept building after the failure"
done
ENVX=(FAKE_NOFILE="kernel:2"); run; ENVX=()
[ $RC = 1 ] && [ "$(errs)" = 1 ] && printf '%s\n' "$OUT" | grep -q 'kernel.elf' || bad "missing artifact: want exit 1 and one ERROR naming kernel.elf, got exit $RC: $OUT"

# ---- 7. usage errors: exit 2, one ERROR line, nothing built ---------------------------------
for args in "--bogus" "extra" "--checkout kernel" "--checkout kernel relative/dir" "--checkout kernel $FX/missing"; do
  # shellcheck disable=SC2086
  run $args
  [ $RC = 2 ] || bad "usage '$args': exit $RC, want 2: $OUT"
  printf '%s\n' "$OUT" | grep -q '^ERROR: repro: ' || bad "usage '$args': no ERROR: repro: line: $OUT"
  [ ! -s "$CALLS" ] || bad "usage '$args': something was built"
done

# ---- 8. --checkout names the checkout the copies come from ---------------------------------------
OS2=$FX/os-other
if git -C "$OS" worktree add -q "$OS2" -b other 2>/dev/null; then
  echo "fn other_tool() {}" >"$OS2/tool.rs"
  : >"$FX/seen.log"
  run --checkout os "$OS2"
  [ $RC = 0 ] || bad "--checkout os: exit $RC: $OUT"
  grep -q 'tool: fn other_tool() {}' "$FX/seen.log" || bad "--checkout os: the build did not use the named checkout"
  grep -q 'tool: fn tool() {}' "$FX/seen.log" && bad "--checkout os: the build used the default os checkout"
else
  bad "cannot create a second os worktree for the --checkout case"
fi

# ---- 9. build_loader: reproducible PE header, caller's flags kept -----------------------------------
cp "$SRC/lib/build.sh" "$OS/tools/lib/build.sh"
cat >"$OS/tools/probe-loader.sh" <<'EOF2'
#!/usr/bin/env bash
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"
. "$TOOLS/lib/build.sh"
cargo_run() { shift 2; printf 'ENV %s\n' "${CARGO_ENV[@]+"${CARGO_ENV[@]}"}"; printf 'ARG %s\n' "$@"; return 1; }
[ "${1:-}" = caller ] && CARGO_ENV=("RUSTFLAGS=-C foo=bar" "KEEP=me")
before=${#CARGO_ENV[@]}
build_loader "$SILICA_RUN/loader.log" 2>&1
echo "BEFORE=$before AFTER=${#CARGO_ENV[@]} OWN=${CARGO_ENV[*]:-}"
EOF2
for mode in none caller; do
  PL=$(cd "$FX" && env -i PATH="$FX/bin:${PATH:-/usr/bin:/bin}" HOME="$FX/home" TMPDIR="$FX" SILICA_WS="$WS" SILICA_RUN="$FX" \
    bash "$OS/tools/probe-loader.sh" $mode 2>&1)
  rf=$(printf '%s\n' "$PL" | sed -n 's/^ENV RUSTFLAGS=//p')
  grep -q -- '-C link-arg=/debug:none' <<<"$rf" || bad "build_loader ($mode): no /debug:none in RUSTFLAGS: $PL"
  grep -q -- '-C link-arg=/timestamp:' <<<"$rf" || bad "build_loader ($mode): no fixed /timestamp in RUSTFLAGS: $PL"
  grep -q 'ARG boot-uefi' <<<"$PL" || bad "build_loader ($mode): cargo was not asked for boot-uefi: $PL"
  after=$(printf '%s\n' "$PL" | sed -n 's/^BEFORE=\([0-9]*\) AFTER=\([0-9]*\).*/\1 \2/p')
  [ "${after% *}" = "${after#* }" ] && [ -n "$after" ] || bad "build_loader ($mode): the caller's CARGO_ENV changed ($after)"
  if [ $mode = caller ]; then
    grep -q -- '-C foo=bar' <<<"$rf" || bad "build_loader: the caller's RUSTFLAGS were dropped: $PL"
    printf '%s\n' "$PL" | grep -q '^ENV KEEP=me$' || bad "build_loader: the caller's other variables were dropped: $PL"
    [ "$(printf '%s\n' "$PL" | grep -c '^ENV RUSTFLAGS=')" = 1 ] || bad "build_loader: RUSTFLAGS set twice: $PL"
  fi
done

[ $fails = 0 ] && echo "repro-test: OK"
exit $((fails > 0))
