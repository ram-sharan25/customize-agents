---
name: fix-bug
description: Workflow child for one bug. Reproduces it, finds the root cause, fixes it test first with proof that the test catches the bug, stages the fix, and records everything in a findings file under the task's artifacts/; reports back to the session that opened it. Opened through agent-launch (C-c i w x, or C-c i w c x / dashboard c x as a child). Not for planned feature work.
disable-model-invocation: true
---

# Fix Bug

One bug, one child session, one findings file. You fix the bug the way the
implementation stage builds anything: a failing test first, the minimal fix,
the whole suite green, changes staged and never committed.

Shared rules: `/Users/rrimal/Stillness/Development/customize-agents/instructions/shared/workflow-conventions.md`.
Read it first; this skill uses its path confirmation, self-sufficient
documents, children and report-back, and `next:` line sections. The git
boundary in `core.md` holds: never commit, push, reset, or rebase.

## 1. Start

- You are usually a **child**, opened through the core launcher
  (`agent-launch --child --skill fix-bug …`): `EXPLORE_DIR` is your output
  directory and `LAUNCH_TASK` the task folder; the brief says what the bug
  is. Opened top-level (`C-c i w x`), the task path in the invoking message
  is confirmed; ask the user for the symptom and make your own directory
  `<task folder>/artifacts/<YYYY-MM-DD>-fix-bug-<slug>/`.
- Read the task's documents (`plan.org` first) for the repository, the
  baseline, and the test command.
- When `EMACS_AGENT_SESSION_ID` is set, register your row's folders
  (`emacs-share folder plans <task folder>`, `emacs-share folder code <worktree>`).
  Do not run `emacs-share state`: the parent's row holds the stage.

## 2. Work the bug, writing as you go

Keep `findings.md` in your output directory up to date as you work, with
these parts in this order:

1. **Symptom and exact reproduction** — what goes wrong, and the commands or
   steps that show it every time, with the output.
2. **Root cause** — what causes it, with evidence: the file and function,
   and the line of reasoning or the command that shows it.
3. **Ideas tried** — in order, each with its result, including the ones that
   did not work and why.
4. **A test that fails before the fix and passes after** — the test's name
   and file; the failing run (for the expected reason) and the passing run;
   then the full suite, green. The fix is the minimal change.
5. **Proof the test catches the bug** — revert the fix (only the fix), run
   the test and see it fail, restore the fix, run it and see it pass. Record
   all four runs.
6. **A note in plan.org** — one line under `* Progress notes` linking this
   file: `- <date>: bug fixed: <one line> — [[file:artifacts/<dir>/findings.md]]`.

Stage the test and the fix with `git add`, and end `findings.md` with the
staged files and a proposed commit message. If the fix needs a change the
plan or requirements did not foresee (scope, behavior the user sees, an
approach), stop and ask the user before making it.

## 3. Report back, stop

When the user says "report back" (or right away when the brief said to):

1. Write `summary.md` (at most 12 lines) next to `findings.md`.
2. Send the one-line notice and share the summary, as "Children and
   report-back" says: `fix-bug <slug> done — ready to bring in (<dir>)`.
3. Tell the user what is staged and the proposed commit message, then print
   the command for the session that continues the work, e.g.:

```
next: /implement-plan <task folder>/
```

Stay open; the user closes the session.

## Excuse / Reality

| Excuse | Reality |
|---|---|
| "I can see the fix; the test can come after." | Test first: it must fail for the bug's reason before the fix. |
| "The test fails, so it must catch the bug." | Revert, fail, restore, pass. Record all four. |
| "The first idea didn't work; no need to write it down." | Ideas tried, in order, with results, are part of the record. |
| "I'll commit the fix so it's safe." | Stage it and propose a message. The user commits. |
| "While I'm in here I'll fix this other thing." | One bug. Note the other one for the user. |
| "Done; I'll close this window." | Stay open. The user closes the session. |
