# herdr-send-to-machine

Send the repository you are looking at — branch, uncommitted edits, untracked
files and the running coding-agent session — to another machine, and open a pane
on it there.

One keypress on the laptop, and the work is on the always-on box with an agent
resuming mid-conversation.

```
ctrl+shift+m

  Send to tron

    repo     /Users/you/Workspace/personal/dotfiles
    branch   feat/thing
    changes  2 uncommitted file(s)
    to       tron:/Users/you/Workspace/personal/dotfiles
    session  claude a3448847-2404-42e9-b065-e834106ae6ec

  [enter] send   [n] send without the agent session   [q] cancel
```

## Install

```bash
herdr plugin install LeandroMAcosta/herdr-send-to-machine
```

Then bind a key in `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = ["ctrl+shift+m", "prefix+m"]
type = "plugin_action"
command = "leandroacosta.send-to-machine.send"
description = "send work to machine"
```

`ctrl+shift+m` needs a terminal that speaks the CSI-u / Kitty keyboard protocol
(Ghostty does by default; iTerm2 needs *Report modifiers using CSI u* in the
profile's Keys tab). The `prefix+m` binding beside it always works.

Without a keybinding the action is still reachable from herdr's menus as
**Send work to remote machine**.

## Requirements

- herdr **0.9.0 or newer** on both machines — saved SSH machines and
  `herdr machine list --json` arrived in 0.9.0.
- At least one destination added with `herdr machine add <ssh-target> --label <name>`.
- Ordinary SSH access to that machine. `ssh <target>` must work non-interactively;
  the plugin uses `BatchMode=yes` and will not prompt for a password.
- `git` on both sides, and `python3` locally for JSON parsing.

Tested on macOS. It is plain POSIX `sh` and should work on Linux, but I have not
run it there.

## What it does

No machine is configured anywhere in this plugin. `herdr machine list` already
stores the SSH target and the remote session for each machine you added, so that
list *is* the configuration.

On `ctrl+shift+m`:

1. Reads the focused pane's working directory from the invocation context and
   opens a popup.
2. Lists your enabled machines. One machine, no picker; several, `fzf`.
3. Shows what it is about to do and waits for confirmation.
4. Pushes the branch to the destination over SSH, into `refs/herdr-send/<branch>`.
5. Applies uncommitted tracked changes as a patch, and copies untracked files.
6. Copies the newest Claude Code transcript for that repository.
7. Creates a workspace there and starts `claude --resume <uuid>` in it.

Selecting the machine in the sidebar stays manual — that is a client action with
no API behind it — so the plugin ends with a notification instead.

## Things worth knowing before you use it

**Your work on the destination is stashed, not lost.** Step 4 ends in a forced
checkout. Anything uncommitted already sitting on the other machine is put into a
`herdr-send <timestamp>` stash first; `git stash list` over there gets it back.

**Nothing goes through GitHub.** The push targets `ssh://<target><path>` over the
same SSH connection you already have, into a private ref namespace so git never
refuses a push to a branch checked out on the other side. The destination needs
no GitHub credential, and this works on repositories with no remote at all.

**Paths mirror relative to `$HOME`.** `~/Workspace/x` here becomes `~/Workspace/x`
there, resolved against the *remote* home, so the two users and home directories
need not match. A repository outside `$HOME` lands in `~/herdr-inbox/<repo>`.

**The agent session is a file.** Claude Code transcripts live at
`~/.claude/projects/<cwd with slashes as dashes>/<uuid>.jsonl`. The newest one
for the repository is copied to the slug for the remote path, which is what makes
`--resume` work across machines. Press `n` at the prompt to send the code without
it.

**It only sends.** There is no reverse direction yet, and a patch that does not
apply cleanly is reported and left alone rather than merged.

## Development

```bash
git clone git@github.com:LeandroMAcosta/herdr-send-to-machine.git
herdr plugin link ./herdr-send-to-machine
```

A linked plugin picks up file edits with no relink, so the loop is edit and press
the key. `herdr plugin log list --plugin leandroacosta.send-to-machine` shows what
the action did and how it exited.

Installing over a locally linked plugin is refused — `herdr plugin unlink
leandroacosta.send-to-machine` first.

## License

MIT. See [LICENSE](LICENSE).
