---
name: issue-workflow
description: Investigate, plan, implement, and review a non-trivial engineering issue in the current repository through an Org plan package in the Plans workspace and an explicit implementation gate. The user does all commits, pushes, and PRs.
disable-model-invocation: true
---

# Issue Workflow

Turn an engineering issue into an evidence-grounded plan and, when explicitly authorized, a reviewed uncommitted implementation, while preserving enough durable state for another agent to resume without conversation history.

## Authorization boundary

Invoking this skill authorizes investigation, discussion, and creation of the review package. It does not by itself authorize implementation. Treat phrases such as “work on this issue,” “determine whether this is required,” “run issue-workflow,” or “if required, run issue-workflow” as authorization for phases 1 and 2 only unless the user also explicitly asks to implement, execute, build, or fix the issue.

`READY-FOR-REVIEW` is a hard stop. After writing and validating the review package, report the conclusion, hand the files to the user to read, and wait for explicit implementation authorization. Do not edit implementation or test files, or mark a plan `FINAL`, based solely on the skill invocation or on the agent's conclusion that the ticket is valid.

Authorization may be present in the same user message that invokes the skill; no redundant approval is required when that message independently and explicitly requests implementation. A prior approval recorded in the current conversation or durable plan artifacts also suffices. When authorization is absent or ambiguous, stop at the gate.

Plan approval authorizes implementation and reconciliation, nothing more. Record an authorization needed for cross-session resume in `plan.org` as workflow state, not in the protected decision ledger.

## Git boundary

The user does every commit, push, and PR. On any branch or worktree, never run `git commit`, `push`, `reset`, `rebase`, or `stash`, and never create, edit, comment on, or resolve anything on a PR.

The agent may stage (`git add`), switch branches (`checkout`/`switch`), and create branches and worktrees. Use these to set up an implementation branch or worktree when the user has not designated one, and to stage changes in the proposed commit grouping. Never switch a worktree that has uncommitted changes.

Leave all implementation changes uncommitted. When work reaches a natural boundary, propose the conceptual commit grouping as text: which files go in each commit and its message. The user decides whether and how to commit.

## Planning workspace

All plan packages live in the Plans workspace, never in the implementation repository:

```text
/Users/rrimal/Stillness/Agent_Stuffs/Plans/<project>/<task>/
```

`<project>` is the implementation repository's name in kebab-case and `<task>` is a short descriptive kebab-case slug for the issue. Work that is not tied to a repository uses `Plans/<task>/` directly.

Before writing anything there, read `Plans/AGENTS.md` and `Plans/README.org`; they are the authoritative workspace rules and win over this skill on structure and format. Initialize the package from `Plans/templates/requirements.org`, `Plans/templates/plan.org`, and `Plans/templates/decisions.org`. All planning documents are Org files.

The Plans workspace is shared with other planning efforts. Write only the package files for the current task and leave unrelated changes alone.

## Baseline

Ground all code claims against the freshly fetched upstream default branch of the implementation repository, not the working tree, a feature branch, or memory. Run `git fetch origin` once at the start of a phase, then read upstream with `git show origin/<default>:<path>` and `git grep <pattern> origin/<default>`. Determine the default branch from `origin/HEAD` (`git symbolic-ref refs/remotes/origin/HEAD`) and fall back to asking the user if it is unset.

Record the baseline SHA (`git rev-parse origin/<default>`) in every package file. Revalidate affected claims if the upstream branch moves before implementation planning or reconciliation.

Read the implementation repository's `AGENTS.md` or `CLAUDE.md` when present, and any plan-style guide the repository ships, before authoring the package. When the repository provides none, follow the inverted-pyramid order described under `plan.org` below.

## Dashboard work links and state

When running inside an Emacs-managed agent session, keep the current issue, pull request, and workflow state visible on that session's dashboard row. If `EMACS_AGENT_SESSION_ID` is set and `emacs-share` is on `PATH`, register each known URL and report each phase transition:

```bash
emacs-share link linear "<full issue URL>" "<ISSUE-ID>"
emacs-share link pr "<full GitHub PR URL>" "PR #<number>"
emacs-share state PLANNING
```

Keep `linear` as the link kind for any issue URL, including GitHub issues: the dashboard only accepts the kinds `linear` and `pr` and refuses others.

Register the issue link as soon as the issue has been resolved to its full URL. Register the PR link once the user has opened the PR and given you its URL. On resume, register any links already recorded in the plan package or repository state; identical registrations are idempotent.

Report state at these points, and only these:

