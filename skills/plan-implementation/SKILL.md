---
name: plan-implementation
description: Workflow stage 3. Writes one task's plan.org from its requirements.org with the user, task by task in the test-first contract, then self-reviews and hands it to plan review; also resolves plan-review findings and finalizes on the user's word. Use for implementation planning; not to clarify requirements, review a plan, or implement.
disable-model-invocation: true
---

# Plan Implementation

Write one `plan.org` that an implementer can follow without making a naming,
file, or test choice, and that a reviewer can check line by line. Planning
never implements and never starts another stage.

Shared rules: `/Users/rrimal/Stillness/Development/customize-agents/instructions/shared/workflow-conventions.md`.
Read it first; it covers path confirmation, the self-sufficient documents,
dashboard registration, children and report-back, findings files, user/agent
marking, statuses and gates, the `next:` line, and never closing the session.

## 1. Start

1. Resolve the task folder (a path in the invoking message is confirmed).
   It must hold `requirements.org`; if not, stop and print
   `next: /clarify-requirements <task folder>`.
2. Requirements must be `FINAL`, unless the user explicitly says to plan from
   the draft. Record that permission in `plan.org` under
   `* Planning authorization`: the requirements path and status, date and
   time with timezone, the user's words, and any limits. It does not finalize
   anything and does not authorize implementation.
3. Do the start-of-stage steps from the conventions and register:

```sh
emacs-share state PLANNING
emacs-share folder plans <task folder>
emacs-share folder code <repository>     # once per #+implementation-repository:
emacs-share link linear|pr <url>         # only when #+issue: is set
```

4. Start `plan.org` from `/Users/rrimal/Stillness/Agent_Stuffs/Plans/templates/plan.org`
   when it does not exist; never overwrite one that does. Copy the
   repository and baseline lines from `requirements.org`, one
   `#+implementation-repository:` / `#+baseline:` pair per repository.
5. Read source code and other material only when the requirements point to
   it or the user allows it in this session; record that permission and what
   you read in `* Current state`.

## 2. Plan one decision at a time

For each open choice that affects scope, architecture, dependencies, or risk:
ask one short question, let the user answer, offer options only when asked,
restate, and get confirmation. A confirmed choice goes to `decisions.org`
with `Why:`; the plan links to it. If planning shows the requirements must
change, stop and print `next: /clarify-requirements <task folder>`; planning
does not edit requirements.

## 3. What plan.org contains

In this order (the template has every section):

- **`* Global constraints`** — the rules that bind every task, copied word
  for word from `requirements.org` (Constraints, Operational and quality
  requirements).
- `* Objective`, `* Current state` (verified facts with their evidence,
  separate from assumptions).
- **`* Proposed approach`** — every choice marked *(user, "<decisions.org
  title>")* or *(agent: <reason>)*.
- **`* Review focus`** — up to five cases a real user would hit that no test
  checks yet, most likely first. Each names the task whose test will pin it;
  the implementation reviewer checks each one on purpose.
- **`* File map`** — every file to create or change, one line each on what it
  is for. Not why the code is organized that way.
- **`* Phases and tasks`** — `** Phase N — <name>` headings, each holding
  `*** TODO Task N — <name>` headings, numbered across the plan.
- **`* Self-review`**, `* Dependencies`, `* Risks and mitigations`,
  `* Validation` (each acceptance criterion and the task that proves it),
  `* Rollback or recovery`, `* Open decisions`, `* Implementation decisions`
  (`None` until implementation), `* Progress notes`.

## 4. The task contract

Every task has these parts, so the implementer writes exactly one reasonable
thing at each step:

- **Files**: exact paths to create, change, and test, with the function or
  section to change. Never line numbers; they move.
- **Interfaces**: what the task uses from earlier tasks and what later tasks
  rely on, with exact names and signatures (parameters and return types).
- **Test**: the failing test, written out: its name and its assertions with
  the requirements' exact values. For skill or instruction text, a
  structural check that reads the file and asserts what the task requires.
- **Run (fail)**: the command, and the failure expected (which message, and
  why it fails).
- **Change**: the minimal change, by signature and file; a code block only
  for an algorithm the signature and the test do not determine.
- **Run (pass)**: the command and the expected pass, then the full suite.
- **Stage**: the `git add` line and a proposed commit message. The user
  commits; a task never does.

Fold setup and documentation into the task whose deliverable needs them.
Split tasks only where a reviewer could reject one and approve its neighbour.

Implementers read one task at a time with the extraction helper:
`~/.claude/skills/plan-implementation/scripts/extract-task <plan.org> <N>`.
Write each task so it stands on its own when read that way.

## 5. Self-review, then hand to review

Before `READY-FOR-REVIEW`, check and fix, then record under `* Self-review`
what you checked and what you changed:

- **Requirements coverage**: every requirement and acceptance criterion maps
  to a task in `* Validation`.
- **Vague lines**: "handle errors", "update as needed", "similar to Task 3" —
  replace with the exact thing.
- **Name and type consistency**: every name, signature, and path is spelled
  the same in every task and in the File map.
- **Review focus** cases each have an owning task with a test.
- **Proportion**: the number and size of tasks fit the scope.

Then, with the user's okay, set `plan.org` to `READY-FOR-REVIEW` and open the
plan review as a child (see "Children and report-back"); set
`emacs-share state REVIEW`:

```sh
agent-launch --child --skill review-plan --task <task folder> \
  --slug review-plan --dir <task folder>/artifacts/<YYYY-MM-DD>-review-plan \
  --brief <that dir>/brief.md --no-focus
```

If the user would rather start the review themselves, set
`emacs-share state PLAN-REVIEW` and print its `next:` line.

On the child's notice, follow "When a review child's notice arrives". On
"bring in", go through the findings with the user one at a time, apply only
approved changes, record user choices in `decisions.org` (others under its
`* Review record`), and link the findings file under `* Progress notes` with
whether it is resolved. A material change returns the plan to `DRAFT`.

## 6. Finalize, then stop

Only an explicit "finalize" from the user sets `#+status: FINAL`; name any
review still outstanding and require it or an explicit bypass that names it.
A material change to the requirements returns both documents to `DRAFT`.
Plan finalization is not permission to implement.

End with `emacs-share state PLAN-REVIEW`, a few lines on the documents, their
status, and what is open, then:

```
next: /implement-plan /Users/rrimal/Stillness/Agent_Stuffs/Plans/<task>/
```

Stay open; the user closes the session.

## Excuse / Reality

| Excuse | Reality |
|---|---|
| "The implementer can pick the names." | Names, files, signatures, and tests are the plan's job. |
| "Line 120 is where it goes." | Name the function or section; line numbers move. |
| "The constraints are in requirements.org already." | Copy them word for word into `* Global constraints`; tasks are read alone. |
| "Self-review is obvious; skip it." | Record what you checked and fixed. Reviewers start from it. |
| "I'll review my own plan in this session." | The review is a child that reads files only. |
| "The plan is good, I'll mark it FINAL." | Only the user's explicit word finalizes. |
| "Each task ends with a commit." | Each task ends staged, with a proposed message. The user commits. |
| "The plan is final, I'll start implementing." | Print the `next:` line and stop. |
