# Durable artifact contracts

Use these contracts as section prompts, not boilerplate to reproduce mechanically. Omit feature-specific sections that do not apply, but never hide an unresolved decision by omission.

## Default directory shape

```text
/Users/rrimal/Stillness/Agent_Stuffs/Plans/<project>/<task>/
├── requirements.org
├── decisions.org
├── plan.org
└── artifacts/          # optional
```

This three-file package is the default:

- `requirements.org` is the short human-facing problem and plan summary.
- `decisions.org` is the protected ledger of decisions made by the user.
- `plan.org` is the executable plan, implementation status, agent-decision record, and reconciled as-built description.

Create files under `artifacts/` only when the user explicitly asks for research artifacts.

Every default artifact identifies the issue, its `#+status:` (`DRAFT`, `READY-FOR-REVIEW`, `FINAL`, or `RECONCILED`), the synchronized baseline SHA, and links to the other package files it depends on. The workspace rules in `Plans/AGENTS.md` and the templates in `Plans/templates/` take precedence over this file on structure and format.

Use absolute paths or Org file links between package documents. Ground ordinary code claims against the fetched upstream default branch (`origin/<default>`); use durable local source links when another agent needs to open the exact evidence. Do not treat the working tree or an implementation branch as the planning baseline.

## `requirements.org`

Owns the readable explanation of the issue and selected direction. A reviewer should understand the problem, intended outcome, scope, and broad plan without reading implementation details.

Follow the template order: overview, goals, non-goals, stakeholders, requirements, constraints, acceptance criteria, assumptions, open questions, decisions.

The header links to both `decisions.org` and `plan.org`.

Keep the problem independent of a proposed implementation. Explain the chosen direction only after the desired behavior is clear. Include important non-goals and ownership boundaries where a reader could otherwise infer broader scope.

Reflect active user decisions accurately, but do not make `requirements.org` their authority. The template's `* Decisions` section holds a pointer to `decisions.org`; the exact decision and its history live there.

After implementation, reconcile this file to the shipped behavior. It should remain a concise landing page, not grow into a duplicate implementation plan.

## `decisions.org`

Owns product, architectural, scope, and behavior decisions explicitly made or confirmed by the user. This file protects human judgment from being silently replaced when implementation uncovers new facts.

Each current decision is concise prose:

```org
* <Decision title>

<The decision, stated plainly.>

<Optional rationale or important consequence, only when it adds useful context.>
```

The file-level contract supplies ownership, current status, and the consult-before-changing rule. Do not repeat those facts as fields on every decision.

### Authority rules

- Record a decision only when the user actually made or confirmed it. If attribution is uncertain, ask or omit it.
- Facts are not decisions. Correct a factual premise when direct evidence disproves it, while preserving the user's intended outcome.
- An agent must not weaken, reinterpret, supersede, or work around a current decision on its own.
- New evidence may challenge a decision. Describe the evidence under `* Implementation decisions` in `plan.org`, and stop for the user's direction when the plan cannot remain correct while honoring it.
- Only the user may reaffirm, supersede, withdraw, or materially reinterpret a decision.
- Preserve meaningful history. When the user changes course, move the old text under an optional `* Superseded decisions` section and identify its replacement when useful rather than rewriting it.

Before implementation begins, audit `requirements.org` and `plan.org` against every current entry. A plan statement that contradicts the ledger is a defect even if the code could implement it.

## `plan.org`

Owns the executable plan and current implementation status. Follow the template sections and any plan-style guide the implementation repository ships; otherwise keep conceptual architecture first, design next, implementation instructions last.

At minimum include:

- header links to `requirements.org` and `decisions.org`, the implementation repository, and the baseline SHA;
- goals, non-goals, ownership, and an object-model sketch;
- component responsibilities and caller migrations;
- process flows plus failure and transaction invariants;
- ordered implementation phases with resumable checklists;
- concrete files and symbols after verifying them against the baseline;
- schema, backfill, flag, rollout, compatibility, and recovery work when applicable;
- specific tests mapped to desired behavior and failure modes;
- runnable verification commands and unavailable checks;
- explicit follow-up work outside the current PR;
- an `* Implementation decisions` section.

Avoid brittle line numbers and speculative symbol names. Name a proposed symbol only after verifying the surrounding code and ownership boundary.

### Implementation decisions

This section owns unexpected evidence and non-routine choices made by the agent while implementing. It is part of the plan because these choices revise or refine the executable design; a second file would split the plan's current truth from the reasons it changed.

Use:

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

Record an entry only when all are true:

1. Implementation exposed evidence not represented in the approved plan.
2. A non-routine choice was required.
3. A future agent could not reliably infer the rationale from final code and commits.

Do not record naming, formatting, ordinary refactors, or routine test organization. If later evidence changes an agent decision, supersede it in this section and reconcile the relevant plan text. If the user resolves the question, put the binding outcome in `decisions.org` and link it from here.

When there are no implementation-time decisions, write `None` rather than manufacturing entries.

### Reconciliation

After implementation:

- set the plan status to `RECONCILED`;
- describe the as-built architecture rather than an abandoned draft;
- check only work that is actually complete;
- record actual verification results;
- mark every agent decision incorporated, superseded, or deferred;
- confirm every active user decision remains honored;
- leave remaining risks and follow-ups visible.

## Optional `artifacts/<topic>.org`

Create research files only when the user explicitly asks for them, usually because the change is large, unfamiliar, or needs broader context.

Each file owns source-grounded understanding of one subsystem or question. Suggested sections:

1. Research question and boundary
2. Module responsibilities
3. Entry points and callers
4. Data and state transitions
5. Failure, retry, and cleanup behavior
6. Existing tests and coverage gaps
7. Findings with source evidence
8. Implications for the issue
9. Open questions

Distinguish direct evidence from inference. Record surprising negative evidence, such as an expected cleanup caller that does not exist. Describe the current upstream default branch; include focused history only when it proves a still-active compatibility constraint or invariant that current code cannot establish.

Research files support the default package. They do not replace `requirements.org`, `decisions.org`, or `plan.org`.

## Final reconciliation check

Confirm all of the following:

- The implementation satisfies the desired behavior summarized in `requirements.org`.
- Every active entry in `decisions.org` is honored.
- Every challenged decision was resolved by the user or remains an explicit blocker.
- Direction-level invariants are reflected in code.
- Every planned caller uses the intended ownership boundary.
- Tests cover identified failure and recovery behavior.
- Implementation checklists match the branch rather than intended future work.
- Every agent decision has a terminal status or explicit owner.
- Remaining risks and follow-ups are visible.
- The reconciled package files are written in the Plans workspace, ready for the user to commit.
