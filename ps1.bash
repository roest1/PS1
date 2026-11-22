#!/usr/bin/env bash
# ps1.bash — a git and GitHub aware bash prompt. https://github.com/roest1/PS1
#
# Source it from ~/.bashrc. Bash 5; git required; gh and jq optional.
#
# Prompt layout:
#   (base) you@host ~/path 🌍 branch 🛡️   2 staged  3 unstaged  1 untracked  🔼2 [5/5 ✅ 1d]
#   $
#
# Left side (PS1): conda env, user@host, path, repo visibility, git
#                  branch, a merge/rebase in progress, branch protection
# Right side (PROMPT_COMMAND): unmerged files, dirty state, sync, GH Actions
#
# Mid-operation the branch carries git's own state word, spelled the way
# git's contrib git-prompt.sh spells it so it reads the same everywhere:
# `main|MERGING`, `feature|REBASE 2/5`, `|CHERRY-PICKING`, `|REVERTING`,
# `|BISECTING`, `|AM`. Files left conflicted by it count as `N unmerged`.
#
# The three dirty-state counts are words rather than glyphs, and share one
# vocabulary on purpose: they answer the same question at three stages of
# the same pipeline, so `2 staged  3 unstaged  1 untracked` reads as one
# sentence where a mixed set of emoji and words read as three unrelated
# facts. Untracked counts entries, not files — see where it is rendered.
#
# Emoji reference:
#   ✅  All workflows passed        🔼  Ahead (needs push)
#   ❌  Workflow(s) failed          🔽  Behind (needs pull)
#   ⏳  Workflows running           🌍  Public repo
#   🔒  Private or internal repo    🛡️   Branch has protection rules
#
# Diverged has no glyph of its own: it renders as both arrows at once
# (🔼2 🔽3), which is unmistakable and cannot be read in the wrong order.
# When diverged, `2 conflicting` in bold red says merging those commits
# would conflict, and in how many files. Its ABSENCE means the merge is
# clean — or that the answer is still being computed, for one prompt.
#
# ─── One process per prompt ─────────────────────────────────────────
#
# Everything below is shaped by one measurement. On WSL2, a subshell fork
# costs ~200us, a fork+exec ~440us, and forking `git` ~900us. This prompt
# used to spend roughly fifty processes and ~19ms per Enter — of which
# about 1ms was git doing actual work. The cost was never the work, it
# was the forking, so the whole design is arranged to avoid it:
#
#   * ONE `git status --porcelain=v2 --branch` yields branch, staged,
#     unstaged, untracked, ahead, behind and the commit sha together. It
#     replaced six git invocations and their wc/head/awk pipelines. (git
#     itself spawns one more per submodule to see whether it is dirty, so
#     a repo with N submodules costs 1+N.)
#   * PS1 reads VARIABLES (__PS1_GIT, __PS1_CONDA) that PROMPT_COMMAND
#     sets. A `$(...)` in PS1 forks on every single Enter.
#   * The right side's visible width is accumulated as the string is
#     built, so nothing shells out to sed to strip colour or to count
#     double-width emoji afterwards.
#   * The GitHub cache is read with the `read` builtin and timestamped
#     from $EPOCHSECONDS, so displaying it costs no processes at all.
#
# Keep it that way. Anything you add below runs on every prompt, and a
# `$(...)` there is not free.

# ─── Conda ──────────────────────────────────────────────────────────
# Prevent Conda from messing with the prompt colors we built
export CONDA_CHANGEPS1=false

