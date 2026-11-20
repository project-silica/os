#!/usr/bin/env bash
# Test for named in-OS tests (component A04, feature A04.02; spec/TESTING.md
# sections 1 and 2). Runs a private copy of the tool suite in a disposable
# fake workshop. Not under test and replaced: the cargo builds (the kernel,
# loader and image tool are placeholders) and QEMU. The fake image tool
# stores every `<path>=<file>` argument of the real build_image call in a
# text "disk"; the fake qemu.sh is a fake guest that reads the kernel command
# line from SILICA/CMDLINE.TXT on that disk and behaves by the name in its
# `test=<name>` word. Everything else is real: test.sh, run_named, run_inos,
# build_image, the sampling. One "ERROR:" line per failed check.
set -uo pipefail
SRC=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd -P)
BASE=${SILICA_RUN:-${TMPDIR:-/tmp}}; mkdir -p "$BASE"
FX=$(mktemp -d "$BASE/inosnamed.XXXX") || exit 2
trap 'rm -rf "$FX"' EXIT
fails=0
bad() { echo "ERROR: inos-named-test: $1"; fails=$((fails + 1)); }

WS=$FX/ws
OS=$WS/os
K=$WS/kernel
mkdir -p "$FX/bin" "$WS/state" "$OS/tools/tests" "$K/targets"
echo x >"$WS/bootstrap.pins"
echo 0 >"$WS/MILESTONE"
cp -r "$SRC/lib" "$SRC/test.sh" "$SRC/size.sh" "$OS/tools/"
printf '# fake manifest: no pinned repositories\n' >"$OS/manifest.toml"
for a in x86_64 aarch64 riscv64; do echo '{}' >"$K/targets/$a-silica.json"; done
cat >"$FX/bin/sandbox.sh" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done
shift
exec "$@"
EOF
printf '#!/bin/bash\nexit 0\n' >"$FX/bin/bwrap"
chmod +x "$FX/bin/sandbox.sh" "$FX/bin/bwrap"

# Builds are not under test: the kernel, the loader and the image tool are
# placeholders, appended to the real build.sh so the real build_image runs.
cat >>"$OS/tools/lib/build.sh" <<'EOF'
build_kernel() { local o; o=$(art_dir "$1")/kernel.elf; echo k >"$o"; echo "$o"; }
build_loader() { local o; o=$(art_dir x86_64)/BOOTX64.EFI; echo l >"$o"; echo "$o"; }
build_image_tool() {
  local o; o=$(cache_of os)/fake-silica-image; mkdir -p "$(dirname "$o")"
  cat >"$o" <<'TOOL'
#!/bin/bash
# the fake image tool: "<dst>\t<file contents on one line>" per argument
out=""; : >/dev/null
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out=$2; shift 2 ;;
    *=*) dst=${1%%=*}; src=${1#*=}; printf '%s\t%s\n' "$dst" "$(tr '\n' ' ' <"$src")" >>"$out.tmp"; shift ;;
    *) shift ;;
  esac
done
mv "$out.tmp" "$out" 2>/dev/null || : >"$out"
TOOL
  chmod +x "$o"; echo "$o"
}
EOF
# The fake guest. It never sees the test name except through the image's
# command line. Behaviours by name prefix (anything else is an ordinary pass):
#   fail_*    TEST <n> FAIL <reason>, debug-exit failure
#   silent_*  exits with the success code and prints no TEST line
#   other_*   TEST <another> PASS
#   crash_*   TEST <n> PASS then a failure exit code
#   both_*    TEST <n> PASS and TEST <n> FAIL
#   hang_*    the qemu.sh timeout: ERROR line, status 124
#   sub_*     TEST <n>x PASS (a name that only extends the asked one)
cat >"$OS/tools/qemu.sh" <<EOF
#!/bin/bash
serial="" img=""
while [ \$# -gt 0 ]; do case "\$1" in --serial) serial=\$2; shift 2 ;; --image) img=\$2; shift 2 ;; *) shift ;; esac; done
cmd=\$(awk -F'\t' '\$1 == "SILICA/CMDLINE.TXT" { print \$2 }' "\$img" 2>/dev/null)
echo "\$cmd" >>"$FX/cmdlines.log"
name=""; for w in \$cmd; do case "\$w" in test=*) name=\${w#test=} ;; esac; done
if [ -z "\$name" ]; then printf 'BOOT OK\r\n' >"\$serial"; exit 0; fi
case "\$name" in
  fail_*) printf 'booting\r\nTEST %s FAIL %s\r\n' "\$name" "assertion left != right" >"\$serial"; exit 1 ;;
  silent_*) printf 'booting\r\n' >"\$serial"; exit 0 ;;
  other_*) printf 'TEST %s PASS\r\n' "\${name}_not" >"\$serial"; exit 0 ;;
  crash_*) printf 'TEST %s PASS\r\n' "\$name" >"\$serial"; exit 1 ;;
  both_*) printf 'TEST %s PASS\r\nTEST %s FAIL late\r\n' "\$name" "\$name" >"\$serial"; exit 1 ;;
  hang_*) printf 'booting\r\n' >"\$serial"; echo "ERROR: qemu: x86_64: timeout after 1s (serial: \$serial)"; exit 124 ;;
  sub_*) printf 'TEST %sx PASS\r\n' "\$name" >"\$serial"; exit 0 ;;
