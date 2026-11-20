#!/usr/bin/env bash
# Idempotent environment check (component A02): toolchain, emulator, firmware.
# Installs nothing that needs the network; prints one ERROR: line per missing
# piece with the command a human runs to fix it. Exit 0 when everything the
# current milestone needs is present. Under 10 s when nothing is missing.
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"
ms=$(milestone)
fail=0
need() { echo "ERROR: init: $1 (fix: $2)"; fail=1; }
later() { echo "SKIP: init: $1 (needed from M$2; fix: $3)"; }

for t in git jq cargo rustup sha256sum size nm socat; do
  command -v "$t" >/dev/null 2>&1 || need "$t is not installed" "install $t"
done
tc=$(sed -n 's/^channel *= *"\(.*\)"/\1/p' "$WS/kernel/rust-toolchain.toml" 2>/dev/null)
if [ -z "$tc" ]; then
  need "no pinned toolchain in kernel/rust-toolchain.toml" "run tools/sync.sh"
elif ! command -v rustup >/dev/null 2>&1; then
  :   # already reported above; the toolchain cannot be checked without rustup
else
  if installed=$(rustup component list --installed --toolchain "$tc" 2>/dev/null); then
    for c in rust-src clippy rustfmt miri; do
      grep -q "^$c" <<<"$installed" || need "component $c missing from $tc" "rustup component add $c --toolchain $tc"
    done
  else
    need "toolchain $tc is not installed" "rustup toolchain install $tc --profile minimal"
  fi
fi
command -v qemu-system-x86_64 >/dev/null || need "qemu-system-x86_64 is not installed" "install QEMU (x86_64 system emulator)"
FW=${SILICA_FW_ROOT:-}   # prefix for firmware paths; the init test points it at a fake tree
ovmf=0
for f in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2-ovmf/x64/OVMF_CODE.fd; do
  [ -f "$FW$f" ] && ovmf=1
done
[ $ovmf = 1 ] || need "OVMF firmware for x86_64 not found" "install edk2-ovmf"
aa=0
for f in /usr/share/AAVMF/AAVMF_CODE.fd /usr/share/edk2/aarch64/QEMU_EFI-pflash.raw /usr/share/qemu-efi-aarch64/QEMU_EFI.fd; do
  [ -f "$FW$f" ] && aa=1
done
if ! command -v qemu-system-aarch64 >/dev/null || [ $aa = 0 ]; then
  if [ "$ms" -ge 2 ]; then need "qemu-system-aarch64 or its UEFI firmware is missing" "install QEMU aarch64 and edk2-aarch64"
  else later "qemu-system-aarch64 and edk2-aarch64 firmware" 2 "install QEMU aarch64 and edk2-aarch64"; fi
fi
[ -w /dev/kvm ] || echo "init: no KVM; QEMU uses TCG (slower, still correct)"
for r in $(manifest_repos) os; do
  [ -e "$WS/$r/.git" ] || need "repository $r is not cloned" "run tools/sync.sh"
done
[ $fail = 0 ] && echo "INIT: OK"
exit $fail