| Transition | State |
|---|---|
| Phase 1 begins | `PLANNING` |
| Package set to `READY-FOR-REVIEW` and the agent stops | `PLAN-REVIEW` |
| Phase 3 begins after explicit authorization | `IMPLEMENTING` |
| Phase 4 hand-off, implementation uncommitted and waiting for the user | `IMPL-REVIEW` |

Do not set `PR-OPEN` or any later state; opening a PR is the user's, and the workflow ends at phase 4.

This dashboard metadata supplements, but never replaces, the `Issue`, `PR`, and `#+status:` fields in the plan artifacts. If the command is unavailable or reports that the session is not Emacs-managed, continue the workflow without treating that as a blocker and without mentioning it again.

## Default artifact package

Use exactly this structure unless the user explicitly asks for additional research artifacts:

```text
Plans/<project>/<task>/
├── requirements.org
├── decisions.org
├── plan.org
└── artifacts/          # optional
```

Follow the workspace templates for section order. Use compact ASCII diagrams in `#+begin_example` blocks for plan visualizations; do not use Mermaid or another rendered diagram language unless the user explicitly requests it.

The files have separate jobs:

- `requirements.org` is the concise human-facing landing page: the problem, audience, desired outcome, scope, acceptance criteria, and selected direction.
- `decisions.org` is the durable review record and protected ledger of product and architectural decisions made by the user.
- `plan.org` is the source-grounded executable specification, current implementation status, and home of implementation-time discoveries and agent decisions.

The decision boundary is load-bearing. An agent may revise or supersede its own implementation judgment inside `plan.org` when evidence changes. It must not revise, weaken, or silently work around a decision in `decisions.org`; conflicting evidence requires challenging the decision and consulting the user first.

Every file identifies the issue, the `#+status:` (`DRAFT`, `READY-FOR-REVIEW`, `FINAL`, or `RECONCILED`), the synchronized baseline SHA, and directly related package files. `FINAL` is the Plans workspace's finalized state and here means the user explicitly approved the package for implementation. Once the user has opened a PR and shared its URL, `requirements.org` and `plan.org` also identify it immediately below the issue line.

### `requirements.org`

Start from the template and keep its sections. Put these keywords in the header after `#+status:`:

```org
#+issue: <full issue URL or ID>
#+pr: <PR URL>
#+baseline: <sha>
#+decisions: /Users/rrimal/Stillness/Agent_Stuffs/Plans/<project>/<task>/decisions.org
#+plan: /Users/rrimal/Stillness/Agent_Stuffs/Plans/<project>/<task>/plan.org
```

Omit the `#+pr:` line until the user shares a PR URL.

Keep it approachable and comparatively short. Explain the product or engineering gap without requiring the reader to know the implementation. State direct behavior, important exclusions, ownership boundaries, and the selected direction in plain language. The template's `* Decisions` section holds only a pointer to `decisions.org`, which is the authority.

`requirements.org` owns the stable problem statement and readable direction summary. Reflect active user decisions there, but keep their authoritative wording and provenance in `decisions.org`. Reconcile the summary after implementation without erasing or reinterpreting the ledger.

### `decisions.org`

Create this file with the package. It records decisions explicitly made or confirmed by the user during issue discussion, planning, review, or implementation. During plan review, it also records every user-requested change and every clarification outcome that changes, constrains, corrects, or confirms the plan. Do not record ordinary agent choices here, and do not treat a question by itself as a decision or change.

Record each current decision as a short titled statement:

```org
* <Decision title>

<The decision, stated plainly.>

<Optional rationale or important consequence, only when it adds useful context.>
```

The file itself establishes that these are current decisions made or confirmed by the user and that an agent must consult the user before changing them. Do not repeat that metadata on every entry. If an agent is unsure whether a statement was a decision, ask or leave it out rather than inventing authority.

Facts are not protected decisions: correct a disproven factual premise while preserving the user's intended outcome. When new evidence makes a genuine decision impossible, unsafe, contradictory, or materially different in cost or scope, record the evidence in `plan.org` and stop for the user's direction. Only the user may reaffirm, supersede, withdraw, or materially reinterpret a decision.

Keep non-decision review corrections and clarifications in a `* Review record` section so another agent can reconstruct how the plan changed without mistaking those notes for protected product decisions. Use short titled entries that state the user's request or clarification and its effect on the plan. Omit conversational questions that produced no plan-relevant outcome.

Preserve meaningful history without burdening current entries. When the user changes a decision, move the original text under an optional `* Superseded decisions` section and identify its replacement when useful. Do not add empty status, provenance, revisit, or supersession fields.

### `plan.org`

Start from the template and keep its sections and `#+` keywords. Add these keywords after `#+implementation-repository:`:

