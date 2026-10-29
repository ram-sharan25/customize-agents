#!/usr/bin/env bash
# fix-bug child (decisions.org, "Stage contents: why-not and bug-fix children").
source "$(dirname "$0")/lib.sh"
f="$repo/skills/fix-bug/SKILL.md"
require_stage_common "$f"
require_regex "$f" "symptom"
require_regex "$f" "reproduc"
require_regex "$f" "root cause"
require_regex "$f" "ideas tried"
require_regex "$f" "fails before the fix and passes after"
require_regex "$f" "revert.*fail.*restore.*pass"
require_text "$f" "plan.org"
require_text "$f" "agent-launch"
require_regex "$f" "report(s)? back"
# The six parts are numbered, in this order.
order=$(grep -oiE "^[0-9]\. \*\*(symptom|root cause|ideas tried|a test|proof|a note)" "$f" \
  | sed -E 's/^([0-9])\. \*\*(.*)/\1 \2/' | tr 'A-Z' 'a-z' | paste -sd, -)
[[ "$order" == "1 symptom,2 root cause,3 ideas tried,4 a test,5 proof,6 a note" ]] \
  || fail "$f: outline parts missing or out of order: $order"
finish
