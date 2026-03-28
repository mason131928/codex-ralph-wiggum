---
description: Resume the most recent stopped Ralph loop in the current workspace
argument-hint: [--loop-id ID] [--additional-iterations N] [--max-iterations N]
allowed-tools: [Bash, Read]
---

# Resume Ralph Loop

This command only relaunches an existing Ralph loop. Do not work on the task directly.

## Instructions

1. Resolve the helper script with Bash using the same lookup order as `/ralph:start`.
2. Run:

```bash
bash "<resolved-script-path>" resume $ARGUMENTS
```

3. Report:
- resumed loop id
- new status
- whether max iterations were extended
- the follow-up slash commands: `/ralph:status`, `/ralph:cancel`

