#!/usr/bin/env bash
# carve-work: break work into sittings before any task exists
# (Plans/customize-agents/carve-work, requirements.org acceptance criteria).
source "$(dirname "$0")/lib.sh"
f="$repo/skills/carve-work/SKILL.md"

# Task 1: frontmatter, trigger phrases, sections, entry.
require_regex "$f" '^name: carve-work$'
for k in "carve" "break this down" "how many sittings"; do
  require_regex "$f" "^description:.*$k"
done
forbid_regex "$f" '^disable-model-invocation:'
for h in "## 1. Entry" "## 2. The questions, in order" "## 3. The Org text" \
         "## 4. Writing, on the user's word" \
         "## 5. Worked example, home room: Reading Codebase: Flask" \
         "## 6. Worked example, work room: Basemap with no labels and borders" \
         "## Excuse / Reality"; do
  require_heading "$f" "$h"
done
require_regex "$f" "the user carves, the skill asks"
require_regex "$f" "after the user has tried"
require_text "$f" "(my proposal)"
require_regex "$f" "one (question )?at a time"
require_regex "$f" "which Area"
require_regex "$f" "work or home"
require_text "$f" "build, learn, fix, decide, admin"
require_regex "$f" '^\| *Kind *\|'
for k in build learn fix decide admin; do require_regex "$f" "^\| *$k *\|"; done
require_regex "$f" "effort .*(is always|stays|fixed) .*1:30|1:30 .*(every|each) sitting"
# Task 2: the ten questions in order, each with a Why: and a sourced Source:.
order=$(awk '/^## 2\. /{on=1; next} /^## /{on=0}
             on && /^### [0-9]+\. /{sub(/^### /,""); sub(/\. /," "); print}' "$f" | paste -sd, -)
[[ "$order" == "1 Outcome,2 Attack,3 First sitting,4 Next sitting,5 Count,6 Depth,7 Needs,8 Throwaway,9 Read back,10 Show" ]] \
  || fail "$f: questions missing or out of order: $order"
missing=$(awk '
  /^## 2\. /{on=1; next} /^## /{on=0}
  on && /^### [0-9]+\. / { flush(); q=$0; why=0; src=0; next }
  on && /^Why: ./ { why++ }
  on && /^Source: .*https:\/\// { src++ }
  END { flush() }
  function flush() { if (q == "") return
    if (why != 1) print "need exactly one Why: under " q
    if (src < 1) print "no Source: with a URL under " q }' "$f")
[[ -z "$missing" ]] || fail "$f: $missing"
# Every line naming one of the four people carries a URL, a (Qn) pointer, or sits in a question block.
# Lines inside an ```org block are the user's own carving (an Outcome may name Flask's author), not a claim.
unsourced=$(awk '
  /^## 2\. /{sec2=1} /^## / && !/^## 2\. /{sec2=0; inq=0}
  /^### [0-9]+\. /{inq=sec2}
  /^```org/{inblk=1; next} /^```/{inblk=0; next}
  /Hashimoto|Zechner|Ronacher|Karpathy/ && !/https:\/\// && !/\(Q[0-9]+([-–]Q?[0-9]+)?\)/ && !inq && !inblk { print NR ": " $0 }' "$f")
[[ -z "$unsourced" ]] || fail "$f: named person without a source or (Qn) pointer: $unsourced"
require_text "$f" "What will exist when this is done that does not exist now?"
require_regex "$f" "who reads it"
require_text "$f" "I want to read the Flask codebase"
require_regex "$f" "(an|is an) activity.*ask(s)? again|ask(s)? again.*activity"
require_text "$f" "Do you know how you would start?"
require_regex "$f" "another way in"
require_regex "$f" "could not possibly be wrong"
require_regex "$f" "become a user, build it, trace one feature, reimplement one commit, change three lines"
require_text "$f" "What is the next single thing you would add, and how would you know it worked?"
require_regex "$f" "no cap"
require_regex "$f" "run (carve-work|it) again after that sitting"
require_regex "$f" "teach you something or decide something"
require_regex "$f" "Deep because the thinking is yours"
require_regex "$f" "What must be at hand before this starts"
require_regex "$f" "Which of these sittings might be thrown away"
require_text "$f" "(may be thrown away)"
require_regex "$f" "the principle it applied"
require_regex "$f" "Show the Org text"
# Task 3: the Org text and the write step.
require_regex "$f" ':OUTCOME: *<'
require_regex "$f" ':NEEDS: *<'
require_regex "$f" ':Effort: +1:30'
require_regex "$f" ':deep: (when|only when) deep'
require_regex "$f" "nothing else new"
require_regex "$f" "(one sitting|a single sitting).*\*\* TODO"
require_regex "$f" "two or more sittings.*project file"
for k in "#+TITLE:" "#+PROPERTY: AREA" "#+FILETAGS:" "#+ARCHIVE: ::* Archive" "* Outcome" "* Tasks [/]" ":COOKIE_DATA: todo recursive" "* Log" "* Notes"; do
  require_text "$f" "$k"
done
require_regex "$f" "no sub-tasks"
require_regex "$f" "rule under .*Outcome"
require_regex "$f" "own project file beside it"
require_regex "$f" "pointer from the old task"
require_regex "$f" "keeps its devlog and clock lines"
require_regex "$f" "writes? nothing (until|before) the user"
require_regex "$f" "on the user's word"
require_text "$f" "~/Stillness/Brain/Areas/"
require_text "$f" ":ID:"
require_text "$f" ":CREATED:"
require_regex "$f" "SCHEDULED: <"
require_regex "$f" "only when the user asks"
require_regex "$f" "never delete(s)? a note"
require_regex "$f" "never commits?"
forbid_regex "$f" 'AskUserQuestion|SendMessage|mcp__|emacs-share|agent-launch'
forbid_regex "$f" '\.emacs\.d|define-key|global-set-key|\(kbd '
forbid_regex "$f" '^[^|]*\b(run|then|and) +`?git (commit|push|reset)'
# Task 4: the two worked examples, each ending in shown Org text.
example_org() {  # example_org "<## heading text>": the Org src block under that heading
  awk -v h="$1" '
    index($0, "## " h) == 1 { on=1; next }
    on && /^## / { exit }
    on && /^```org/ { b=1; next }
    on && /^```/ { b=0 }
    on && b' "$f"
}
check_example() {  # check_example NAME ORGTEXT N: N sittings, each complete, nothing else new
  local name=$1 org=$2 n=$3 c
  c=$(grep -cE '^\*\* TODO ' <<<"$org");            [[ "$c" == "$n" ]] || fail "$name: $c sittings, want $n"
  c=$(grep -cE '^\*\* TODO .*:deep:$' <<<"$org");   [[ "$c" == "$n" ]] || fail "$name: $c :deep: headings, want $n"
  c=$(grep -cE '^:OUTCOME: .' <<<"$org");           [[ "$c" == "$n" ]] || fail "$name: $c OUTCOME lines, want $n"
  c=$(grep -cE '^:NEEDS: .' <<<"$org");             [[ "$c" == "$n" ]] || fail "$name: $c NEEDS lines, want $n"
  c=$(grep -cE '^:Effort: +1:30$' <<<"$org");       [[ "$c" == "$n" ]] || fail "$name: $c Effort lines, want $n"
  grep -qE '^\*\*\* ' <<<"$org" && fail "$name: a sub-task"
  c=$(grep -E '^:[A-Za-z_]+:' <<<"$org" | grep -vE '^:(OUTCOME|NEEDS|Effort|PROPERTIES|END|COOKIE_DATA):' || true)
  [[ -z "$c" ]] || fail "$name: property not allowed on a sitting: $c"
  grep -qE '^\* Outcome$' <<<"$org" || fail "$name: no * Outcome"
  grep -qE "^\* Tasks \[0/$n\]$" <<<"$org" || fail "$name: no * Tasks [0/$n]"
  for k in "#+TITLE: " "#+PROPERTY: AREA " "#+FILETAGS: :" "#+ARCHIVE: ::* Archive"; do
    grep -qF -- "$k" <<<"$org" || fail "$name: missing $k"
  done
}
flask=$(example_org "5. Worked example, home room: Reading Codebase: Flask")
[[ -n "$flask" ]] || fail "$f: no Org block under the Flask example"
check_example flask "$flask" 4
grep -qF -- "#+PROPERTY: AREA Craft" <<<"$flask" || fail "flask: AREA is not Craft"
grep -qF -- "#+FILETAGS: :learn:" <<<"$flask" || fail "flask: FILETAGS is not :learn:"
grep -qiE "architecture" <<<"$flask" || fail "flask: Outcome does not name the architecture note"
grep -qE '^\*\* TODO .*\(may be thrown away\)' <<<"$flask" || fail "flask: no throwaway mark on a heading"
basemap=$(example_org "6. Worked example, work room: Basemap with no labels and borders")
[[ -n "$basemap" ]] || fail "$f: no Org block under the basemap example"
check_example basemap "$basemap" 4
grep -qF -- "#+PROPERTY: AREA Impact" <<<"$basemap" || fail "basemap: AREA is not Impact"
grep -qF -- "#+FILETAGS: :decide:" <<<"$basemap" || fail "basemap: FILETAGS is not :decide:"
grep -qiE "seniors" <<<"$basemap" || fail "basemap: Outcome does not name the reader"
grep -qiE "known only after sitting 3" <<<"$basemap" || fail "basemap: no rule for the sittings carved later"
# The walks: entry, the user's answers, and a read-back with a (Qn) per sitting.
for sec in "## 5. " "## 6. "; do
  body=$(awk -v h="$sec" 'index($0, h) == 1 {on=1; next} on && /^## / {exit} on' "$f")
  grep -qE '^(Area|Entry)' <<<"$body" || fail "$sec: no entry line"
  grep -qiE 'kind: (learn|decide)' <<<"$body" || fail "$sec: no kind"
  c=$(grep -cE '\(Q[0-9]+\)' <<<"$body"); (( c >= 4 )) || fail "$sec: read-back has $c (Qn) pointers, want at least 4"
  grep -qiE 'shown, not written|shown and not written' <<<"$body" || fail "$sec: does not end as shown text"
done
require_text "$f" "Reading Codebase: Flask"
require_text "$f" "Basemap with no labels and borders"
require_regex "$f" "Q1.*understand how large codebases are written"
# Review fix: the walk says what happened; Mapbox was the user's own addition, not an answer to a question.
forbid_text "$f" "Asked for another way in"
require_regex "$f" "added Mapbox unprompted"
# Task 5: the Excuse / Reality table, and the README row.
require_regex "$f" '\| *Excuse *\| *Reality *\|'
rows=$(awk '/^## Excuse \/ Reality/{on=1; next} on && /^## /{exit} on && /^\|/' "$f" | grep -vcE '^\| *(Excuse|-)')
(( rows >= 8 )) || fail "$f: Excuse / Reality has $rows rows, want at least 8"
require_regex "$f" '\| *"The outcome is .work on X.*\| *An outcome is something you can see, run, or watch pass'
require_regex "$f" '\| *"It needs five sittings.*\| *Carve all five'
require_regex "$f" '\| *"I.ll propose the breakdown.*\| *The user carves'
require_regex "$f" '\| *"Deep because it is important.*\| *Deep because the thinking is yours'
require_regex "$f" '\| *"Sitting 3 adds the parser and the runtime.*\| *One addition per sitting'
require_regex "$f" '\| *"I.ll write the headings into the file now.*\| *Show the Org text'
require_regex "$f" '\| *"Sub-tasks under the sitting would help.*\| *Projects, not parents'
require_regex "$f" '\| *"The user is busy, I.ll schedule it too.*\| *Scheduling is the Shutdown ritual'
require_regex "$repo/README.org" '^\| *=skills/carve-work/= *\|.*sitting'
finish
