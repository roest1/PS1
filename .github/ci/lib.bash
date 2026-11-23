# Sourced by the steps in ../workflows/ci.yml, and by perf.bash. Steps
# cannot share shell functions, so they share this file instead.

# strip
# Removes colours, cursor moves and readline's zero-width markers from
# what it is piped.
strip() { sed 's/\x1b\[[0-9;]*[mG]//g; s/[\x01\x02\r]//g'; }

# settle
# Waits until no background refresh is running under $XDG_RUNTIME_DIR, and
# fails the step if one never finishes. ps1.bash writes the marker this
# looks for before it starts the refresh, so there is no gap to miss one in.
settle() {
  local i
  for (( i = 0; i < 100; i++ )); do
    [ -n "$(find "$XDG_RUNTIME_DIR" -name '*.pending' 2>/dev/null)" ] || return 0
    sleep 0.05
  done
  echo "a background refresh never finished" >&2
  exit 1
}

# render [setup]
# Draws one prompt the way bash would, in a clean shell: sources ps1.bash,
# runs <setup> (stubs, settings), then __prompt_render. Prints the right
# side, a newline, and LEFT=<the git part of PS1>, with colours and
# readline's zero-width markers stripped. COLUMNS defaults to 200.
render() {
  COLUMNS="${COLUMNS:-200}" bash --norc --noprofile -c "
    source '$GITHUB_WORKSPACE/ps1.bash'
    ${1:-}
    __prompt_render; printf '\nLEFT=%s\n' \"\$__PS1_GIT\"" 2>&1 | strip
}

# want <text>
# Fails the step unless $out contains <text>, showing what it did contain
# and, when a stub gh is in play, every call it was given.
# shellcheck disable=SC2154  # $out is the calling step's
want() {
  grep -qF -- "$1" <<<"$out" && return
  echo "$out"; echo "missing: $1"
  if [ -n "${GHLOG:-}" ]; then echo "gh calls:"; cat "$GHLOG"; fi
  exit 1
}
