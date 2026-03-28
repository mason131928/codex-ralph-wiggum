---
description: Cancel the active Ralph campaign in the current workspace
argument-hint: [--campaign-id ID]
allowed-tools: [Bash, Read]
---

# Cancel Ralph Campaign

This command only stops an existing Ralph campaign. Do not work on the task directly.

## Instructions

1. Resolve the helper script with Bash using the same lookup order as `/ralph:start`.
2. Run:

```bash
bash "<resolved-script-path>" campaign-cancel $ARGUMENTS
```

3. Report:
- cancelled campaign id
- new status
- whether the current loop was also cancelled
- the follow-up slash commands: `/ralph:campaign-status`, `/ralph:status`
