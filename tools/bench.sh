#!/usr/bin/env bash
# Benchmarks against Linux (spec/TESTING.md section 4).
#   bench.sh [--runs <n>] [--out <results.json>] [--update-ratchet]
#
# Builds the Silica benchmark image (the kernel's root task run with "bench"
# on its command line) and the Linux baseline image (tools/lib/linux.sh, from
# the pinned source in bench/linux), then boots them alternately, Silica
# first, --runs times each (default 5) in this one session, on the same pinned
# host processors with the same virtual machine. Both guests print
#     BENCH <metric> <number> <unit>     one line per metric, then
#     BENCH DONE
# and the host stamps "BENCH MARK userspace" for the boot time. A metric's
# value is the median over the runs; its noise is the median absolute
# deviation; the noise of a ratio to Linux combines both systems' deviations.
#
# Each metric below has a gate against Linux and the milestone it applies
# from (the MILESTONE file in the workshop root). Before that milestone a
# miss or a missing value is a SKIP line, from it an ERROR. Every metric is
# also a ratchet: bench/ratchet.tsv keeps the best ratio to Linux (or the best
# value where Linux has no equivalent), and a result worse than that by more
# than three times the noise is an ERROR. --update-ratchet records
# improvements in that file, to be committed with the change that earned them.
# Timings are gated only under KVM; under TCG they are printed and recorded.
#
# Output: one line per metric, one ERROR: bench::<metric>: line per failure,
# a "behind Linux" line naming every metric still slower than Linux (the
# system is not finished while there is one), last line
# RESULT: pass=<n> fail=<n> skipped=<n> time=<s>.
# Exit: 0 pass, 1 a gate failed, 2 usage or setup error, 3 Linux baseline unavailable.
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"
. "$TOOLS/lib/build.sh"
. "$TOOLS/lib/linux.sh"
start=$SECONDS
export LC_ALL=C

# name unit better gate limit from-milestone
#   gate: win  ours/linux strictly below limit     le   ours/linux at most limit
#         min  ours at least limit (no Linux value needed)
#         max  ours at most limit                  none ratchet only
METRICS='ipc_roundtrip ns lower win 0.5 2
ctx_switch ns lower le 1 2
boot_userspace ms lower win 1 2
timer_overshoot_p99 ns lower le 1 2
ipc_scaling x higher min 7 2
ipc_cross_pairs1 ops/s higher le 1 2
ipc_cross_pairs4 ops/s higher le 1 2
ipc_cross_scaling x higher none - 2
page_fault ns lower none - 2
null_syscall ns lower none - 2
ipc_roundtrip_p99 ns lower none - 2
ctx_switch_p99 ns lower none - 2
timer_overshoot ns lower none - 2'

runs=5 out="" update=0
while [ $# -gt 0 ]; do
  case "$1" in
    --runs) [ $# -ge 2 ] || die "--runs needs a value"; runs=$2; shift 2 ;;
    --out) [ $# -ge 2 ] || die "--out needs a file"; out=$2; shift 2 ;;
    --update-ratchet) update=1; shift ;;
    *) die "unknown argument $1" ;;
  esac
done
case "$runs" in ''|0|*[!0-9]*) die "--runs must be a positive number" ;; esac
command -v jq >/dev/null || die "jq is not installed (run tools/init.sh)"

OS=$(checkout_of os)
RATCHET=$OS/bench/ratchet.tsv
ms=$(milestone)
mkdir -p "$LOGS/bench"
new_run
pass=0 fail=0 skipped=0
accel=tcg; [ -w /dev/kvm ] && [ -z "${SILICA_NO_KVM:-}" ] && accel=kvm
SMP=${SILICA_BENCH_SMP:-8} MEM=${SILICA_BENCH_MEM:-512}

finish() {
  echo "RESULT: pass=$pass fail=$fail skipped=$skipped time=$((SECONDS - start))"
  [ "$fail" = 0 ] || exit 1
  exit 0
}
ok() { echo "bench: $1"; pass=$((pass + 1)); }
enforce() { # enforce <metric> <from-milestone> <message>: ERROR from the milestone (under KVM), SKIP before
  if [ "$ms" -ge "$2" ] && [ $accel = kvm ]; then echo "ERROR: bench::$1: $3"; fail=$((fail + 1))
  else echo "SKIP: bench: $1: $3 (gated from M$2 under KVM)"; skipped=$((skipped + 1)); fi
}
fmt() { awk -v x="$1" 'BEGIN { printf "%.4g", x }'; }