# ─── Colors and icons: the settings ────────────────────────────────
# The public interface of this file. Set any of these BEFORE sourcing it;
# they are read once, here, so changing one later needs a re-source.
#
#   PS1_COLOR_<NAME>   a 256-colour number (0-255) or a hex colour (#rrggbb)
#   PS1_ICON_<NAME>    any string; empty hides that marker
#   PS1_ICON_<NAME>_W  the columns it occupies, when the guess below is wrong
#
# Everything else in this file -- every __name -- is internal and may change.
#
# Colours become real ESC bytes rather than the string "\033": building the
# prompt from actual control characters means `printf '%s'` is enough,
# where `printf '%b'` would also expand any backslash in the data printed.
#
# A value that is neither form warns once on stderr and keeps the default,
# rather than drawing garbage or silently ignoring a typo. 10# because a
# leading zero would otherwise read as octal and `08` would be an error.
__ps1_color() {  # <out var> <NAME> <default 0-255> [bold]
  local n="PS1_COLOR_$2" v sgr
  v="${!n:-$3}"
  if [[ "$v" =~ ^[0-9]{1,3}$ ]] && (( 10#$v < 256 )); then
    sgr="38;5;$((10#$v))"
  elif [[ "$v" =~ ^#?([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$ ]]; then
    sgr="38;2;$((16#${BASH_REMATCH[1]}));$((16#${BASH_REMATCH[2]}));$((16#${BASH_REMATCH[3]}))"
  else
    printf 'ps1: %s=%q is not 0-255 or #rrggbb; using %s\n' "$n" "$v" "$3" >&2
    sgr="38;5;$3"
  fi
  printf -v "$1" '\033[%s%sm' "${4:+1;}" "$sgr"
}

# Width matters only for icons on the right side and for the fitting pass,
# which add up visible columns as they build the line. bash cannot ask the
# terminal how wide a glyph is, so: an explicit _W wins; plain ASCII is its
# length; anything else is assumed to be one double-width glyph, which is
# what the default emoji are. A Nerd Font or Material icon is usually ONE
# column -- set its _W.
__ps1_icon() {  # <out var> <width out var> <NAME> <default>
  local n="PS1_ICON_$3" wn="PS1_ICON_$3_W" v w chars
  if [[ -n "${!n+set}" ]]; then v="${!n}"; else v="$4"; fi
  w="${!wn:-}"
  printf -v "$1" '%s' "$v"
  if [[ ! "$w" =~ ^[0-9]+$ ]]; then
    # ASCII when its length in characters equals its length in bytes;
    # the local LC_ALL makes ${#v} count bytes and is undone on return.
    chars=${#v}
    local LC_ALL=C
    if (( chars == 0 )); then w=0
    elif (( chars == ${#v} )); then w=$chars
    else w=2
    fi
  fi
  printf -v "$2" '%s' "$w"
}

__ps1_color __C_HOST      HOST      75
__ps1_color __C_PATH      PATH      110
__ps1_color __C_CONDA     CONDA     141
__ps1_color __C_BRANCH    BRANCH    215
__ps1_color __C_STAGED    STAGED    150
__ps1_color __C_UNSTAGED  UNSTAGED  203
# Deliberately the quietest of the three dirty-state colours. Untracked is
# the least urgent of them — green is done, red is in progress, this is
# merely not-yet-git's-problem — and it used to be rendered as ✨, the
# loudest glyph on the line, which had the emphasis exactly backwards.
__ps1_color __C_UNTRACKED UNTRACKED 180
__ps1_color __C_GH        CI        250
__ps1_color __C_WARN      WARN      214
# The unstaged red, but bold. A predicted conflict is the same colour
# family as "you have edits" because that is what it is about to become a
# problem for, and it is the loudest thing on the line because it is the
# only state here that costs an afternoon rather than a keystroke.
__ps1_color __C_CONFLICT  CONFLICT  203 bold
__C_OFF=$'\033[0m'

# 🌍 and 🔒 are East Asian Wide; 🛡 is Neutral and needs the U+FE0F
# variation selector to render as an emoji at all, so terminals draw it 2
# columns wide while wcwidth() calls it 1. That mismatch is harmless for
# the three left-side markers: they sit on the first line of a two-line
# PS1, and readline measures only the text after the last newline when it
# places the cursor. Moving any of them below the \n would make the width
# lie matter — see the __NP_ON comment below for that class of bug.
__ps1_icon __I_PUBLIC    __IW_PUBLIC    PUBLIC    "🌍"
__ps1_icon __I_PRIVATE   __IW_PRIVATE   PRIVATE   "🔒"
__ps1_icon __I_PROTECTED __IW_PROTECTED PROTECTED "🛡️"
__ps1_icon __I_AHEAD     __IW_AHEAD     AHEAD     "🔼"
__ps1_icon __I_BEHIND    __IW_BEHIND    BEHIND    "🔽"
__ps1_icon __I_CI_PASS   __IW_CI_PASS   CI_PASS   "✅"
__ps1_icon __I_CI_FAIL   __IW_CI_FAIL   CI_FAIL   "❌"
__ps1_icon __I_CI_RUN    __IW_CI_RUN    CI_RUN    "⏳"
unset -f __ps1_color __ps1_icon

# \001 and \002 are what bash's \[ and \] decode to: "readline, the bytes
# between these occupy no columns". They cannot be spelled \[ and \] in
# __PS1_GIT / __PS1_CONDA, because bash decodes backslash escapes in PS1
# *before* it expands the variables — a \[ arriving through a variable
# stays literal and readline never learns the colour is zero-width. That
# was the old bug: ~29 colour bytes counted as visible, so long command
# lines and Ctrl-R recall wrapped in the wrong place.
__NP_ON=$'\001'
__NP_OFF=$'\002'

# ─── Time helpers ───────────────────────────────────────────────────

# __relative_age <out_var> <epoch> <now_epoch>
# Formats an age as now / 2m / 1h / 3d / 2w into a variable, in pure bash.
# Pure bash on purpose: an ISO-string version wrapping two `date` execs in
# $( ) cost 1631us per prompt to produce the same string this does in
# 66us.
#
# The local is __ra_secs, not the obvious `age`, because bash locals are
# dynamically scoped: a caller doing `__relative_age age ...` would have
# `printf -v age` land on THIS function's local and vanish on return. The
# ugly prefix is what makes the out-parameter safe to name anything.
__relative_age() {
  local __ra_secs=$(( $3 - $2 ))
  if   (( __ra_secs < 60 ));     then printf -v "$1" "now"
  elif (( __ra_secs < 3600 ));   then printf -v "$1" "%dm" $(( __ra_secs / 60 ))
  elif (( __ra_secs < 86400 ));  then printf -v "$1" "%dh" $(( __ra_secs / 3600 ))
  elif (( __ra_secs < 604800 )); then printf -v "$1" "%dd" $(( __ra_secs / 86400 ))
  else                                printf -v "$1" "%dw" $(( __ra_secs / 604800 ))
  fi
}

# ─── Background cache ───────────────────────────────────────────────
#
# Three segments below want an answer too slow to compute on the prompt
# path: CI status (a network round trip), repo visibility and branch
# protection (two more), and whether a diverged pull would conflict (up to
# 11ms of merge). All three want the same shape — show what was last known
# instantly, refresh in a detached job — so the shape lives here once.
#
# It is one place on purpose. The staleness check is easy; the corpse
# check below is not, and it was worth getting wrong once rather than
# three times.
#
# The contract: a producer is called as `<fn> [args...]` and PRINTS one
# line of |-separated fields, or nothing when it has no answer. Those
# fields are its own business. This layer owns everything else: it appends
# the epoch the entry EXPIRES at as the last field, writes the line
# atomically, and strips that field again on the way back out — so a
# producer that had no answer simply reads back as no fields at all.
#
# An expiry rather than a fetch time, so that "no answer" can be cached
# too, for less long, without a sentinel the reader has to know about.
# Caching it is the point: every producer used to delete its entry when it
# had nothing to say, which left nothing to be fresh by, and a GitHub repo
# with no workflows, a commit not pushed yet, a GitLab remote or a
# logged-out gh each cost a gh launch, and an API call, on every Enter.

__CACHE_PENDING_TTL=120  # seconds before an unfinished refresh is presumed dead
__CACHE_MISS_TTL=60      # seconds before "no answer" is asked again

# __cache_run <cache_file> <ttl> <fn> [args...]
# The detached half. Forks as freely as it likes — by the time this runs
# it is already off the prompt path.
__cache_run() {
  local cache_file="$1" ttl="$2" fn="$3" line
  shift 3

  line=$("$fn" "$@")
  line="${line%%$'\n'*}"
  # No answer is kept for less long, so a fresh login or a first push
  # shows up within a minute rather than within the TTL.
  [[ -z "$line" ]] && (( ttl > __CACHE_MISS_TTL )) && ttl=$__CACHE_MISS_TTL

  # Written beside the entry and renamed over it. A prompt reading at the
  # same moment as a plain `>` would find the file truncated and empty;
  # rename is atomic, so it finds the old line or the new one.
  local tmp="${cache_file}.${BASHPID}.tmp"
  printf '%s%s\n' "${line:+$line|}" "$(( EPOCHSECONDS + ttl ))" > "$tmp" \
    && mv -f "$tmp" "$cache_file"

  # These caches are keyed, so they accumulate an entry per commit, per
  # branch, per merge. Sweeping here costs nothing; sweeping in the prompt
  # would cost a `find`. -mtime +1 rounds down, so it really means "two
  # days or older" — this is garbage collection, not a TTL, and the TTL is
  # what keeps answers fresh.
  find "${cache_file%/*}" -type f -mtime +1 -delete 2>/dev/null

  rm -f "${cache_file}.pending" "$tmp"
}

# __cache_get <dir> <ttl> <key> <now> <fn> [args...]
# Sets __CACHE_FIELDS to the producer's fields for this key, empty when
# there is none yet or it had no answer, and launches <fn> detached when
# the entry has expired. Spends no processes: `read` is a builtin and the
# expiry is arithmetic.
#
# The locals carry a __cg_ prefix for the reason __relative_age documents
# above: bash locals are dynamically scoped, so a plainly-named local here
# would shadow a same-named variable in the caller for the duration of the
# call. __CACHE_FIELDS is a global for the same reason — an out-parameter
# naming the caller's variable would have to dodge its own locals.
__cache_get() {
  local __cg_dir="$1" __cg_ttl="$2" __cg_key="$3" __cg_now="$4" __cg_fn="$5"
  shift 5

  local __cg_file="${__cg_dir}/${__cg_key}"
  local __cg_pending="${__cg_file}.pending"

  # Split straight out of the file. Reading the line and splitting it
  # afterwards would want a <<< here-string, and bash implements those
  # with a temporary file — real I/O, on the prompt path, per segment.
  __CACHE_FIELDS=()
  [[ -f "$__cg_file" ]] && IFS='|' read -r -a __CACHE_FIELDS < "$__cg_file"

  # The expiry is the layer's own field; what is left is the producer's.
  # (Guarded: [-1] of an empty array is an error message, not an empty string.)
  local __cg_expires=0
  if (( ${#__CACHE_FIELDS[@]} )); then
    __cg_expires="${__CACHE_FIELDS[-1]}"
    unset '__CACHE_FIELDS[-1]'
  fi
  case "$__cg_expires" in
    '' | *[!0-9]*) __cg_expires=0 ;;
  esac

  (( __cg_now > __cg_expires )) || return 0

  # A pending marker whose job died — terminal closed, WSL shut down,
  # SIGKILL — used to freeze its entry permanently, because the marker was
  # only ever removed by the job that no longer existed. A trap cannot fix
  # that (SIGKILL runs no traps), so the marker carries the epoch it was
  # written at and anything too old is a corpse. Unreadable or empty
  # counts as too old: the worst case there is a duplicate refresh, where
  # the worst case of trusting it is freezing forever.
  local __cg_pend=""
  [[ -f "$__cg_pending" ]] && read -r __cg_pend < "$__cg_pending"
  case "$__cg_pend" in
    '' | *[!0-9]*) __cg_pend=0 ;;
  esac
  (( __cg_now - __cg_pend > __CACHE_PENDING_TTL )) || return 0

  # The directory is made here, the first time a refresh is due, rather
  # than at source time, where it would fork in every shell that starts.
  # It has to exist before the marker below, or the marker cannot be
  # written and every Enter until the first refresh finishes launches
  # another one. Once per boot, since XDG_RUNTIME_DIR is a tmpfs. umask,
  # not `mkdir -m`: -m applies to the last directory only.
  [[ -d "$__cg_dir" ]] || (umask 077 && mkdir -p "$__cg_dir") 2>/dev/null

  # 2>/dev/null FIRST: the directory can still be unwritable, redirections
  # are applied left to right, and the other order leaks the failure to the
  # terminal mid-prompt.
  printf '%s' "$__cg_now" 2>/dev/null > "$__cg_pending"

  # Launched from inside a subshell, not as a bare `... & disown`. An
  # interactive shell announces a background job as "[1] 12345" on stderr,
  # and this runs in the shell itself rather than inside a $( ), so the
  # announcement would land in the terminal every time a cache went stale.
  # Job control is off in a subshell, which silences it; the grandchild
  # outlives the subshell and is reparented, so no disown is needed.
  # Its output goes nowhere: it would otherwise still own the terminal, and
  # anything it printed would land in the middle of whatever you typed.
  ( __cache_run "$__cg_file" "$__cg_ttl" "$__cg_fn" "$@" >/dev/null 2>&1 & )
  return 0
}

# ─── Where the caches live ──────────────────────────────────────────
# Per user, never a fixed name in /tmp. A shared /tmp lets any other
# account create /tmp/gh_status_cache first and fill it: this prompt would
# then print their bytes -- terminal escapes included -- into yours, and
# feed their fields to its arithmetic. XDG_RUNTIME_DIR is the user's own
# 0700 tmpfs on systemd machines, cleared at logout like /tmp; the cache
# directory is the fallback where there is none.
__PS1_CACHE_ROOT="${XDG_RUNTIME_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}}/ps1"

# ─── GitHub Actions (on by default; export GH_PROMPT=0 to hide) ─────
#
# Only displays for repos that HAVE workflows.
# Background refresh every 60s — never blocks prompt.
# Timestamp = when the workflow actually ran (not cache age).
export GH_PROMPT="${GH_PROMPT:-1}"

__GH_CACHE_DIR="$__PS1_CACHE_ROOT/gh_status"
__GH_TTL=60           # seconds before a cached answer is refreshed

# Cache file: succeeded|total|symbol|run_epoch|skipped|expires_epoch
#
# Both timestamps are integers rather than ISO strings, and the expiry
# lives in the file rather than in its mtime. That is what lets the
# display path below run without a single `date` or `stat`.
#
# The key is the worktree and the commit sha, not $PWD. Check runs belong
# to a commit, so every subdirectory of a repo shares one entry instead of
# each making its own API call, and committing invalidates instantly
# instead of showing the previous commit's verdict for up to a minute. The
# worktree is in it because a fork and its parent can sit at the same sha
# with different CI, and a key of the sha alone handed one the other's.

# __gh_remote <branch>
# Sets __gh_host and __gh_repo (OWNER/REPO) for the GitHub repo this
# branch belongs to: the remote it tracks, else origin, else the first
# remote. Fails for a remote that is not a URL, or on a host other than
# github.com that gh holds no login for. Runs only in the detached
# refresh, so it forks freely.
#
# Not a bare `gh repo view`, which this used to be. That makes gh pick a
# remote by its OWN ranking, where a remote named `upstream` outranks
# origin — so in a fork it answered for the parent repo, and the globe,
# the shield and the CI block all described a repo you were not on.
#
# `gh auth token` is a local lookup: a host with no login (gitlab.com, an
# intranet git server) is turned away before anything touches the network.
# Not asked for github.com, where a logged-out `gh api` already fails the
# same way without the network — and asking costs a ~45ms gh start.
__gh_remote() {
  local branch="$1" remote="" url host path
  __gh_host="" __gh_repo=""

  [[ -n "$branch" ]] && remote=$(git config "branch.${branch}.remote" 2>/dev/null)
  # `.` means it tracks another LOCAL branch — there is no remote in that.
  [[ -z "$remote" || "$remote" == . ]] && remote=origin
  url=$(git remote get-url "$remote" 2>/dev/null) \
    || url=$(git remote get-url "$(git remote 2>/dev/null | head -n 1)" 2>/dev/null) \
    || return 1

  # scheme://[user@]host[:port]/owner/repo[.git]   or   [user@]host:owner/repo[.git]
  case "$url" in
    *://*) url="${url#*://}"; host="${url%%/*}"; path="${url#*/}"
           host="${host##*@}"; host="${host%%:*}" ;;
    *:*)   host="${url%%:*}"; path="${url#*:}"; host="${host##*@}" ;;
    *)     return 1 ;;  # a path on disk
  esac
  path="${path%/}"; path="${path%.git}"
  # GitHub's ssh-over-443 endpoint is github.com under another name.
  [[ "$host" == ssh.github.com ]] && host=github.com
  [[ -n "$host" && "$path" == */* ]] || return 1

  [[ "$host" == github.com ]] || gh auth token --hostname "$host" &>/dev/null || return 1
  __gh_host="$host" __gh_repo="$path"
}

# __uri_encode <string>
# Prints it percent-encoded, keeping only unreserved characters and `/`.
# A branch goes into an API path, and `fix#12` sent raw is `fix` — the
# `#` starts a URL fragment — so a branch named `main#x` used to borrow
# main's protection. Bytes, not characters: hence the C locale.
__uri_encode() {
  local LC_ALL=C s="$1" c i out=""
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [A-Za-z0-9._~/-]) out+="$c" ;;
      *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

# __gh_refresh <sha> <branch>
# A producer for __cache_get: prints the fields, or nothing.
#
# One jq pass over every page (`--paginate`; the API returns 30 runs per
# page by default, so a big matrix used to read as [30/30]). A finished
# run counts as failed unless it succeeded, was skipped or was neutral:
# timed_out, cancelled, startup_failure and action_required all used to
# render as ✅. The age is the most recent run's, not whichever the API
# happened to list first, and jq converts it, so no `date` is spent.
__gh_refresh() {
  local sha="$1" branch="$2" result
  __gh_remote "$branch" || return 0
  result=$(gh api --hostname "$__gh_host" --paginate \
             "repos/${__gh_repo}/commits/${sha}/check-runs?per_page=100" 2>/dev/null) || return 0

  jq -rs '
    [ .[].check_runs[] ] as $r
    | select($r | length > 0)
    | [ ($r | map(select(.conclusion == "success")) | length),
        ($r | length),
        ( if any($r[]; .status == "completed"
                       and (.conclusion | IN("success", "skipped", "neutral") | not))
            then "fail"
          elif any($r[]; .status != "completed") then "run"
          else "ok" end ),
        ( $r | map(.completed_at // .started_at // empty) | max
          | if . == null then "" else (try fromdateiso8601 catch "") end ),
        ($r | map(select(.conclusion == "skipped")) | length)
      ] | map(tostring) | join("|")' <<< "$result" 2>/dev/null
}

# __gh_segment <sha> <branch> <now_epoch>
# Sets __gh_out (the rendered segment) and __gh_w (its width in columns).
# Spends no processes: `command -v` and `read` are builtins and the age is
# arithmetic. Only the background refresh it may launch costs anything.
# The branch only says which remote to ask; it is not part of the key.
__gh_segment() {
  __gh_out=""
  __gh_w=0

  [[ "$GH_PROMPT" == "1" ]] || return
  local sha="$1" branch="$2" now="$3"
  [[ -n "$sha" ]] || return
  command -v gh &>/dev/null || return
  command -v jq &>/dev/null || return

  local key="${__GIT_TOPLEVEL:-$PWD}"
  key="${key//\//%}#${sha}"
  __cache_get "$__GH_CACHE_DIR" "$__GH_TTL" "$key" "$now" __gh_refresh "$sha" "$branch"

  local s="${__CACHE_FIELDS[0]}" t="${__CACHE_FIELDS[1]}" sym="${__CACHE_FIELDS[2]}"
  local run_epoch="${__CACHE_FIELDS[3]}" skipped="${__CACHE_FIELDS[4]}"

  [[ -n "$s" && -n "$t" ]] || return

  # Both of these reach `(( ))` below, and a cache entry written by an
  # OLDER version of this file will not have the shape this one expects.
  # That is not hypothetical: the old /tmp caches held entries from before
  # run_epoch became an integer, and feeding one of those to the
  # arithmetic prints
  #
  #   value too great for base (error token is "08")
  #
  # into the middle of the prompt, once per Enter, forever. The CI check
  # that configs emit nothing when sourced cannot see this — it happens at
  # prompt time, not source time — so the guard has to live here. Anything
  # non-numeric is treated as absent, which costs one refresh.
  case "$run_epoch" in
    *[!0-9]*) run_epoch="" ;;
  esac
  case "$skipped" in
    '' | *[!0-9]*) skipped=0 ;;
  esac

  local emoji emoji_w
  case "$sym" in
    fail) emoji="$__I_CI_FAIL" emoji_w=$__IW_CI_FAIL ;;
    run)  emoji="$__I_CI_RUN"  emoji_w=$__IW_CI_RUN ;;
    *)    emoji="$__I_CI_PASS" emoji_w=$__IW_CI_PASS ;;
  esac

  local skipped_str=""
  (( skipped > 0 )) && skipped_str=" (${skipped} skipped)"

  local age=""
  [[ -n "$run_epoch" ]] && __relative_age age "$run_epoch" "$now"

  __gh_out="${__C_GH}[${s}/${t} ${emoji}${skipped_str} ${age}]${__C_OFF}"
  # Visible: [ s / t <space> icon <skipped> <space> age ] — the two
  # brackets, the slash and the two spaces are 5, plus the icon's width.
  __gh_w=$(( ${#s} + ${#t} + ${#skipped_str} + ${#age} + 5 + emoji_w ))
}

# ─── Repo visibility and branch protection ──────────────────────────
#
# Wrapped around the branch on the left side of the prompt:
#
#   🌍 main 🛡️     public repo, branch has protection rules
#   🔒 main        private repo, no rules on this branch
#
# Both answers live on GitHub, so both are fetched exactly the way CI
# status above is: a detached job writes a cache file, and the prompt
# reads it back with the `read` builtin. Nothing here forks on the prompt
# path. A repo you have not visited in the last __GH_REPO_TTL seconds
# therefore shows its branch bare for one prompt and decorated from the
# next one, which is the same one-prompt lag the CI segment has.
#
# Cache file: visibility|protected|expires_epoch
#
# Keyed on worktree + branch, NOT on the commit sha the CI cache uses.
# Neither answer is a property of a commit — protection attaches to a
# branch NAME and visibility to the repo — so keying on the sha would
# throw away a still-correct answer on every commit and re-ask GitHub for
# it. The worktree is in the key because two worktrees of one repo can
# sit on different branches, and a submodule's visibility is its own.
__GH_REPO_CACHE_DIR="$__PS1_CACHE_ROOT/gh_repo"
__GH_REPO_TTL=300      # visibility and protection rules both change rarely

# The three markers are __I_PUBLIC, __I_PRIVATE and __I_PROTECTED, set
# with the other icons at the top of this file.

# __repo_meta_refresh <branch>
# A producer for __cache_get: prints the fields, or nothing. No visibility
# means no GitHub repo here — a non-GitHub remote, a deleted repo, an
# expired token — and printing nothing records that as a miss.
#
# Every call is checked for success, not just for output: on an error gh
# prints the error BODY to stdout, and a 404 once went into the cache as
# this repo's "visibility".
__repo_meta_refresh() {
  local branch="$1" vis prot=0 out enc

  __gh_remote "$branch" || return 0
  vis=$(gh api --hostname "$__gh_host" "repos/${__gh_repo}" -q .visibility 2>/dev/null) || return 0
  case "$vis" in
    public | private | internal) ;;
    *) return 0 ;;
  esac

  if [[ -n "$branch" ]]; then
    enc=$(__uri_encode "$branch")
    # The branch's own `.protected` first: it covers classic protection
    # AND rulesets — this repo's main has no classic protection and still
    # reads true off its rulesets — so on a pushed branch it is the whole
    # answer in one call. It 404s on a branch that exists only here, and
    # for those the rulesets endpoint answers instead: it needs no admin
    # rights, and a ruleset matches a NAME rather than an existing ref.
    if out=$(gh api --hostname "$__gh_host" "repos/${__gh_repo}/branches/${enc}" -q '.protected' 2>/dev/null); then
      [[ "$out" == true ]] && prot=1
    elif out=$(gh api --hostname "$__gh_host" "repos/${__gh_repo}/rules/branches/${enc}" -q 'length' 2>/dev/null); then
      [[ "$out" =~ ^[0-9]+$ ]] && (( out > 0 )) && prot=1
    fi
  fi

  printf '%s|%s' "$vis" "$prot"
}

# __repo_meta_segment <branch> <now_epoch>
# Sets __repo_pre (rendered left of the branch) and __repo_post (right of
# it). An empty branch still gets visibility — that is the detached-HEAD
# call, where there is no branch name for a rule to attach to.
# Spends no processes; only the background refresh it may launch does.
__repo_meta_segment() {
  __repo_pre=""
  __repo_post=""
  __repo_pre_w=0
  __repo_post_w=0

  [[ "$GH_PROMPT" == "1" ]] || return
  local branch="$1" now="$2"
  command -v gh &>/dev/null || return

  # Slashes become % so that a path and a branch like feature/foo compose
  # into one filename. A worktree buried deeper than the 255-byte filename
  # limit simply fails to cache and shows a bare branch, which is the
  # right way for this to degrade.
  local key="${__GIT_TOPLEVEL:-$PWD}"
  key="${key//\//%}#${branch//\//%}"

  __cache_get "$__GH_REPO_CACHE_DIR" "$__GH_REPO_TTL" "$key" "$now" \
    __repo_meta_refresh "$branch"

  local vis="${__CACHE_FIELDS[0]}" prot="${__CACHE_FIELDS[1]}"

  # Internal is an org repo visible to that org and nobody else. It is not
  # public, so it reads as the lock rather than inventing a third glyph.
  case "$vis" in
    public)
      [[ -n "$__I_PUBLIC" ]] && { __repo_pre="$__I_PUBLIC "; __repo_pre_w=$(( __IW_PUBLIC + 1 )); } ;;
    private | internal)
      [[ -n "$__I_PRIVATE" ]] && { __repo_pre="$__I_PRIVATE "; __repo_pre_w=$(( __IW_PRIVATE + 1 )); } ;;
  esac
  [[ "$prot" == "1" && -n "$__I_PROTECTED" ]] \
    && { __repo_post=" $__I_PROTECTED"; __repo_post_w=$(( __IW_PROTECTED + 1 )); }
  return 0
}

# ─── Will the pull fight you? ───────────────────────────────────────
#
# 🔼2 🔽3 says the pull is not a fast-forward. It does not say whether
# merging those commits will conflict, which is the part that decides
# whether you deal with it now or after lunch. `git merge-tree` answers
# exactly that: it performs the merge in memory and reports the result,
# touching no working tree, no index and no branch.
#
#   exit 0                  merges clean
#   exit 1 + stdout         conflicts; stdout is the tree oid then paths
#   exit 1 + NO stdout      the ref does not exist
#   exit 128 / 129          unrelated histories, or a git too old for
#                           --write-tree (added in 2.38)
#
# That third line is the trap. A missing upstream ref exits 1 exactly
# like a real conflict does, so the obvious `if ! git merge-tree ...`
# reports a conflict that does not exist every time the ref is gone. The
# tree oid on stdout is what tells them apart, and it is why this reads
# the output rather than trusting the status alone. Exit 129 is also why
# no version check is needed: an old git simply lands in the "unknown"
# case and the prompt stays quiet.
#
# ONLY RUN WHEN DIVERGED. Behind-but-not-ahead fast-forwards, and a
# fast-forward cannot conflict, so the common case never starts this at
# all. That matters: merge-tree is fast on a normal divergence (~1ms) but
# was measured at 11.66ms merging 40 commits against 40 over 400 shared
# files, and a prompt does not get to have a worst case like that. Hence
# the same background-cache shape as the two segments above.
#
# Cache file: conflicted_files|expires_epoch
__GIT_MERGE_CACHE_DIR="$__PS1_CACHE_ROOT/git_merge"
__GIT_MERGE_TTL=300

# __merge_refresh <upstream>
# A producer for __cache_get: prints the conflicted file count, or nothing.
__merge_refresh() {
  local upstream="$1"
  local out rc files=0 line first=1

  out=$(git --no-optional-locks merge-tree --write-tree --name-only \
          HEAD "$upstream" 2>/dev/null)
  rc=$?

  if (( rc == 1 )) && [[ -n "$out" ]]; then
    # Line 1 is the merged tree's oid. The conflicted paths follow it, and
    # a blank line ends them before git's human-readable explanation.
    while IFS= read -r line; do
      if (( first )); then first=0; continue; fi
      [[ -z "$line" ]] && break
      (( ++files ))
    done <<< "$out"
  elif (( rc != 0 )); then
    # Unknown, not clean. Print nothing rather than a reassuring zero —
    # silence here already means "merges fine", and this is the one
    # indicator where guessing wrong in that direction is the bad way.
    return 0
  fi

  printf '%s' "$files"
}

# __merge_segment <upstream> <oid> <ahead> <behind> <now_epoch>
# Sets __merge_out and __merge_w. Spends no processes; only the background
# refresh it may launch does.
__merge_segment() {
  __merge_out=""
  __merge_w=0

  local upstream="$1" oid="$2" ahead="$3" behind="$4" now="$5"
  [[ -n "$upstream" && -n "$oid" ]] || return

  # Keyed on both sides of the merge. The oid moves when you commit; the
  # behind count moves when a fetch brings something new, which is the
  # only way the upstream can change under you. An upstream force-pushed
  # to a DIFFERENT set of commits of the same length keeps the same key
  # and so keeps a stale answer until the TTL expires — the one case this
  # key cannot see, and the reason there is a TTL at all rather than
  # caching forever on an exact key.
  local key="${__GIT_TOPLEVEL:-$PWD}"
  key="${key//\//%}#${oid}#${ahead}#${behind}"

  __cache_get "$__GIT_MERGE_CACHE_DIR" "$__GIT_MERGE_TTL" "$key" "$now" \
    __merge_refresh "$upstream"

  local files="${__CACHE_FIELDS[0]}"

  case "$files" in
    '' | *[!0-9]* | 0) return ;;
  esac

  __merge_out="${__C_CONFLICT}${files} conflicting${__C_OFF}  "
  (( __merge_w = ${#files} + 14 ))               # " conflicting" + 2 spaces
  return 0
}

# ─── Is there a repo here at all? ───────────────────────────────────
#
# Forking git only to have it walk up the tree and fail costs ~700us on
# the Linux filesystem and ~1.6ms under /mnt, where every stat crosses
# drvfs. Walking the same parents in bash costs 7us in a repo and 287us
# in the worst /mnt case, so this is worth doing before the fork.
#
# It deliberately answers a slightly different question from git's, and
# is therefore only ever used to SKIP work, never to claim a repo exists.
# The two ways it disagrees, both measured against real repos:
#
#   inside a .git directory  it says yes where git says no. Harmless —
#                            git is forked, fails, and its answer wins.
#   GIT_DIR / GIT_WORK_TREE  it would say no where git says yes, which
#                            would silently drop the branch. Shells
#                            spawned from git hooks have these set, so
#                            they bypass the fast path entirely.
#
# Sets __GIT_TOPLEVEL and __GIT_DIR as a side effect, which saves asking
# git for them. __GIT_DIR is the directory git keeps THIS worktree's state
# in: .git itself, or, where .git is a file (a linked worktree or a
# submodule), the directory its `gitdir:` line names.
__in_git_tree() {
  __GIT_TOPLEVEL="" __GIT_DIR=""
  # Let git answer whenever the environment overrides where the repo is.
  if [[ -n "$GIT_DIR" || -n "$GIT_WORK_TREE" ]]; then
    __GIT_DIR="$GIT_DIR"
    return 0
  fi
  local d="$PWD" line
  while :; do
    # -e first, one stat per parent; -d and -f only once something is there.
    if [[ -e "$d/.git" ]]; then
      __GIT_TOPLEVEL="$d" __GIT_DIR="$d/.git"
      if [[ ! -d "$__GIT_DIR" ]]; then
        { read -r line < "$__GIT_DIR"; } 2>/dev/null
        __GIT_DIR="${line#gitdir: }"
        [[ "$__GIT_DIR" == /* ]] || __GIT_DIR="$d/$__GIT_DIR"
      fi
      return 0
    fi
    [[ -z "$d" || "$d" == / ]] && return 1
    d="${d%/*}"
    [[ -z "$d" ]] && d=/
  done
}

# __repo_has_remote
# True if the repo's config declares any remote at all. Read with the
# `read` builtin (22us) rather than `git remote` (716us, a fork).
#
# Only reached when the branch has no upstream, so the common case pays
# nothing. Anything it cannot read counts as "has a remote", because the
# warning this drives should never fire on a guess.
__repo_has_remote() {
  local dir="$__GIT_DIR" common line
  # A linked worktree's own git directory holds no config: `commondir`
  # points at the main repo's, which does.
  if [[ -f "$dir/commondir" ]]; then
    { read -r common < "$dir/commondir"; } 2>/dev/null
    [[ "$common" == /* ]] && dir="$common" || dir="$dir/$common"
  fi
  local cfg="$dir/config"
  [[ -n "$__GIT_DIR" && -f "$cfg" ]] || return 0
  while IFS= read -r line; do
    [[ "$line" == '[remote '* ]] && return 0
  done < "$cfg"
  return 1
}

# __git_state
# Sets __git_op to the operation in progress ("MERGING", "REBASE 2/5",
# ...) or empty, and __git_op_head to the branch a rebase is rewriting.
#
# Read off the files git leaves in the git directory, in the order and
# with the words git's contrib git-prompt.sh uses: a few stat calls and
# `read`s, no fork. This is the one state where the prompt matters most —
# mid-rebase HEAD is detached, and without it the branch reads as a bare
# sha with nothing to say why.
#
# The operation files are per worktree, which is why this reads __GIT_DIR
# (this worktree's) and not the main repo's.
__git_state() {
  __git_op="" __git_op_head=""
  local g="$__GIT_DIR" step="" total=""
  [[ -n "$g" ]] || return 0

  if [[ -d "$g/rebase-merge" ]]; then
    {
      read -r __git_op_head < "$g/rebase-merge/head-name"
      read -r step  < "$g/rebase-merge/msgnum"
      read -r total < "$g/rebase-merge/end"
    } 2>/dev/null
    __git_op="REBASE"
  elif [[ -d "$g/rebase-apply" ]]; then
    {
      read -r step  < "$g/rebase-apply/next"
      read -r total < "$g/rebase-apply/last"
    } 2>/dev/null
    if   [[ -f "$g/rebase-apply/rebasing" ]]; then
      { read -r __git_op_head < "$g/rebase-apply/head-name"; } 2>/dev/null
      __git_op="REBASE"
    elif [[ -f "$g/rebase-apply/applying" ]]; then __git_op="AM"
    else                                             __git_op="AM/REBASE"
    fi
  elif [[ -f "$g/MERGE_HEAD" ]];       then __git_op="MERGING"
  elif [[ -f "$g/CHERRY_PICK_HEAD" ]]; then __git_op="CHERRY-PICKING"
  elif [[ -f "$g/REVERT_HEAD" ]];      then __git_op="REVERTING"
  elif [[ -f "$g/BISECT_LOG" ]];       then __git_op="BISECTING"
  fi

  __git_op_head="${__git_op_head#refs/heads/}"
  [[ -n "$__git_op" && -n "$step" && -n "$total" ]] && __git_op+=" $step/$total"
  return 0
}

# ─── The prompt ─────────────────────────────────────────────────────
#
# Sets __PS1_CONDA and __PS1_GIT for PS1 to read, then prints the right
# side at the right edge using ANSI cursor positioning (\033[{col}G)
# followed by a carriage return, so PS1 redraws over it from column 0.

# The PROMPT_COMMAND entry. It runs FIRST (see the bottom of this file),
# so every hook after it reads $? — and used to read this function's
# status rather than your last command's, which is a lie to any hook that
# shows or acts on exit codes. It hands the real one back on the way out.
__prompt_render() {
  local __pr_status=$?
  __prompt_draw
  return "$__pr_status"
}

__prompt_draw() {
  local st line xy ab
  local head="" oid="" staged=0 unstaged=0 untracked=0 unmerged=0 ahead=0 behind=0
  # The upstream's NAME, not a flag. porcelain v2 hands it over for free
  # and the merge check below needs something to merge against; emptiness
  # still answers the "is there an upstream at all" question a flag did.
  local upstream=""

  __PS1_CONDA=""
  if [[ -n "$CONDA_DEFAULT_ENV" ]]; then
    __PS1_CONDA="${__NP_ON}${__C_CONDA}${__NP_OFF}(${CONDA_DEFAULT_ENV})${__NP_ON}${__C_OFF}${__NP_OFF} "
  fi

  # Cleared before the git call, not after it: leaving a repo has to drop
  # the branch, and the early return below is the path that does it.
  __PS1_GIT=""

  # Skip the fork entirely in directories with no repo above them — see
  # __in_git_tree for why it is safe to trust a "no" here.
  __in_git_tree || return

  # The one process this prompt spends. --no-optional-locks keeps it from
  # taking the index lock, so pressing Enter cannot contend with a rebase
  # running in another terminal.
  st=$(git --no-optional-locks status --porcelain=v2 --branch 2>/dev/null) || return

  while IFS= read -r line; do
    case "$line" in
      '# branch.oid '*)  oid="${line#'# branch.oid '}" ;;
      '# branch.head '*) head="${line#'# branch.head '}" ;;
      '# branch.upstream '*) upstream="${line#'# branch.upstream '}" ;;
      '# branch.ab '*)   ab="${line#'# branch.ab '}"      # "+2 -3"
                         ahead="${ab%% *}";  ahead="${ahead#+}"
                         behind="${ab##* }"; behind="${behind#-}" ;;
      # 1 = tracked change, 2 = rename/copy. Columns 3-4 are XY: X is the
      # staged state, Y the unstaged one, '.' meaning unchanged. Pre-
      # increment, because (( n++ )) evaluates to 0 the first time and so
      # returns a non-zero status.
      '1 '* | '2 '*)     xy="${line:2:2}"
                         [[ "${xy:0:1}" == . ]] || (( ++staged ))
                         [[ "${xy:1:1}" == . ]] || (( ++unstaged )) ;;
      '? '*)             (( ++untracked )) ;;
      # u = unmerged: a path an operation left conflicted. It has neither
      # staged nor unstaged meaning, and it used to fall through this case
      # entirely, so a merge with conflicts in it drew nothing at all.
      'u '*)             (( ++unmerged )) ;;
    esac
  done <<< "$st"

  # An unborn branch reports "(initial)" — a placeholder, not a sha, and
  # nothing to ask GitHub about.
  [[ "$oid" == '(initial)' ]] && oid=""
  # porcelain v2 says "(detached)" where the old prompt showed
  # `git rev-parse --short`, which picks its length by ambiguity. Seven is
  # what it returns for repos this size.
  #
  # prot_branch stays empty while detached, because what is displayed then
  # is a sha, and protection rules attach to branch names. Asking GitHub
  # whether a sha is protected is not a question it has an answer to.
  local prot_branch=""
  __git_state
  if [[ "$head" == '(detached)' ]]; then
    # Mid-rebase, the branch being rewritten is the useful name, and it is
    # what git-prompt.sh shows; otherwise the sha.
    head="${__git_op_head:-${oid:0:7}}"
  else
    prot_branch="$head"
  fi

  # Right side, one variable per segment, each with its visible width.
  # Built separately rather than concatenated as it goes, because the
  # fitting pass below removes individual pieces — appending would mean
  # rebuilding the whole string to drop one. Every emoji here is East
  # Asian Wide: one character, two columns.
  local r_unmerged="" r_staged="" r_unstaged="" r_untracked="" r_sync="" r_conflict="" r_gh=""
  local w_unmerged=0 w_staged=0 w_unstaged=0 w_untracked=0 w_sync=0 w_conflict=0 w_gh=0

  # First on the line and in the conflict colour: these are the files
  # standing between you and finishing the merge or rebase in progress.
  if (( unmerged )); then
    r_unmerged="${__C_CONFLICT}${unmerged} unmerged${__C_OFF}  "
    (( w_unmerged = ${#unmerged} + 11 ))           # " unmerged" + 2 spaces
  fi
  if (( staged )); then
    r_staged="${__C_STAGED}${staged} staged${__C_OFF}  "
    (( w_staged = ${#staged} + 9 ))                # " staged" + 2 spaces
  fi
  # "unstaged", not "modified": porcelain v2's Y column is literally the
  # unstaged state, and the pair reads as one idea next to "N staged"
  # where "modified" invited the question of modified-versus-what.
  if (( unstaged )); then
    r_unstaged="${__C_UNSTAGED}${unstaged} unstaged${__C_OFF}  "
    (( w_unstaged = ${#unstaged} + 11 ))           # " unstaged" + 2 spaces
  fi
  # Counts porcelain ENTRIES, not files. Git's default -unormal collapses
  # an untracked directory into one `?` line, so a new build/ holding 500
  # files reads as 1. That is the more useful number — it counts things
  # you would have to act on, and one .gitignore line covers that
  # directory — but it is not a file count, and nothing here should imply
  # it is. Making it a true file count means -uall, which is the untracked
  # mode that actually costs time on a large tree, spent to buy a number
  # whose only distinct behaviour is being alarming.
  if (( untracked )); then
    r_untracked="${__C_UNTRACKED}${untracked} untracked${__C_OFF}  "
    (( w_untracked = ${#untracked} + 12 ))         # " untracked" + 2 spaces
  fi
  # One segment, not two, because they are one idea and the fitting pass
  # drops them together: 🔼 alone after 🔽 was dropped would read as "you
  # are only ahead", which is a different and wrong statement. Two
  # independent ifs inside it, though, not an if/elif with a third glyph
  # for the both-at-once case — seeing 🔼 and 🔽 together IS the diverged
  # signal, and the counts cannot be read in the wrong order the way a
  # single 🔄2/3 could be.
  if (( ahead )); then
    r_sync="${__I_AHEAD}${ahead}"
    (( w_sync = ${#ahead} + __IW_AHEAD ))
  fi
  if (( behind )); then
    # ONE space between the arrows, where every other gap on this line is
    # two. Two made them read as two separate segments; they are one fact
    # about one relationship, and the tighter gap is what says so.
    [[ -n "$r_sync" ]] && { r_sync+=" "; (( ++w_sync )); }
    r_sync+="${__I_BEHIND}${behind}"
    (( w_sync += ${#behind} + __IW_BEHIND ))
  fi
  # The two-space separator every right-side segment ends with, added once
  # for the pair rather than once per arrow.
  [[ -n "$r_sync" ]] && { r_sync+="  "; (( w_sync += 2 )); }

  # The bracketed slot reports this repo's relationship with its remote.
  # Usually that is CI status; when there is nothing to have a
  # relationship WITH, it says so instead, and there is no point asking
  # GitHub about a repo GitHub has never heard of.
  #
  # Keyed on "no remote configured", NOT on "no upstream". A branch you
  # have created and not yet pushed has no upstream and is completely
  # normal — warning about that would nag on every new branch. No remote
  # at all is the condition worth surfacing: nothing here is backed up.
  #
  # The globe/lock and shield are gated on the same condition, and not
  # only to save the calls: a repo with no remote has no GitHub
  # visibility to report and no rules that could apply to it, so the
  # honest rendering of both is nothing at all.
  __repo_pre=""
  __repo_post=""
  __repo_pre_w=0
  __repo_post_w=0
  if [[ -z "$upstream" ]] && ! __repo_has_remote; then
    r_gh="${__C_WARN}[no origin]${__C_OFF}"
    (( w_gh = 11 ))
  else
    # Read once and handed to every segment, so they agree on what "now" is.
    local now="$EPOCHSECONDS"

    __repo_meta_segment "$prot_branch" "$now"

    # Only when diverged. Behind-alone fast-forwards and cannot conflict,
    # so this never starts outside the state the two arrows already show.
    if (( ahead && behind )); then
      __merge_segment "$upstream" "$oid" "$ahead" "$behind" "$now"
      r_conflict="$__merge_out"
      (( w_conflict = __merge_w ))
    fi

    __gh_segment "$oid" "$prot_branch" "$now"
    r_gh="$__gh_out"
    (( w_gh = __gh_w ))
  fi

  # ─── Fitting ────────────────────────────────────────────────────────
  #
  # Everything above built the widest prompt this directory could want.
  # The right side is drawn first at column (cols - w) and PS1 is then
  # drawn over it from column 0, so anything the left side reaches, it
  # destroys. The old guard only asked whether the right side fit the
  # TERMINAL; it never knew the left side existed, so a busy repo in a
  # 95-column window overwrote its own status line.
  #
  # $COLUMNS is maintained by bash itself (`shopt -s checkwinsize`,
  # which bash 5 defaults on), which is why this does not
  # shell out to `tput cols`. It updates on resize, so the NEXT prompt
  # after dragging the window narrower is already fitted — the one on
  # screen is not redrawn, because readline only repaints its last line.
  local cols="${COLUMNS:-80}"

  # The left side's own text is never shortened. Losing a character of
  # the path, the machine name or the conda env to make room for a status
  # glyph is a bad trade — those are how you know WHERE you are.
  #
  # Measured by having bash expand the very escapes PS1 uses: ${x@P} is
  # prompt expansion as a parameter operator, so no fork. Re-deriving them
  # by hand was close but not equal — it turned /home/you2 into ~2, which
  # \w does not, read $USER where \u asks the password database, and knew
  # nothing of PROMPT_DIRTRIM. (Wide CJK characters in a path still count
  # as one column each; bash has no way to ask.)
  local ltext='\u@\h \w' lw
  ltext="${ltext@P}"
  (( lw = ${#ltext} ))
  [[ -n "$CONDA_DEFAULT_ENV" ]] && (( lw += ${#CONDA_DEFAULT_ENV} + 3 ))

  # The branch and its two decorations sit on the left as well, and are
  # the only part of it that may go. An operation in progress is part of
  # the branch — `main|MERGING` — and goes with it, never before it.
  local r_vis="$__repo_pre" w_vis=$__repo_pre_w
  local r_shield="$__repo_post" w_shield=$__repo_post_w
  local r_branch="$head" w_branch=0
  [[ -n "$head" ]] && (( w_branch = ${#head} + 1 ))
  [[ -n "$__git_op" ]] && (( w_branch += ${#__git_op} + 1 ))

  # Least useful goes first. The order is deliberate and runs roughly
  # "housekeeping before warnings, warnings before identity". Dirty-state
  # counts go first — `git status` answers those on demand. Then
  # ahead/behind. Then CI, which is a fact about a commit you already
  # pushed. Then repo visibility, which is stable context you rarely need
  # reminding of. `N conflicting` outlives all of them because it is the
  # only one warning about damage you are about to do, and `N unmerged`
  # outlives that because it is damage already done. 🛡️ outlives both
  # because committing to a protected branch is a mistake you make BEFORE
  # you read a status line. The branch name is last: it is the single
  # most useful thing here, and a prompt that has lost everything else is
  # still worth having with it.
  #
  # Dropping a piece empties its r_ AND zeroes its w_, so the widths are
  # the one record of what is left and every sum below is taken from them.
  # Tracking a running total beside them is how the right side once went
  # undrawn: the total said it fit, the widths still counted the dropped
  # globe, and the final check believed the widths.
  local seg n
  local total=$(( lw + w_vis + w_branch + w_shield + w_unmerged + w_staged
                  + w_unstaged + w_untracked + w_sync + w_conflict + w_gh ))
  if (( total >= cols )); then
    for seg in untracked unstaged staged sync gh vis conflict unmerged shield branch; do
      n="w_$seg"
      (( total -= ${!n} ))
      printf -v "r_$seg" ''
      printf -v "w_$seg" 0
      (( total < cols )) && break
    done
  fi
  local w=$(( w_unmerged + w_staged + w_unstaged + w_untracked + w_sync + w_conflict + w_gh ))

  # Assembled here rather than where the branch was parsed, because
  # neither the decorations nor the fitting are known until now. The
  # emoji are deliberately OUTSIDE the \001..\002 colour markers: they
  # are visible characters and readline has to count them, where the
  # colour bytes are invisible and it must not.
  if [[ -n "$r_branch" ]]; then
    local op=""
    [[ -n "$__git_op" ]] && op="${__NP_ON}${__C_WARN}${__NP_OFF}|${__git_op}${__NP_ON}${__C_OFF}${__NP_OFF}"
    __PS1_GIT=" ${r_vis}${__NP_ON}${__C_BRANCH}${__NP_OFF}${r_branch}${__NP_ON}${__C_OFF}${__NP_OFF}${op}${r_shield}"
  fi

  if (( w > 0 && lw + w_vis + w_branch + w_shield + w < cols )); then
    printf '\033[%dG%s\r' $(( cols - w )) \
      "${r_unmerged}${r_staged}${r_unstaged}${r_untracked}${r_sync}${r_conflict}${r_gh}"
  fi
  return 0
}

# PS1: left side + second line
# Branch is on the left after the path. White dollar sign.
#
# Single-quoted, so ${__PS1_CONDA} and ${__PS1_GIT} are expanded at prompt
# time rather than right now. That is safe against hostile branch names:
# bash does not re-expand the result of a parameter expansion, so a branch
# called `$(rm -rf ~)` renders as those literal characters.
#
# The colours come in through variables too, inside \[ \]: bash decodes the
# \[ \] escapes first and expands variables after, so the colour bytes land
# between the zero-width markers where readline expects them.
PS1='${__PS1_CONDA}\[${__C_HOST}\]\u@\h\[${__C_OFF}\] \[${__C_PATH}\]\w\[${__C_OFF}\]${__PS1_GIT}\n\$ '

# Prepend, do not assign. Other tools hook PROMPT_COMMAND too -- `zoxide
# init bash` adds __zoxide_hook, the only thing that teaches `z` where you
# have been -- and a plain `PROMPT_COMMAND=` would throw theirs away with no
# error, in whichever order the two were sourced. The guard (zoxide's own
# pattern) keeps re-sourcing this file into a live shell idempotent.
case ";${PROMPT_COMMAND};" in
  *";__prompt_render;"*) : ;;
  *) PROMPT_COMMAND="__prompt_render${PROMPT_COMMAND:+;${PROMPT_COMMAND}}" ;;
esac
