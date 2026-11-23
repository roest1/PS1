#!/usr/bin/env bash
# time-prompt.sh — how long ps1.bash takes to draw a prompt, here.
#
# Usage: ./time-prompt.sh [runs] [path/to/ps1.bash]
#
# Run it from the directory you want to measure: the cost depends almost
# entirely on the repo you are in. It times __prompt_render, the function
# bash runs on every Enter, and then `git status` alone, the one process
# that function spends, so you can see how much of the total is git's.
#
# The GitHub segments read their caches exactly as your prompt does, so a
# stale entry may start one background refresh during the warm-up. That
# refresh runs off the prompt path and is not part of what is timed.
set -euo pipefail

runs="${1:-100}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="${2:-}"
if [[ -z "$src" ]]; then
  if   [[ -f "$here/ps1.bash" ]];  then src="$here/ps1.bash"
  elif [[ -f ~/.bash_prompt ]];     then src=~/.bash_prompt
  fi
fi
[[ -f "$src" ]] || { echo "time-prompt: no ps1.bash found; pass its path as the second argument" >&2; exit 1; }
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

if git rev-parse --is-inside-work-tree &>/dev/null; then
  # The same command, the same way: inside $( ), as the prompt runs it.
  git_us=$(RUNS=$runs bash --norc --noprofile -c "$time_it" _ \
             'st=$(exec git --no-optional-locks status --porcelain=v2 --branch 2>/dev/null)')
  pct=$(( prompt_us > 0 ? git_us * 100 / prompt_us : 0 ))
  (( pct > 100 )) && pct=100   # separate runs; on a fast repo the noise can cross
  printf 'git status:  %6d µs of that     (%d%%)\n' "$git_us" "$pct"
else
  echo "git status:  not run           (not inside a git repo, so the prompt skips it)"
fi
