#!/usr/bin/env bash
# agent-launch --dry-run: the window command and environment it would use.
source "$(dirname "$0")/../skills/lib.sh"
launch="$repo/emacs/agent-sessions/bin/agent-launch"
tmp=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$tmp"' EXIT
task="$tmp/plans/t"; mkdir -p "$task/artifacts/r"; printf 'brief text\n' > "$task/artifacts/r/brief.md"
out="$tmp/out"

run() { env -u AGENT_DEFAULT -u TMUX -u TMUX_PANE -u EMACS_AGENT_SESSION_ID "$@" > "$out" 2>&1; }
has() { grep -qF -- "$1" "$out" || fail "$2: expected '$1' in: $(cat "$out")"; }
lacks() { if grep -qF -- "$1" "$out"; then fail "$2: unexpected '$1' in: $(cat "$out")"; fi; }

# Top-level, Claude, no brief: the skill and task are the first prompt.
run "$launch" --dry-run --top --skill plan-implementation --task "$task" --cwd "$tmp" \
  || fail "top: exit $?"
has "mode:   top" top
has "command: claude -n 'plan-implementation' '/plan-implementation $task/'" top
lacks "EXPLORE_PARENT_TMUX" top

# Pi uses its skill command form.
run "$launch" --dry-run --top --agent pi --skill review-plan --task "$task" --cwd "$tmp" \
  || fail "pi: exit $?"
has "command: pi -n 'review-plan' '/skill:review-plan $task/'" pi

# agy takes Claude's skill form through -i, which keeps the session open.
run "$launch" --dry-run --top --agent agy --skill review-plan --task "$task" --cwd "$tmp" \
  || fail "agy: exit $?"
has "command: agy -i '/review-plan $task/'" agy
run "$launch" --dry-run --top --agent agy --fork --skill review-plan --task "$task" --cwd "$tmp" \
  && fail "agy fork: expected a failure"
has "--fork is not supported for agy" "agy fork"

# Machine preference applies only when --agent is omitted, and reaches children.
run env AGENT_DEFAULT=pi "$launch" --dry-run --top --skill review-plan --task "$task" --cwd "$tmp" \
  || fail "configured Pi: exit $?"
has "command: pi -n 'review-plan'" "configured Pi"
has "env:    AGENT_DEFAULT=pi" "preference propagation"
run env AGENT_DEFAULT=pi "$launch" --dry-run --top --agent claude --skill review-plan --task "$task" --cwd "$tmp" \
  || fail "explicit Claude: exit $?"
has "command: claude -n 'review-plan'" "explicit override"
has "env:    AGENT_DEFAULT=pi" "override preserves preference"
run env AGENT_DEFAULT=claude "$launch" --dry-run --top --agent pi --skill review-plan --task "$task" --cwd "$tmp" \
  || fail "explicit Pi: exit $?"
has "command: pi -n 'review-plan'" "explicit Pi override"
run env AGENT_DEFAULT=invalid "$launch" --dry-run --top --skill review-plan --task "$task" --cwd "$tmp"
[[ $? -eq 2 ]] || fail "invalid default: expected exit 2"

# A brief is appended after the skill line.
run "$launch" --dry-run --top --skill review-plan --task "$task" --cwd "$tmp" \
  --brief "$task/artifacts/r/brief.md" || fail "brief: exit $?"
has "cat '$task/artifacts/r/brief.md'" brief

# Child: the parent's identity reaches the child; task folder and output dir too.
run env TMUX=/tmp/x,1,0 TMUX_PANE=%1 AGENT_LAUNCH_FAKE_PANE="main	@3	3	%1" \
  "$launch" --dry-run --child --skill review-plan --task "$task" --slug review-plan \
  --dir "$task/artifacts/r" --brief "$task/artifacts/r/brief.md" --cwd "$tmp" \
  || fail "child: exit $?"
has "mode:   child" child
has "EXPLORE_PARENT_TMUX=main:@3.%1" child
has "EXPLORE_DIR=$task/artifacts/r" child
has "LAUNCH_TASK=$task/" child
has "LAUNCH_SKILL=review-plan" child

# Child with neither tmux nor a known parent cannot open anything.
run "$launch" --dry-run --child --skill review-plan --task "$task" --slug x --dir "$task/artifacts/r" --cwd "$tmp"
[[ $? -eq 2 ]] || fail "child outside tmux and Emacs: expected exit 2"

# A task folder that does not exist is refused.
run "$launch" --dry-run --top --skill review-plan --task "$tmp/nope" --cwd "$tmp"
[[ $? -ne 0 ]] || fail "missing task folder: expected failure"

# Neither --skill nor --prompt-file.
run "$launch" --dry-run --top --cwd "$tmp"
[[ $? -eq 2 ]] || fail "no skill: expected exit 2"
finish
