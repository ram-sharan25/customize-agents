#!/usr/bin/env bash
# review-implementation (decisions.org, "Stage contents: review implementation").
source "$(dirname "$0")/lib.sh"
f="$repo/skills/review-implementation/SKILL.md"
require_stage_common "$f"
require_regex "$f" "child"
require_regex "$f" "read(s)? (the )?files only|reads only"
require_regex "$f" "working tree"
require_regex "$f" "staged"
require_regex "$f" "untracked"
require_regex "$f" "each recorded baseline|every recorded baseline|each repository.*baseline"
require_text "$f" "Missing"
require_text "$f" "Extra"
require_text "$f" "Misunderstood"
require_regex "$f" "every .?decisions.org.? entry"
require_regex "$f" "met or not met|met / not met"
require_regex "$f" "proof"
require_text "$f" "Review focus"
for s in BLOCKER HIGH MEDIUM LOW; do require_text "$f" "$s"; done
require_text "$f" "Declined to judge"
finish
