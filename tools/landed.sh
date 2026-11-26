#!/usr/bin/env bash
# Say what is not on main yet, in the workshop and every repository beside it.
#   landed.sh            read the local clones only (no network): each
#                        repository not on main, every branch but main (local,
#                        and remote as of the last fetch), every worktree but
#                        the clone itself, commits main has that origin/main
#                        lacks, and modified or untracked files
#   landed.sh --remote   fetch and prune first, and name the open pull
#                        requests (needs the network and gh)
# One line per finding, `UNLANDED: <repository>: <what>`; exit 1 if there is
# any, 0 with `LANDED:` if everything is on main and pushed. It changes
# nothing but, with --remote, the remote-tracking refs a fetch updates.
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"
remote=0
case "$#:${1:-}" in
  0:) ;;
  1:--remote) remote=1 ;;
  *) die "usage: landed.sh [--remote]" ;;
esac
found=0
say() { echo "UNLANDED: $1: $2"; found=1; }
G() { git -c protocol.allow=always "$@"; }
for r in workshop $(all_repos); do
  d=$WS/$r; [ "$r" = workshop ] && d=$WS
  [ -e "$d/.git" ] || continue
  top=$(realdir "$d")
  if [ $remote = 1 ]; then G -C "$d" fetch --quiet --prune origin 2>/dev/null || say "$r" "cannot fetch origin (no network?)"; fi
  cur=$(git -C "$d" symbolic-ref -q --short HEAD || echo "a detached commit")
  [ "$cur" = main ] || say "$r" "is on $cur, not main"
  while read -r b; do
    [ -n "$b" ] && [ "$b" != main ] && say "$r" "branch $b ($(git -C "$d" log -1 --format='%h %s' "$b" | cut -c1-72))"
  done < <(git -C "$d" for-each-ref --format='%(refname:short)' refs/heads)
  while read -r b; do
    case "$b" in "" | origin | origin/HEAD | origin/main) continue ;; esac
    say "$r" "remote branch ${b#origin/}"
  done < <(git -C "$d" for-each-ref --format='%(refname:short)' refs/remotes/origin)
  while read -r w; do
    [ -n "$w" ] && [ "$w" != "$top" ] && say "$r" "worktree $w"
  done < <(git -C "$d" worktree list --porcelain | sed -n 's/^worktree //p')
  if git -C "$d" rev-parse -q --verify refs/remotes/origin/main >/dev/null; then
    n=$(git -C "$d" rev-list --count refs/remotes/origin/main..refs/heads/main 2>/dev/null || echo 0)
    [ "$n" = 0 ] || say "$r" "main has $n commits origin/main lacks"
  else
    say "$r" "has no origin/main to compare with"
  fi
  n=$(git -C "$d" status --porcelain --untracked-files=all 2>/dev/null | grep -c .)
  [ "$n" = 0 ] || say "$r" "$n modified or untracked files"
  if [ $remote = 1 ] && command -v gh >/dev/null 2>&1; then
    url=$(git -C "$d" remote get-url origin 2>/dev/null)
    while IFS=$'\t' read -r num head title; do
      [ -n "$num" ] && say "$r" "open pull request #$num ($head): $title"
    done < <(cd "$d" && gh pr list --state open --json number,headRefName,title --jq '.[] | [.number, .headRefName, .title] | @tsv' ${url:+--repo "$url"} 2>/dev/null)
  fi
done
[ $found = 0 ] || exit 1
echo "LANDED: every repository is on main, pushed, with no other branch or worktree"
