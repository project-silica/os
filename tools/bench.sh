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
# and the host stamps the firmware's "BdsDxe: starting" and "BENCH MARK
# userspace" for the boot time (the operating system's part of it). A metric's
# value is the median over the runs; its noise is the median absolute
# deviation; the noise of a ratio to Linux combines both systems' deviations.
#
# Each metric below has a gate against Linux and the milestone it applies
# from (the MILESTONE file in the workshop root). Every metric with a Linux
# equivalent is gated at or better than Linux: no milestone permits Silica
# to be slower (spec/TESTING.md section 4.2). Before that milestone a
# missing value is a SKIP line, from it an ERROR; a measured result that
# misses its gate or its ratchet is an ERROR at every milestone. Every metric is
# also a ratchet: bench/ratchet.tsv keeps the best ratio to Linux (or the best
# value where Linux has no equivalent), and a result worse than that by more
# than three times the noise is an ERROR. --update-ratchet records
# improvements in that file, to be committed with the change that earned them.
# Timings are gated only under KVM; under TCG they are printed and recorded.
#
# Output: one line per metric, one ERROR: bench::<metric>: line per failure,
# a "behind Linux" line naming every metric still slower than Linux (a
# scaling factor, unit x, is not one: its throughputs are; the
# system is not finished while there is one), last line
# RESULT: pass=<n> fail=<n> skipped=<n> time=<s>.
# Exit: 0 pass, 1 a gate failed, 2 usage or setup error, 3 Linux baseline unavailable.
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"
. "$TOOLS/lib/build.sh"
. "$TOOLS/lib/linux.sh"
start=$SECONDS
export LC_ALL=C

# name unit better gate limit from-milestone [repeat]
#   repeat: how far, in percent of its best, a timing may sit from one session
#   to the next on a host held still (default 1). The two timer metrics are
#   how promptly the host wakes a virtual processor more than anything Silica
#   does: three sessions of one kernel read 830, 937 and 995 ns (median) and
#   7.4, 9.9 and 8.4 us (p99), so their ratchets allow 25% and 40%; the gate
#   against Linux, measured in the same session, is what holds them.
#   gate: win  ours/linux strictly below limit     le   ours/linux at most limit
#         min  ours at least limit (no Linux value needed)
#         max  ours at most limit                  none ratchet only
METRICS='ipc_roundtrip ns lower win 0.5 2
ctx_switch ns lower le 1 2
boot_userspace ms lower win 1 2
timer_overshoot_p99 ns lower le 1 2 40
ipc_pairs1 ops/s higher le 1 2
ipc_pairs8 ops/s higher le 1 2
ipc_scaling x higher min 7 2
ipc_cross_pairs1 ops/s higher le 1 2
ipc_cross_pairs4 ops/s higher le 1 2
ipc_cross_scaling x higher min 3.5 2
page_fault ns lower le 1 2
null_syscall ns lower le 1 2
ipc_roundtrip_p99 ns lower le 1 2
ctx_switch_p99 ns lower le 1 2
timer_overshoot ns lower le 1 2 25
insns_null_syscall insns lower none 0 2
insns_ipc_roundtrip insns lower none 0 2
insns_ctx_switch insns lower none 0 2
insns_page_fault insns lower none 0 2'

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
# Instruction counts (insns_*) do not depend on the accelerator: they are
# gated under TCG as well.
gated() { [ $accel = kvm ] || [ "${1#insns_}" != "$1" ]; }
enforce() { # enforce <metric> <from-milestone> <message>: a metric not measured yet: ERROR from its milestone (under KVM), SKIP before
  if [ "$ms" -ge "$2" ] && gated "$1"; then echo "ERROR: bench::$1: $3"; fail=$((fail + 1))
  else echo "SKIP: bench: $1: $3 (required from M$2 under KVM)"; skipped=$((skipped + 1)); fi
}
miss() { # miss <metric> <message>: a measured result that misses its gate or ratchet: ERROR at every milestone (under KVM)
  if gated "$1"; then echo "ERROR: bench::$1: $2"; fail=$((fail + 1))
  else echo "SKIP: bench: $1: $2 (timings are gated under KVM only)"; skipped=$((skipped + 1)); fi
}
fmt() { awk -v x="$1" 'BEGIN { printf "%.4g", x }'; }

