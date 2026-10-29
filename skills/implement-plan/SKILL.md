---
name: implement-plan
description: Workflow stage 5. Implements one task's plan.org test first, task by task, recording an Evidence part under each task and stopping at staged, uncommitted changes; opens the implementation review as a child and does the wrap-up after its fixes. Use only on an explicit request to implement a planned (or, when the user says so, requirements-only) task; not for planning or reviewing.
disable-model-invocation: true
---

# Implement Plan

Build what `plan.org` says, one task at a time, test first, with proof of
every claim written under the task. Changes end staged; the user commits.

Shared rules: `/Users/rrimal/Stillness/Development/customize-agents/instructions/shared/workflow-conventions.md`.
Read it first; it covers path confirmation, the self-sufficient documents,
dashboard registration, children and report-back, findings files, user/agent
marking, statuses and gates, the `next:` line, and never closing the session.
The git boundary in `core.md` holds throughout: never commit, push, reset,
rebase, or open a PR.

## 1. Preflight

Use exactly one branch. Plan-backed is the default; requirements-only only
when the user explicitly asks to implement from requirements without a plan.

**Plan-backed.**

1. Resolve exactly one `plan.org` (a path in the invoking message is
   confirmed) and pair it only with the `requirements.org` in the same folder.
2. Read every `#+implementation-repository:` and its `#+baseline:` from the
   plan.
3. Report in a few lines: the task folder, both documents and their
   `#+status:`, and each repository with its baseline (or `N/A`).
4. Get the user's explicit confirmation of those, unless the invoking
   message already named the task and asked to implement it.

If a document is missing, or a repository is needed but not recorded, stop
and ask how to proceed.

By default both documents must be `FINAL`. An explicit instruction to
"go forward and implement" bypasses unfinished requirements and plan reviews
and finalization. Under that bypass, you may decide unfinished choices yourself,
but never silently: record each one under `* Implementation decisions`. If a
choice changes or completes a requirement, update `requirements.org` first,
set both documents to `DRAFT`, and record it. Neither returns to `FINAL`
without its reviews and the user's word. Record the bypass under
`* Planning authorization` with the date and the user's words.

**Requirements-only.** Resolve one `requirements.org`; get the repository
from it or from the user (or an explicit `N/A`); report and confirm as above.
This branch never creates, reads for direction, or updates a `plan.org`.
Record requirement-affecting choices in `requirements.org` (setting it to
`DRAFT`); keep task Evidence in the chat or a file under `artifacts/` you
name.

## 2. Before the first task

1. Do the start-of-stage steps from the conventions, and register:

```sh
emacs-share state IMPLEMENTING
emacs-share folder plans <task folder>
emacs-share folder code <worktree>       # each worktree you work in
emacs-share link linear|pr <url>         # when #+issue: / #+pr: is set
```

2. **Worktree hygiene**: for each repository, check that you are in the
   worktree and branch the plan says, and note uncommitted changes that are
   not yours (`git status --short`). Leave them alone; never switch a
   worktree that has uncommitted changes.
3. **Baseline full-suite run**: run the project's full test suite once and
   record the command and result in `* Progress notes`. If it is not green,
   stop and report before changing anything.

## 3. Each task, test first

Read only the task at hand:
`~/.claude/skills/plan-implementation/scripts/extract-task <plan.org> <N>`.
Set its heading to `NEXT`, then:

1. Write the test the task gives.
2. Run it and see it **fail for the expected reason** (the message the task
   names, not a typo or a missing import). A test that passes at once, or
   fails for another reason, is not proof; fix the test first.
3. Write the minimal change that makes it pass. No extra features, options,
   or clean-ups the task does not ask for.
4. Run it and see it pass; then run the whole suite and see it green.
5. `git add` the task's files.
6. Write the task's **Evidence** part under its heading in `plan.org`, and
   set the heading to `DONE`:

```org
**** Evidence
| Claim       | Command          | Output excerpt              | Commit                |
|-------------+------------------+-----------------------------+-----------------------|
| Fails first | <test command>   | <the expected failure line> | —                     |
| Passes      | <test command>   | <pass line>                 | —                     |
| Full suite  | <suite command>  | <summary line>              | —                     |
| Staged      | git add <files>  | <git status --short lines>  | staged, not committed |
Proposed commit message: <message>
```

The commit column reads `staged, not committed` until the user commits; the
user's commit id is filled in at wrap-up. For text-only tasks (skills,
instructions, templates), the "test" is the structural check the task names.

**Subagents.** You may hand a task to a subagent with only that task's text
and the Global constraints. Check its claims against the diff and by running
the commands yourself, never against its report alone.

## 4. Decisions and deviations

- A judgment the plan did not settle (a name, an edge case, a library call)
  goes under `* Implementation decisions`: the choice, `Why:`, and
  `Cost if wrong:` (what breaks, and how hard it is to undo).
- A **material deviation** (one that changes scope, behavior the user sees,
  an approved approach, a dependency, or risk) stops for the user, unless the
  implementation request explicitly granted that discretion. A material
  change to requirements returns both documents to `DRAFT`; to the plan, the
  plan to `DRAFT`.
- Task states, Evidence, and progress notes are execution records; they do
  not change a document's status.

## 5. Implementation review (a child)

When every task is `DONE` and the suite is green:

1. Open the implementation review as a child (see "Children and
   report-back") and set `emacs-share state REVIEW`:

```sh
agent-launch --child --skill review-implementation --task <task folder> \
  --slug review-implementation \
  --dir <task folder>/artifacts/<YYYY-MM-DD>-review-implementation \
  --brief <that dir>/brief.md --no-focus
```

   If the user would rather start it themselves, set
   `emacs-share state IMPL-REVIEW` and print its `next:` line:

```
next: /review-implementation /Users/rrimal/Stillness/Agent_Stuffs/Plans/<task>/
```

2. On the child's notice, follow "When a review child's notice arrives"
   (the state is `IMPL-REVIEW`).
3. On "bring in", go through the findings with the user one at a time and
   apply only approved fixes, each test first with its own Evidence. Link the
   findings file under `* Progress notes` with whether it is resolved.

## 6. Wrap-up, right after the review fixes

1. Update `requirements.org`, `decisions.org`, and `plan.org` to describe
   what was built (the as-built result), including any decisions made on the
   way.
2. Fill in the commit column of each Evidence part with the user's commit ids
   once the user has committed (ask; never commit yourself).
3. Set `plan.org` to `RECONCILED` when the user agrees the documents describe
   the result and the commits are in.
4. End with `emacs-share state IMPL-REVIEW` (the user's move), a few lines on
   what is staged and the proposed commit messages, and a last `next:` line
   naming what remains: the review when it has not run yet, otherwise
   `next: commit the staged changes, then tell this session the commit ids`.

Stay open; the user closes the session.

## Excuse / Reality

| Excuse | Reality |
|---|---|
| "The change is tiny; a test is overkill." | Test first, every task. A text task's test is its structural check. |
| "The test passed straight away, good." | A test that never failed proves nothing. Make it fail for the expected reason first. |
| "While I'm here I'll tidy this up." | Minimal change. Anything else is a deviation to record or ask about. |
| "The subagent says it's done." | Check the diff and run the commands yourself. |
| "I'll commit this task so the history is clean." | Stage it and propose the message. The user commits. |
| "Evidence can go in the chat." | It goes under the task in `plan.org`. |
| "This deviation is obviously fine." | Material deviations stop for the user. |
| "I'll review my own diff." | The review is a child that reads files only. |
| "All tasks done; I'll close the session." | Stay open at `IMPL-REVIEW`. The user closes it. |
