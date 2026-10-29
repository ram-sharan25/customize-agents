# e2e: plan-implementation writes a v2 plan from FINAL requirements.
setup() { rm "$TASK/plan.org"; }
brief() { echo "Make every planning decision yourself, marked (agent: reason). Do the self-review, set the plan to READY-FOR-REVIEW, do not open the review child, and end the stage."; }
check() {
  p="$TASK/plan.org"
  for h in "* Global constraints" "* Review focus" "* File map" "* Self-review" "** TODO Phase 1 —" "*** TODO Task 1 —"; do
    require_heading "$p" "$h"
  done
  require_text "$p" "(agent:"
  require_regex "$p" '^#\+status: (DRAFT|READY-FOR-REVIEW)'
  require_next 'review-plan|implement-plan'
}
