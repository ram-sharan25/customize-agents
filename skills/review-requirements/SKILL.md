---
name: review-requirements
description: Workflow stage 2. Reviews one task's requirements.org and decisions.org independently, reading files only, and saves a findings file in the task's artifacts/. Runs as a child of the clarify-requirements session (or in a fresh session the user starts). Use for a requirements review; not to clarify, edit, finalize, plan, or implement.
disable-model-invocation: true
---

# Review Requirements

Review one task's requirements as someone who was not in the conversation.
You read files only, write only your findings, and change nothing else.

Shared rules: `/Users/rrimal/Stillness/Development/customize-agents/instructions/shared/workflow-conventions.md`.
Read it first; this skill uses its path confirmation, findings-file format,
children and report-back, and `next:` line sections.

## 1. Where you are and what you review

- You are usually a **child**: `EXPLORE_DIR` is set, or your first prompt
  was a child brief. The task folder is the one in your prompt
  (`LAUNCH_TASK`); write your findings in `EXPLORE_DIR` (the brief's output
  directory).
- Started on your own by the user, the task path in the invoking message is
  confirmed; make your own output directory
  `<task folder>/artifacts/<YYYY-MM-DD>-review-requirements/`.
- Register your row's folders when `EMACS_AGENT_SESSION_ID` is set
  (`emacs-share folder plans <task folder>`, and
  `emacs-share folder code <repository>` once per `#+implementation-repository:`),
  but never run `emacs-share state`: a review child sets no workflow state.
  The parent's row tells the dashboard where the work stands.

## 2. Evidence: the files only

- Read `requirements.org` and `decisions.org` in the task folder, and the
  conventions file. Nothing from the author's chat reaches you, and you do
  not ask the author anything.
- Follow another source only when the documents link it and you need it to
  judge a requirement; say which one and why in the findings.
- Never edit, create, or format a file outside your output directory.

## 3. What to check

In order of practical effect:

1. **Contradictions and correctness**: requirements that contradict each
   other, `decisions.org`, or a stated fact.
2. **Scope**: what is in and out, including anti-goals under `* Non-goals`.
3. **Feasibility, dependencies, and constraints.**
4. **Risk**: safety, operational, and delivery risk.
5. **Acceptance**: can each criterion be checked by a command or by looking?
6. **Marking**: guesses not marked *(agent's guess: …)*; `decisions.org`
   entries without `Why:`; the how creeping into requirements (requirements
   say what and why).
7. **Self-sufficiency**: `#+implementation-repository:` (one line per
   repository, or `N/A`), `#+baseline:`, `#+issue:` when there is an issue,
   `#+status:` — what a fresh session would need.

Then the **builder check**: read the documents as a builder who must plan
and build this and cannot ask the author anything. List every place where
you would have to guess and a wrong guess would matter, most important first. Each one is a finding (usually `HIGH` or `MEDIUM`) titled
"Builder would have to guess: …".

Do not invent product choices or turn your preferences into requirements.
No findings is a valid result.

## 4. Write the findings, report back, stop

1. Write `findings.md` in your output directory, in the conventions' format:
   `BLOCKER` / `HIGH` / `MEDIUM` / `LOW`, most severe first, and a
   `Declined to judge` list at the end (one line each, with the reason).
2. Write `summary.md` (at most 12 lines) next to it.
3. As a child, send the one-line notice and share the summary, as
   "Children and report-back" says:
   `review-requirements review-requirements done — ready to bring in (<dir>)`.
4. Tell the user in a few lines: the reviewed paths and their status, the
   count per severity, and where the findings are. Then print:

```
next: /clarify-requirements /Users/rrimal/Stillness/Agent_Stuffs/Plans/<task>/
```

   (in the parent session, the user says "bring in" instead). Stay open.

## Excuse / Reality

| Excuse | Reality |
|---|---|
| "This typo is quick to fix myself." | You change nothing outside your output directory. Report it. |
| "I'll put the findings in chat; it's faster." | Findings go in `findings.md`; the chat gets a short summary. |
| "The author probably meant X." | You cannot ask the author. Where a builder would guess, that is a finding. |
| "There must be something wrong; I'll find a few issues." | No findings is a valid result. Never make findings up. |
| "I'll set the row to PLAN-REVIEW when I finish." | A review child sets no workflow state; the parent does. |
| "Out of scope, so I'll just skip it." | Put it under `Declined to judge` with the reason. |
