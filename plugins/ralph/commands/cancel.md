---
description: Cancel the active Ralph loop in the current workspace
argument-hint: [--loop-id ID]
allowed-tools: [Bash, Read]
---

# Cancel Ralph Loop

This command only requests cancellation and reports the result.

## Instructions

1. Resolve the helper script with Bash using the same lookup order as `/ralph:start`.
2. Run:

```bash
bash "<resolved-script-path>" cancel $ARGUMENTS
```

3. Return the cancellation result. Do not do additional cleanup beyond what the helper script already does.

