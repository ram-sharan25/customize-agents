#!/bin/sh
# Open an exploration child session in a new window of the CURRENT tmux session.
#
#   open-window.sh --agent claude|pi --slug SLUG --dir OUTDIR
#                  [--cwd DIR] [--fork] [--session-file FILE] [--no-focus]
#                  [--name WINDOW-NAME] [--env KEY=VALUE]... [--dry-run]
#
#   --dir           the exploration directory; OUTDIR/brief.md must exist and
#                   becomes the child's first prompt
#   --cwd           the child's working directory (default: this directory)
#   --fork          full-context child instead of a fresh one:
#                     claude: claude --resume $CLAUDE_CODE_SESSION_ID --fork-session
#                     pi:     pi --session FILE  (FILE from --session-file, a
#                             branch copy the pi extension wrote)
#   --no-focus      leave the current window selected (tmux new-window -d)
#   --env           extra variables for the child (repeatable)
#   --dry-run       print the command and environment; open nothing
#
# A thin wrapper over the workflow's core launcher,
# emacs/agent-sessions/bin/agent-launch, which holds the tmux, environment and
# Emacs plumbing (and the facts it relies on).  This script only adds what is
# particular to an exploration: brief.md as the first prompt, the
# `explore-SLUG' window name, the `explore: SLUG' dashboard title, and the
# refusal outside tmux (an exploration always shares its parent's tmux
# session).

set -eu

die() { printf 'open-window: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() { sed -n '2,17p' "$0" | sed -e 's/^# \{0,1\}//' >&2; }

# The skill directory is linked into each harness; resolve the real one.
here=$(cd -- "$(dirname -- "$0")" && pwd -P)
launch="$here/../../../emacs/agent-sessions/bin/agent-launch"
[ -x "$launch" ] || die "core launcher not found: $launch"

agent=""; slug=""; dir=""; cwd=""; rest=""
# Options other than these four pass through to agent-launch unchanged.
while [ $# -gt 0 ]; do
  case "$1" in
    --agent) agent=${2:-}; shift 2 ;;
    --slug) slug=${2:-}; shift 2 ;;
    --dir) dir=${2:-}; shift 2 ;;
    --cwd) cwd=${2:-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --fork|--no-focus|--focus|--dry-run) rest="$rest $1"; shift ;;
    --session-file|--name|--env)
      [ $# -ge 2 ] || die "$1 needs a value" 2
      rest="$rest $1 $(printf '%s' "$2" | sed "s/'/'\\\\''/g; s/^/'/; s/\$/'/")"; shift 2 ;;
    *) die "unknown option: $1" 2 ;;
  esac
done
[ -n "$agent" ] || { usage; die "--agent is required" 2; }
[ -n "$slug" ] || { usage; die "--slug is required" 2; }
[ -n "$dir" ] || { usage; die "--dir is required" 2; }
[ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] ||
  die "not inside tmux (no \$TMUX/\$TMUX_PANE); nothing opened" 2
dir=$(cd -- "$dir" 2>/dev/null && pwd -P) || die "no such directory: $dir"
[ -s "$dir/brief.md" ] || die "brief not found or empty: $dir/brief.md (write it first)"

[ -n "$cwd" ] || cwd=$(pwd -P)

eval "set -- $rest"
exec "$launch" --child --agent "$agent" --slug "$slug" --dir "$dir" --cwd "$cwd" \
  --prompt-file "$dir/brief.md" --name "explore-$slug" \
  --title "explore: $slug" --attach-label "exploration brief" "$@"
