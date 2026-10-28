---
description: Stage a skill profile (research|implement|write|defense). Restart session to apply.
allowed-tools: Bash(profile:*)
---

Run the following bash command exactly, then report the output verbatim to the user (do not paraphrase):

```
profile $ARGUMENTS
```

After the command runs, remind the user that skill swaps only take effect after `Ctrl+D` followed by `claude --continue`. Do not perform any other action.
