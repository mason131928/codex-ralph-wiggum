---
description: Show whether the Ralph local dashboard is running for the current workspace
argument-hint: ""
allowed-tools: [Bash, Read]
---

# Ralph Dashboard Status

This command inspects Ralph dashboard state only.

## Instructions

1. Resolve the helper script with Bash using the same lookup order as `/ralph:start`.
2. Run:

```bash
bash "<resolved-script-path>" dashboard-status
```

3. Return the script output as-is unless you need to trim only obvious shell noise.
