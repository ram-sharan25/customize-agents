---
name: plan-implementation
description: Collaboratively creates or refines one implementation plan.org from one confirmed requirements.org, governing planning decisions, synchronization, review handoff, and explicit finalization. Use for implementation planning; do not use to clarify requirements, independently review a plan, or implement it.
---

# Plan Implementation

Develop one actionable `plan.org` with the user. Planning never authorizes implementation and this skill never implements, performs a plan review, invokes Plannotator, or starts another lifecycle stage.

## Terms

- **Material decision or change:** one capable of meaningfully affecting scope, correctness, risk, cost, feasibility, user-visible behavior, acceptance, or the approved approach.
- **Explicit approval:** an unambiguous user instruction to perform the stated action; agreement with content is not automatically approval to write, finalize, or advance.
- **Explicit bypass:** an unambiguous user instruction to skip a named outstanding review or lifecycle gate.
- **Verified fact:** a claim supported by identified available evidence.
- **Assumption:** a claim treated as true without adequate verification.
- **Unresolved decision:** an open choice whose outcome may affect a material decision.
- **Explicit reference:** a literal path, URL, citation, or named artifact in a planning document, not an inferred neighboring source.
- **Review blocker:** a contradiction, infeasible or unsafe plan, or outcome that cannot be verified.

## 1. Confirm the planning pair

Before reading or writing planning files, discover and follow all applicable `AGENTS.md` instructions. Defer workspace structure to those files.

Resolve exactly one planning directory under `/Users/rrimal/Stillness/Agent_Stuffs/Plans/` and exactly one `requirements.org` in it:

1. If the user supplies an exact file or directory, resolve it to one planning directory and its `requirements.org`.
2. Otherwise ask for a task name or description, search path names and Org titles, and inspect only enough candidate metadata to disambiguate.
3. Report the exact planning directory, requirements path, requirements status, expected sibling `plan.org`, and any repository path already recorded there.
4. For one match, require explicit user confirmation before substantive planning. For multiple candidates, list them and require a choice. Do not choose silently. If requirements are absent, stop and suggest a fresh `clarify-requirements` session.

A path included in the planning request still requires concise confirmation. Resolve one pair only; do not combine requirements documents.

## 2. Enforce requirements status

Require `#+status: FINAL` by default. If requirements are `DRAFT`, stop unless the user explicitly authorizes planning from those draft requirements. That authorization is distinct from finalizing requirements, finalizing the plan, bypassing reviews, or authorizing implementation.

After explicit draft-planning authorization, initialize or update the sibling `plan.org` and durably record:

- the exact `requirements.org` path;
- the authorization date and time, including timezone;
- all stated conditions or limits; and
- the statement that authorization neither finalizes requirements nor authorizes implementation.

A chat-only record is insufficient. Keep the plan `DRAFT` while requirements are `DRAFT` unless the user later separately and explicitly finalizes the plan against those draft requirements after completing or explicitly bypassing its reviews.

## 3. Initialize or preserve the plan

Use `/Users/rrimal/Stillness/Agent_Stuffs/Plans/templates/plan.org` and applicable workspace instructions for a new plan. Refuse silent overwrite. If `plan.org` exists, preserve useful content and propose material restructuring before applying it.

The plan must retain valid Org structure and identify durably:

- `#+status: DRAFT` or `#+status: FINAL`;
- its absolute planning-task directory;
- the exact sibling requirements path; and
- the absolute implementation repository path when applicable, otherwise an explicit `N/A`.

Do not infer a repository merely from nearby directories. Obtain confirmation for a material path choice.

## 4. Plan one material decision at a time

Maintain a concise ledger distinguishing settled decisions, verified facts with evidence, assumptions, risks, dependencies, and unresolved decisions.

For each highest-impact unresolved material implementation choice:

1. Ask one concise, neutral, first-principles question.
2. Let the user answer before presenting options.
3. Give a small option set, trade-offs, or a recommendation only if requested; label uncertainty.
4. Restate the proposed settled decision and obtain confirmation before recording it.

Never silently choose scope, architecture, dependencies, or risk trade-offs during normal planning. Stop probing when an issue is non-material, reversible, speculative, or better deferred, but record any unresolved material choice and its blocking effect.

Inspect repositories, source, or external material only when `requirements.org` explicitly requires it or the user authorizes it during this planning chat. Record planning-chat authorization and resulting evidence in `plan.org` or a literally referenced artifact, including enough source identification for a fresh review session. Do not broaden an explicit reference by inference.

If planning reveals a proposed scope or other requirements change, stop planning and suggest a fresh `clarify-requirements` session. Do not edit the requirement as a planning choice.

## 5. Keep an actionable synchronized plan

Keep heading-level alignment with `requirements.org` by default. Add a requirements-to-task matrix when complexity or ambiguity prevents reliable coverage verification, and record why stronger traceability is needed.

The plan must include:

- objective aligned to requirements;
- relevant current state, separating verified facts/evidence from assumptions;
- selected approach and rationale;
- phased, actionable tasks with progress states;
- explicit task and external dependencies;
- risks and mitigations;
- validation mapped to requirements and acceptance criteria;
- rollback or recovery;
- open decisions; and
- progress notes.

Keep tasks specific enough for another agent to execute, with ordering and expected verification. Keep the plan synchronized rather than preserving stale conclusions.

Synchronization rules:

- Any material requirements change sets both `requirements.org` and `plan.org` to `DRAFT`. Requirements then complete applicable review and explicit finalization before the synchronized plan does by default.
- The user retains a separate explicit exception to finalize a plan against `DRAFT` requirements; record that approval and do not alter requirements status.
- Any material change to a `FINAL` plan sets the plan to `DRAFT` until applicable plan reviews and explicit finalization recur.
- Non-material execution records—task state, validation result, and progress-note updates that do not alter requirements or the approved approach—may retain `FINAL`.
- Never treat authorization to plan, review bypass, finalization, and implementation permission as interchangeable.

## 6. Reviews, finalization, and stop boundary

The default plan sequence is:

1. fresh user-started agent review with `review-plan`;
2. separate user-directed human annotation with the installed `plannotator` skill;
3. return in a fresh `plan-implementation` session to resolve feedback; and
4. explicit user finalization.

Track outstanding reviews. Honor an explicit bypass of either named review or both; a general instruction to continue is not a bypass. If finalization is requested with reviews outstanding, require their completion or explicit bypass. Only an unambiguous user finalization request may change `#+status: DRAFT` to `#+status: FINAL`. Plan finalization is not implementation authorization.

End by reporting concisely the plan and requirements paths and statuses, repository path or `N/A`, unresolved items, and next suggested stage. Then stop. Never launch review, invoke annotation, implement, manage another stage, or imply that the current planning session can cross into implementation. Implementation requires a fresh user-started session, a separate explicit request, and artifact confirmation under global instructions.
