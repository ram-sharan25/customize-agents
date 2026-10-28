#!/bin/sh
# Open an exploration child session in a new window of the CURRENT tmux session.
#
#   open-window.sh --agent claude|pi --slug SLUG --dir OUTDIR
#                  [--cwd DIR] [--fork] [--session-file FILE] [--no-focus]
#                  [--name WINDOW-NAME] [--env KEY=VALUE]...
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
#
# Shared plumbing for every agent; nothing here talks to an agent's API.
# Facts this relies on (verified 2026-10-28, tmux 3.7c):
#   * `tmux display-message` without -t reports the attached CLIENT's active
#     pane, not the caller's, so the caller is identified through $TMUX_PANE.
#   * New windows inherit the tmux server's environment, not the caller's, so
#     identity reaches the child through `env K=V` in the window command, and
#     agent-process markers are unset there in case the server has them
#     (agent-sessions-tmux.el does the same; `new-window -e` cannot unset and
#     tmux replaces a `-e PATH=`).
#   * Outside tmux there is nothing to open a window in: exit 2, do nothing.
#   * When the parent runs in a terminal the Emacs agent-sessions dashboard
#     opened ($EMACS_AGENT_SESSION_ID set), Emacs is asked to open the window
#     (rsr/agent-sessions-explore-spawn), so the child gets a dashboard row of
#     its own, nested under the parent; anything short of success falls back
#     to plain tmux here.  Same command, same environment either way.
#
# Codex is deferred: add a `codex)` case to child_command below when the CLI
# is on PATH (codex fork <id> for --fork; `codex queue` for the notice).

set -eu

die() { printf 'open-window: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() { sed -n '2,17p' "$0" | sed -e 's/^# \{0,1\}//' >&2; }
# Single-quote STRING for a POSIX shell.
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

agent=""; slug=""; dir=""; cwd=""; fork=""; session_file=""; focus=1; name=""
envs=""   # newline-separated KEY=VALUE

while [ $# -gt 0 ]; do
  case "$1" in
    --agent) agent=${2:-}; shift 2 ;;
    --slug) slug=${2:-}; shift 2 ;;
    --dir) dir=${2:-}; shift 2 ;;
    --cwd) cwd=${2:-}; shift 2 ;;
    --fork) fork=1; shift ;;
    --session-file) session_file=${2:-}; shift 2 ;;
    --no-focus) focus=""; shift ;;
    --focus) focus=1; shift ;;
    --name) name=${2:-}; shift 2 ;;
    --env) envs="$envs
