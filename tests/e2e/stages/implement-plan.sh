# e2e: implement-plan on the toy repository; test first, staged, Evidence.
brief() { echo "The user explicitly asks you to implement this plan; the artifacts are confirmed. Do not open the review child; stop after the last task."; }
check() {
  out=$(cd "$REPO" && sh -c '. ./greet.sh; greet --shout Ada')
  [[ "$out" == "HELLO, ADA!" ]] || fail "greet --shout Ada printed: $out"
  [[ -n "$(git -C "$REPO" diff --cached --name-only)" ]] || fail "nothing staged"
  require_text "$TASK/plan.org" "Evidence"
  require_text "$TASK/plan.org" "staged, not committed"
  require_regex "$TASK/plan.org" "Fails first"
  require_regex "$TASK/plan.org" "Proposed commit message"
  require_next 'review-implementation'
}
