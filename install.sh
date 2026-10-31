#!/usr/bin/env bash
# Link this repo's skills into every agent harness and shared instructions into Pi.  Idempotent: re-running
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
)

link() {
  local src="$1" dst="$2"
  if [[ -L "$dst" ]]; then
    [[ "$(readlink "$dst")" == "$src" ]] && return 0
    ln -sfn "$src" "$dst"
    echo "relinked  $dst"
  elif [[ -e "$dst" ]]; then
    echo "skipped   $dst (a real file or directory is there)"
  else
    ln -s "$src" "$dst"
    echo "linked    $dst"
  fi
}

mkdir -p "$HOME/.pi/agent"
link "$repo/instructions/pi/AGENTS.md" "$HOME/.pi/agent/AGENTS.md"
link "$repo/instructions/shared/core.md" "$HOME/.pi/agent/APPEND_SYSTEM.md"

for skill in "$repo"/skills/*/; do
  skill="${skill%/}"
  for dir in "${harness_dirs[@]}"; do
    mkdir -p "$dir"
    link "$skill" "$dir/$(basename "$skill")"
  done
done
