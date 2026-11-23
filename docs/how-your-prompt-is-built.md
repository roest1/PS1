# How your prompt is built

Every time you press Enter, bash builds your prompt from a handful of variables, set by a
handful of files. This page explains that mechanism and where each piece comes from, and
mostly points you at the real files, because reading them is the best way to learn it.

The mechanism (sections 1 and 2) is bash's own and works the same on any Unix-like system:
Linux, the BSDs, macOS with a current bash. Which files set what (section 3) is a
convention, and conventions vary by distribution. Fedora/RHEL and Debian/Ubuntu are shown
here, checked on Fedora 44, Debian stable and Ubuntu 24.04. Section 6 shows how to find
the same things on any machine.

## 1. What bash does on every Enter

1. **It runs `PROMPT_COMMAND`.** That's a string of commands, or since bash 5.1 an
   array of them. Tools hook in here: a window title, the terminal's idea of your
   directory, this prompt.
2. **It expands `PS1`**, in two passes:
   - First, the backslash escapes: `\u` user, `\h` host, `\w` directory, `\$` (`#` for
     root, `$` otherwise), and `\[ … \]`.
   - Then, because the `promptvars` option is on by default, the normal shell expansions:
     `$variables`, `$(commands)`, `$((arithmetic))`.
3. **readline draws the result** and puts your cursor after it.

`\[` and `\]` tell readline "the bytes between these take up no space on screen". Colors
are escape sequences that take up no columns, so they must be wrapped. If they aren't,
readline miscounts where the cursor is, and long command lines wrap in the wrong place.

There are siblings: `PS2` is the `> ` you see when a command continues onto the next
line, `PS0` is printed after you press Enter but before the command runs, and `PS4`
prefixes `set -x` traces.

The authority is `man bash`, sections **PROMPTING** and **INVOCATION**. To see your
current setup:

```sh
declare -p PS1 PROMPT_COMMAND   # the raw template, and what runs before it
echo "${PS1@P}"                 # the template expanded, as bash would draw it
```

## 2. Which files bash reads when it starts

From `man bash`, INVOCATION:

| Shell | Typical case | Reads |
|---|---|---|
| login | a text console, `ssh`, `bash -l` | `/etc/profile`, then the first of `~/.bash_profile`, `~/.bash_login`, `~/.profile` that exists |
| interactive, not login | a new terminal tab on most desktops | `~/.bashrc`, plus a system-wide file **if your distribution built bash with one** |

Two conventions sit on top of that:

- **`/etc/profile.d/*.sh`** holds small snippets that packages drop in. `/etc/profile`
  runs them on every distribution here.
- **`/etc/skel/`** is copied into a new account's home directory, which is where your
  `~/.bashrc` came from. Your copy is yours to change; the distribution's defaults live
  in `/etc/skel/.bashrc`.

## 3. Where distributions set the prompt

**Debian and Ubuntu.** bash is built to read **`/etc/bash.bashrc`** by itself. That file
sets a plain `PS1`, and its `PROMPT_COMMAND` line is commented out. The colored
`user@host:path$` you normally see comes from your `~/.bashrc`, copied from
`/etc/skel/.bashrc`. It also sets the window title inside `PS1` itself, with a
`\[\e]0;…\a\]` sequence.

**Fedora and RHEL.** bash reads **no** system file by itself. With no `~/.bashrc` you get
bash's bare built-in `bash-5.3$`. The default `~/.bashrc` sources **`/etc/bashrc`**,
which sets a fallback `PS1`, puts a window title in `PROMPT_COMMAND`, and runs
`/etc/profile.d/*.sh` itself for non-login shells. On Fedora 44 the pieces that end up in
your prompt are:

