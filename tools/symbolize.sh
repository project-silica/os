#!/usr/bin/env bash
# Symbolizer for serial logs: turns the addresses in panic messages and
# backtraces into function, file and line (component A09).
#   symbolize.sh [--arch <arch>] [--elf <file>] [--bias <hex>] [<log> | -]
#   symbolize.sh [--arch <arch>] [--elf <file>] [--bias <hex>] --addr <hex>...
# Log mode copies the log (a file, or standard input for "-" or no argument)
# to standard output unchanged and puts one decoded line after every line that
# names an address:
#     <4 spaces>0x<address> <function> at <file>:<line>
# Inlined callers follow as further lines for the same address. Candidates are
# 0x-prefixed hex numbers of 6 to 16 digits anywhere in a line, and the first
# number of a backtrace frame line ("#N <address> ...", "#N: <address>", with or
# without 0x). In a frame with N >= 1 the number is a return address: the
# lookup uses address - 1, so the call site is decoded and not the instruction
# after it. Numbers that match no function (stack pointers, flags, data) stay
# undecoded and are not an error.
# --addr mode decodes the given addresses (plain lookups, no adjustment), one
# decoded line each, and exits 1 with one ERROR line per address that matches
# no function.
# The ELF is the kernel test.sh booted: <kernel cache>/artifacts/<arch>/kernel.elf
# (arch defaults to x86_64), or --elf. --bias is subtracted from every address
# first (a load offset); the statically linked kernel needs none.
# Exit 0 when the log was processed, 2 on a usage error, a missing ELF or a
# missing addr2line.
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"

usage="usage: symbolize.sh [--arch <arch>] [--elf <file>] [--bias <hex>] [<log> | -] | --addr <hex>..."
arch=x86_64 elf="" bias=0 log="" mode=log addrs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --arch) [ $# -ge 2 ] || die "--arch needs a value ($usage)"; arch=$2; shift 2 ;;
    --elf) [ $# -ge 2 ] || die "--elf needs a file ($usage)"; elf=$2; shift 2 ;;
    --bias) [ $# -ge 2 ] || die "--bias needs a hex number ($usage)"; bias=$2; shift 2 ;;
    --addr)
      mode=addr; shift
      [ $# -gt 0 ] && [ "${1#-}" = "$1" ] || die "--addr needs at least one address ($usage)"
      while [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; do addrs+=("$1"); shift; done ;;
    -) [ -z "$log" ] || die "one log only ($usage)"; log=-; shift ;;
    -*) die "unknown argument $1 ($usage)" ;;
    *) [ -z "$log" ] || die "one log only ($usage)"; log=$1; shift ;;
  esac
