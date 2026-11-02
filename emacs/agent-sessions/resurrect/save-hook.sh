#!/bin/sh
# tmux-resurrect post-save-layout hook: make a save restorable without strays.
#
#   set -g @resurrect-hook-post-save-layout '<this dir>/save-hook.sh'
#
# Resurrect calls it with the save file it has just written.  Two things:
#
# - View sessions (S~view-N, made by `o') are dropped.  A view only shows a
#   window of S; restored, it would be a second copy of that window.
# - The agent tags of each window (@agent-session-id, @agent-session-log-id)
#   go to agent-sessions-tags.tsv beside the save, because resurrect keeps no
#   window options.  restore-hook.sh puts them back.

file=$1
[ -f "$file" ] || exit 0
tab=$(printf '\t')

tmp=$(mktemp "$file.XXXXXX") || exit 0
if awk -F'\t' -v OFS='\t' '
     $1 == "state" { for (i = 2; i <= NF; i++) sub(/~view-.*$/, "", $i); print; next }
     $2 ~ /~view-/ { next }
     { print }' "$file" > "$tmp"; then
  mv "$tmp" "$file"
else
  rm -f "$tmp"
fi

tags=$(dirname "$file")/agent-sessions-tags.tsv
if windows=$(tmux list-windows -a -F "#{session_name}$tab#{window_index}$tab#{@agent-session-id}$tab#{@agent-session-log-id}$tab#{pane_current_path}"); then
  # No empty field: the reader splits on tabs, which would merge around one.
  printf '%s\n' "$windows" |
    awk -F'\t' -v OFS='\t' '$3 != "" && $1 !~ /~view-/ { if ($4 == "") $4 = $3; print }' > "$tags.tmp" &&
    mv "$tags.tmp" "$tags"
fi
exit 0
