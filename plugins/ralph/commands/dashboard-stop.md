---
description: Stop the Ralph local dashboard for the current workspace
argument-hint: ""
allowed-tools: [Bash, Read]
---

# Stop Ralph Dashboard

This command only stops Ralph's local dashboard server.

## Instructions

1. Resolve the helper script with Bash using the same lookup order as `/ralph:start`.
2. Run:

```bash
bash "<resolved-script-path>" dashboard-stop
```

3. Report only the stop result and the dashboard workspace.
