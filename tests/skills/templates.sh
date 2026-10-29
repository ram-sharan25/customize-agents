#!/usr/bin/env bash
# Plans templates match workflow v2 (Plans/templates, outside this repo).
source "$(dirname "$0")/lib.sh"
t="${PLANS_TEMPLATES:-/Users/rrimal/Stillness/Agent_Stuffs/Plans/templates}"

for f in requirements decisions plan; do
  require_text "$t/$f.org" "#+implementation-repository:"
done
forbid_regex "$t/decisions.org" "optional rationale"
require_regex "$t/decisions.org" "^Why: "
for h in "* Global constraints" "* Review focus" "* File map" "* Self-review" \
         "** TODO Phase 1 —" "*** TODO Task 1 —"; do
  require_heading "$t/plan.org" "$h"
done
require_text "$t/plan.org" "Evidence"
require_regex "$t/plan.org" "Cost if wrong"
require_regex "$t/plan.org" "\(user\)|\*\(user"
require_regex "$t/requirements.org" "anti-goal"
require_regex "$t/requirements.org" "agent's guess"
finish
