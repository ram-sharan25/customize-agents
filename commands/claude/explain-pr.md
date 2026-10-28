---
description: "Explain what a PR does, why, and what could break"
argument-hint: "[PR number | URL | branch | nothing for current branch]"
allowed-tools: ["Bash", "Read", "Grep", "Glob"]
---

# Explain a PR

Target: "$ARGUMENTS" (empty means: the PR for the current branch)

Goal is **comprehension, not review**. Do not hunt for bugs or suggest
improvements unless asked. The reader wants to understand a change someone
else wrote, well enough to discuss it.

## 1. Gather

Resolve the target, then collect in one batch:

```
gh pr view <target> --json number,title,author,state,baseRefName,headRefName,body,additions,deletions,changedFiles,labels,url
gh pr diff <target>
gh pr view <target> --comments
gh pr view <target> --json commits --jq '.commits[] | .messageHeadline'
```

Bare number / URL / branch name all work as `<target>`. With no argument, plain
`gh pr view` resolves the current branch; if that fails, fall back to
`git diff --stat $(git merge-base HEAD origin/main)..HEAD` and say you are
explaining the branch, not a PR.

If the diff is very large, read the stat first, pick the files carrying the
actual logic, and read those closely — skip lockfiles, generated code,
snapshots, and pure formatting churn. Say which files you skipped.

Read surrounding context from the working tree for anything the diff alone does
not explain: the function being modified, the type being changed, the caller.
A diff hunk without its surroundings is usually unreadable, and guessing is
worse than looking.

## 2. Explain

Structure the answer this way. Keep it tight — prose, not bullet soup.

**The one-liner.** What this changes, in a sentence a teammate would accept.

**Why.** The motivation, from the PR body, linked issues, and commit messages.
If the stated why and the actual diff disagree, say so — that gap is the single
most useful thing you can surface.

**The shape of the change.** The 2–4 moving parts and how they relate. Lead
with the load-bearing change; everything mechanical that follows from it
(renames, signature updates at call sites, test fixups) gets one line as
follow-on, not its own section.

**File by file**, for files that matter — what changed and what role it plays.
Group the mechanical ones together.

**What could break.** Behavior changes visible to callers or users: API shape,
defaults, migrations, perf characteristics, error paths. Observation, not
criticism.

**Open questions.** What you could not determine from the diff — and for each,
exactly where to look or who to ask.

## 3. Rules

- Cite `file_path:line` so claims are clickable.
- Distinguish what the diff *shows* from what you *infer*. Mark inference.
- If the PR is trivial, say so in two sentences and stop. Do not pad the
  structure above onto a one-line change.
- Never commit, push, comment on, approve, or otherwise write to the PR. This
  command is read-only.
