---
description: Start a Ralph campaign that keeps launching new loops until a boundary checklist is honestly cleared
argument-hint: <goal> [--watch-active-loop] [--verify-cmd CMD] [--boundary-doc PATH] [--boundary-section TITLE] [--promise-prefix PREFIX]
allowed-tools: [Bash, Read]
---

# Start Ralph Campaign

This command launches Ralph's outer campaign orchestrator. Do not work on the repository directly in this command invocation.

## Instructions

1. Resolve the helper script with Bash:

```bash
if [ -x "./plugins/ralph/scripts/ralph-loop.sh" ]; then
  printf '%s\n' "./plugins/ralph/scripts/ralph-loop.sh"
elif [ -x "$HOME/plugins/ralph/scripts/ralph-loop.sh" ]; then
  printf '%s\n' "$HOME/plugins/ralph/scripts/ralph-loop.sh"
else
  echo "Ralph helper script not found. Expected ./plugins/ralph/scripts/ralph-loop.sh or \$HOME/plugins/ralph/scripts/ralph-loop.sh" >&2
  exit 1
fi
```

2. Run the helper with Bash and pass the user's arguments exactly once:

```bash
bash "<resolved-script-path>" campaign $ARGUMENTS
```

3. Report only the launcher result:
- campaign id
- status
- where campaign state/logs were created
- the follow-up slash commands: `/ralph:campaign-status`, `/ralph:campaign-cancel`, `/ralph:status`

4. If the helper exits non-zero, surface the error and stop.
