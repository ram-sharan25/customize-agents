#!/usr/bin/env bash
# instructions/shared/workflow-conventions.md: the rules every stage skill shares.
source "$(dirname "$0")/lib.sh"
f="$repo/instructions/shared/workflow-conventions.md"

require_heading "$f" "## A path given at invocation is confirmed"
require_heading "$f" "## The documents are self-sufficient"
for k in "#+issue:" "#+pr:" "#+baseline:" "#+implementation-repository:" "#+status:" "findings"; do
  require_text "$f" "$k"
done
require_heading "$f" "## Register on the dashboard"
require_text "$f" "emacs-share state"
require_text "$f" "emacs-share folder plans"
require_text "$f" "emacs-share folder code"
require_text "$f" "emacs-share link"
require_heading "$f" "## End with the next command"
require_text "$f" "next: /"
require_text "$f" "next: /review-plan <task folder>/"
require_regex "$f" "exactly as (given|confirmed)"
require_regex "$f" "never rebuild it from the Plans"
forbid_regex "$f" 'next: /[a-z-]+ /Users/[^ ]*/Plans/<'
require_heading "$f" "## Never close the session"
require_heading "$f" "## Findings files"
require_text "$f" "BLOCKER"
require_text "$f" "HIGH"
require_text "$f" "MEDIUM"
require_text "$f" "LOW"
require_text "$f" "Declined to judge"
require_heading "$f" "## Mark who decided"
require_text "$f" "(agent:"
require_heading "$f" "## Every choice records why"
require_heading "$f" "## Children and report-back"
require_text "$f" "agent-launch"
require_text "$f" "ready to bring in"
# Task 13: the parent's states around a review child.
require_heading "$f" "## When a review child's notice arrives"
require_regex "$f" "REVIEW.*when.*(open|opening)"
require_text "$f" "PLAN-REVIEW"
require_text "$f" "IMPL-REVIEW"
require_regex "$f" "nothing else.*until the user says .?bring in"
forbid_regex "$f" "git commit -"
finish
