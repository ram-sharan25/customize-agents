# e2e: review-requirements started top-level; findings file, no edits.
setup() { md5 -q "$TASK/requirements.org" > "$tmp/req.md5"; }
check() {
  f=$(ls "$TASK"/artifacts/*review-requirements*/findings.md 2>/dev/null | head -1)
  [[ -n "$f" ]] || { fail "no findings.md under artifacts/"; return; }
  require_text "$f" "Declined to judge"
  require_regex "$f" '\[(BLOCKER|HIGH|MEDIUM|LOW)\]|no findings'
  [[ "$(md5 -q "$TASK/requirements.org")" == "$(cat "$tmp/req.md5")" ]] || fail "requirements.org was edited"
  grep -qE 'next: /clarify-requirements' "$tmp/output.txt" || fail "no next: line in output"
}
