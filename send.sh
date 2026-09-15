#!/bin/sh
# Send the repository in front of you to a saved herdr machine and continue there.
#
# Two modes. `open` is the plugin action: it runs on the focused pane, reads the
# repository out of the invocation context, and relaunches this script in a
# popup, because the machine picker and the confirmation both need a terminal.
# `run` is that popup, and does the work.
#
# Every remote step goes through ssh. Herdr servers are per-machine - workspace,
# tab and pane ids are scoped to one server and a local socket cannot create a
# pane on another host - so the only way to open something over there is to run
# that machine's own herdr CLI against its own session. `herdr machine list`
# supplies both the ssh target and the session name, which is why this plugin
# holds no machine configuration of its own.

set -eu

herdr_bin="${HERDR_BIN_PATH:-herdr}"

# Popup panes vanish the moment their command exits, so anything worth reading
# has to hold the pane open first.
finish() {
  if [ -n "${1:-}" ]; then printf '\n%s\n' "$1"; fi
  printf '\nPress enter to close.\n'
  read -r _ 2>/dev/null || true
  exit "${2:-0}"
}

ctx_field() {
  json="${HERDR_PLUGIN_CONTEXT_JSON:-}"
  [ -n "$json" ] || json='{}'
  printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1]) or "")' "$1"
}

# Paths travel inside single-quoted remote command strings. A path containing a
# single quote would break out of that quoting, so refuse it rather than build a
# command that means something other than it reads.
assert_quotable() {
  case "$1" in
    *"'"*) finish "Path contains a single quote, refusing: $1" 1 ;;
  esac
}

# ---------------------------------------------------------------- open mode

if [ "${1:-run}" = open ]; then
  cwd="$(ctx_field focused_pane_cwd)"
  [ -n "$cwd" ] || cwd="$(ctx_field workspace_cwd)"
  [ -n "$cwd" ] || cwd="$PWD"
  exec "$herdr_bin" plugin pane open \
    --plugin "${HERDR_PLUGIN_ID:-leandro.send-to-machine}" \
    --entrypoint picker \
    --env "SEND_CWD=$cwd" \
    --env "SEND_AGENT=$(ctx_field focused_pane_agent)"
fi

# ---------------------------------------------------------------- run mode

cwd="${SEND_CWD:-$PWD}"

repo="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$repo" ] || finish "Not a git repository: $cwd" 1
assert_quotable "$repo"

branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD)"
[ "$branch" != HEAD ] || finish "HEAD is detached. Check out a branch first." 1

# --- pick the machine ------------------------------------------------------
# Only `enabled` filters the list. `selected` looks like the obvious second
# filter and is not: it merely marks the machine the sidebar is showing, and it
# flips on its own, so filtering it empties the picker exactly when you are
# looking at the machine you want to send to.

machines="$("$herdr_bin" machine list --json 2>/dev/null | python3 -c '
import json, sys
for m in json.load(sys.stdin):
    if m.get("enabled"):
        print("\t".join([m["label"], m["target"], m.get("session") or "default"]))
' || true)"

[ -n "$machines" ] || finish "No other machine saved. Add one with: herdr machine add <ssh-target> --label <name>" 1

count="$(printf '%s\n' "$machines" | wc -l | tr -d ' ')"
if [ "$count" = 1 ]; then
  chosen="$machines"
elif command -v fzf >/dev/null 2>&1; then
  chosen="$(printf '%s\n' "$machines" | fzf --prompt='send to> ' --with-nth=1 --delimiter='\t' || true)"
  [ -n "$chosen" ] || exit 0
else
  printf 'Machines:\n'
  printf '%s\n' "$machines" | nl -w2 -s') ' | cut -f1
  printf 'Number: '
  read -r pick || exit 0
  chosen="$(printf '%s\n' "$machines" | sed -n "${pick}p")"
  [ -n "$chosen" ] || finish "No such machine." 1
fi

label="$(printf '%s' "$chosen" | cut -f1)"
target="$(printf '%s' "$chosen" | cut -f2)"
session="$(printf '%s' "$chosen" | cut -f3)"

# ssh reads standard input greedily, and this script is a terminal prompt as
# much as it is a transfer: without -n the first remote call would swallow the
# confirmation keypress before it is ever asked for. Commands that genuinely
# pipe data in use rsh_stdin instead.
rsh() { ssh -n -o BatchMode=yes "$target" "$@"; }
rsh_stdin() { ssh -o BatchMode=yes "$target" "$@"; }

# --- where it lands --------------------------------------------------------
# Mirror the path relative to home rather than absolutely: the remote user and
# home directory may differ, and the same relative path keeps every repository
# in the same place on both machines. Repositories outside home have no such
# natural home, so they get a dedicated inbox.

