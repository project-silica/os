#!/usr/bin/env bash
# Benchmarks against the recorded Linux baseline (spec/TESTING.md section 4).
#   bench.sh [--image <bench.img>] [--runs <n>] [--out <results.json>] [--previous <results.json>]
#            [--checkout <repo> <absolute-dir>]...
#   bench.sh --build-baseline [--force] [--runs <n>] [--smp <n>] [--mem <MiB>] [--checkout os <dir>]
#
# Guests (ours and the Linux baseline image) boot through tools/qemu.sh and print
#   BENCH <metric> <number> <unit>     one line per metric, then
#   BENCH DONE
# on the serial port and exit through the debug-exit device. Each metric is the
# median of --runs boots (default 3); metrics with an absolute limit take the worst run.
#
# Our image: <kernel artifact cache>/artifacts/x86_64/bench.img, or --image.
# Missing before M2 is one SKIP line; from M2 it is an ERROR.
# Baseline: <os checkout>/bench/linux-baseline.json, written by --build-baseline from
#   $SILICA_LINUX_SRC (default <workshop>/baseline/linux), which must hold
#     linux.img      UEFI-bootable disk image of the current LTS kernel plus an initramfs
#                    whose init runs the micro-benchmarks and prints the BENCH lines
#     linux.version  one line naming the kernel version
#   Without them there is nothing to build from offline: baseline unavailable, exit 3.
#   The baseline records the QEMU configuration (smp, memory, acceleration); a run
#   uses the same smp and memory and refuses to compare across a different acceleration.
#   An existing baseline is replaced only with --force ("built once").
# Gates: each metric has a limit against Linux and a "from" milestone (state/MILESTONE).
#   Before it a violation or a missing value is a SKIP line, from it an ERROR.
#   --previous <results.json>: any tracked metric more than 5% worse than in that
#   earlier results file is an ERROR (the nightly regression rule).
# Output follows the test output rules: one ERROR: bench::<metric>: line per failure,
#   last line RESULT: pass=<n> fail=<n> skipped=<n> time=<s>.
# Exit: 0 pass, 1 a gate failed, 2 usage or setup error, 3 baseline unavailable.
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"
start=$SECONDS
export LC_ALL=C

# name unit direction(lower|higher) limit kind(win|le|abs) from-milestone
#   win: ratio to Linux strictly below limit ("faster", "under 2x"); le: ratio at most limit;
#   abs: our value at most limit (Linux recorded, not gated). Ratio is ours/linux for
#   "lower is better" metrics and linux/ours for "higher is better" ones.
METRICS='boot_userspace_ms ms lower 1 win 2
ipc_roundtrip_ns ns lower 2 win 2
ctx_switch_ns ns lower 1 le 2
boot_network_ms ms lower 1 win 4
idle_mem_kib KiB lower 0.25 le 4
driver_recovery_blk_ms ms lower 1000 abs 3
driver_recovery_net_ms ms lower 1000 abs 3
driver_lost_writes_blk count lower 0 abs 3
driver_lost_writes_net count lower 0 abs 3
sched_p99_us us lower 1 le 3
tcp_mbit_s Mbit/s higher 1.25 le 4
file_meta_ops_s ops/s higher 1.5 le 5
blk_iops iops higher 1.25 le 5
app_cold_start_ms ms lower 1 win 6
nvme_iops iops higher 1.25 le 8'

parse_checkouts "$@"
set -- "${ARGS[@]+"${ARGS[@]}"}"
mode=run image="" runs=3 out="" prev="" force=0 smp="" mem=""
while [ $# -gt 0 ]; do
  case "$1" in
    --build-baseline) mode=baseline; shift; continue ;;
    --force) force=1; shift; continue ;;
    --image|--runs|--out|--previous|--smp|--mem) [ $# -ge 2 ] || die "$1 needs a value" ;;
  esac
  case "$1" in
    --image) image=$2 ;; --runs) runs=$2 ;; --out) out=$2 ;; --previous) prev=$2 ;;
    --smp) smp=$2 ;; --mem) mem=$2 ;;
    *) die "unknown argument $1" ;;
  esac
  shift 2
done
for n in "$runs" "$smp" "$mem"; do
  case "$n" in ''|0|*[!0-9]*) [ -z "$n" ] || die "not a positive number: $n" ;; esac
done
[ "$runs" -ge 1 ] 2>/dev/null || die "--runs must be at least 1"
if [ $mode = run ]; then
  [ -z "$smp$mem" ] || die "--smp and --mem apply to --build-baseline; a run uses the baseline's configuration"
  [ $force = 0 ] || die "--force applies to --build-baseline"
fi
command -v jq >/dev/null || die "jq is not installed (run tools/init.sh)"

OS=$(checkout_of os)
BASELINE=$OS/bench/linux-baseline.json
ms=$(milestone)
mkdir -p "$LOGS/bench"
new_run
pass=0 fail=0 skipped=0
accel=tcg; [ -w /dev/kvm ] && accel=kvm

