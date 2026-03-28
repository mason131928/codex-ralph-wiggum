---
description: Show status for the active Ralph campaign in the current workspace
argument-hint: [--campaign-id ID] [--tail N]
allowed-tools: [Bash, Read]
---

# Ralph Campaign Status

This command inspects Ralph campaign state only. Do not start, resume, or modify a campaign unless the user explicitly asked for that.

## Instructions

1. Resolve the helper script with Bash using the same lookup order as `/ralph:start`.
2. Run:

```bash
bash "<resolved-script-path>" campaign-status $ARGUMENTS
```

3. Return the script output as-is unless you need to trim only obvious shell noise.