case "$repo" in
  "$HOME"/*) rel="${repo#"$HOME"/}" ;;
  *)         rel="herdr-inbox/$(basename "$repo")" ;;
esac

remote_home="$(rsh 'printf %s "$HOME"' 2>/dev/null || true)"
[ -n "$remote_home" ] || finish "Cannot reach $label over ssh ($target)." 1
remote_path="$remote_home/$rel"
assert_quotable "$remote_path"

# --- the agent session it carries ------------------------------------------
# Claude Code transcripts are plain files under ~/.claude/projects/<slug>, where
# the slug is the working directory with every slash turned into a dash. Copying
# the newest one across and resuming it by id is what makes the work continue
# rather than restart. The slug is computed from each side's own path, because
# the two homes need not match.

transcript=''
uuid=''
if [ "${SEND_AGENT:-}" = claude ]; then
  slug="$(printf '%s' "$repo" | tr '/' '-')"
  transcript="$(ls -t "$HOME/.claude/projects/$slug"/*.jsonl 2>/dev/null | head -1 || true)"
  if [ -n "$transcript" ]; then uuid="$(basename "$transcript" .jsonl)"; fi
fi

# --- confirm ---------------------------------------------------------------

dirty="$(git -C "$repo" status --porcelain | wc -l | tr -d ' ')"

printf 'Send to %s\n\n' "$label"
printf '  repo     %s\n' "$repo"
printf '  branch   %s\n' "$branch"
printf '  changes  %s uncommitted file(s)\n' "$dirty"
printf '  to       %s:%s\n' "$target" "$remote_path"
if [ -n "$uuid" ]; then
  printf '  session  claude %s\n' "$uuid"
else
  printf '  session  none, a fresh agent starts there\n'
fi
printf '\n[enter] send   [n] send without the agent session   [q] cancel: '
read -r answer || exit 0
case "$answer" in
  q|Q) exit 0 ;;
  n|N) transcript=''; uuid='' ;;
esac

# --- move the code ---------------------------------------------------------
# Pushed into refs/herdr-send/ rather than straight onto the branch: pushing to
# a branch that is checked out on the other side is refused by git, and the
# namespace sidesteps that without weakening receive.denyCurrentBranch there.

printf '\n==> preparing %s\n' "$remote_path"
rsh "mkdir -p '$remote_path' && cd '$remote_path' && { git rev-parse --git-dir >/dev/null 2>&1 || git init -q; }" \
  || finish "Could not prepare the remote repository." 1

printf '==> pushing %s\n' "$branch"
git -C "$repo" push --force --quiet "ssh://$target$remote_path" "HEAD:refs/herdr-send/$branch" \
  || finish "Push failed." 1

# Work already sitting on the other machine is stashed, never discarded. The
# checkout below is forced, so without this a send would silently overwrite
# whatever you had left running over there.
printf '==> checking out %s there\n' "$branch"
rsh "cd '$remote_path' && \
  if [ -n \"\$(git status --porcelain 2>/dev/null)\" ]; then \
    git stash push -u -q -m \"herdr-send \$(date -u +%Y-%m-%dT%H:%M:%SZ)\" || exit 1; \
    echo '    (existing changes stashed there: git stash list)'; \
  fi; \
  git checkout -q -f -B '$branch' 'refs/herdr-send/$branch'" \
  || finish "Remote checkout failed." 1

# --- move the work in progress ---------------------------------------------

if [ "$dirty" != 0 ]; then
  printf '==> applying uncommitted changes\n'
  if ! git -C "$repo" diff HEAD --binary | rsh_stdin "cd '$remote_path' && git apply --whitespace=nowarn -"; then
    printf '    tracked changes did not apply cleanly; they are not on %s\n' "$label"
  fi
  # Untracked files are carried separately: a diff against HEAD does not see
  # them, and a new file the agent just wrote is exactly the kind of context
  # this is for.
  if [ -n "$(cd "$repo" && git ls-files -o --exclude-standard | head -1)" ]; then
    ( cd "$repo" && git ls-files -o --exclude-standard -z | tar --null -T - -czf - ) \
      | rsh_stdin "cd '$remote_path' && tar -xzf -" \
      || printf '    untracked files did not copy\n'
  fi
fi

# --- move the agent session ------------------------------------------------

start_cmd='claude'
if [ -n "$transcript" ]; then
  printf '==> copying agent session\n'
  remote_slug="$(printf '%s' "$remote_path" | tr '/' '-')"
  if rsh "mkdir -p '$remote_home/.claude/projects/$remote_slug'" \
     && scp -q "$transcript" "$target:$remote_home/.claude/projects/$remote_slug/"; then
    start_cmd="claude --resume $uuid"
  else
    printf '    session did not copy; a fresh agent will start there\n'
  fi
fi

# --- open it there ---------------------------------------------------------

printf '==> opening a workspace on %s\n' "$label"
created="$(rsh "HERDR_SESSION='$session' herdr workspace create --cwd '$remote_path' --label '$(basename "$repo"):$branch' --no-focus" || true)"
pane="$(printf '%s' "$created" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin)["result"]["root_pane"]["pane_id"])
except Exception:
    print("")
' 2>/dev/null || true)"
[ -n "$pane" ] || finish "Work is on $label at $remote_path, but the workspace could not be created there." 1

rsh "HERDR_SESSION='$session' herdr pane run '$pane' '$start_cmd'" >/dev/null 2>&1 \
  || printf '    pane opened but the agent did not start\n'

# Selecting a machine is a client action with no API behind it, so the last step
# stays manual and the notification is what points at it.
"$herdr_bin" notification show "Sent to $label" \
  --body "$(basename "$repo"):$branch is running on $label. Select $label in the sidebar." \
  --sound done >/dev/null 2>&1 || true

finish "Done. Select $label in the sidebar to continue there."
