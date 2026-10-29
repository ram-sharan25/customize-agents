---
name: review-plan
description: Workflow stage 4. Reviews one task's plan.org against its requirements.org and decisions.org independently, reading files only, and saves a findings file with a task-contract table in the task's artifacts/. Runs as a child of the plan-implementation session (or in a fresh session the user starts). Use for a plan review; not to edit plans, clarify requirements, finalize, or implement.
disable-model-invocation: true
---

# Review Plan

Review one plan as someone who was not in the planning conversation, and as
the implementer who will have to follow it. You read files only, write only
your findings, and change nothing else.

Shared rules: `/Users/rrimal/Stillness/Development/customize-agents/instructions/shared/workflow-conventions.md`.
Read it first; this skill uses its path confirmation, findings-file format,
children and report-back, and `next:` line sections.

## 1. Where you are and what you review

- You are usually a **child**: `EXPLORE_DIR` is set, or your first prompt
  was a child brief. The task folder is the one in your prompt
  (`LAUNCH_TASK`); write your findings in `EXPLORE_DIR`.
- Started on your own by the user, the task path in the invoking message is
  confirmed; make your own output directory
  `<task folder>/artifacts/<YYYY-MM-DD>-review-plan/`.
- Register your row's folders when `EMACS_AGENT_SESSION_ID` is set
  (`emacs-share folder plans <task folder>`, and
  `emacs-share folder code <repository>` once per `#+implementation-repository:`),
  but never run `emacs-share state`: a review child sets no workflow state.

## 2. Evidence: the files only

- Read `plan.org`, `requirements.org`, and `decisions.org` in the task
  folder, and the conventions file. Nothing from the author's chat reaches
  you, and you do not ask the author anything.
- Follow a source only when a document links it and you need it to judge a
  claim (for example, that a function the plan names exists); say which one
  and why in the findings. Do not explore the repository at large.
- Never edit, create, or format a file outside your output directory.

## 3. What to check

**The contract table first.** One row per task, one column per contract part
(see the plan-implementation skill, "The task contract"), each cell ✓ or ✗:

```markdown
| Task | Files | Interfaces | Test | Run (fail) | Change | Run (pass) | Stage |
|------|-------|------------|------|------------|--------|------------|-------|
| 1 — <name> | ✓ | ✗ | ✓ | ✓ | ✓ | ✓ | ✓ |
```

A ✗ is a finding when an implementer would have to guess because of it.

**Then the checklist**, in order of practical effect:

1. Every task has all contract fields, and none cites line numbers.
2. Names and interfaces match across tasks and the File map: the same
   function, signature, path, and type everywhere.
3. Plan-mandated defects: a task that, followed exactly, would build
   something wrong (a test that cannot fail, a change that breaks another
   task, an order that cannot work).
4. Speculative generality: tasks, options, or abstractions no requirement
   asks for.
5. Coverage: every requirement and acceptance criterion maps to a task in
   `* Validation`; `* Global constraints` is copied word for word.
6. `decisions.org`: plan content that contradicts, weakens, or works around
   an entry.
7. Marking: choices not marked *(user, …)* or *(agent: <reason>)*.
8. `* Review focus`: up to five cases, each with an owning task and test.
9. `* Self-review` exists and its claims hold.
10. Sequencing, dependencies, risks, validation, rollback; and the status
    (a `FINAL` plan with material changes, a plan that claims to authorize
    implementation, a plan stale against changed requirements).

Do not invent design choices or turn your preferences into requirements. No
findings is a valid result.

## 4. Write the findings, report back, stop

1. Write `findings.md` in your output directory in the conventions' format,
   with the contract table under `## Contract table` before `## Findings`:
   `BLOCKER` / `HIGH` / `MEDIUM` / `LOW`, most severe first, and a
   `Declined to judge` list at the end. (Mapping from a borrowed checklist:
   Critical → `BLOCKER` or `HIGH`, Important → `MEDIUM`, Minor → `LOW`.)
2. Write `summary.md` (at most 12 lines) next to it.
3. As a child, send the one-line notice and share the summary, as
   "Children and report-back" says:
   `review-plan review-plan done — ready to bring in (<dir>)`.
4. Tell the user in a few lines: the reviewed paths and their status, the
   count per severity, the number of ✗ cells, and where the findings are.
   Then print:

```
next: /plan-implementation <task folder>/
```

   (in the parent session, the user says "bring in" instead). Stay open.

## Excuse / Reality

| Excuse | Reality |
|---|---|
| "I'll fix this task wording myself." | You change nothing outside your output directory. Report it. |
| "Findings in chat are enough." | Findings go in `findings.md`, with the contract table. |
| "The task is mostly complete; I'll tick it." | A ✓ means an implementer would not guess. Otherwise ✗. |
| "This extra option might be useful later." | Speculative generality is a finding. |
| "The author surely meant the same name." | A mismatch between tasks is a finding. |
| "I'll set PLAN-REVIEW when I'm done." | A review child sets no workflow state; the parent does. |
