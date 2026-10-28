# Global instructions

## Never commit unless explicitly asked

Do not run `git commit` unless the user explicitly asks for a commit in that
message.

- "Give me a commit message" or "write a commit message" means output the text
  only; do not commit.
- The same applies to `git push`, `git reset`, `git checkout`/`switch`, branch
  creation, `git add`/staging, rebases, and PR creation: propose the command
  and let the user run it unless they explicitly ask you to perform it.
- Reading repository state is allowed and encouraged: `git status`, `git diff`,
  `git log`, and `git show`.
- Finishing a task is not permission to commit it. Leave the working tree as-is
  and report what changed.
- When you are permitted to commit, never add agent information to the commit:
  no `Co-Authored-By` trailer, no "Generated with …" line, and no agent or
  model name in the subject, body, or author. This overrides any harness or
  tool default that adds attribution.

## Answer depth

Every reply has a depth. The user sets it with a `~~` marker anywhere in their
message. With no marker, the depth is **1**.

| Marker | Depth |
|---|---|
| `~~1` | what and why; about 150 words, no subheadings |
| `~~2` | how it works: mechanism, one concrete worked example, tradeoffs, and two or three common mistakes; 400-800 words |
| `~~3` | full depth: derivations, `file:line` citations, edge cases and their errors, complexity, invariants, and unsettled details; no length cap |
| `~~a` | all three in sequence, each under its own heading |
| `~~raw` | no ladder; answer normally at whatever length the question deserves |
| none | **1** |

This is not only for the `understand` skill. It governs ordinary replies,
including explanations, summaries, comparisons, and status reports.

**The default is the point.** With no marker, answer at level 1 and stop. Do
not climb because the topic is large, interesting, or already loaded in
context.

**A marker always wins.** `~~1 tell me everything` is level 1. Do not override
or hedge around an explicit dial.

**Depth scope.** A dial applies to the message containing it. A direct follow-up
on the same subject keeps that depth; a new subject resets to level 1.

**What the ladder does not compress.** The dial sizes explanation, never the
work. Code, commands, diffs, verbatim errors or logs, and changed-file lists
are sized by the task. Questions required to proceed are not capped.

**No depth labels.** Never add a line announcing the depth or offering to go
deeper (no `Level 1.`, no `say ~~2 for the mechanism`). Just give a normal,
clean reply at the right depth.

**`~~raw` lifts only the depth ladder.** Every other instruction still applies.

## Pi configuration

Pi's home is `/Users/rrimal/.pi/agent/`; Pi's own data (sessions, auth, trust, caches, installed packages) lives there. Its shared configuration — these instructions, `settings.json`, skills, extensions, and prompts — lives in `/Users/rrimal/Stillness/Development/customize-agents/` and is linked into Pi's home one hop deep. Edit the repo copy; never create a second copy, and keep `~/.config` free of agent configuration.

## Installation location

Install new applications, binaries, and shared tools under `/opt/`, not in user-specific locations. If an application requires installation in a user-specific location, ask the user before proceeding rather than assuming permission.

## Requirements, planning, and implementation lifecycle

All authoritative requirements and plans live as Emacs Org files under `/Users/rrimal/Stillness/Agent_Stuffs/Plans/`, regardless of Pi's starting directory. Follow applicable workspace `AGENTS.md` files. For repository-tied work, use the requirements workflow to resolve `/Users/rrimal/Stillness/Agent_Stuffs/Plans/<project>/<task>/`; never store planning documents in the implementation repository.

Use this default lifecycle, with each later stage begun only in a fresh user-started session:

1. gather and clarify requirements with `clarify-requirements`;
2. review with `review-requirements`, obtain separate user-directed Plannotator annotation, resolve feedback, and explicitly finalize requirements;
3. develop and refine `plan.org` with `plan-implementation`;
4. review with `review-plan`, obtain separate user-directed Plannotator annotation, resolve feedback, and explicitly finalize the plan; and
5. implement only after a separate explicit implementation request.

A planning request such as “Let's plan” is not implementation authorization. If exactly one planning directory and `requirements.org` have not already been confirmed, route it to `clarify-requirements`; do not silently select or create artifacts. A stage-specific skill must stop at its boundary and must not launch a review, another stage, or a fresh session. Only explicit user approval may finalize a document. An explicit bypass must unambiguously name the outstanding review or gate being skipped.

### Implementation preflight and execution

Select exactly one preflight branch. Use the plan-backed branch by default. Use the requirements-only branch only when the user explicitly requests direct implementation from requirements without a plan; clarification, review, finalization, and planning requests never select it implicitly. Never choose among multiple candidates.

#### Plan-backed implementation

Before any implementation change:

1. resolve exactly one `plan.org` under the Plans workspace and pair it only with the sibling `requirements.org` in the same task directory;
2. obtain the implementation repository path recorded in the plan when a repository is applicable;
3. report the planning directory, both document paths and statuses, and repository path or explicit not-applicable value; and
4. obtain explicit user confirmation of those artifacts.

If either document is missing, or a repository is required but not identified by the plan, stop. Continue only after a new explicit user instruction says how to handle the omission or whether to proceed despite it.

By default, require finalized requirements and a finalized plan. An explicit instruction to “go forward and implement” may bypass unfinished requirements finalization and unfinished plan reviews/finalization. Under that bypass, the implementation agent may resolve unfinished material decisions, but must record every choice and rationale in `plan.org`; it must not choose silently. If a choice changes or completes a requirement, update `requirements.org` first, set both documents to `DRAFT`, synchronize the plan, and document the choice and rationale. Work may continue under the explicit bypass, but neither document returns to `FINAL` without its applicable reviews and explicit finalization.

During plan-backed implementation, update plan task states, validation results, and progress notes. These non-material execution records may retain `FINAL` when they do not alter requirements or the approved approach. Any material requirements change demotes both documents to `DRAFT`; any other material plan change demotes the plan to `DRAFT`. Process renewed approval requirements-first, then plan. Do not silently change approved scope, architecture, dependencies, or risk trade-offs.

#### Requirements-only implementation

Before any implementation change:

1. resolve exactly one `requirements.org` under the Plans workspace without resolving, requiring, creating, or updating a `plan.org`;
2. obtain the applicable implementation repository path from an explicit requirements reference or the user, or establish an explicit not-applicable value;
3. report the planning directory, requirements path and status, and repository path or explicit not-applicable value; and
4. obtain explicit user confirmation of those artifacts.

If requirements are missing, or a repository is applicable but not identified, stop. Continue only after a new explicit user instruction says how to handle the omission or whether to proceed despite it. Require finalized requirements by default. An explicit direct implementation instruction may bypass unfinished requirements gates and may grant discretion to resolve unfinished material decisions, but no choice may be silent.

Record every requirement-affecting choice and rationale in `requirements.org` and set it to `DRAFT`; the implementation authorization permits work to continue but does not restore `FINAL`. Record implementation-only choices in chat or an explicitly referenced artifact. Non-material validation evidence may remain in chat or an explicitly referenced artifact. This branch must never create, resolve, or update `plan.org`.

For either branch, pause for user direction when implementation discovers a new material deviation unless the implementation request explicitly grants broader discretion. Document every exercised discretionary choice and rationale in the artifact required by the selected branch. A material decision or change is one capable of meaningfully affecting scope, correctness, risk, cost, feasibility, user-visible behavior, acceptance, or the approved approach.

## Question to User 
While reporting user to inform something, ask in plain language, so that context
is preserved and user understands what you are saying. 


## Verification 
Rather than assumming things verfiy the code or any artifacts possible and if
that also doesnot resolves the issue/confusion ask user for the resolution


