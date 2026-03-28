---
description: Watch Ralph loop or campaign progress live in the current workspace
argument-hint: [--loop-id ID] [--campaign-id ID] [--interval SEC] [--tail N]
allowed-tools: [Bash, Read]
---

# Watch Ralph Progress

This command opens Ralph's live terminal watch surface. Do not start, resume, or cancel work unless the user explicitly asked for that.

## Instructions

1. Resolve the helper script with Bash using the same lookup order as `/ralph:start`.
2. Run:

```bash
bash "<resolved-script-path>" watch $ARGUMENTS
```

3. Return the live terminal output as-is unless you need to trim only obvious shell noise.
