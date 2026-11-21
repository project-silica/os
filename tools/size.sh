#!/usr/bin/env bash
# Size budgets and bloat ceilings (spec/ARCHITECTURE.md section 2).
#   size.sh
# Measures the artifacts test.sh builds and boots (the kernel checkout's
# artifact cache). A missing artifact is one SKIP: line before its
# "Required from" milestone (the MILESTONE file in the workshop root; absent means 0) and one ERROR: line from then on.
# Conventions the kernel follows so the counts are mechanical:
#   syscalls      variants of `enum Syscall` in abi/src (every kernel operation is its own syscall)
#   object types  variants of `enum ObjectType` in abi/src
#   fast path     ELF sections named .text.fast* in the x86_64 kernel
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"
. "$TOOLS/lib/build.sh"
ms=$(milestone)
K=$(checkout_of kernel)
ART=$(cache_of kernel)/artifacts
fail=0 lines=0
ok() { echo "size: $1"; }
bad() { echo "ERROR: size: $1"; fail=1; }
missing() { # missing <what> <required-from>
  if [ "$ms" -ge "$2" ]; then bad "$1: artifact missing (required from M$2)"; else echo "SKIP: size: $1: not built yet (required from M$2)"; fi
}
check() { # check <name> <value> <limit> <required-from> [unit]: a measured artifact over its budget fails at every milestone
  if [ "$2" -le "$3" ]; then ok "$1: $2/$3${5:-}"
  else bad "$1: $2 over budget $3${5:-}"; fi
}
sections() { # sum of section sizes in ELF $1 whose names match regex $2
  size -A "$1" 2>/dev/null | awk -v re="$2" '$1 ~ re { s += $2 } END { print s + 0 }'
}

elf=$ART/x86_64/kernel.elf
if [ -f "$elf" ]; then
  check "kernel text+rodata (x86_64)" "$(sections "$elf" '^[.](text|rodata)')" 262144 1 " bytes"
  fast=$(sections "$elf" '^[.]text[.]fast')
  if [ "$fast" -gt 0 ]; then check "IPC fast path + context switch + syscall entry" "$fast" 32768 2 " bytes"
  else missing "IPC fast path section .text.fast" 2; fi
  if nm "$elf" 2>/dev/null | grep -qE '__rust_(alloc|alloc_zeroed|realloc)$|__rg_alloc'; then
    bad "kernel heap: the x86_64 kernel links an allocator (ceiling 0)"
  fi
else
  missing "kernel image (x86_64)" 1
fi
missing_or_measure() { # <name> <file> <budget> <from>
  if [ -f "$2" ]; then check "$1" "$(stat -c %s "$2")" "$3" "$4" " bytes"; else missing "$1" "$4"; fi
}
missing_or_measure "kernel + core servers resident text" "$ART/x86_64/core-text.bin" 2097152 5
missing_or_measure "minimal server image" "$ART/x86_64/server.img" 16777216 4
missing_or_measure "desktop image" "$ART/x86_64/desktop.img" 134217728 6

# Bloat ceilings.
rs_lines() { # non-blank, non-comment lines of Rust under the given paths, tests excluded
  [ $# -gt 0 ] || { echo 0; return; }
  find "$@" -name '*.rs' -not -path '*/tests/*' -not -path '*/benches/*' 2>/dev/null | sort |
    xargs -r cat | grep -cvE '^[[:space:]]*($|//)'
}
if [ -d "$K" ]; then
  src=()
  for d in "$K/abi/src" "$K/formats/src" "$K/kernel-core/src" "$K/kernel/src"; do [ -d "$d" ] && src+=("$d"); done
  check "kernel source lines (no tests, no arch)" "$(rs_lines "${src[@]}")" 12000 1
  for a in "$K"/kernel/arch/*/; do
    [ -d "$a" ] || continue
    n=$(find "$a" -type f \( -name '*.rs' -o -name '*.S' -o -name '*.s' \) -print0 | xargs -0r cat | grep -cvE '^[[:space:]]*($|//)')
    check "arch $(basename "$a") lines" "$n" 4000 1
  done
  variants() { # variants <enum name>: count variants of that enum in abi/src and kernel-core/src
    { find "$K/abi/src" "$K/kernel-core/src" -name '*.rs' -print0 2>/dev/null | xargs -0r cat; } | awk -v e="$1" '
      $0 ~ "enum[ \t]+" e "[ \t]*\\{" { inside = 1; depth = 0 }
      inside { t = $0; o = gsub(/\{/, "{", t); c = gsub(/\}/, "}", t)
        if (depth == 1 && $0 ~ /^[ \t]*[A-Z][A-Za-z0-9_]*[ \t]*([,=({]|$)/) n++
        depth += o - c; if (depth <= 0 && o + c > 0) inside = 0 }
      END { print n + 0 }'
  }
  check "syscalls" "$(variants Syscall)" 32 1
  check "kernel object types" "$(variants ObjectType)" 10 1
  heap=$(grep -rlE 'extern crate alloc|global_allocator|\balloc::' "${src[@]}" "$K"/kernel/arch 2>/dev/null | grep -v '/tests/' | head -3 | tr '\n' ' ')
  if [ -n "$heap" ]; then bad "kernel heap: allocation in kernel source: $heap(ceiling 0)"; else ok "kernel heap allocations: 0/0"; fi
fi

if [ $fail = 0 ]; then echo "SIZE: PASS"; else echo "SIZE: FAIL"; fi
exit $fail
