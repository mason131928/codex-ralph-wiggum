---
description: Start a Ralph loop that keeps running codex exec against the current workspace
argument-hint: <task> [--completion-promise TEXT] [--max-iterations N] [--model MODEL] [--sandbox MODE] [--approval-policy POLICY]
allowed-tools: [Bash, Read]
---

# Start Ralph Loop

This command only launches the Ralph runner. Do not work on the task directly in this command invocation.

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
bash "<resolved-script-path>" start $ARGUMENTS
```

3. Report only the launcher result:
- loop id
- status
- where logs/state were created
- the follow-up slash commands: `/ralph:status`, `/ralph:cancel`, `/ralph:resume`

4. If the helper exits non-zero, surface the error and stop.