# Host processors for the guests: $SILICA_BENCH_CPUS, else one hardware thread
# of each of the fastest cores, as many as the guest has processors.
pin=${SILICA_BENCH_CPUS:-}
if [ -z "$pin" ] && [ -d /sys/devices/system/cpu/cpu0/topology ]; then
  pin=$(for c in /sys/devices/system/cpu/cpu[0-9]*; do
      [ -r "$c/topology/thread_siblings_list" ] || continue
      first=$(cut -d, -f1 "$c/topology/thread_siblings_list" | cut -d- -f1)
      [ "${c##*cpu}" = "$first" ] || continue
      echo "$(cat "$c/cpufreq/cpuinfo_max_freq" 2>/dev/null || echo 0) ${c##*cpu}"
    done | sort -k1,1nr -k2,2n | head -n "$SMP" | awk '{ print $2 }' | sort -n | paste -sd, -)
fi

log=$LOGS/bench/build.silica.log
# $SILICA_BENCH_IMG names a ready-made Silica image (used by the tool's own test).
silica=${SILICA_BENCH_IMG:-$(build_image x86_64 "$log" bench)} && [ -f "$silica" ] || { err "cannot build the Silica benchmark image (log: $log)"; echo "RESULT: pass=0 fail=1 skipped=0 time=$((SECONDS - start))"; exit 2; }
log=$LOGS/bench/build.linux.log
linux=$(build_linux "$log"); rc=$?
if [ $rc = 3 ]; then
  echo "ERROR: bench::baseline: Linux baseline unavailable: $(tail -n 1 "$log") (log: $log)"
  echo "RESULT: pass=0 fail=1 skipped=0 time=$((SECONDS - start))"; exit 3
elif [ $rc != 0 ]; then
  err "cannot build the Linux baseline image: $(grep -m1 -iE 'error' "$log" | cut -c1-160) (log: $log)"
  echo "RESULT: pass=0 fail=1 skipped=0 time=$((SECONDS - start))"; exit 2
fi

# boot <system> <image> <run>: one boot; appends "<metric> <value>" lines to $RUN/<system>.values
boot() {
  local sys=$1 img=$2 i=$3 ser=$RUN/$1.$3.serial st=$RUN/$1.$3.stamp qlog=$LOGS/bench/$1.$3.log rc t0 t1
  "$TOOLS/qemu.sh" --image "$img" --serial "$ser" --stamp "$st" --timeout "${SILICA_BENCH_TIMEOUT:-300}" \
    --smp "$SMP" --mem "$MEM" ${pin:+--pin "$pin"} >"$qlog" 2>&1
  rc=$?
  if [ $rc = 2 ]; then err "$sys: qemu.sh setup error: $(head -c 200 "$qlog" | tr '\n' ' ')"; echo "RESULT: pass=$pass fail=1 skipped=$skipped time=$((SECONDS - start))"; exit 2; fi
  if ! tr -d '\r' <"$ser" 2>/dev/null | grep -qx 'BENCH DONE'; then
    echo "ERROR: bench::$sys: run $i did not finish (qemu.sh exit $rc, no BENCH DONE; serial $ser)"
    echo "RESULT: pass=$pass fail=1 skipped=$skipped time=$((SECONDS - start))"; exit 1
  fi
  tr -d '\r' <"$ser" | awk '$1 == "BENCH" && NF == 4 && $3 ~ /^[0-9]+([.][0-9]+)?$/ { print $2, $3, $4 }' >>"$RUN/$sys.values"
  # Boot time, by the host's clock: emulator start to the first line from userspace.
  t0=$(awk '$2 == "QEMU" && $3 == "START" { print $1; exit }' "$st")
  t1=$(tr -d '\r' <"$st" | awk '$2 == "BENCH" && $3 == "MARK" { print $1; exit }')
  [ -n "$t0" ] && [ -n "$t1" ] && awk -v a="$t0" -v b="$t1" 'BEGIN { printf "boot_userspace %.3f ms\n", (b - a) * 1000 }' >>"$RUN/$sys.values"
}
for ((i = 1; i <= runs; i++)); do
  boot silica "$silica" "$i"
  boot linux "$linux" "$i"
done

