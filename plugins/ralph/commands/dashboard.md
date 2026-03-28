---
description: Start the Ralph local dashboard for the current workspace and return the URL
argument-hint: [--host HOST] [--port PORT] [--open-browser]
allowed-tools: [Bash, Read]
---

# Start Ralph Dashboard

This command only launches Ralph's local observability dashboard. Do not work on the repository directly in this command invocation.

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
bash "<resolved-script-path>" dashboard $ARGUMENTS
```

3. Report only the launcher result:
- dashboard URL
- workspace
- where dashboard state/logs were created
- the follow-up shell commands: `ralph-loop.sh dashboard-status`, `ralph-loop.sh dashboard-stop`

4. If the helper exits non-zero, surface the error and stop.
