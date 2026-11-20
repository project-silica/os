# Test ids:
#   <crate dir>/<target source>::<test path>   a Rust test, for example
#       kernel-core/tests/stub.rs::banner_is_boot_ok   (integration test file)
#       kernel-core/src/lib.rs::cap::tests::derive     (unit test in the lib)
#   inos/<arch>::<name>                          an in-OS test booted in QEMU
#   tools/tests/<name>.sh                        a tool self-test script in os
# Paths are relative to the root of the test's repository.

# Results are appended to $RES as "<status>\t<suite>\t<test>\t<reason>",
# status one of pass, fail, skip.
record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >>"$RES"; }
logfile() {
  local suite=$1 filename link_dir
  filename="$(printf '%s' "$2" | tr '/: ' '___').log"
  mkdir -p "$LOGS/$suite"
  if [ "$LOGS" != "$OUTBASE/logs" ]; then
    # Stable path to the latest log; each run also keeps its own private copy.
    link_dir=$OUTBASE/logs/$suite
    mkdir -p "$link_dir"
    ln -sfnT "$LOGS/$suite/$filename" "$link_dir/$filename"
  fi
  echo "$LOGS/$suite/$filename"
}

# Cargo packages of a checkout: "<name>\t<crate dir relative to repo>\t<default member 0|1>"
packages() {
  local dir; dir=$(checkout_of "$1")
  (cd "$dir" && cargo metadata --no-deps --format-version 1 --offline 2>/dev/null) | jq -r --arg root "$dir/" '
    (.workspace_default_members // .workspace_members) as $def
    | .packages[] | [.name, (.manifest_path | ltrimstr($root) | rtrimstr("/Cargo.toml") | if . == "Cargo.toml" then "." else . end),
      (if (.id as $i | $def | index($i)) then 1 else 0 end)] | @tsv'
}

# Parse `cargo test` output: "<status>\t<id>\t<reason>" per test.
parse_cargo_tests() { # parse_cargo_tests <crate dir> <log>
  awk -v cd="$1" '
    /^ *Running unittests / { t = $3; next }
    /^ *Running / { t = $2; next }
    /^ *Doc-tests / { t = "doc"; next }
    /^test .* \.\.\. / {
      line = $0; sub(/^test /, "", line); res = line; sub(/.* \.\.\. /, "", res); name = line; sub(/ \.\.\. .*/, "", name)
      sub(/ - should panic$/, "", name)
      id = cd "/" t "::" name
      if (res ~ /^ok/) print "pass\t" id "\t"
      else if (res ~ /^ignored/) print "ignored\t" id "\tignored"
      else print "fail\t" id "\tfailed"
    }' "$2"
}

# Parse `cargo test -- --list` output: one test id per line, ids as in parse_cargo_tests.
parse_cargo_list() { # parse_cargo_list <crate dir> <log>
  awk -v cd="$1" '
    /^ *Running unittests / { t = $3; next }
    /^ *Running / { t = $2; next }
    /^ *Doc-tests / { t = "doc"; next }
    /: test$/ { name = $0; sub(/: test$/, "", name); print cd "/" t "::" name }' "$2"
}

first_error() { grep -m1 -E '^(error|ERROR)|panicked|assertion' "$1" | cut -c1-160; }

# TEST_ARGS: extra `cargo test` arguments for run_named (loom models run with --release).
TEST_ARGS=()

# run_named <repo> <test id> <suite> [expect-fail]
# Records the outcome; returns 0 pass, 1 fail, 3 missing, 4 ignored.
run_named() {
  local repo=$1 id=$2 suite=$3 log path name dir crate rel pkg sel
  log=$(logfile "$suite" "$id")
  case "$id" in
    inos/*::*)
      local arch=${id%%::*}; arch=${arch#inos/}; name=${id#*::}
      run_inos "$arch" "$suite" "$name"; return $? ;;
    *.sh)
      dir=$(checkout_of "$repo")
      [ -f "$dir/$id" ] || { record fail "$suite" "$id" "missing"; return 3; }
      mkdir -p "$RUN/named"
      (cd "$dir" && sandboxed "$RUN/named" "$LOGS" -- env SILICA_WS="$WS" SILICA_RUN="$RUN/named" bash "$dir/$id") >"$log" 2>&1
      if [ $? = 0 ]; then record pass "$suite" "$id"; return 0; fi
      record fail "$suite" "$id" "$(first_error "$log")"; return 1 ;;
  esac
  path=${id%%::*}; name=${id#*::}
  [ "$path" != "$id" ] && [ -n "$name" ] || { record fail "$suite" "$id" "malformed test id"; return 3; }
  dir=$(checkout_of "$repo")
  [ -f "$dir/$path" ] || { record fail "$suite" "$id" "missing: no file $path"; return 3; }
  # The crate is the deepest package directory that contains the file.
  local best="" bestlen=-1 n d _
  while IFS=$'\t' read -r n d _; do
    if [ "$d" = . ] || [ "${path#"$d"/}" != "$path" ]; then
      [ ${#d} -gt $bestlen ] && { best=$n; crate=$d; bestlen=${#d}; }
    fi
  done < <(packages "$repo")
  [ -n "$best" ] || { record fail "$suite" "$id" "missing: no crate contains $path"; return 3; }
  pkg=$best; rel=${path#"$crate"/}; [ "$crate" = . ] && rel=$path
  case "$rel" in
    tests/*.rs) sel=(--test "$(basename "$rel" .rs)") ;;
    src/lib.rs) sel=(--lib) ;;
    src/main.rs) sel=(--bin "$pkg") ;;
    src/bin/*.rs) sel=(--bin "$(basename "$rel" .rs)") ;;
    *) record fail "$suite" "$id" "unsupported test path $rel"; return 3 ;;
  esac
  cargo_run "$repo" "$log" test "${TEST_ARGS[@]+"${TEST_ARGS[@]}"}" -p "$pkg" "${sel[@]}" -- --exact "$name"
  local out; out=$(parse_cargo_tests "$crate" "$log" | awk -F'\t' -v id="$id" '$2 == id')
  case "$out" in
    pass*) record pass "$suite" "$id"; return 0 ;;
    ignored*) record fail "$suite" "$id" "ignored"; return 4 ;;
    fail*) record fail "$suite" "$id" "$(grep -m1 -E 'panicked|assert' "$log" | cut -c1-160)"; return 1 ;;
  esac
  if grep -q 'could not compile' "$log"; then record fail "$suite" "$id" "build failed: $(first_error "$log")"; return 1; fi
  record fail "$suite" "$id" "missing: no test named $name"; return 3
}

# run_inos <arch> <suite> [name]: boots the image and records one result.
# boot_ok is the plain boot: the stub writes BOOT OK and exits through the
# debug-exit device. Any other name is an in-OS test: the kernel command line
# (SILICA/CMDLINE.TXT on the ESP) carries test=<name>, the kernel prints one
# line "TEST <name> PASS" or "TEST <name> FAIL <reason>" on serial and exits
# through the debug-exit device. A name that is empty or has a character
# outside A-Za-z0-9_.:- never boots. A missing line, a line for another name,
# both PASS and FAIL, a PASS with a failing exit status, or a timeout is a failure.
run_inos() {
  local arch=$1 suite=$2 name=${3-boot_ok} log img serial cmdline="" rc
  case "$name" in ''|*[!A-Za-z0-9_.:-]*) record fail "$suite" "$name" "malformed in-OS test name"; return 3 ;; esac
  [ "$name" = boot_ok ] || cmdline="test=$name"
  log=$(logfile "$suite" "build.$name")
  img=$(build_image "$arch" "$log" "$cmdline") || { record fail "$suite" "$name" "image build failed (log: $log)"; return 1; }
  serial=$(logfile "$suite" "$name")
  "$TOOLS/qemu.sh" --arch "$arch" --image "$img" --serial "$serial" --timeout "${SILICA_QEMU_TIMEOUT:-60}" >"$serial.qemu" 2>&1
  rc=$?
  local lines npass nfail nother why
  lines=$(tr -d '\r' <"$serial" 2>/dev/null)
  if [ "$name" = boot_ok ]; then
    if [ $rc = 0 ] && grep -qx 'BOOT OK' <<<"$lines"; then record pass "$suite" "$name"; return 0; fi
  else
    npass=$(grep -cxF "TEST $name PASS" <<<"$lines")
    nfail=$(grep -cE "^TEST ${name//./\\.} FAIL( .*)?\$" <<<"$lines")
    nother=$(grep -E '^TEST ' <<<"$lines" | grep -vcE "^TEST ${name//./\\.} (PASS|FAIL( .*)?)\$")
    if [ $rc = 0 ] && [ "$npass" = 1 ] && [ "$nfail" = 0 ] && [ "$nother" = 0 ]; then record pass "$suite" "$name"; return 0; fi
  fi
  # The log of a failed boot, decoded against the kernel ELF just booted.
  [ -x "$TOOLS/symbolize.sh" ] && "$TOOLS/symbolize.sh" --arch "$arch" "$serial" >"$serial.symbolized" 2>&1
  if [ $rc = 124 ]; then record fail "$suite" "$name" "timeout"; return 1; fi
  if [ "$name" = boot_ok ]; then
    record fail "$suite" "$name" "no BOOT OK or bad exit status $rc (serial: $serial)"; return 1
  fi
  if [ "$nfail" -gt 0 ]; then
    why=$(grep -m1 -E "^TEST ${name//./\\.} FAIL" <<<"$lines" | sed "s/^TEST [^ ]* FAIL *//" | cut -c1-140)
    [ "$npass" = 0 ] && [ "$nfail" = 1 ] || why="both PASS and FAIL lines or repeated: $why"
    record fail "$suite" "$name" "${why:-failed} (serial: $serial)"
  elif [ "$nother" -gt 0 ]; then record fail "$suite" "$name" "TEST line for another test (serial: $serial)"
  elif [ "$npass" -gt 1 ]; then record fail "$suite" "$name" "TEST $name PASS printed $npass times (serial: $serial)"
  elif [ "$npass" = 1 ]; then record fail "$suite" "$name" "TEST $name PASS but bad exit status $rc (serial: $serial)"
  else record fail "$suite" "$name" "no TEST $name PASS/FAIL line, exit status $rc (serial: $serial)"; fi
  return 1
}
