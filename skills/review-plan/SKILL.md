---
name: review-plan
description: Performs a bounded, read-only review of one existing plan.org against its sibling requirements.org and reports material findings in chat. Use for independent plan review; do not use to clarify requirements, create or refine plans, finalize documents, or implement.
---

# Review Plan

Review exactly one implementation plan against its paired requirements without changing files or advancing the lifecycle.

## Terms and thresholds

- **Material decision or change:** one capable of meaningfully affecting scope, correctness, risk, cost, feasibility, user-visible behavior, acceptance, or the approved approach.
- **Explicit approval:** an unambiguous user instruction to perform the stated action; agreement with content is not automatically approval to write, finalize, or advance.
- **Explicit bypass:** an unambiguous user instruction to skip a named outstanding review or lifecycle gate.
- **Verified fact:** a claim supported by identified available evidence.
- **Assumption:** a claim treated as true without adequate verification.
- **Unresolved decision:** an open choice whose outcome may affect a material decision.
- **Explicit reference:** a literal path, URL, citation, or named artifact in either selected document, not an inferred neighboring source.
- **Review blocker:** a contradiction, infeasible or unsafe plan, or outcome that cannot be verified.

Always report blockers and material omissions, errors, or ambiguities. Report minor concerns only when they form a meaningful pattern or the user explicitly requests detailed review. Suppress isolated style issues and speculative edge cases by default.

## 1. Confirm exactly one document pair

Discover and follow applicable `AGENTS.md` instructions while remaining read-only. Instructions govern conduct but are not evidence for judging the plan.

1. If the user supplies an exact file or directory, resolve it to exactly one `plan.org` under `/Users/rrimal/Stillness/Agent_Stuffs/Plans/`.
2. Otherwise ask for a task name or description, search candidate paths and Org titles, and inspect only enough metadata to identify plausible matches.
3. Pair the selected plan only with `requirements.org` in the same planning directory. Never infer or substitute a requirements document elsewhere.
4. Report the exact plan and requirements paths and their statuses, then require explicit user confirmation before substantive review.

A path in the review request still requires concise confirmation. If selection is ambiguous, list candidates and stop for a choice. If either document is missing, report the missing pairing and stop; do not review another document or create anything.

## 2. Bound evidence and remain read-only

Review evidence is limited to:

- the confirmed `plan.org`;
- its confirmed sibling `requirements.org`; and
- literal sources explicitly referenced by either document, only when needed to assess a claim.

Do not inspect neighboring files, repositories, documentation, prior chats, or convention merely because they seem relevant. State each explicit reference followed and why. If a reference is ambiguous, inaccessible, sensitive, or invites broad exploration, report the verification gap instead of expanding scope.

Use read-only operations for discovery and review. Do not edit, create, format, annotate, finalize, clarify, plan, or implement. Findings belong only in chat, never in a file.

## 3. Review priorities

Assess in practical impact order:

1. correctness and internal consistency with the paired requirements;
2. complete requirements and acceptance-criteria coverage;
3. unauthorized scope, architecture, dependencies, trade-offs, or other material choices;
4. feasibility and relevant verified evidence or assumptions;
5. phase sequencing, task dependencies, and external dependencies;
6. material risks and mitigations;
7. validation adequacy and observability;
8. rollback or recovery; and
9. whether tasks, decisions, states, and handoffs make the plan actionable by another agent.

Check that verified facts cite evidence, assumptions remain labeled, and unresolved material decisions and blockers are visible. Verify stronger traceability when the plan says complexity requires it. Do not invent missing design choices or turn reviewer preferences into requirements.

Also identify lifecycle-invalid states when material changes appear to retain `FINAL`, draft-planning authorization is incomplete, a plan appears to authorize implementation, or the selected plan is stale against materially changed requirements.

## 4. Report and stop

Order findings by severity and impact. Use this exact shape for each finding:

```text
[BLOCKER|HIGH|MEDIUM|LOW] Short title
Problem: concise description grounded in the selected documents, including an Org heading or line reference when useful.
Why it matters: concrete effect on correctness, scope, feasibility, risk, sequencing, actionability, or verification.
```

Use `BLOCKER` for contradictions, infeasibility, unsafe plans, missing authoritative pairing, or unverifiable outcomes that prevent reliable progression. Use `HIGH` or `MEDIUM` for other material decision-impacting gaps. Use `LOW` only for a requested detailed review or a meaningful minor pattern.

If there are no reportable findings, say so and identify any material verification limitation; do not manufacture findings. State that the review was read-only. Identify the two reviewed paths and every explicit reference inspected.

Then stop. Do not edit or finalize either document, resolve feedback, start planning, invoke Plannotator, implement, or start another session. Suggest a fresh user-started `plan-implementation` session to resolve findings. Human annotation, if requested later, must use the separately loaded existing `plannotator` skill.
