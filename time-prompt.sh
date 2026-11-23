#!/usr/bin/env bash
# time-prompt.sh — how long ps1.bash takes to draw a prompt, here.
#
# Usage: ./time-prompt.sh [--compare] [runs] [path/to/ps1.bash]
#
# Run it from the directory you want to measure: the cost depends almost
# entirely on the repo you are in. It times __prompt_render, the function
# bash runs on every Enter, and then `git status` alone, the one process
# that function spends, so you can see how much of the total is git's.
#
# --compare also times whole prompts, everything bash does per Enter,
# against what you would otherwise have: your system's stock prompt, and
# git's own __git_ps1. Each runs in a clean interactive bash whose home is
# a fresh copy of /etc/skel, which is what a new account on this machine
# starts with, so your own ~/.bashrc plays no part.
#
# The GitHub segments read their caches exactly as your prompt does, so a
# stale entry may start one background refresh during the warm-up. That
# refresh runs off the prompt path and is not part of what is timed.
set -euo pipefail

compare=0
if [[ "${1:-}" == --compare ]]; then compare=1; shift; fi
runs="${1:-100}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="${2:-}"
if [[ -z "$src" ]]; then
  if   [[ -f "$here/ps1.bash" ]];  then src="$here/ps1.bash"
  elif [[ -f ~/.bash_prompt ]];     then src=~/.bash_prompt
  fi
fi
[[ -f "$src" ]] || { echo "time-prompt: no ps1.bash found; pass its path as the second argument" >&2; exit 1; }
src="$(cd "$(dirname "$src")" && pwd)/$(basename "$src")"
[[ "$runs" =~ ^[1-9][0-9]*$ ]] || { echo "time-prompt: runs must be a positive number, not '$runs'" >&2; exit 1; }

# A fresh bash without your rc files, so the time is this prompt's alone
# and not that of anything else your shell runs. COLUMNS is not exported
# to scripts, so it is asked for; the width changes which segments fit.
export COLUMNS="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"

# Prints the average microseconds per run of <command>. $EPOCHREALTIME
# has six decimals, written with the locale's decimal point — a comma in
# much of Europe — so either is stripped to get whole microseconds.
# shellcheck disable=SC2016  # expanded by the inner bash, not here
time_it='
  for (( i = 0; i < 5; i++ )); do eval "$1"; done     # warm-up: caches, page cache
  s=$EPOCHREALTIME
  for (( i = 0; i < RUNS; i++ )); do eval "$1"; done
  e=$EPOCHREALTIME
  echo $(( (${e/[.,]/} - ${s/[.,]/}) / RUNS ))'

prompt_us=$(RUNS=$runs bash --norc --noprofile -c "source '$src'; $time_it" _ \
              '__prompt_render >/dev/null')

printf 'prompt:      %6d µs per Enter   (%d runs in %s)\n' "$prompt_us" "$runs" "$PWD"

in_repo=0
git rev-parse --is-inside-work-tree &>/dev/null && in_repo=1
if (( in_repo )); then
  # The same command, the same way: inside $( ), as the prompt runs it.
  git_us=$(RUNS=$runs bash --norc --noprofile -c "$time_it" _ \
             'st=$(exec git --no-optional-locks status --porcelain=v2 --branch 2>/dev/null)')
  pct=$(( prompt_us > 0 ? git_us * 100 / prompt_us : 0 ))
  (( pct > 100 )) && pct=100   # separate runs; on a fast repo the noise can cross
  printf 'git status:  %6d µs of that     (%d%%)\n' "$git_us" "$pct"
else
  echo "git status:  not run           (not inside a git repo, so the prompt skips it)"
fi

(( compare )) || exit 0

# ─── --compare ──────────────────────────────────────────────────────
#
# Whole prompts, measured the same way for each: every PROMPT_COMMAND
# entry, then PS1's expansion, which is all bash does per Enter before
# readline draws. The stock setup comes first in every row, because it
# stays: installing a prompt adds to what your system already runs on
# every Enter, it does not replace it.

home=$(mktemp -d)
trap 'rm -rf "$home"' EXIT
for f in /etc/skel/.bashrc /etc/skel/.bash_profile /etc/skel/.profile; do
  [[ -f "$f" ]] && cp "$f" "$home/"
done

# shellcheck disable=SC2016  # expanded by the inner bash, not here
draw='{ for __c in "${PROMPT_COMMAND[@]}"; do eval "$__c"; done; : "${PS1@P}"; } >/dev/null 2>&1'

# whole <setup>: average µs per Enter for a stock interactive bash plus <setup>.
whole() {
  env -i HOME="$home" TERM="${TERM:-xterm-256color}" PATH="$PATH" LANG="${LANG:-C.UTF-8}" \
    XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}" COLUMNS="$COLUMNS" RUNS="$runs" \
    bash -i -c "$1"$'\n'"$time_it" _ "$draw" 2>/dev/null | tail -n 1
}

# git ships its prompt helper in a different place on each system.
git_prompt=""
for f in /usr/share/git-core/contrib/completion/git-prompt.sh \
         /usr/lib/git-core/git-sh-prompt \
         /usr/share/git/completion/git-prompt.sh \
         /opt/homebrew/etc/bash_completion.d/git-prompt.sh \
         /usr/local/etc/bash_completion.d/git-prompt.sh; do
  [[ -f "$f" ]] && { git_prompt="$f"; break; }
done

echo
echo "Whole prompt per Enter, on top of this system's stock setup:"
printf '  %-46s %6d µs\n' "stock prompt alone" "$(whole ':')"
printf '  %-46s %6d µs\n' "+ ps1.bash" "$(whole "source '$src'")"
if [[ -n "$git_prompt" ]]; then
  gp="source '$git_prompt'; PROMPT_COMMAND+=('__git_ps1 \"\\u@\\h \\w\" \"\\\\\$ \"')"
  if (( in_repo )); then
    printf '  %-46s %6d µs\n' "+ git's __git_ps1, branch only" "$(whole "$gp")"
    printf '  %-46s %6d µs\n' "+ __git_ps1 with dirty, untracked, upstream" \
      "$(whole "GIT_PS1_SHOWDIRTYSTATE=1 GIT_PS1_SHOWUNTRACKEDFILES=1 GIT_PS1_SHOWUPSTREAM=auto; $gp")"
  else
    printf '  %-46s %6d µs\n' "+ git's __git_ps1" "$(whole "$gp")"
  fi
  echo "  (__git_ps1 from $git_prompt)"
else
  echo "  git's git-prompt.sh: not found on this system, so not compared"
fi