| Piece | Comes from | What it does |
|---|---|---|
| the green `PS1` | `/etc/profile.d/bash-color-prompt.sh` (package `bash-color-prompt`) | builds `PS1` from `PROMPT_*` variables you can set to restyle it; read the file for the list |
| window title | `/etc/bashrc` | a `printf` of an `ESC ] 0;` sequence in `PROMPT_COMMAND` |
| `__systemd_osc_context_precmdline` | `/etc/profile.d/80-systemd-osc-context.sh` (package `systemd`) | tells the terminal where each command starts and ends, and whether it succeeded, with `ESC ] 3008` sequences |
| current directory reporting | `/etc/profile.d/vte.sh` | only in VTE terminals (GNOME Terminal, Ptyxis): reports your directory so new tabs open there |
| a prefix or suffix on `PS1` | `/etc/profile.d/70-systemd-shell-extra.sh` (package `systemd`) | wraps `PS1` in `$SHELL_PROMPT_PREFIX` / `$SHELL_PROMPT_SUFFIX` when systemd hands you a shell with those set, so you can tell which machine or session you're in |
| the `⬢` marker | `/etc/profile.d/toolbox.sh` | only inside a Toolbox container: marks the prompt so you know you're not on the host |

Two things worth noticing in that systemd hook:

- **It reads `$?`**, the last command's exit status. So any hook that runs before it in
  `PROMPT_COMMAND` must leave `$?` alone, or your terminal is told every command
  succeeded. `ps1.bash` runs first, and keeps `$?` for exactly this reason.
- **It costs about 1 ms per Enter**, because it runs a `$( … )` every time, and a
  subshell is a process. That is most of what Fedora's stock prompt costs.

## 4. Git's own prompt

git ships a prompt helper, `git-prompt.sh`, which defines `__git_ps1`:

| Distribution | File |
|---|---|
| Fedora/RHEL | `/usr/share/git-core/contrib/completion/git-prompt.sh` |
| Debian/Ubuntu | `/usr/lib/git-core/git-sh-prompt`, loaded by `/etc/bash_completion.d/git-prompt` |

Its options are the `GIT_PS1_*` variables documented at the top of the file, such as
`GIT_PS1_SHOWDIRTYSTATE` and `GIT_PS1_SHOWUNTRACKEDFILES`. Each option it turns on is
another `git` process per prompt. In this repo, on the laptop the README's numbers come
from, it took 4.4 ms showing only the branch and 17.8 ms with dirty state, untracked files
and upstream turned on.

Its operation words (`|MERGING`, `|REBASE 2/5`, …) are the ones `ps1.bash` copies, so the
two read the same.

## 5. How ps1.bash fits in

- You source it from `~/.bashrc`, so it runs in every interactive shell, after the
  system files above.
- It **prepends** `__prompt_render` to `PROMPT_COMMAND` and keeps everything already
  there, such as systemd's hook, zoxide's or your own.
- `__prompt_render` runs one `git status --porcelain=v2 --branch`. From that single
  output it fills variables (`__PS1_GIT`, `__PS1_CONDA`) that `PS1` reads. `PS1` itself
  contains no `$( … )`, because each one would start a process on every Enter.
- Anything slow (GitHub, predicting a merge) is answered from a cache that a background
  job refreshes, so Enter never waits on the network.

Where its time goes, and why, is in the README's **How it stays fast**. `time-prompt.sh`
measures it in whatever directory you run it from. The short version:

- Starting any `git` costs about 1.6 ms before it does any work.
- Each submodule costs one more `git`.
- After tools touch files without changing them, `git status` re-reads their contents
  until a git command saves a refreshed index. Running `git status` once does that.

## 6. Finding all this on your own machine

```sh
# Every startup file that mentions the prompt
grep -ls 'PS1\|PROMPT_COMMAND' /etc/profile /etc/bash.bashrc /etc/bashrc \
  /etc/profile.d/*.sh ~/.bashrc ~/.bash_profile ~/.profile 2>/dev/null

# Which package a file belongs to
rpm -qf /etc/profile.d/bash-color-prompt.sh      # Fedora/RHEL
dpkg -S /etc/bash.bashrc                         # Debian/Ubuntu

# Watch bash start, line by line: every file it reads, in order
bash -x -i -c exit 2>&1 | less

# Where a prompt function was defined
shopt -s extdebug; declare -F __git_ps1; shopt -u extdebug
```

`bash -x -i -c exit` is the most instructive of these. It starts an interactive shell,
prints every line of every startup file as it runs, and exits.
