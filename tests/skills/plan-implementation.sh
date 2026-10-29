#!/usr/bin/env bash
# plan-implementation v2 (decisions.org, "Stage contents: plan" and the task contract).
source "$(dirname "$0")/lib.sh"
f="$repo/skills/plan-implementation/SKILL.md"
require_stage_common "$f"
for k in "Files" "Test" "Run (fail)" "Change" "Run (pass)" "Stage"; do require_text "$f" "$k"; done
require_regex "$f" "signature"
require_regex "$f" "proposed commit message"
require_regex "$f" "never (cite )?line numbers|no line numbers"
require_text "$f" "* Global constraints"
require_regex "$f" "word for word"
require_text "$f" "* Review focus"
require_regex "$f" "up to five"
require_text "$f" "* File map"
require_text "$f" "** Phase N —"
require_text "$f" "*** TODO Task N —"
require_text "$f" "(agent:"
require_text "$f" "* Self-review"
for k in coverage "vague" "name and type consistency" "proportion"; do require_regex "$f" "$k"; done
require_text "$f" "READY-FOR-REVIEW"
require_text "$f" "review-plan"
require_text "$f" "agent-launch"
require_text "$f" "extract-task"
finish