# stat <system> <metric>: "<median> <mad>" over the runs, empty when never reported.
stat() {
  awk -v m="$2" '$1 == m { print $2 }' "$RUN/$1.values" | sort -g | awk '
    { v[NR] = $1 }
    END { if (!NR) exit; med = (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2
      for (i = 1; i <= NR; i++) { d[i] = v[i] - med; if (d[i] < 0) d[i] = -d[i] }
      n = asort(d); mad = (n % 2) ? d[(n + 1) / 2] : (d[n / 2] + d[n / 2 + 1]) / 2
      print med, mad }'
}
ratchet_of() { [ -f "$RATCHET" ] && awk -F'\t' -v m="$1" '$1 == m { print $2; exit }' "$RATCHET"; }

behind="" results=() newratchet=$RUN/ratchet.tsv
printf '# Best result per metric (tools/bench.sh --update-ratchet). vs-linux: ours/linux for\n# lower-is-better metrics, linux/ours otherwise; value: the metric itself.\n' >"$newratchet"
while read -r name unit better gate limit from; do
  read -r o omad <<<"$(stat silica "$name")"
  read -r l lmad <<<"$(stat linux "$name")"
  if [ -z "${o:-}" ]; then enforce "$name" "$from" "Silica reported no value"; continue; fi
  ratio=""
  if [ -n "${l:-}" ]; then
    ratio=$(awk -v o="$o" -v l="$l" -v b="$better" 'BEGIN { if (b == "lower") { if (l > 0) print o / l } else if (o > 0) print l / o }')
  fi
  desc="silica $(fmt "$o") $unit (noise $(fmt "$omad"))"
  [ -n "${l:-}" ] && desc="$desc, linux $(fmt "$l") $unit${ratio:+, ratio $(fmt "$ratio")}"
  results+=("$(jq -cn --arg n "$name" --arg u "$unit" --argjson o "$o" --argjson mad "$omad" --arg l "${l:-}" --arg r "$ratio" \
    '{key: $n, value: {unit: $u, silica: $o, noise: $mad, linux: (if $l == "" then null else ($l | tonumber) end), ratio: (if $r == "" then null else ($r | tonumber) end)}}')")
  [ -n "$ratio" ] && awk -v r="$ratio" 'BEGIN { exit !(r > 1) }' && behind="$behind $name ($(fmt "$ratio")x)"
  good=1
  case "$gate" in
    win|le)
      if [ -z "$ratio" ]; then enforce "$name" "$from" "Linux reported no value to compare with ($desc)"; good=0
      elif awk -v r="$ratio" -v x="$limit" -v g="$gate" 'BEGIN { exit !((g == "win") ? (r < x) : (r <= x)) }'; then :
      else enforce "$name" "$from" "$desc, gate: ratio $([ $gate = win ] && echo '<' || echo '<=') $limit"; good=0; fi ;;
    min) awk -v o="$o" -v x="$limit" 'BEGIN { exit !(o >= x) }' || { enforce "$name" "$from" "$desc, gate: at least $limit"; good=0; } ;;
    max) awk -v o="$o" -v x="$limit" 'BEGIN { exit !(o <= x) }' || { enforce "$name" "$from" "$desc, gate: at most $limit"; good=0; } ;;
  esac
  # The ratchet: against Linux where there is a Linux value, else the value itself.
  if [ -n "$ratio" ]; then kind=vs-linux now=$ratio noise=$(awk -v r="$ratio" -v o="$o" -v m="$omad" -v l="$l" -v n="${lmad:-0}" 'BEGIN { print 3 * r * (m / o + n / l) }'); worse=higher
  else kind=value now=$o noise=$(awk -v m="$omad" 'BEGIN { print 3 * m }'); worse=$([ "$better" = lower ] && echo higher || echo lower); fi
  best=$(ratchet_of "$name")
  keep=${best:-$now}
  if [ -n "$best" ]; then
    if awk -v n="$now" -v b="$best" -v e="$noise" -v w="$worse" 'BEGIN { exit !((w == "higher") ? (n > b + e) : (n < b - e)) }'; then
      enforce "$name" "$from" "regression: $kind $(fmt "$now") against the ratchet $(fmt "$best") (noise $(fmt "$noise")); $desc"; good=0
    elif awk -v n="$now" -v b="$best" -v w="$worse" 'BEGIN { exit !((w == "higher") ? (n < b) : (n > b)) }'; then
      keep=$now; desc="$desc; better than the ratchet $(fmt "$best")"
    fi
  fi
  printf '%s\t%s\t%s\n' "$name" "$keep" "$kind" >>"$newratchet"
  [ $good = 1 ] && ok "$name: $desc"
done <<<"$METRICS"

[ -z "$behind" ] || echo "bench: behind Linux:$behind"
if [ $update = 1 ]; then
  if [ $accel = kvm ] && [ $fail = 0 ]; then cp "$newratchet" "$RATCHET" && echo "bench: ratchet updated: $RATCHET"
  else echo "bench: ratchet not updated (needs KVM and no failure)"; fi
fi
out=${out:-$LOGS/bench/results.json}
printf '%s\n' "${results[@]+"${results[@]}"}" | jq -s --argjson ms "$ms" --arg accel "$accel" --argjson runs "$runs" --arg pin "$pin" \
  --arg linux "$(linux_field version)" '{schema: 2, milestone: $ms, accel: $accel, runs: $runs, host_cpus: $pin, linux: $linux, metrics: from_entries}' >"$out" 2>/dev/null ||
  echo "ERROR: bench: cannot write $out"
echo "bench: results in $out"
finish
