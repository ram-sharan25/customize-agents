---
name: review-implementation
description: Workflow stage 6. Reviews the uncommitted implementation of one task against its plan.org, requirements.org, and decisions.org, reading files only, and saves a findings file in the task's artifacts/ — per-task Missing/Extra/Misunderstood, a verdict per decision, and met/not met with proof per acceptance criterion. Runs as a child of the implement-plan session (or in a fresh session the user starts). Not for fixing code or editing documents.
disable-model-invocation: true
---

# Review Implementation

Judge what was built against what was asked, so the builder does not grade
itself. You read files only (plus read-only commands such as `git diff` and
the test suite); you change nothing but your own findings.

Shared rules: `/Users/rrimal/Stillness/Development/customize-agents/instructions/shared/workflow-conventions.md`.
Read it first; this skill uses its path confirmation, findings-file format,
children and report-back, and `next:` line sections.

## 1. Where you are and what you review

- You are usually a **child**: `EXPLORE_DIR` is set, or your first prompt
  was a child brief. The task folder is the one in your prompt
  (`LAUNCH_TASK`); write your findings in `EXPLORE_DIR`.
- Started on your own by the user, the task path in the invoking message is
  confirmed; make your own output directory
  `<task folder>/artifacts/<YYYY-MM-DD>-review-implementation/`.
- Register your row's folders when `EMACS_AGENT_SESSION_ID` is set
  (`emacs-share folder plans <task folder>`, and
  `emacs-share folder code <repository>` once per repository you review),
  but never run `emacs-share state`: a review child sets no workflow state.

## 2. Evidence: the files and the working tree only

- Read `plan.org`, `requirements.org`, and `decisions.org`. Nothing from the
  implementer's chat reaches you; its Evidence parts are claims to check, not
  proof.
- The work is uncommitted. For each repository and each recorded baseline
  (`#+implementation-repository:` / `#+baseline:` pairs), compare:
  - committed changes since the baseline: `git -C <repo> diff <baseline>..HEAD`;
  - staged changes: `git -C <repo> diff --cached`;
  - the working tree: `git -C <repo> diff`;
  - new untracked files: `git -C <repo> status --short --untracked-files=all`.
- Run the tests and checks the plan names, read-only, to get your own proof.
  Never edit, stage, stash, reset, or commit; never fix what you find.

## 3. What to check

1. **Per task**, sort every problem into:
   - **Missing** — asked for (by the task, a requirement, or Global
     constraints) and not there;
   - **Extra** — built but not asked for, including files outside the File
     map that no Implementation decision explains;
   - **Misunderstood** — the right thing, built the wrong way.
   Also check the task's Evidence: the failing run was real and for the
   expected reason, and the passing and full-suite runs hold when you rerun
   them.
2. **Every `decisions.org` entry**: one line each — honored, not honored, or
   not applicable — with where you looked.
3. **Every acceptance criterion** in `requirements.org`: met or not met, with
   proof — the command you ran and its output, or what you inspected (file
   and function). "The implementer says so" is not proof.
4. **Each `* Review focus` case**, on purpose: try it, and say what happened.
5. `* Implementation decisions`: each has `Why:` and `Cost if wrong:`, and
   none is a material deviation the user did not approve.

## 4. Write the findings, report back, stop

1. Write `findings.md` in your output directory, in the conventions' format,
   with these sections before `## Findings`:

```markdown
## Per task
### Task 1 — <name>
- Missing: … | none
- Extra: … | none
- Misunderstood: … | none
- Evidence holds: yes | no — <why>

## Decisions
| decisions.org entry | Verdict | Where checked |

## Acceptance criteria
| Criterion | Met / not met | Proof (command and output, or what was inspected) |

## Review focus
| Case | What happened |
```

   Then `## Findings` (`BLOCKER` / `HIGH` / `MEDIUM` / `LOW`, most severe
   first) and `## Declined to judge`.
2. Write `summary.md` (at most 12 lines) next to it.
3. As a child, send the one-line notice and share the summary, as
   "Children and report-back" says:
   `review-implementation review-implementation done — ready to bring in (<dir>)`.
4. Tell the user in a few lines: the counts per severity, criteria met / not
   met, and where the findings are. Then print:

```
next: /implement-plan <task folder>/
```

   (in the parent session, the user says "bring in" instead). Stay open.

## Excuse / Reality

| Excuse | Reality |
|---|---|
| "The Evidence table says it passed." | Rerun it. Claims are not proof. |
| "This bug is a one-line fix; I'll just do it." | You change nothing. Report it with the fix you suggest. |
| "Only committed changes count." | The work is uncommitted: check staged, unstaged, and untracked too. |
| "That decision isn't relevant, skip it." | Every entry gets a verdict, even "not applicable". |
| "The criterion is obviously met." | Met needs proof: a command and its output, or what you inspected. |
| "I'll set IMPL-REVIEW when done." | A review child sets no workflow state; the parent does. |