# Host processors for the guests: $SILICA_BENCH_CPUS, else one hardware thread
# of each of the fastest cores, as many as the guest has processors.
pin=${SILICA_BENCH_CPUS:-$(fastest_cpus "$SMP")}
# Those processors are held at one policy for both systems while the guests
# run (host_tune), and put back afterwards, whichever way this script ends.
# A host left on its power-saving default measures its own frequency ramps
# and sleep states: the same kernel then reads several percent apart from
# one session to the next. Where the policy cannot be set the results say so.
policy=$LOGS/bench/host-policy tuned=no
mkdir -p "$LOGS/bench"
host_restore "$policy"   # left by a run that was killed
# (The tool's own test boots nothing: there is no host to hold.)
[ -n "${SILICA_BENCH_IMG:-}" ] && tuned=stub
if [ $accel = kvm ] && [ -n "$pin" ] && [ $tuned = no ]; then
  trap 'host_restore "$policy"' EXIT
  trap 'exit 130' INT TERM
  if host_tune "$pin" "$policy"; then tuned=yes
  else host_restore "$policy"; echo "bench: host not tuned (needs passwordless sudo): timings carry its power-saving policy"; fi
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
  # Boot time, by the host's clock: from the firmware starting the boot
  # option (the operating system's loader) to the first line from userspace.
  # The firmware before that is the same code for both systems and moves by
  # tens of milliseconds from boot to boot, more than the operating system's
  # own boot takes; it is printed for context, not gated.
  t0=$(tr -d '\r' <"$st" | awk '/BdsDxe: starting/ { print $1; exit }')
  tq=$(awk '$2 == "QEMU" && $3 == "START" { print $1; exit }' "$st")
  t1=$(tr -d '\r' <"$st" | awk '$2 == "BENCH" && $3 == "MARK" { print $1; exit }')
  [ -n "$t0" ] && [ -n "$t1" ] && awk -v a="$t0" -v b="$t1" 'BEGIN { printf "boot_userspace %.3f ms\n", (b - a) * 1000 }' >>"$RUN/$sys.values"
  [ -n "$tq" ] && [ -n "$t0" ] && awk -v a="$tq" -v b="$t0" 'BEGIN { printf "%.3f\n", (b - a) * 1000 }' >>"$RUN/$sys.firmware"
}
# Kernel instructions per operation of the fixed paths (spec/TESTING.md
# 4.1), counted under TCG with icount by tools/profile.sh: a boot running
# the benchmark twice minus one running it once is exactly one benchmark.
# Each value is recorded <runs> times so it carries the noise of a
# deterministic count: a boot's count moves by a few hundred instructions
# with the other processor's timing, under 0.05 per operation, so a
# tolerance of one instruction per operation is added in the ratchet check.
# $SILICA_BENCH_COUNTS names a file of ready "insns_<metric> <n> insns"
# lines instead (the tool's own test).
counts() {
  local spec b name per one two v
  if [ -n "${SILICA_BENCH_COUNTS:-}" ]; then
    for ((i = 1; i <= runs; i++)); do cat "$SILICA_BENCH_COUNTS" >>"$RUN/silica.values"; done; return
  fi
  for spec in "null null_syscall 22000" "ipc ipc_roundtrip 22000" "ctx ctx_switch 44000" "fault page_fault 2048"; do
    read -r b name per <<<"$spec"
    one=$("$TOOLS/profile.sh" --count --bench "$b" --times 1 --out "$RUN/count.$b.1" 2>"$LOGS/bench/count.$b.log" | awk '$1 == "COUNT" { print $2 }')
    two=$("$TOOLS/profile.sh" --count --bench "$b" --times 2 --out "$RUN/count.$b.2" 2>>"$LOGS/bench/count.$b.log" | awk '$1 == "COUNT" { print $2 }')
    if [ -z "$one" ] || [ -z "$two" ]; then
      echo "bench: no instruction count for $name (log: $LOGS/bench/count.$b.log)"; continue
    fi
    v=$(awk -v a="$one" -v b="$two" -v p="$per" 'BEGIN { printf "%.1f", (b - a) / p }')
    for ((i = 1; i <= runs; i++)); do echo "insns_$name $v insns" >>"$RUN/silica.values"; done
  done
}
counts

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
ratchet_row() { [ -f "$RATCHET" ] && awk -F'\t' -v m="$1" '$1 == m { print; exit }' "$RATCHET"; }
# The host a value was measured on: its processor model ($SILICA_BENCH_HOST
# overrides, for the tool's own test).
host=${SILICA_BENCH_HOST:-$(LC_ALL=C lscpu 2>/dev/null | sed -n 's/^Model name: *//p' | head -n 1 | tr -s ' ' '_')}
host=${host:-unknown}
# Values measured with the host held still do not compare with values from
# the same machine left to its own frequency policy: a different host.
[ "$tuned" = yes ] && host=$host+tuned