finish() {
  echo "RESULT: pass=$pass fail=$fail skipped=$skipped time=$((SECONDS - start))"
  [ "$fail" = 0 ] || exit 1
  exit 0
}
enforce() { # enforce <metric> <from-milestone> <message>: ERROR from the milestone, SKIP before
  if [ "$ms" -ge "$2" ]; then echo "ERROR: bench::$1: $3"; fail=$((fail + 1))
  else echo "SKIP: bench: $1: $3 (gated from M$2)"; skipped=$((skipped + 1)); fi
}
baseline_missing() { echo "ERROR: bench::baseline: baseline unavailable: $1"; echo "RESULT: pass=$pass fail=$fail skipped=1 time=$((SECONDS - start))"; exit 3; }
mfield() { echo "$METRICS" | awk -v m="$1" -v f="$2" '$1 == m { print $f }'; }
fmt() { awk -v x="$1" 'BEGIN { printf "%.4g", x }'; }
# Boot <image> --runs times; fill OURS[metric]=value. A guest that does not finish is fatal.
declare -A OURS=()
collect() { # collect <image> <label> <smp> <mem>
  local img=$1 label=$2 s=$3 m=$4 i rc ser log d=$RUN/$2 name unit val
  mkdir -p "$d"; OURS=()
  for ((i = 1; i <= runs; i++)); do
    ser=$d/serial.$i; log=$LOGS/bench/$label.$i.log
    "$TOOLS/qemu.sh" --image "$img" --serial "$ser" --timeout "${SILICA_BENCH_TIMEOUT:-300}" --smp "$s" --mem "$m" >"$log" 2>&1
    rc=$?
    if [ $rc = 2 ]; then echo "ERROR: bench: $label: qemu.sh setup error: $(head -c 200 "$log" | tr '\n' ' ')"; echo "RESULT: pass=$pass fail=1 skipped=$skipped time=$((SECONDS - start))"; exit 2; fi
    if ! tr -d '\r' <"$ser" 2>/dev/null | grep -qx 'BENCH DONE'; then
      echo "ERROR: bench::$label: run $i did not finish (qemu.sh exit $rc, no BENCH DONE; log $log)"
      echo "RESULT: pass=$pass fail=1 skipped=$skipped time=$((SECONDS - start))"; exit 1
    fi
    while read -r name val unit; do
      if [ -z "$(mfield "$name" 1)" ]; then echo "ERROR: bench::$name: $label reports an unknown metric"; fail=$((fail + 1)); continue; fi
      if [ "$unit" != "$(mfield "$name" 2)" ]; then echo "ERROR: bench::$name: $label reports unit $unit, want $(mfield "$name" 2)"; fail=$((fail + 1)); continue; fi
      echo "$val" >>"$d/v.$name"
    done < <(tr -d '\r' <"$ser" | awk '$1 == "BENCH" && NF == 4 && $3 ~ /^[0-9]+([.][0-9]+)?$/ { print $2, $3, $4 }')
  done
  [ "$fail" = 0 ] || { echo "RESULT: pass=$pass fail=$fail skipped=$skipped time=$((SECONDS - start))"; exit 1; }
  for f in "$d"/v.*; do
    [ -f "$f" ] || continue
    name=${f##*/v.}
    if [ "$(mfield "$name" 5)" = abs ]; then OURS[$name]=$(sort -g "$f" | tail -n 1)   # worst run
    else OURS[$name]=$(sort -g "$f" | awk '{ v[NR] = $1 } END { print (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2 }'); fi
  done
}
metrics_json() { # metrics_json: OURS as {"name":{"value":n,"unit":u}}
  local m
  for m in "${!OURS[@]}"; do printf '%s\t%s\t%s\n' "$m" "${OURS[$m]}" "$(mfield "$m" 2)"; done |
    jq -Rn '[inputs | split("\t") | {key: .[0], value: {value: (.[1] | tonumber), unit: .[2]}}] | from_entries'
}

if [ $mode = baseline ]; then
  smp=${smp:-2} mem=${mem:-512}
  src=${SILICA_LINUX_SRC:-$WS/baseline/linux}
  [ -f "$src/linux.img" ] && [ -f "$src/linux.version" ] ||
    baseline_missing "Linux baseline sources are not available offline: need $src/linux.img (UEFI-bootable disk image of the current LTS kernel whose initramfs prints BENCH lines and BENCH DONE, exits through debug-exit) and $src/linux.version; set SILICA_LINUX_SRC to another directory if they are elsewhere"
  if [ -e "$BASELINE" ] && [ $force = 0 ]; then
    die "$BASELINE exists; the baseline is built once (--force replaces it)"
  fi
  collect "$src/linux.img" linux "$smp" "$mem"
  [ ${#OURS[@]} -gt 0 ] || { echo "ERROR: bench::linux: the baseline image reported no metrics"; echo "RESULT: pass=0 fail=1 skipped=0 time=$((SECONDS - start))"; exit 1; }
  mkdir -p "$(dirname "$BASELINE")"
  jq -n --argjson m "$(metrics_json)" --arg k "$(head -n 1 "$src/linux.version")" --argjson smp "$smp" --argjson mem "$mem" \
     --arg accel "$accel" --argjson runs "$runs" \
     '{schema: 1, linux: {kernel: $k}, config: {smp: $smp, mem_mib: $mem, accel: $accel, runs: $runs}, metrics: $m}' >"$BASELINE.tmp" &&
    mv "$BASELINE.tmp" "$BASELINE" || die "cannot write $BASELINE"
  echo "bench: baseline: ${#OURS[@]} metrics for Linux $(head -n 1 "$src/linux.version") recorded in $BASELINE (smp $smp, mem ${mem}M, $accel)"
  pass=1; finish
fi

# ---- run ----------------------------------------------------------------------------
[ -n "$image" ] || image=$(cache_of kernel)/artifacts/x86_64/bench.img
if [ ! -f "$image" ]; then
  enforce suite "$(echo "$METRICS" | awk 'NR == 1 { print $6 }')" "bench image $image not built"
  finish
fi
[ -f "$BASELINE" ] || baseline_missing "no recorded Linux baseline ($BASELINE); run tools/bench.sh --build-baseline"
jq -e '.schema == 1 and (.config.smp | type == "number") and (.config.mem_mib | type == "number") and (.config.accel | type == "string") and (.metrics | type == "object")' \
  "$BASELINE" >/dev/null 2>&1 || die "$BASELINE is not a schema 1 baseline"
[ "$(jq -r .config.accel "$BASELINE")" = "$accel" ] ||
  die "baseline was recorded under $(jq -r .config.accel "$BASELINE"), this host runs $accel: timings are not comparable; rebuild the baseline here with --force"
declare -A BASE=() PREV=()
while IFS=$'\t' read -r k v; do BASE[$k]=$v; done < <(jq -r '.metrics | to_entries[] | "\(.key)\t\(.value.value)"' "$BASELINE")
if [ -n "$prev" ]; then
  jq -e '.metrics | type == "object"' "$prev" >/dev/null 2>&1 || die "$prev is not a bench results file"
  while IFS=$'\t' read -r k v; do PREV[$k]=$v; done < <(jq -r '.metrics | to_entries[] | "\(.key)\t\(.value.value)"' "$prev")
fi

collect "$image" silica "$(jq -r .config.smp "$BASELINE")" "$(jq -r .config.mem_mib "$BASELINE")"

while read -r name unit dir limit kind from; do
  o=${OURS[$name]:-} b=${BASE[$name]:-}
  if [ -z "$o" ]; then enforce "$name" "$from" "the guest reported no value"; continue; fi
  if [ "$kind" = abs ]; then
    if awk -v a="$o" -v l="$limit" 'BEGIN { exit !(a <= l) }'; then
      echo "bench: $name: ours $(fmt "$o") $unit (limit <= $limit${b:+, linux $(fmt "$b") recorded})"; pass=$((pass + 1))
    else enforce "$name" "$from" "ours $(fmt "$o") $unit over the limit $limit"; fi
    continue
  fi
  if [ -z "$b" ]; then enforce "$name" "$from" "the baseline has no Linux value"; continue; fi
  ratio=$(awk -v o="$o" -v b="$b" -v d="$dir" 'BEGIN {
    if (d == "lower") { if (b <= 0) { print "nan"; exit } print o / b }
    else { if (o <= 0) { print 1e99; exit } print b / o } }')
  if [ "$ratio" = nan ]; then enforce "$name" "$from" "the baseline value $b is not positive"; continue; fi
  if [ "$kind" = win ]; then op="<"; else op="<="; fi
  desc="ours $(fmt "$o") $unit, linux $(fmt "$b") $unit, ratio $(fmt "$ratio") (limit $op $limit)"
  if awk -v r="$ratio" -v l="$limit" -v k="$kind" 'BEGIN { exit !((k == "win") ? (r < l) : (r <= l)) }'; then
    echo "bench: $name: $desc"; pass=$((pass + 1))
  else enforce "$name" "$from" "$desc"; fi
done <<<"$METRICS"

# Regression against an earlier results file: more than 5% worse on any tracked metric.
for name in "${!PREV[@]}"; do
  o=${OURS[$name]:-} p=${PREV[$name]}
  [ -n "$o" ] && [ -n "$(mfield "$name" 1)" ] || continue
  if awk -v o="$o" -v p="$p" -v d="$(mfield "$name" 3)" 'BEGIN { if (p <= 0) exit 1; exit !((d == "lower") ? (o > p * 1.05) : (o < p / 1.05)) }'; then
    echo "ERROR: bench::$name: regression over 5%: $(fmt "$o") now, $(fmt "$p") in $prev"; fail=$((fail + 1))
  fi
done

out=${out:-$LOGS/bench/results.json}
jq -n --argjson m "$(metrics_json)" --argjson ms "$ms" --arg accel "$accel" '{schema: 1, milestone: $ms, accel: $accel, metrics: $m}' >"$out" 2>/dev/null ||
  echo "ERROR: bench: cannot write $out"
echo "bench: results in $out"
finish
