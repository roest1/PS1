# ps1

A bash prompt that knows about git and GitHub, in one file, with no framework or plugin
manager. It costs one process per prompt.

| Before | After |
|---|---|
| ![Fedora's default bash prompt](images/before.png) | ![The same terminal with ps1](images/after.png) |

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/roest1/ps1/main/ps1.bash -o ~/.bash_prompt
echo '[ -f ~/.bash_prompt ] && source ~/.bash_prompt' >> ~/.bashrc
exec bash
```

To keep up with changes, clone the repo and source `ps1.bash` from the clone instead.

## What it shows

```
user@host ~/path 🌍 main 🛡️                    2 staged  1 unstaged  2 untracked  🔼2 [11/11 ✅ 22h]
$
```

| | |
|---|---|
| 🌍 / 🔒 | repo is public / private |
| 🛡️ | branch has protection rules |
| `2 staged  1 unstaged  2 untracked` | working tree |
| 🔼2&nbsp;🔽3 | commits to push / to pull; both at once means diverged |
| `2 conflicting` | that pull would conflict, in 2 files |
| `[11/11 ✅ 22h]` | GitHub Actions for this commit, last run 22h ago |
| `(base)` | active conda env |

When the window is too narrow, the right side drops segments in priority order rather
than overwrite the left.

## Requirements

Bash 5 and `git`. `gh` (logged in) and `jq` add the Actions status and the 🌍/🔒/🛡️
markers; `export GH_PROMPT=0` before sourcing turns those off. Every tool is behind a
`command -v` guard, so a missing one drops its segment instead of breaking the prompt.

## How it stays fast

Anything that needs the network or a real merge is read from a cache that a detached job
refreshes, so pressing Enter never waits on GitHub. Inside a repo, one
`git status --porcelain=v2 --branch` answers everything else; outside one, nothing forks.
The caches live in `$XDG_RUNTIME_DIR/ps1` (or `~/.cache/ps1`), private to you.
The comments in [`ps1.bash`](ps1.bash) explain each choice.

## License

MIT.