```org
#+issue: <full issue URL or ID>
#+pr: <PR URL>
#+baseline: <sha>
#+decisions: /Users/rrimal/Stillness/Agent_Stuffs/Plans/<project>/<task>/decisions.org
```

Omit the `#+pr:` line until the user shares a PR URL.

Preserve an inverted-pyramid order inside the template's sections: conceptual architecture first, design next, executable implementation last. Use this content shape, mapped onto the template:

- `* Objective` — the feature in one paragraph, aligned with `requirements.org`.
- `* Current state` — goals, non-goals, ownership boundaries, and an object-model sketch grounded in the baseline, with verified facts separated from assumptions.
- `* Proposed approach` — process flows plus failure and transaction invariants, and the selected design with its rationale.
- `* Phases and tasks` — ordered `** TODO Phase N — <conceptual unit>` headings with resumable checklists, concrete module responsibilities, caller migrations, and the files and symbols each phase touches.
- `* Dependencies`, `* Risks and mitigations`, `* Rollback or recovery` — as the template describes.
- `* Validation` — specific test cases mapped to desired behavior and failure modes, runnable verification commands, and checks that are unavailable.
- `* Open decisions` — unresolved choices that need the user.
- `* Implementation decisions` — add this section; see below.
- `* Progress notes` — task-state changes and discoveries during implementation.

The plan must name concrete module responsibilities, caller migrations, ordered phases, files, specific test cases, and runnable verification. Checklists are resumable state: unchecked before implementation, checked only when the work is actually complete. Avoid brittle line numbers and speculative symbol names; name a proposed symbol only after verifying the surrounding code.

Use `* Implementation decisions` only for unexpected evidence and non-routine choices made while implementing. Each entry records the discovery point, new evidence, agent decision, rationale, affected code, and which active user decisions constrain it. Routine coding choices do not belong there. Revise or supersede agent decisions freely when later evidence changes; preserve the history long enough to explain why the plan moved.

When an implementation question is resolved by the user, put the binding outcome in `decisions.org`; `plan.org` may link to it but must not become a second authority. If no unexpected judgment occurs, the section may simply say `None`.

Use this entry shape:

```org
** <Decision title>

- Status :: proposed | incorporated | superseded | deferred
- Discovered while :: <phase, task, or commit>
- New evidence :: <fact missing from the approved plan>
- Agent decision :: <what was chosen>
- Rationale :: <why>
- User decisions preserved :: <links to decisions.org entries>
- Affected artifacts/code :: <links>
```

After implementation, set the plan status to `RECONCILED`, describe the as-built system rather than the abandoned draft, check completed items, record actual verification results, reconcile each agent decision, and leave explicit future work visible.

## Optional research artifacts

Do not create files under `artifacts/` unless the user explicitly asks for research artifacts. This is most useful for large changes, unfamiliar systems, or issues whose direction depends on substantial context.

When requested, partition `artifacts/` by meaningful subsystem or question as `artifacts/<topic>.org`. Read [references/artifacts.md](references/artifacts.md) and follow its evidence contract.

Research files own detailed traces, callers, state transitions, failure behavior, tests, and source evidence. The three default files should summarize or link to those findings rather than reproduce them.

## Workflow

### 1. Ground and discuss

Report `PLANNING` to the dashboard. Read the issue while treating any proposed fix as a hypothesis unless the user adopts it. Inspect the baseline, trace the relevant callers and ownership boundaries, and identify the observable gap, desired behavior, non-goals, and material questions.

Explain the current system and viable direction to the user before freezing judgment-sensitive choices. Record every explicit user decision in `decisions.org`. Do not manufacture alternatives when one direction clearly follows from existing invariants.

### 2. Write the review package

Create `requirements.org` once the problem and direction are coherent. Create `decisions.org` with the user decisions that govern that direction. Create `plan.org` with the detailed architecture, flows, phases, file inventory, `Implementation decisions` section, and verification plan.

Review `requirements.org` and `plan.org` together against the code. Surface unresolved decisions and accidental scope expansion. Stop for the user's input when a missing choice would materially change the result.

Set a complete package to `READY-FOR-REVIEW`, report `PLAN-REVIEW` to the dashboard, tell the user the exact paths to read, and stop unless explicit implementation authorization already exists. Present the ticket-validity conclusion and proposed implementation scope without beginning branch or code work.

### 2a. Review and revise the plan

While the user reviews the package, answer questions from the recorded baseline and inspect more code when needed. Treat the review as an ongoing revision round: do not assume that a clarification, correction, or requested change applies only to the current reply.

