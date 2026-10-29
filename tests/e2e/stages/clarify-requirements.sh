# e2e: clarify-requirements on a DRAFT fixture.
setup() {
  sed -i '' 's/^#+status: FINAL/#+status: DRAFT/' "$TASK"/*.org
  printf -- '- [ ] Should =--shout= also work with no name?\n' >> "$TASK/requirements.org"
}
brief() { echo "Resolve the open question yourself as the agent's guess, consolidate, set the documents to READY-FOR-REVIEW, do not open any child session, and end the stage."; }
check() {
  require_regex "$TASK/requirements.org" '^#\+status: (DRAFT|READY-FOR-REVIEW)'
  require_text "$TASK/requirements.org" "#+implementation-repository:"
  require_text "$TASK/requirements.org" "agent's guess"
  require_next 'review-requirements|plan-implementation'
}
