# e2e: review-plan started top-level; findings with the contract table.
setup() { md5 -q "$TASK/plan.org" > "$tmp/plan.md5"; }
check() {
  f=$(ls "$TASK"/artifacts/*review-plan*/findings.md 2>/dev/null | head -1)
  [[ -n "$f" ]] || { fail "no findings.md under artifacts/"; return; }
  require_regex "$f" '✓|✗'
  require_regex "$f" '\| *Task'
  require_text "$f" "Declined to judge"
  [[ "$(md5 -q "$TASK/plan.org")" == "$(cat "$tmp/plan.md5")" ]] || fail "plan.org was edited"
  grep -qE 'next: /plan-implementation' "$tmp/output.txt" || fail "no next: line in output"
}
