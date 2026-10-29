#!/usr/bin/env bash
# Run one workflow stage skill headless against a fresh copy of the fixture.
#
#   run-stage.sh --selftest
#   run-stage.sh SKILL ASSERTIONS-FILE [--keep]
#
# The copy lives in a temp directory: TASK=<tmp>/plans/sample-task and a toy
# git repository REPO=<tmp>/repo whose HEAD is the recorded baseline.  The
# assertions file is sourced with TASK, REPO, and OUTPUT (the agent's printed
# reply) set.  It may define:
#   setup   — adjust the fixture before the run (e.g. set a status to DRAFT)
#   brief   — extra text appended to the prompt
#   check   — the assertions, using tests/skills/lib.sh helpers
# Slow, costs tokens, and varies run to run, so it is not part of tests/run.sh.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../skills/lib.sh"
fixture="$here/../fixtures"

make_copy() {
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/run-stage.XXXXXX")
  TASK="$tmp/plans/sample-task"
  REPO="$tmp/repo"
  mkdir -p "$TASK"
  cp -R "$fixture/repo" "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" add -A
  git -C "$REPO" -c user.name=fixture -c user.email=fixture@example.com \
    commit -q -m "fixture baseline"
  baseline=$(git -C "$REPO" rev-parse --short HEAD)
  for f in "$fixture"/plans/sample-task/*.org; do
    sed -e "s|@TASK@|$TASK|g" -e "s|@REPO@|$REPO|g" -e "s|@BASELINE@|$baseline|g" \
      "$f" > "$TASK/$(basename "$f")"
  done
}

if [[ "${1:-}" == --selftest ]]; then
  make_copy
  for f in requirements decisions plan; do
    require_text "$TASK/$f.org" "#+status:"
    forbid_text "$TASK/$f.org" "@TASK@"
  done
  [[ -n "$(git -C "$REPO" log --oneline)" ]] || fail "toy repo has no baseline commit"
  rm -rf "$tmp"
  finish
fi

skill=${1:?usage: run-stage.sh SKILL ASSERTIONS-FILE [--keep]}
assertions=${2:?usage: run-stage.sh SKILL ASSERTIONS-FILE [--keep]}
keep=${3:-}
setup() { :; }
brief() { :; }
check() { :; }
source "$assertions"

make_copy
setup
log_before=$(git -C "$REPO" log --oneline)
prompt="/$skill $TASK/

Headless test run: no human is present and no dashboard session exists (emacs-share will fail; note that and continue). Where the skill would ask the user, take the most conservative choice, record it as the agent's guess with its reason, and carry on to the stage's end. $(brief)"
# Not this session's dashboard row, tmux pane, or parent: the run is isolated.
OUTPUT=$(cd "$tmp" && env -u EMACS_AGENT_SESSION_ID -u EMACS_AGENT_PARENT \
  -u TMUX -u TMUX_PANE -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
  claude -p "$prompt" --permission-mode acceptEdits \
  --allowedTools "Bash Read Write Edit Glob Grep" 2>&1)
printf '%s\n' "$OUTPUT" > "$tmp/output.txt"

check
[[ "$(git -C "$REPO" log --oneline)" == "$log_before" ]] || fail "a commit was made in the toy repo"
echo "run:    $tmp"
echo "output: $tmp/output.txt"
[[ -n "$keep" ]] || trap 'rm -rf "$tmp"' EXIT
finish