done
hex() { local h=${1#0[xX]}; [[ "$h" =~ ^[0-9a-fA-F]{1,16}$ ]]; }
hex "$bias" || die "--bias $bias is not a hex number ($usage)"
if [ "$mode" = addr ]; then
  [ -z "$log" ] || die "give a log or --addr, not both ($usage)"
  for a in "${addrs[@]}"; do hex "$a" || die "$a is not a hex address ($usage)"; done
fi
[[ "$arch" =~ ^[A-Za-z0-9_]+$ ]] || die "bad --arch $arch ($usage)"
[ -n "$elf" ] || elf=$(cache_of kernel)/artifacts/$arch/kernel.elf
[ -f "$elf" ] || die "no kernel ELF at $elf (boot the kernel with test.sh first, or pass --elf)"
a2l=""
for t in ${SILICA_ADDR2LINE:-llvm-addr2line addr2line}; do
  if command -v "$t" >/dev/null 2>&1; then a2l=$t; break; fi
done
[ -n "$a2l" ] || die "neither llvm-addr2line nor addr2line is installed"

T=$(mktemp -d "${TMPDIR:-/tmp}/symbolize.XXXXXX") || die "no temporary directory"
trap 'rm -rf "${T:?}"' EXIT
bias_n=$((16#${bias#0[xX]}))

# Executable segments of the ELF (start and size). Debug info of code the linker
# dropped sits at address 0, so only addresses inside an executable segment are
# looked up. An ELF without program headers is not filtered.
SEG_LO=() SEG_SZ=()
while read -r lo sz; do SEG_LO+=("$((lo))"); SEG_SZ+=("$((sz))"); done < <(
  readelf -lW "$elf" 2>/dev/null | awk '$1 == "LOAD" {
    fl = ""; for (i = 7; i < NF; i++) fl = fl $i
    if (fl ~ /E/) print $3, $6 }')
in_code() { # in_code <unsigned address as a bash integer>
  [ "${#SEG_LO[@]}" -gt 0 ] || return 0
  local i m=$((1 << 63))
  for i in "${!SEG_LO[@]}"; do
    # unsigned compare through the sign bit: lo <= a < lo + size
    [ $(($1 ^ m)) -ge $((SEG_LO[i] ^ m)) ] && [ $(($1 - SEG_LO[i] ^ m)) -lt $((SEG_SZ[i] ^ m)) ] && return 0
  done
  return 1
}
# lookup <hex> <adjust> <index>: appends the address to the lookup file when it
# is code (the map file keeps its index).
lookup() {
  local v=$((16#${1#0[xX]} - bias_n - ${2:-0}))
  in_code "$v" || return 0
  printf '0x%x\n' "$v" >>"$T/lookup"; echo "$3" >>"$T/map"
}

# decode: one addr2line run over the lookup file; prints
# "<index><TAB><function><TAB><file:line>" for every frame (inlined callers
# included) whose function is known; the index comes from the map file.
decode() {
  [ -s "$T/lookup" ] || return 0
  "$a2l" -e "$elf" -a -f -C -i <"$T/lookup" 2>/dev/null | awk -v OFS='\t' -v mapf="$T/map" '
    BEGIN { while ((getline l < mapf) > 0) m[++k] = l }
    /^0x[0-9a-fA-F]+$/ { n++; state = 0; next }
    NF == 0 { next }
    state == 0 { fn = $0; state = 1; next }
    { if (fn != "??") print m[n], fn, $0; state = 0 }'
}
: >"$T/lookup"; : >"$T/map"

if [ "$mode" = addr ]; then
  i=0
  for a in "${addrs[@]}"; do i=$((i + 1)); lookup "$a" 0 "$i"; done
  decode >"$T/frames"
  rc=0 i=0
  for a in "${addrs[@]}"; do
    i=$((i + 1))
    if ! awk -F'\t' -v n="$i" '$1 == n { f = 1 } END { exit !f }' "$T/frames"; then
      err "$a: no function at this address in $elf"; rc=1; continue
    fi
    awk -F'\t' -v n="$i" -v a="$a" '$1 == n { printf "%s %s at %s\n", a, $2, $3 }' "$T/frames"
  done
  exit $rc
fi

# Log mode. Pass 1: every candidate as "<line><TAB><token as written><TAB><return address 0|1>".
if [ -z "$log" ] || [ "$log" = - ]; then cat >"$T/log"; else
  [ -f "$log" ] || die "no log file $log"
  cp -- "$log" "$T/log" || die "cannot read $log"
fi
LC_ALL=C awk -v OFS='\t' '
  function digits(t) { return length(t) - (t ~ /^0[xX]/ ? 2 : 0) }
  {
    rest = $0
    if (match($0, /^[ \t]*#[0-9]+:?[ \t]+(0[xX])?[0-9a-fA-F]+/)) {
      s = substr($0, RSTART, RLENGTH); rest = substr($0, RSTART + RLENGTH)
      num = s; sub(/^[ \t]*#/, "", num); sub(/[^0-9].*/, "", num)
      tok = s; sub(/^.*[ \t]/, "", tok)
      if (digits(tok) >= 6 && digits(tok) <= 16) print NR, tok, (num + 0 >= 1 ? 1 : 0)
      else rest = $0
    }
    while (match(rest, /0[xX][0-9a-fA-F]+/)) {
      tok = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
      if (digits(tok) >= 6 && digits(tok) <= 16) print NR, tok, 0
    }
  }' "$T/log" >"$T/cands"
i=0
while IFS=$'\t' read -r _ tok adj; do i=$((i + 1)); lookup "$tok" "$adj" "$i"; done <"$T/cands"
decode >"$T/frames"
# Pass 2: the log, each candidate line followed by its decoded frames.
awk -F'\t' '
  FILENAME == ARGV[1] { nc++; cl[nc] = $1; ct[nc] = $2; next }
  FILENAME == ARGV[2] { nf[$1]++; fn[$1, nf[$1]] = $2; fl[$1, nf[$1]] = $3; next }
  {
    print
    while (c < nc && cl[c + 1] == FNR) {
      c++
      for (k = 1; k <= nf[c]; k++) printf "    %s %s at %s\n", ct[c], fn[c, k], fl[c, k]
    }
  }' "$T/cands" "$T/frames" "$T/log"
exit 0
