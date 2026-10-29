#!/usr/bin/env bash
# review-requirements v2: a child that reads files only and saves a findings file.
source "$(dirname "$0")/lib.sh"
f="$repo/skills/review-requirements/SKILL.md"
require_stage_common "$f"
require_regex "$f" "child"
require_regex "$f" "read(s)? (the )?files only|reads only"
require_text "$f" "findings.md"
require_text "$f" "artifacts/"
require_regex "$f" "builder"
require_regex "$f" "guess"
require_regex "$f" "most important first"
for s in BLOCKER HIGH MEDIUM LOW; do require_text "$f" "$s"; done
require_text "$f" "Declined to judge"
require_regex "$f" "sets? no workflow state|never (run|runs|set|sets) .?emacs-share state"
forbid_regex "$f" "Report only in chat"
finish