${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" 2 ;;
  esac
done

# --- Preconditions ---------------------------------------------------------
[ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] ||
  die "not inside tmux (no \$TMUX/\$TMUX_PANE); nothing opened" 2
command -v tmux >/dev/null 2>&1 || die "tmux not found" 2
[ -n "$agent" ] || { usage; die "--agent is required" 2; }
[ -n "$slug" ] || { usage; die "--slug is required" 2; }
printf '%s' "$slug" | grep -Eq '^[a-z0-9][a-z0-9-]{0,47}$' || die "bad slug: $slug" 2
[ -n "$dir" ] || { usage; die "--dir is required" 2; }
dir=$(cd -- "$dir" 2>/dev/null && pwd -P) || die "no such directory: $dir"
brief="$dir/brief.md"
[ -s "$brief" ] || die "brief not found or empty: $brief (write it first)"
[ -n "$cwd" ] || cwd=$(pwd -P)
cwd=$(cd -- "$cwd" 2>/dev/null && pwd -P) || die "no such cwd: $cwd"
[ -n "$name" ] || name="explore-$slug"
command -v "$agent" >/dev/null 2>&1 || {
  [ "$agent" = codex ] && die "codex is deferred (not on PATH); see SKILL.md" 4
  die "agent command not found on PATH: $agent" 2
}

# --- Who am I (the parent) --------------------------------------------------
self=$(tmux display-message -p -t "$TMUX_PANE" \
  '#{session_name}	#{window_id}	#{window_index}	#{pane_id}') ||
  die "tmux could not describe pane $TMUX_PANE"
session=$(printf '%s' "$self" | cut -f1)
parent_window=$(printf '%s' "$self" | cut -f2)
parent_index=$(printf '%s' "$self" | cut -f3)
parent_pane=$(printf '%s' "$self" | cut -f4)
parent_tmux="$session:$parent_window.$parent_pane"
tmux has-session -t "=$session" 2>/dev/null || die "tmux session '$session' not found"

# --- The child's command ----------------------------------------------------
mode=brief; [ -z "$fork" ] || mode=fork
child_command() {
  case "$agent" in
    claude)
      if [ -n "$fork" ]; then
        [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] ||
          die "--fork for claude needs \$CLAUDE_CODE_SESSION_ID (run from the parent's Bash tool)"
        printf 'claude --resume %s --fork-session -n %s "$(cat %s)"' \
          "$(shq "$CLAUDE_CODE_SESSION_ID")" "$(shq "$name")" "$(shq "$brief")"
      else
        printf 'claude -n %s "$(cat %s)"' "$(shq "$name")" "$(shq "$brief")"
      fi ;;
    pi)
      if [ -n "$fork" ]; then
        [ -n "$session_file" ] && [ -s "$session_file" ] ||
          die "--fork for pi needs --session-file FILE (the branch copy the extension writes)"
        printf 'pi --session %s -n %s "$(cat %s)"' \
          "$(shq "$session_file")" "$(shq "$name")" "$(shq "$brief")"
      else
        printf 'pi -n %s "$(cat %s)"' "$(shq "$name")" "$(shq "$brief")"
      fi ;;
    *) die "unsupported agent: $agent (claude, pi; codex deferred)" 2 ;;
  esac
}
cmd=$(child_command) || exit 1
shell=${SHELL:-/bin/sh}
# Run the agent, then leave a login shell so the window survives the agent.
window_cmd="$cmd; exec $(shq "$shell") -l"

# --- Environment for the child ----------------------------------------------
# Markers that must not leak from a server started inside an agent, plus the
# parent's own identity so nothing stale is inherited.
unset_vars="CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_CHILD_SESSION
CLAUDE_CODE_SESSION_ID CLAUDE_PID CLAUDE_CODE_MESSAGING_SOCKET
CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_CODE_EXECPATH CLAUDE_CODE_SESSION_ATTENDED
CLAUDE_EFFORT AI_AGENT PI_CODING_AGENT_DIR PI_CODING_AGENT PI_SESSION_ID
PI_SESSION_FILE PI_PROVIDER PI_MODEL PI_REASONING_LEVEL
EXPLORE_SLUG EXPLORE_DIR EXPLORE_PARENT_AGENT EXPLORE_PARENT_TMUX
EXPLORE_PARENT_PID EXPLORE_PARENT_SESSION_ID EXPLORE_PARENT_NAME
EXPLORE_PARENT_SOCKET"

# The child's own variables, one KEY=VALUE per line.  Both ways of opening the
# window below inject exactly this list.
child_env="EXPLORE_SLUG=$slug
EXPLORE_DIR=$dir
EXPLORE_PARENT_AGENT=$agent
EXPLORE_PARENT_TMUX=$parent_tmux"
add_env() { child_env="$child_env
$1"; }
case "$agent" in
  claude)
    [ -z "${CLAUDE_PID:-}" ] || add_env "EXPLORE_PARENT_PID=$CLAUDE_PID"
    [ -z "${CLAUDE_CODE_SESSION_ID:-}" ] ||
      add_env "EXPLORE_PARENT_SESSION_ID=$CLAUDE_CODE_SESSION_ID"
    if [ -n "${CLAUDE_PID:-}" ] && pname=$("$(dirname -- "$0")/parent-address.sh" --field name 2>/dev/null); then
      [ -z "$pname" ] || add_env "EXPLORE_PARENT_NAME=$pname"
    fi ;;
esac
# Extra --env entries (the pi extension passes its inbox socket this way).
oldifs=$IFS; IFS='
'
for kv in $envs; do
  [ -n "$kv" ] || continue
  case "$kv" in *=*) add_env "$kv" ;; *) IFS=$oldifs; die "--env needs KEY=VALUE: $kv" 2 ;; esac
done
IFS=$oldifs