esac
printf 'TEST %s PASS\r\n' "\$name" >"\$serial"; exit 0
EOF
chmod +x "$OS/tools/qemu.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.invalid
for r in "$OS" "$K"; do
  (cd "$r" && git init -q . && git add -A && git commit -qm fake) ||
    { echo "ERROR: inos-named-test: cannot create the fake repository $r"; exit 2; }
done

CLEAN=(env -i PATH="$FX/bin:${PATH:-/usr/bin:/bin}" HOME="$FX" TMPDIR="$FX" SILICA_WS="$WS" SILICA_SANDBOX="$FX/bin/sandbox.sh")
# run <args...>: a real test.sh run; OUT, RC and the results file RES
run() {
  : >"$FX/cmdlines.log"
  OUT=$(cd "$FX" && "${CLEAN[@]}" bash "$OS/tools/test.sh" "$@" 2>&1); RC=$?
  local r; r=$(ls -dt "$WS"/target/runs/test.* 2>/dev/null | head -n 1)
  RES=$r/results.tsv
}
status() { awk -F'\t' -v t="$1" '$3 == t { print $1 }' "$RES"; } # status of one result
reason() { awk -F'\t' -v t="$1" '$3 == t { print $4 }' "$RES"; }
asked() { sed -n 's/.*test=\([^ ]*\).*/\1/p' "$FX/cmdlines.log"; } # names the guest was asked for

guest_tests() {
  local args=() name
  for name in "$@"; do args+=(--guest "$name"); done
  run "${args[@]}"
}

# ---- 1. a named test boots with test=<name> and passes on its TEST line ----
guest_tests good_one
[ "$(status good_one)" = pass ] || bad "pass: a guest printing 'TEST good_one PASS' and exiting 0 must pass: [$(status good_one)] $(reason good_one)"
[ "$RC" = 0 ] || bad "pass: the run must succeed (exit $RC): $(printf '%s\n' "$OUT" | grep '^ERROR' | head -n 2)"
[ "$(asked)" = good_one ] || bad "pass: the kernel command line must carry test=good_one, got [$(asked | tr '\n' ' ')] (cmdlines: $(tr '\n' '|' <"$FX/cmdlines.log"))"

# ---- 2. a test name is passed to the kernel exactly, namespaces included ---
guest_tests mm::alloc.big-1_x
[ "$(status 'mm::alloc.big-1_x')" = pass ] && [ "$(asked)" = 'mm::alloc.big-1_x' ] || bad "name: mm::alloc.big-1_x did not reach the kernel intact: [$(asked | tr '\n' ' ')] $(reason 'mm::alloc.big-1_x')"

# ---- 3. every other outcome is a failure with a reason ---------------------
guest_tests fail_a silent_a other_a crash_a both_a hang_a sub_a
for t in fail_a silent_a other_a crash_a both_a hang_a sub_a; do
  [ "$(status $t)" = fail ] || bad "outcome: $t must fail, got [$(status $t)]"
done
reason fail_a | grep -q 'assertion left != right' || bad "outcome: fail_a must carry the guest's FAIL reason: [$(reason fail_a)]"
reason silent_a | grep -qi 'TEST' || bad "outcome: a guest that prints no TEST line must fail saying so: [$(reason silent_a)]"
reason hang_a | grep -qi 'timeout' || bad "outcome: a hung guest must fail with timeout: [$(reason hang_a)]"
printf '%s\n' "$OUT" | grep -q '^ERROR: inos\.x86_64::fail_a: .*assertion left != right' || bad "outcome: the ERROR line must name the test and the reason: $(printf '%s\n' "$OUT" | grep fail_a | head -n 1)"
[ "$RC" != 0 ] || bad "outcome: failing in-OS tests must fail the run"
printf '%s\n' "$OUT" | grep -qE '^RESULT: pass=0 fail=7 ' || bad "outcome: want pass=0 fail=7: $(printf '%s\n' "$OUT" | tail -n 1)"

# ---- 4. a malformed name never boots ---------------------------------------
guest_tests "bad name test=evil" "" "a;b"
n=$(awk -F'\t' '$1 == "fail"' "$RES" | wc -l)
[ "$n" = 3 ] || bad "malformed: three malformed names must be three failures, got $n"
[ ! -s "$FX/cmdlines.log" ] || bad "malformed: a malformed name reached the guest: $(cat "$FX/cmdlines.log" | head -n 2 | tr '\n' '|')"

# ---- 6. boot_ok stays the plain boot (no test=) ------------------------------
guest_tests boot_ok
[ "$(status boot_ok)" = pass ] || bad "boot_ok: must pass on BOOT OK: [$(status boot_ok)] $(reason boot_ok)"
grep -q 'test=' "$FX/cmdlines.log" && bad "boot_ok: the plain boot must not carry test="

# Full coverage includes every eligible test on each architecture due.
echo 2 >"$WS/MILESTONE"
mkdir -p "$K/tests"
printf '%s\n' ok_full fail_full >"$K/tests/inos-x86_64.txt"
echo ok_arm >"$K/tests/inos-aarch64.txt"
run --full --repo os
[ "$RC" != 0 ] && grep -q '^ERROR: inos.x86_64::fail_full:' <<<"$OUT" || bad "full omitted failing guest"
grep -q $'pass\tinos.x86_64\tok_full' "$RES" || bad "full omitted passing guest"
grep -q $'fail\tinos.aarch64\tok_arm' "$RES" || bad "full omitted required aarch64 guest"
echo 0 >"$WS/MILESTONE"

[ "$fails" = 0 ]
