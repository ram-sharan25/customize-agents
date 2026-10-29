#!/usr/bin/env bash
# explore-session: opens children through agent-launch; why-not outline.
source "$(dirname "$0")/lib.sh"
skill="$repo/skills/explore-session/SKILL.md"
open="$repo/skills/explore-session/scripts/open-window.sh"

require_text "$open" "agent-launch"
require_text "$skill" "agent-launch"
# The why-not findings outline (decisions.org, "Stage contents: why-not ...").
require_regex "$skill" "why-not"
require_regex "$skill" "choice questioned"
require_regex "$skill" "must achieve"
require_regex "$skill" "alternative.*why not"
require_regex "$skill" "verdict"
require_text "$skill" "Why-not:"

# Same child command and environment as before the refactor.
tmp=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$tmp"' EXIT
printf '# brief\n' > "$tmp/brief.md"
out=$(env -u EMACS_AGENT_SESSION_ID TMUX=/tmp/x,1,0 TMUX_PANE=%1 \
  AGENT_LAUNCH_FAKE_PANE="main	@3	3	%1" \
  "$open" --agent claude --slug topic --dir "$tmp" --cwd "$tmp" --dry-run 2>&1) \
  || fail "open-window --dry-run failed: $out"
grep -qF "command: claude -n 'explore-topic' \"\$(cat '$tmp/brief.md')\"" <<<"$out" \
  || fail "unexpected child command: $out"
grep -qF "env:    EXPLORE_SLUG=topic" <<<"$out" || fail "no EXPLORE_SLUG: $out"
grep -qF "env:    EXPLORE_PARENT_TMUX=main:@3.%1" <<<"$out" || fail "no parent tmux: $out"
finish
