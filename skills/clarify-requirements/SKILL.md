---
name: clarify-requirements
description: Guides user-owned requirements discovery, clarification, drafting, review handoffs, and explicit finalization in requirements.org. Use when discussing a vague task, creating or updating structured requirements, resolving review feedback, or finalizing requirements; do not use for an independent requirements review.
disable-model-invocation: true
---

# Clarify Requirements

Develop one authoritative `requirements.org` through a user-directed conversation. Do not make material choices for the user or cross into another lifecycle stage.

## Terms

- **Material decision:** a choice that can meaningfully change scope, risk, cost, feasibility, user-visible behavior, or acceptance.
- **Verified fact:** a claim supported by identified available evidence.
- **Assumption:** a claim currently treated as true without adequate verification.
- **Unresolved question:** an open issue whose answer may affect a material decision.
- **Review blocker:** a contradiction, infeasible or unsafe requirement, or outcome that cannot be verified.
- **Explicit reference:** a literal path, URL, citation, or named artifact in the requirements document, not an inferred neighboring source.
- **Explicit approval:** an unambiguous user instruction to perform the stated action; agreement with content is not automatically approval to write, finalize, or advance.
- **Explicit bypass:** an unambiguous user instruction to skip a named outstanding review stage.

## 1. Establish the requirements document

Before reading or writing planning files, discover and follow all applicable workspace instructions such as `AGENTS.md`. Defer to them; do not substitute this skill for workspace policy.

Resolve exactly one planning directory and confirm it with the user before clarification:

1. If the user gives an exact file or directory path, resolve it to one `requirements.org`. Report the resolved path and ask for confirmation.
2. Otherwise ask for a task name or short description. Search `/Users/rrimal/Stillness/Agent_Stuffs/Plans/` for matching planning directories or `requirements.org` files. Use path names and document titles first; inspect only enough candidate content to disambiguate.
3. For one match, report it and ask for confirmation. For multiple plausible matches, present a concise list and require the user to choose. Do not choose silently.
4. If there is no match, propose creating a planning directory; do not create it yet.

For a new task:

- Ask whether it belongs to an identifiable project. Use `/Users/rrimal/Stillness/Agent_Stuffs/Plans/<project>/<task>/` when it does and `/Users/rrimal/Stillness/Agent_Stuffs/Plans/<task>/` otherwise.
- Agree with the user on descriptive kebab-case project and task names.
- Re-check applicable instructions at the chosen location.
- Obtain explicit approval to initialize. Refuse to overwrite existing files silently.
- Copy `/Users/rrimal/Stillness/Agent_Stuffs/Plans/templates/requirements.org`, `decisions.org`, and `plan.org` into the directory, preserving their Org structure and header keywords as the workspace `AGENTS.md` describes. Customize titles as appropriate, but keep `#+status: DRAFT`; do not develop the plan during this stage.

## 2. Clarify one decision at a time

Maintain a compact working ledger that distinguishes confirmed decisions, verified facts with their evidence, assumptions, and unresolved questions.

Repeat until the requirements are ready for consolidation:

1. Select the highest-impact unresolved material decision.
2. Ask one concise, neutral, first-principles question. Let the user formulate an answer before giving options.
3. If the user is uncertain or asks for help, offer only a small relevant option set with concise trade-offs. Recommend an option only when explicitly asked, and label the rationale and uncertainty.
4. Verify material factual claims against available evidence where practical. Cite the evidence used. If verification is unavailable or disproportionate, identify the claim as an assumption or unresolved question instead of silently accepting it as fact.
5. Restate the proposed settled decision concisely and obtain confirmation before treating or recording it as settled.

Adapt language and depth to the domain. Probe a missed nuance only when it has a plausible material effect. Bound the probe to the decision at hand; stop when further inquiry is speculative, low-impact, reversible, or better deferred. Prefer convergence over exhaustive exploration.

## 3. Consolidate only with approval

Readiness is not approval. Suggest consolidation when these are sufficiently clear for the task:

- problem and reason for the work;
- desired outcome;
- in-scope and out-of-scope boundaries;
- material constraints;
- observable success or acceptance conditions; and
- all remaining material assumptions and unresolved questions are visible.

Show a concise proposed consolidation or change summary, then ask whether to update the initialized `requirements.org`. Write only after explicit approval. Keep that file authoritative for the problem and scope, and clearly separate facts, assumptions, and unresolved questions. Write confirmed decisions to `decisions.org` as short titled entries; the `* Decisions` section of `requirements.org` only points there. Do not hide open items merely to make the draft appear complete. Keep status `DRAFT` while clarifying; with the user's approval, set `READY-FOR-REVIEW` when handing the document to review.

If resolving agent-review or Plannotator feedback, discuss each material point through the same loop and apply only user-approved changes. Record changed or confirmed decisions in `decisions.org` and other review outcomes under its `* Review record`. A material change returns the document to `DRAFT`. Do not duplicate either review mechanism inside this skill.

## 4. Reviews and finalization

The default pre-finalization sequence is:

1. agent review in a fresh, user-started session using `review-requirements`;
2. human annotation in a separate user-directed invocation of the existing `plannotator` skill;
3. return to `clarify-requirements` to resolve feedback; and
4. explicit user finalization.

Track which reviews remain outstanding. At the current stage boundary, summarize the document path, status, unresolved items, and next suggested stage, then stop. Do not launch a review or a fresh session.

Honor an explicit bypass of either named review or both. A general request to continue is not a review bypass. If the user requests finalization while reviews remain, identify them and require either completion or an explicit bypass.

Change only the Org directive `#+status:` from `DRAFT` or `READY-FOR-REVIEW` to `FINAL` when the user unambiguously requests finalization and any outstanding reviews are completed or explicitly bypassed. Permission to plan or implement from a draft is a separate exception: record/report that authorization while retaining `DRAFT`.

After finalization, report the path and stop. By default, suggest that the user manually begin a fresh planning session with `plan-implementation`. If the user explicitly requests direct implementation from the confirmed `requirements.org`, report that authorization and stop; a separately user-started implementation agent may use that requirements document alone without requiring a `plan.org`. Do not produce a plan, review a plan, implement, or claim later user testing within this skill. Implementation is allowed only in a separately user-started implementation stage with an explicit implementation request.
