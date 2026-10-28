#!/usr/bin/env bash
# Link this repo's skills into every agent harness.  Idempotent: re-running
# fixes links that point elsewhere and leaves correct ones alone.  A real
# file or directory already at a target is never touched; it is reported so
# you can decide what to do with it.
set -euo pipefail

repo="$(cd "$(dirname "$0")" && pwd)"

# Where each harness looks for skills.
harness_dirs=(
  "$HOME/.claude/skills"
  "$HOME/.agents/skills"
  "$HOME/.pi/agent/skills"
  "$HOME/.config/pi/skills"
)

link() {
  local src="$1" dst="$2"
  if [[ -L "$dst" ]]; then
    [[ "$(readlink "$dst")" == "$src" ]] && return
    ln -sfn "$src" "$dst"
    echo "relinked  $dst"
  elif [[ -e "$dst" ]]; then
    echo "skipped   $dst (a real file or directory is there)"
  else
    ln -s "$src" "$dst"
    echo "linked    $dst"
  fi
}

for skill in "$repo"/skills/*/; do
  skill="${skill%/}"
  for dir in "${harness_dirs[@]}"; do
    mkdir -p "$dir"
    link "$skill" "$dir/$(basename "$skill")"
  done
done
