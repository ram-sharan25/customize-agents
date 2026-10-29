#!/usr/bin/env bash
# issue-workflow composes the stage skills in one session; no copies of them.
source "$(dirname "$0")/lib.sh"
f="$repo/skills/issue-workflow/SKILL.md"
require_text "$f" "instructions/shared/workflow-conventions.md"
# Each stage skill, in order.
order=$(grep -oE '`(clarify-requirements|review-requirements|plan-implementation|review-plan|implement-plan|review-implementation)`' "$f" \
  | tr -d '`' | awk '!seen[$0]++' | paste -sd, -)
[[ "$order" == "clarify-requirements,review-requirements,plan-implementation,review-plan,implement-plan,review-implementation" ]] \
  || fail "$f: stage skills not named in order: $order"
require_regex "$f" "one session"
require_regex "$f" "gate"
require_regex "$f" "approv"
require_regex "$f" "as (a )?child|children"
require_text "$f" "agent-launch"
require_text "$f" "emacs-share link linear"
require_text "$f" "emacs-share link pr"
require_text "$f" "#+pr:"
require_regex "$f" "^[^a-z]*next: /"
forbid_regex "$f" 'next: /[a-z-]+ /Users/[^ ]*/Plans/<'
require_regex "$f" '\| *Excuse *\| *Reality *\|'
# No copy of a stage's rules or of the templates.
for old in "Write the review package" "Review and revise the plan" "Optional: independently verify the plan" \
           "Verify and reconcile" "### \`requirements.org\`" "### \`plan.org\`" "- Status :: proposed"; do
  forbid_text "$f" "$old"
done
forbid_regex "$f" '^#\+(title|status|baseline|decisions|plan):'
forbid_regex "$f" '^\s*#\+(issue|pr|baseline): <'
[[ ! -e "$repo/skills/issue-workflow/references/artifacts.md" ]] \
  || require_regex "$repo/skills/issue-workflow/references/artifacts.md" "templates"
[[ ! -e "$repo/skills/issue-workflow/references/artifacts.md" ]] \
  || forbid_text "$repo/skills/issue-workflow/references/artifacts.md" "- Status :: proposed"
finish