behind="" results=() newratchet=$RUN/ratchet.tsv
printf '# Best result per metric (tools/bench.sh --update-ratchet). vs-linux: ours/linux for\n# lower-is-better metrics, linux/ours otherwise, then the best value and the host it\n# was measured on; value: the metric itself.\n' >"$newratchet"
while read -r name unit better gate limit from repeat; do
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
  # A scaling factor (unit x) compares a system with itself, not with the
  # other: its own gate judges it, and the throughputs it is made of are
  # compared with Linux directly.
  [ -n "$ratio" ] && [ "$unit" != x ] && awk -v r="$ratio" 'BEGIN { exit !(r > 1) }' && behind="$behind $name ($(fmt "$ratio")x)"
  good=1
  case "$gate" in
    win|le)
      if [ -z "$ratio" ]; then enforce "$name" "$from" "Linux reported no value to compare with ($desc)"; good=0
      elif awk -v r="$ratio" -v x="$limit" -v g="$gate" 'BEGIN { exit !((g == "win") ? (r < x) : (r <= x)) }'; then :
      else miss "$name" "$desc, gate: ratio $([ $gate = win ] && echo '<' || echo '<=') $limit"; good=0; fi ;;
    min) awk -v o="$o" -v x="$limit" 'BEGIN { exit !(o >= x) }' || { miss "$name" "$desc, gate: at least $limit"; good=0; } ;;
    max) awk -v o="$o" -v x="$limit" 'BEGIN { exit !(o <= x) }' || { miss "$name" "$desc, gate: at most $limit"; good=0; } ;;
  esac
  # The ratchet. It exists to catch Silica getting slower. On the host that
  # set it, Silica's own value is the measure: it repeats from session to
  # session within about 1%, while Linux's, and so the ratio, moves by up to
  # 5% (ipc_pairs1 Linux 804k to 847k round trips/s across sessions on the
  # reference host): a ratchet on the best ratio ever seen would keep the
  # luckiest Linux session and fail later ones at random. On another host,
  # where values do not compare, the ratio to Linux in the same session does.
  # A metric with a Linux value keeps both: "<best ratio> vs-linux <best
  # value> <host>". A timing allows at least 1% of its best either way; an
  # instruction count allows one instruction.
  IFS=$'\t' read -r _ rbest rkind vbest vhost <<<"$(ratchet_row "$name")"
  floor() { awk -v e="$1" -v b="$2" -v u="$unit" -v p="${repeat:-1}" 'BEGIN { f = (u == "insns") ? 0 : b * p / 100; if (f < 0) f = -f; print (e > f ? e : f) }'; }
  vnoise=$(awk -v m="$omad" -v u="$unit" 'BEGIN { print 3 * m + (u == "insns" ? 1 : 0) }')
  vworse=$([ "$better" = lower ] && echo higher || echo lower)
  worse_than() { awk -v n="$1" -v b="$2" -v e="$3" -v w="$4" 'BEGIN { exit !((w == "higher") ? (n > b + e) : (n < b - e)) }'; }
  better_than() { awk -v n="$1" -v b="$2" -v w="$3" 'BEGIN { exit !((w == "higher") ? (n < b) : (n > b)) }'; }
  if [ -n "$ratio" ] && [ "$unit" != x ]; then
    rnoise=$(awk -v r="$ratio" -v o="$o" -v m="$omad" -v l="$l" -v n="${lmad:-0}" 'BEGIN { print 3 * r * (m / o + n / l) }')
    rkeep=${rbest:-$ratio} vkeep=$o
    if [ -n "$vbest" ] && [ "$vhost" = "$host" ]; then
      e=$(floor "$vnoise" "$vbest"); vkeep=$vbest
      if worse_than "$o" "$vbest" "$e" "$vworse"; then
        miss "$name" "regression: silica $(fmt "$o") $unit against its best $(fmt "$vbest") $unit on this host (noise $(fmt "$e")); $desc"; good=0
      elif better_than "$o" "$vbest" "$vworse"; then vkeep=$o; desc="$desc; better than its best $(fmt "$vbest") on this host"; fi
    elif [ -n "$rbest" ]; then
      e=$(floor "$rnoise" "$rbest")
      if worse_than "$ratio" "$rbest" "$e" higher; then
        miss "$name" "regression: vs-linux $(fmt "$ratio") against the ratchet $(fmt "$rbest") (noise $(fmt "$e")); $desc"; good=0
      fi
    fi
    better_than "$ratio" "$rkeep" higher && rkeep=$ratio
    printf '%s\t%s\tvs-linux\t%s\t%s\n' "$name" "$rkeep" "$vkeep" "$host" >>"$newratchet"
  else
    keep=${rbest:-$o}
    if [ -n "$rbest" ]; then
      e=$(floor "$vnoise" "$rbest")
      if worse_than "$o" "$rbest" "$e" "$vworse"; then
        miss "$name" "regression: value $(fmt "$o") against the ratchet $(fmt "$rbest") (noise $(fmt "$e")); $desc"; good=0
      elif better_than "$o" "$rbest" "$vworse"; then keep=$o; desc="$desc; better than the ratchet $(fmt "$rbest")"; fi
    fi
    printf '%s\t%s\tvalue\n' "$name" "$keep" >>"$newratchet"
  fi
  [ $good = 1 ] && ok "$name: $desc"