# --- Open the window --------------------------------------------------------
# Through Emacs when it owns the parent.  A parent that the agent-sessions
# dashboard opened carries EMACS_AGENT_SESSION_ID; asking that Emacs to open
# the window gives the child what plain tmux cannot: a tracked id of its own
# (hooks, session log, restore, emacs-share), a dashboard row nested under the
# parent, and brief.md attached to that row.  Emacs runs the same `env' list
# and types this same command; only the opener differs.  Anything short of
# success — no Emacs, no server, an id this Emacs does not know, code without
# the entry point — falls back to plain tmux and says so on stderr.
via=tmux
elisp_esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
elisp_unquote() { printf '%s' "$1" | sed -e 's/^"//' -e 's/"$//' -e 's/\\"/"/g' -e 's/\\\\/\\/g'; }
open_through_emacs() {
  [ -n "${EMACS_AGENT_SESSION_ID:-}" ] || return 1
  command -v emacsclient >/dev/null 2>&1 || return 1
  detached=nil; [ -n "$focus" ] || detached=t
  reply=$(emacsclient -e "(rsr/agent-sessions-explore-spawn \
\"$(elisp_esc "$EMACS_AGENT_SESSION_ID")\" \"$(elisp_esc "$session")\" \
\"$(elisp_esc "$cwd")\" \"$(elisp_esc "$name")\" \"$(elisp_esc "$dir")\" \
\"$(elisp_esc "$slug")\" \"$(elisp_esc "$cmd")\" \"$(elisp_esc "$child_env")\" \
$detached)" 2>&1) || {
    printf 'open-window: Emacs did not answer (%s); opening with plain tmux\n' "$reply" >&2
    return 1
  }
  reply=$(elisp_unquote "$reply")
  case "$reply" in
    Opened\ @*) ;;
    *) printf 'open-window: Emacs declined (%s); opening with plain tmux\n' "$reply" >&2
       return 1 ;;
  esac
  window=$(printf '%s' "$reply" | cut -d' ' -f2)
  via="emacs (terminal $(printf '%s' "$reply" | cut -d' ' -f3))"
  index=$(tmux display-message -p -t "$window" '#{window_index}' 2>/dev/null) || index='?'
}

if ! open_through_emacs; then
  set -- env
  for v in $unset_vars; do set -- "$@" -u "$v"; done
  oldifs=$IFS; IFS='
'
  for kv in $child_env; do set -- "$@" "$kv"; done
  IFS=$oldifs
  set -- "$@" "$shell" -l -c "$window_cmd"
  if [ -n "$focus" ]; then
    out=$(tmux new-window -t "=$session:" -n "$name" -c "$cwd" -P -F '#{window_id}	#{window_index}' "$@")
  else
    out=$(tmux new-window -d -t "=$session:" -n "$name" -c "$cwd" -P -F '#{window_id}	#{window_index}' "$@")
  fi || die "tmux new-window failed"
  window=$(printf '%s' "$out" | cut -f1)
  index=$(printf '%s' "$out" | cut -f2)
fi

# Tag both ends so either side can find the other later, without any database.
tmux set-option -w -t "$window" @explore-parent "$parent_tmux" >/dev/null 2>&1 || true
tmux set-option -w -t "$window" @explore-dir "$dir" >/dev/null 2>&1 || true
tmux set-option -w -t "$window" @explore-slug "$slug" >/dev/null 2>&1 || true
tmux set-option -w -t "$window" @explore-agent "$agent" >/dev/null 2>&1 || true
children=$(tmux show-option -wqv -t "$parent_window" @explore-children 2>/dev/null || true)
tmux set-option -w -t "$parent_window" @explore-children "${children:+$children }$window=$slug" >/dev/null 2>&1 || true

cat <<EOF
opened: tmux window $window (index $index, name $name) in session $session
via:    $via
child:  $agent ($mode) in $cwd
brief:  $brief
dir:    $dir
parent: window $parent_window (index $parent_index)
switch: tmux select-window -t $window   (prefix $index; back: prefix $parent_index)
EOF
[ -n "$focus" ] || printf 'focus:  left on the parent window (--no-focus)\n'
