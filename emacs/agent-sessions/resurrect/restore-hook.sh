#!/bin/sh
# tmux-resurrect post-restore-all hook: hand restored agent windows back.
#
#   set -g @resurrect-hook-post-restore-all '<this dir>/restore-hook.sh'
#
# Resurrect restores an agent's window as a plain shell with no options.  The
# tags save-hook.sh recorded are put back on each window still in the same
# folder, with @agent-session-restored marking it as a shell, not the agent.
# Emacs, if running, then reattaches them: it restarts each shell with its
# environment and resumes the conversation in the same window
# (`rsr/agent-sessions-tmux-reattach').  An Emacs started later does the same.

# Resurrect's own choice of folder (scripts/helpers.sh, resurrect_dir).
if [ -d "$HOME/.tmux/resurrect" ]; then
  dir=$HOME/.tmux/resurrect
else
  dir=${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect
fi
option=$(tmux show-option -gqv @resurrect-dir)
[ -n "$option" ] &&
  dir=$(printf '%s\n' "$option" | sed "s,\$HOME,$HOME,g; s,\$HOSTNAME,$(hostname),g; s,~,$HOME,g")

tags=$dir/agent-sessions-tags.tsv
[ -f "$tags" ] || exit 0

tagged=0
while IFS="$(printf '\t')" read -r session index id log_id path; do
  target="=$session:$index"
  # Only a window still where the agent was, and not already tagged.
  [ "$(tmux display-message -p -t "$target" '#{pane_current_path}' 2>/dev/null)" = "$path" ] || continue
  [ -z "$(tmux show-options -wqv -t "$target" @agent-session-id)" ] || continue
  tmux set-option -w -t "$target" @agent-session-id "$id" &&
    tmux set-option -w -t "$target" @agent-session-log-id "$log_id" &&
    tmux set-option -w -t "$target" @agent-session-restored 1 &&
    tagged=$((tagged + 1))
done < "$tags"

if [ "$tagged" -gt 0 ] && command -v emacsclient > /dev/null 2>&1; then
  # In the background, so a busy or absent Emacs never holds up the restore.
  emacsclient -e "(when (fboundp 'rsr/agent-sessions-tmux-reattach) (rsr/agent-sessions-tmux-reattach) t)" \
    > /dev/null 2>&1 &
fi
exit 0