done <<<"$METRICS"

[ -z "$behind" ] || echo "bench: behind Linux:$behind"
med() { [ -s "$1" ] && sort -g "$1" | awk '{ v[NR] = $1 } END { printf "%.0f", (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2 }'; }
fs=$(med "$RUN/silica.firmware"); fl=$(med "$RUN/linux.firmware")
[ -n "$fs$fl" ] && echo "bench: firmware before the boot option (the same for both, not gated): silica ${fs:-?} ms, linux ${fl:-?} ms"
if [ $update = 1 ]; then
  # A metric that failed keeps its previous best in the new file, so writing
  # it never loosens anything; it only records what the others improved.
  if [ $accel = kvm ] && [ $tuned != no ]; then cp "$newratchet" "$RATCHET" && echo "bench: ratchet updated: $RATCHET"
  else echo "bench: ratchet not updated (needs KVM and a host held still: host_tune)"; fi
fi
out=${out:-$LOGS/bench/results.json}
printf '%s\n' "${results[@]+"${results[@]}"}" | jq -s --argjson ms "$ms" --arg accel "$accel" --argjson runs "$runs" --arg pin "$pin" --arg tuned "$tuned" \
  --arg linux "$(linux_field version)" '{schema: 2, milestone: $ms, accel: $accel, runs: $runs, host_cpus: $pin, host_tuned: $tuned, linux: $linux, metrics: from_entries}' >"$out" 2>/dev/null ||
  echo "ERROR: bench: cannot write $out"
echo "bench: results in $out"
finish
