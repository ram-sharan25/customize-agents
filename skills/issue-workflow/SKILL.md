---
name: issue-workflow
description: Take one engineering issue from requirements to a reviewed, uncommitted implementation in a single session, by running the workflow's stage skills in order with the user approving each gate; reviews run as child sessions. The user does all commits, pushes, and PRs.
disable-model-invocation: true
---

# Issue Workflow

One issue, one session, the same stages as always. This skill does not
define any stage itself: it runs the stage skills in order, in this session,
and adds only what is particular to working from an issue. Each stage's rules
live in its own skill; read that skill when you enter the stage, and follow
it as written.

Shared rules: `/Users/rrimal/Stillness/Development/customize-agents/instructions/shared/workflow-conventions.md`.

## The sequence

| # | Stage | Skill | Gate before the next stage |
|---|---|---|---|
| 1 | Clarify requirements | `clarify-requirements` | user agrees the requirements are ready for review |
| 2 | Review requirements | `review-requirements`, as a child | user says "bring in"; findings resolved in stage 1's way |
| 3 | Plan | `plan-implementation` | user agrees the plan is ready for review |
| 4 | Review plan | `review-plan`, as a child | findings resolved; user finalizes the plan, or bypasses by name |
| 5 | Implement | `implement-plan` | **explicit implementation authorization** |
| 6 | Review implementation | `review-implementation`, as a child | findings resolved, then `implement-plan`'s wrap-up |

- Everything runs in one session; the stage skills' rule "the user starts
  the next stage" becomes "the user approves the gate", and you then read the
  next stage's skill and continue. You never cross a gate on your own, and
  "continue" crosses only the gate the user is looking at.
- The reviews are still independent: open each one as a child through the
  core launcher, exactly as the authoring stage's skill says
  (`agent-launch --child --skill review-plan …`). The child reads files only
  and never sees this session's chat. Never review your own work in this
  session instead.
- At each gate, print the stage skill's `next:` line anyway, so the user can
  move the work to a fresh session at any point; the documents carry
  everything a fresh session needs.
- A stage may be skipped only when the user names it ("skip the requirements
  review"). Record the skip in the affected document.

## Authorization

Invoking this skill authorizes stages 1 to 4. It does not authorize
implementation: requests such as "work on this issue", "run issue-workflow",
or "see whether this is needed" stop at the gate before stage 5. Enter stage 5
only when the user explicitly asks to implement (in the invoking message, in
this session, or recorded in `plan.org`); `implement-plan`'s preflight then
applies. Never infer authorization from a finished plan, an existing branch,
or uncommitted code.

## What is particular to an issue

- **The issue.** Read it, treating any fix it proposes as a hypothesis unless
  the user adopts it. Record `#+issue:` (full URL) in all three documents at
  stage 1, and register it: `emacs-share link linear "<issue URL>" "<ID>"`
  (`linear` is the kind for any issue URL, GitHub issues included).
- **The baseline.** For a shared repository, ground code claims in the freshly
  fetched upstream default branch: `git fetch origin` once per stage, the
  default branch from `git symbolic-ref refs/remotes/origin/HEAD` (ask when it
  is unset), and record `git rev-parse --short origin/<default>` as the
  repository's `#+baseline:`. Read the repository's `AGENTS.md` / `CLAUDE.md`
  before planning.
- **Research artifacts.** Only when the user asks: `artifacts/<topic>.org`,
  one subsystem or question each, with source evidence; the three documents
  link to them rather than repeat them.
- **Dashboard states** follow the stage skills (`PLANNING`, `REVIEW` while a
  review child works, `PLAN-REVIEW`, `IMPLEMENTING`, `IMPL-REVIEW`). Never
  set `PR-OPEN` or later; opening a PR is the user's.
- **After the user opens a PR.** When they share its URL, add `#+pr:` under
  `#+issue:` in `requirements.org` and `plan.org`, and run
  `emacs-share link pr "<PR URL>" "PR #<n>"`. Help with PR feedback only by
  investigating and proposing changes or reply text; edit files only when
  asked; never push, reply, or resolve threads.

## Resuming

A new session continues an issue from the documents alone: run this skill
with the task folder, read the three documents, and find the stage from the
statuses, the plan's task states, and the repository's working tree:

| What the documents show | Resume at |
|---|---|
| no `requirements.org`, or it is `DRAFT` | 1 |
| requirements `READY-FOR-REVIEW`, findings not linked | 2 |
| requirements done, no `plan.org` or plan `DRAFT` | 3 |
| plan `READY-FOR-REVIEW` | 4 |
| plan `FINAL` with tasks not `DONE`, and implementation authorized | 5 |
| every task `DONE`, implementation findings not resolved | 6 |
| plan `RECONCILED` | done |

Say which stage you resume at and why, register on the dashboard, and wait
at that stage's gate if it is one. Do not redo finished work because the chat
history is gone.

## End

The workflow ends after stage 6's wrap-up, with the changes staged, the
proposed commit messages listed, and the dashboard at `IMPL-REVIEW`. Print the
last stage's `next:` line, e.g.:

```
next: /review-implementation /Users/rrimal/Stillness/Agent_Stuffs/Plans/<project>/<task>/
```

and stay open. Committing, pushing, and opening the PR are the user's.

## Excuse / Reality

| Excuse | Reality |
|---|---|
| "I know this stage well; I don't need to read its skill." | Read the stage skill on entry. It is the only rulebook for that stage. |
| "Same session, so I can review my own plan." | Reviews are children that read files only. |
| "The plan is ready, so implementing is the obvious next step." | Implementation needs the user's explicit request. |
| "The user said continue." | Continue crosses only the gate in front of the user. |
| "I'll commit at the end so the PR is easy." | The user commits, pushes, and opens the PR. |
| "The chat has the context; the documents can catch up later." | Write it into the documents now; a fresh session must be able to resume. |
