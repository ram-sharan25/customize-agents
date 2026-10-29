#!/usr/bin/env bash
# review-plan v2: a child with a findings file and the contract table.
source "$(dirname "$0")/lib.sh"
f="$repo/skills/review-plan/SKILL.md"
require_stage_common "$f"
require_regex "$f" "child"
require_regex "$f" "read(s)? (the )?files only|reads only"
require_text "$f" "findings.md"
require_regex "$f" "contract table"
require_text "$f" "✓"
require_text "$f" "✗"
require_regex "$f" "every task has (all|every) contract field"
require_regex "$f" "names and interfaces"
require_regex "$f" "plan-mandated defect"
require_regex "$f" "speculative generality"
for s in BLOCKER HIGH MEDIUM LOW; do require_text "$f" "$s"; done
require_text "$f" "Declined to judge"
forbid_regex "$f" "Findings belong only in chat"
finish
