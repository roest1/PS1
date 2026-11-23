#!/usr/bin/env bash
# perf.bash <base/ps1.bash> <head/ps1.bash>
#
# Fails when head draws a prompt measurably slower than base, in the same
# job on the same machine. Used by CI to compare a pull request with main.
#
# Absolute timings are useless in CI: a shared runner's speed varies by tens
# of percent between jobs, and git's own run time swings by a third between
# calls. So both versions are measured here, alternately, in rounds, and
# only their medians are compared; and the prompt's one call to git,
# __git_status, is replaced, in the measuring shell only, by the assignment
# of a status recorded from a real repo. Nothing forks, so what is left to
# time is the prompt's own work — exactly what a change to ps1.bash can
# make slower — and no fork's worth of noise for a small slowdown to hide
# in. How many processes the prompt starts is the other check's job, in
# ci.yml.
#
# Settings, as environment variables:
#   ROUNDS   alternating rounds per scenario       (default 9)
#   RUNS     prompts per round                      (default 300)
#   MAX_PCT  slowdown that fails, in percent        (default 5)
#   MAX_US   ...and in microseconds, both required  (default 40)
set -euo pipefail

rounds="${ROUNDS:-9}" runs="${RUNS:-300}" max_pct="${MAX_PCT:-5}" max_us="${MAX_US:-40}"
lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.bash"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT

# A ps1.bash from before it had __git_status calls git inline, where there
# is nothing to replace, so that call is rewritten in a copy to the same
# assignment. It changes nothing in a file that has the function. Only the
# base can be that old: once main has __git_status, this goes.
sed 's/st=\$(exec git [^)]*)/st=$ST/' "$1" > "$t/base.bash"
# Either way there has to be something stood in for: without it the real
# git runs, and the comparison is of its noise.
for f in "$t/base.bash" "$2"; do
  grep -qE '^__git_status\(\)|st=\$ST' "$f" \
    || { echo "perf: no call to git to stand in for in $f" >&2; exit 1; }
done

# ─── A repo in a typical state ─────────────────────────────────────
# A branch with an upstream, one file each staged, unstaged and untracked,
# and GitHub data cached by a stand-in gh, so every segment draws.
mkdir "$t/bin"
cat > "$t/bin/gh" <<'EOF'
#!/bin/bash
case "$*" in
  *"repos/me/app -q .visibility") echo public ;;
  *"/branches/main -q .protected") echo true ;;
  *"/commits/"*) echo '{"check_runs":[{"status":"completed","conclusion":"success","completed_at":"2026-01-01T00:00:00Z"}]}' ;;
esac
EOF
chmod +x "$t/bin/gh"
export PATH="$t/bin:$PATH"
git init -q -b main "$t/repo"
(
  cd "$t/repo"
  git config user.name ci; git config user.email ci@example.invalid
  echo a > a; echo b > b; git add a b; git commit -qm one
  git remote add origin git@github.com:me/app.git
  git update-ref refs/remotes/origin/main HEAD
  git config branch.main.remote origin; git config branch.main.merge refs/heads/main
  echo staged > a; git add a; echo unstaged > b; echo new > c
)
mkdir "$t/outside"

# warm <ps1.bash> <runtime dir>: fill that version's caches with real git,
# with lifetimes long enough that nothing expires while it is being timed.
warm() {
  ( cd "$t/repo"; XDG_RUNTIME_DIR="$2" COLUMNS=200 bash --norc --noprofile -c '
      source "$1"; source "$2"; __GH_TTL=86400 __GH_REPO_TTL=86400 __CACHE_MISS_TTL=86400
      for _ in 1 2 3; do __prompt_render >/dev/null; settle; done' _ "$1" "$lib" )
}

# What stands in for git's answer: the repo's status, recorded once.
status=$(git -C "$t/repo" --no-optional-locks status --porcelain=v2 --branch)

# one <ps1.bash> <runtime dir> <dir>: µs per prompt, one round.
one() {
  ( cd "$3"; ST="$status" XDG_RUNTIME_DIR="$2" COLUMNS=200 RUNS="$runs" bash --norc --noprofile -c '
      source "$1"
      __git_status() { __GIT_STATUS=$ST; }
      for (( i = 0; i < 20; i++ )); do __prompt_render >/dev/null; done
      s=$EPOCHREALTIME
      for (( i = 0; i < RUNS; i++ )); do __prompt_render >/dev/null; done
      e=$EPOCHREALTIME
      echo $(( (${e/[.,]/} - ${s/[.,]/}) / RUNS ))' _ "$1" )
}

median() { sort -n | awk '{ v[NR] = $1 } END { print v[int((NR + 1) / 2)] }'; }

warm "$1" "$t/run-base"
warm "$2" "$t/run-head"

fail=0
for scenario in repo outside; do
  b=() h=()
  for (( r = 0; r < rounds; r++ )); do
    # Alternating, so that a machine slowing down or speeding up during the
    # job lands on both versions alike.
    b+=("$(one "$t/base.bash" "$t/run-base" "$t/$scenario")")
    h+=("$(one "$2" "$t/run-head" "$t/$scenario")")
  done
  mb=$(printf '%s\n' "${b[@]}" | median)
  mh=$(printf '%s\n' "${h[@]}" | median)
  d=$(( mh - mb ))
  pct=$(( mb > 0 ? d * 100 / mb : 0 ))
  verdict="ok"
  if (( d > max_us && pct >= max_pct )); then verdict="SLOWER"; fail=1; fi
  printf '%-8s base %5d µs   head %5d µs   %+5d µs (%+d%%)   %s\n' "$scenario" "$mb" "$mh" "$d" "$pct" "$verdict"
  printf '         rounds: base %s | head %s\n' "${b[*]}" "${h[*]}"
done

if (( fail )); then
  echo "The prompt got slower than ${max_pct}% and ${max_us} µs. If that is intended, add the"
  echo "perf-ok label to the pull request, which re-runs this check and lets it pass."
fi
exit "$fail"
