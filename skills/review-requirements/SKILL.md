---
name: review-requirements
description: Performs a bounded, read-only review of one existing requirements.org and reports material findings in chat. Use when asked to critique, audit, or agent-review requirements; do not use to clarify, edit, finalize, plan, or implement.
disable-model-invocation: true
---

# Review Requirements

Review exactly one requirements document without changing files or advancing the workflow.

## Terms and thresholds

- **Material:** capable of meaningfully changing correctness, scope, risk, cost, feasibility, user-visible behavior, or acceptance.
- **Review blocker:** a contradiction, infeasible or unsafe requirement, or outcome that cannot be verified.
- **Explicit reference:** a literal path, URL, citation, or named artifact in the selected document, not an inferred neighboring file, repository, convention, or prior context.
- **Unresolved question:** an open issue whose answer could affect a material decision.

Always report blockers and material omissions or ambiguities. Report minor concerns only when they form a meaningful pattern or the user explicitly requests a detailed review. Omit isolated style issues and speculative edge cases by default.

## 1. Select exactly one document

Discover and follow applicable workspace instructions such as `AGENTS.md`, while remaining read-only. Defer to those instructions rather than restating workspace policy.

1. If the user supplies an exact file or directory path, resolve it to one `requirements.org`.
2. Otherwise ask for a task name or short description, then search `/Users/rrimal/Stillness/Agent_Stuffs/Plans/` using candidate paths and Org titles. Inspect only the minimum candidate metadata needed to identify plausible matches.
3. If there is one match, report its exact path and ask for confirmation. If there are multiple plausible matches, list them concisely and require the user to choose. If there is no match, say so and suggest using `clarify-requirements` to propose a new planning directory.
4. Do not begin review until the user confirms exactly one document.

A path supplied in the same message as an explicit request to review it still requires a concise confirmation before reading it substantively.

## 2. Bound the evidence

The selected `requirements.org` and its sibling `decisions.org`, when present, are the default and authoritative review evidence. Do not inspect neighboring plans, repositories, documentation, prior conversation artifacts, or other files merely because they appear relevant.

Follow another source only when the selected document explicitly references it and the source is needed to evaluate a requirement. State which reference is being followed and why. If a reference is ambiguous, inaccessible, sensitive, or would cause broad exploration, report the resulting verification gap rather than expanding scope. An applicable instruction file may govern conduct but is not evidence for judging the requirements.

Use read-only operations throughout discovery and review. Do not edit, create, format, or finalize any file, including the selected document and its references.

## 3. Review priorities

Assess, in this order of practical impact:

1. internal correctness and contradictions;
2. scope boundaries and ownership of material decisions;
3. feasibility, dependencies, and constraints;
4. safety, operational, and delivery risk;
5. user-visible behavior and material edge conditions; and
6. whether outcomes and acceptance criteria are observable and verifiable.

Distinguish requirements, confirmed decisions, assumptions, and unresolved questions. Flag unsupported claims only when their uncertainty matters. Do not invent missing product choices or turn preferences into requirements.

## 4. Report and stop

Order findings by severity and impact. Use this exact shape for each finding:

```text
[BLOCKER|HIGH|MEDIUM|LOW] Short title
Problem: concise description grounded in the selected document (include an Org heading or line reference when useful).
Why it matters: concrete effect on correctness, scope, feasibility, risk, user behavior, or verification.
```

Use `BLOCKER` for contradictions, infeasibility, unsafe requirements, or unverifiable outcomes that prevent reliable progression. Use `HIGH` or `MEDIUM` for other material decision-impacting gaps. Use `LOW` only for a requested detailed review or a meaningful minor pattern.

If there are no reportable findings, say so and mention any material verification limitation; do not manufacture findings. Report only in chat. State that the review was read-only and identify the reviewed path and any explicit references inspected.

Then stop. Do not edit or finalize requirements, start clarification, invoke Plannotator, create a plan, implement, or start another session. Suggest a fresh user-started `clarify-requirements` session for resolving findings. Human annotation, if requested later, must use the separately loaded existing `plannotator` skill rather than behavior copied here.
