---
name: clarify-requirements
description: Workflow stage 1. Clarifies one task's requirements with the user, one decision at a time, and writes requirements.org and decisions.org; also resolves requirements-review findings and finalizes on the user's word. Use to start a task, clarify or change requirements, or act on a requirements review; not for reviewing requirements, planning, or implementing.
disable-model-invocation: true
---

# Clarify Requirements

Turn a task into one clear `requirements.org` (what is needed and why) and a
`decisions.org` ledger of the user's decisions, through a conversation the
user leads. This stage never plans, implements, or starts another stage.

Shared rules: `/Users/rrimal/Stillness/Development/customize-agents/instructions/shared/workflow-conventions.md`.
Read it first; it covers path confirmation, the self-sufficient documents,
dashboard registration, children and report-back, findings files, user/agent
marking, statuses and gates, the `next:` line, and never closing the session.

## 1. Find or create the task

- A task folder or document path in the invoking message is confirmed (see
  the conventions). Otherwise ask for the task, search
  `/Users/rrimal/Stillness/Agent_Stuffs/Plans/` by folder name and `#+title:`,
  and let the user pick; never pick for them.
- A new task: agree on a kebab-case name (`Plans/<project>/<task>/` when it
  belongs to a project, else `Plans/<task>/`), get the user's okay, then copy
  the three templates from `/Users/rrimal/Stillness/Agent_Stuffs/Plans/templates/`.
  Never overwrite an existing file.
- Fill the headers from the start, in all three files:
  - `#+implementation-repository:` — one line per repository the work will
    touch, each followed by its own `#+baseline:` (that repository's HEAD now,
    `git -C <repo> rev-parse --short HEAD`). Write `N/A` when there is no
    repository. Ask the user which repositories; do not infer them from the
    current directory.
  - `#+issue:` when the work starts from an issue; remove the line otherwise.
- Then do the start-of-stage steps from the conventions: read the headers,
  check each baseline, and register:

```sh
emacs-share state PLANNING
emacs-share folder plans <task folder>
emacs-share folder code <repository>     # once per #+implementation-repository:
emacs-share link linear|pr <url>         # only when #+issue: is set
```

## 2. Clarify one decision at a time

Keep a short working list: confirmed decisions, verified facts (with their
evidence), assumptions, and open questions.

1. Pick the open question with the most effect on scope, risk, or acceptance.
2. Ask one short, neutral question. Let the user answer before you offer
   options. Offer two or three options with trade-offs only when the user is
   unsure or asks; recommend only when asked, with your reason.
3. Check factual claims against evidence when it is cheap (a file, a
   command). Otherwise record the claim as an assumption.
4. Restate the decision in one or two lines and get the user's confirmation
   before treating it as settled.

Stop probing when a question is minor, reversible, or better left to the plan.

## 3. What goes in the documents

- **What and why only.** Requirements say what is needed and why. How to
  build it belongs in the plan; when the user talks about the how, note it
  for the plan and keep it out of `requirements.org`.
- **Mark guesses.** Anything you filled in rather than the user said is
  marked *(agent's guess: <reason>)*, so the user and reviewers can tell the
  two apart.
- **Anti-goals.** Under `* Non-goals`, list outcomes that count as failure
  even if the work technically works (`- Anti-goal: …`). Ask for them.
- **Decisions.** Each confirmed decision is a short titled entry in
  `decisions.org` with a `Why:` line (the user's reason, or the agent's
  recommendation and the user's confirmation, with the date). The
  `* Decisions` section of `requirements.org` only points to `decisions.org`.
- **Acceptance criteria** are observable: someone can check each one with a
  command or by looking.
- Open questions and assumptions stay visible; never hide them to make the
  draft look done.

Write to the files only after the user agrees to the summary of changes you
show them. Keep `#+status: DRAFT` while clarifying.

## 4. Requirements review (a child)

When the user agrees the requirements are ready for review:

1. With their okay, set `requirements.org` (and `decisions.org`) to
   `READY-FOR-REVIEW`.
2. If the user wants the review opened from here, open it as a child (see
   "Children and report-back" in the conventions) and set
   `emacs-share state REVIEW`:

```sh
agent-launch --child --skill review-requirements --task <task folder> \
  --slug review-requirements --dir <task folder>/artifacts/<YYYY-MM-DD>-review-requirements \
  --brief <that dir>/brief.md --no-focus
```

   Otherwise set `emacs-share state PLAN-REVIEW` and print the `next:` line
   for a review the user starts themselves.
3. On the child's notice, follow "When a review child's notice arrives".
4. On "bring in": read the summary, then go through the findings with the
   user one by one, using the loop in section 2. Apply only changes the user
   approves. A material change returns the documents to `DRAFT`. Record
   decisions in `decisions.org`, other review outcomes under its
   `* Review record`, and link the findings file under `* Open questions`
   with whether it is resolved.

Human annotation (the `plannotator` skill) happens only when the user asks
for it, in its own invocation.

## 5. Finalize, then stop

Only an explicit "finalize" from the user sets `#+status: FINAL`. If a
review is outstanding, name it and ask whether to run it or bypass it; a
bypass must name the review. Permission to plan from a draft is not
finalization: record it in `requirements.org` and leave it `DRAFT`.

End the stage with `emacs-share state PLAN-REVIEW` (waiting on the user), a
few lines on the documents, their status, and what is open, then:

```
next: /plan-implementation <task folder>/
```

(or `next: /review-requirements <task folder>` while a review is still to
run). Stay open; the user closes the session.

## Excuse / Reality

| Excuse | Reality |
|---|---|
| "The user obviously wants X, I'll write it as a requirement." | Write it as *(agent's guess: <reason>)* or ask. Unmarked guesses look like decisions. |
| "This detail of how to build it is useful, I'll put it in." | How belongs in the plan. Note it for the plan. |
| "The requirements look done; I'll mark them FINAL." | Only the user's explicit word finalizes. |
| "I'll review the requirements myself to save time." | The review is a separate child that reads files only. |
| "They said continue, so the review is skipped." | A bypass names the review it skips. |
| "The stage is done, I'll start the plan now." | Print the `next:` line and stop. The user starts the next stage. |
| "The decision is clear without a reason." | Every `decisions.org` entry has `Why:`. |
