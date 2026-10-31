#!/usr/bin/env bash
# core.md keeps only a pointer to the workflow; its other sections are untouched.
source "$(dirname "$0")/lib.sh"
f="$repo/instructions/shared/core.md"

forbid_text "$f" "Implementation preflight"
forbid_text "$f" "fresh user-started session"
forbid_text "$f" "Plan-backed implementation"
forbid_text "$f" "Requirements-only implementation"

require_heading "$f" "## Planning workflow"
require_regex "$f" "opt-in"
order=$(grep -oE '`(clarify-requirements|review-requirements|plan-implementation|review-plan|implement-plan|review-implementation)`' "$f" \
  | tr -d '`' | awk '!seen[$0]++' | paste -sd, -)
[[ "$order" == "clarify-requirements,review-requirements,plan-implementation,review-plan,implement-plan,review-implementation" ]] \
  || fail "$f: stage skills not listed in order: $order"
require_regex "$f" "rules live (only )?in (its|the) (stage )?skill"
require_text "$f" "issue-workflow"
require_regex "$f" "fresh session"
require_text "$f" "~/Stillness/Agent_Stuffs/Plans/"
require_text "$f" "workflow-conventions.md"

# The other sections, word for word as at the baseline.
section() { awk -v h="$1" '$0 == h {on=1; print; next} on && /^## / {exit} on {print}'; }
for h in "## Never commit unless explicitly asked" "## Answer depth" "## Installation location" \
         "## Question to User" "## Verification"; do
  before=$(git -C "$repo" show 71ac60c:instructions/shared/core.md | section "$h")
  now=$(section "$h" < "$f")
  [[ -n "$before" && "$before" == "$now" ]] || fail "$f: section changed or missing: $h"
done
finish