Persist each plan-relevant outcome in `decisions.org` as it occurs so it survives context loss. Put binding user choices among the current decision entries, move replaced choices under `* Superseded decisions`, and put factual corrections or non-binding clarification outcomes under `* Review record`. Preserve distinct changes even when several arrive across separate messages; do not collapse away constraints or rationale that affect implementation.

Do not churn `requirements.org` and `plan.org` after every conversational exchange. At the end of the review round—when the user says the review is done, approves or authorizes implementation, or the workflow otherwise moves beyond plan review—re-read the complete `decisions.org` and reconcile both plan files together. Before accepting implementation authorization or handing the package off:

- apply every active decision and review-record change to the relevant problem statement, scope, architecture, phases, file list, and verification steps;
- remove or revise stale statements that conflict with the review outcomes while preserving superseded history in `decisions.org`;
- check `requirements.org`, `decisions.org`, and `plan.org` for internal consistency and unresolved questions;
- keep the package `READY-FOR-REVIEW` unless the user explicitly approved it, and set it to `FINAL` only when that approval is explicit; and
- tell the user the paths of every changed plan file again so they can see the reconciled version.

If the conversation pauses or the work must be handed off before the user explicitly ends the review, treat that pause as the end of the current review round and perform the same reconciliation before stopping. The durable files, not conversation memory, must contain every accepted change.

### Optional: independently verify the plan

When the user requests an independent check, or subagent delegation is otherwise explicitly authorized and the plan's complexity warrants it, ask a subagent to review the completed package without editing it. Give the reviewer the issue, baseline SHA, package paths, and these review goals:

- ground material claims against the recorded baseline;
- identify correctness gaps, hidden behavior changes, and ownership mistakes;
- look for a materially simpler implementation or verification strategy;
- return prioritized findings with concrete source evidence.

Evaluate the findings rather than accepting them mechanically. Reconcile supported corrections into the package, preserve every active user decision, and keep reviewer suggestions out of `decisions.org` unless the user adopts them. If revisions are material, a short second read-only pass may check internal consistency. This phase is optional and must not block implementation when it was not requested or justified.

### 3. Implement only with explicit authorization

Enter this phase only when the user has explicitly authorized implementation. Approval must come from the user; never infer it from a `READY-FOR-REVIEW` package, the absence of objections, or the invocation of this skill. Report `IMPLEMENTING` to the dashboard on entry.

Use the implementation repository recorded in `plan.org`, on the branch or worktree the user designated or one the agent creates for the task. Treat the plan as a reviewed hypothesis, not a substitute for inspecting current code. If implementation exposes a false assumption or requires a non-routine judgment, record it under `* Implementation decisions` in `plan.org`. Update the plan directly only when the correction preserves every active entry in `decisions.org`; otherwise challenge the conflicting decision and consult the user.

Leave production code, supporting artifacts, tests, and documentation uncommitted. Organize the work so it splits cleanly into reviewable conceptual commits, and propose that split as text per the git boundary.

### 4. Verify and reconcile

Review the actual diff independently against the goals and invariants. Validate field-level behavior and failure paths, not only whether tests pass.

Reconcile the package with the branch:

- `requirements.org` accurately summarizes the shipped behavior and boundaries;
- `decisions.org` preserves every user decision, including superseded history, and the implementation honors every active entry;
- `plan.org` describes the as-built architecture, completed checklist, and actual verification;
- every agent implementation decision in `plan.org` is incorporated, superseded, or deferred;
- remaining risks and follow-ups are explicit.

Then stop and hand off. Report `IMPL-REVIEW` to the dashboard. Report the changed files in the implementation repository and the Plans workspace, what is staged, the proposed commit split, and remaining risks. Committing, pushing, and opening the PR are the user's.

### 5. After the user opens a PR

The workflow ends at phase 4. If the user later asks for help with PR feedback, investigate it and propose code changes or reply text, but follow the git boundary: edit files only when asked, and never push, reply, or resolve threads. Register the PR link on the dashboard when the user shares its URL; do not change the dashboard state.

## Resume protocol

When continuing existing work, read in this order:

1. `requirements.org`
2. current entries in `decisions.org`, excluding `* Superseded decisions`
3. `plan.org`, including its status and checklists
4. unresolved entries under `* Implementation decisions`
5. only the optional research files linked by the active section
6. the current implementation branch, commits, and working-tree state, including uncommitted changes from a prior session

Determine the active phase from those artifacts and repository state, re-register dashboard links, and report the matching state. Do not repeat completed research merely because prior conversation history is unavailable.

If the package is `READY-FOR-REVIEW` and the current request or durable artifacts do not contain explicit implementation authorization, remain at the phase-2 hard stop. Do not infer authorization from an existing task branch, implementation checklist, or prior uncommitted code.
