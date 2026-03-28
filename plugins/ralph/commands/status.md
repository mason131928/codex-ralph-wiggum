---
description: Show status for the active Ralph loop in the current workspace
argument-hint: [--loop-id ID] [--tail N] [--all]
allowed-tools: [Bash, Read]
---

# Ralph Status

This command inspects Ralph loop state only. Do not start, resume, or modify a loop unless the user explicitly asked for that.

## Instructions

1. Resolve the helper script with Bash using the same lookup order as `/ralph:start`.
2. Run:

```bash
bash "<resolved-script-path>" status $ARGUMENTS
```

3. Return the script output as-is unless you need to trim only obvious shell noise.

