# Ralph Plugin

Ralph is a Codex-compatible automation layer around `codex exec`.

It is inspired by the Ralph Wiggum technique from Claude Code, but intentionally uses different runtime semantics: an external, resumable state machine around fresh `codex exec` runs rather than an in-session stop-hook loop.

It now supports two modes:

- `loop mode`: keep rerunning the same task until a completion promise is emitted, the loop is cancelled, or limits are hit
- `campaign mode`: keep chaining new Ralph loops until a higher-level roadmap or boundary checklist is honestly cleared and repository verification still passes

And it now includes a third product layer:

- `observability mode`: a live terminal watch surface plus a local dashboard so you can see what Ralph is doing without tailing raw files by hand

## Commands

Loop mode:

- `/ralph:start <task> [--completion-promise TEXT] [--max-iterations N]`
- `/ralph:status [--loop-id ID] [--tail N] [--all]`
- `/ralph:watch [--loop-id ID] [--campaign-id ID] [--interval SEC] [--tail N]`
- `/ralph:cancel [--loop-id ID]`
- `/ralph:resume [--loop-id ID] [--additional-iterations N] [--max-iterations N]`

Campaign mode:

- `/ralph:campaign <goal> [--watch-active-loop] [--verify-cmd CMD] [--boundary-doc PATH] [--boundary-section TITLE]`
- `/ralph:campaign-status [--campaign-id ID] [--tail N]`
- `/ralph:campaign-cancel [--campaign-id ID]`

Observability:

- `/ralph:dashboard [--host HOST] [--port PORT] [--open-browser]`
- `/ralph:dashboard-status`
- `/ralph:dashboard-stop`
- `ralph-loop.sh watch [--interval SEC] [--tail N]`
- `ralph-loop.sh dashboard-status`
- `ralph-loop.sh dashboard-stop`

## Runtime Model

Ralph for Codex makes a deliberate tradeoff:

- it gives up the "same agent keeps going inside the same session" behavior
- it gains explicit state, resumability, cancellation, observability, and multi-round orchestration

If you need stable unattended execution, that tradeoff is usually worth it.

## Loop Mode

Loop mode is the original Ralph behavior:

- each iteration is a fresh `codex exec` session
- the working tree, git diff, handoff file, and prior final messages preserve context across iterations
- Ralph stops when one of these conditions is met:
  - the assistant outputs the exact completion promise
  - the loop hits its max-iteration limit
  - the loop is cancelled
  - `codex exec` fails repeatedly and crosses the configured error limit

## Campaign Mode

Campaign mode is for larger objectives that cannot be trusted to complete in a single Ralph loop.

It wraps multiple Ralph loops with an outer orchestrator that:

- optionally watches an already-running Ralph loop first
- runs a verification command after each completed round
- inspects a Markdown section that lists the remaining global boundaries
- launches the next Ralph round if boundaries still remain
- stops only when verification passes and the watched boundary section is empty

This is the built-in form of the external roadmap/autopilot scripts used during long-running repo upgrades.

### Default campaign assumptions

- `--verify-cmd` defaults to `npm run verify`
- `--boundary-doc` defaults to `docs/public-release.md`
- `--boundary-section` defaults to `Current Boundaries`
- `--promise-prefix` defaults to `SHIPIT`
- `--max-rounds` defaults to `0` which means unlimited
- `--loop-max-iterations` defaults to `0` which means unlimited per generated round

### Typical campaign example

Start a new campaign from scratch:

```bash
bash ./plugins/ralph/scripts/ralph-loop.sh campaign \
  --foreground \
  --verify-cmd "npm run verify" \
  --boundary-doc docs/public-release.md \
  --boundary-section "Current Boundaries" \
  "Finish the remaining roadmap honestly. Keep implementing the highest-leverage boundaries until the document no longer lists any current boundaries."
```

Attach a campaign to an already-running loop:

```bash
bash ./plugins/ralph/scripts/ralph-loop.sh campaign \
  --foreground \
  --watch-active-loop \
  "Continue this roadmap until the remaining boundaries are gone and verification still passes."
```

## Runtime Behavior

- The loop runner itself lives in `scripts/ralph-loop.sh`.
- Campaign state lives alongside loop state under `.ralph/campaigns/<id>/`.
- Dashboard state lives under `.ralph/dashboard/`.
- Background execution is still best-effort:
  - macOS: prefers `launchctl submit`
  - fallback: detached child process
  - if the host reaps detached children, use `--foreground` from a normal terminal

## Observability Layer

Ralph now exposes three ways to inspect progress:

- `status` and `campaign-status` for one-shot snapshots
- `watch` for a live terminal view that refreshes in place
- `dashboard` for a local HTTP UI with active loop, active campaign, recent iterations, boundary snapshots, and verify log tails

### Watch example

```bash
bash ./plugins/ralph/scripts/ralph-loop.sh watch --tail 16
```

### Dashboard example

```bash
bash ./plugins/ralph/scripts/ralph-loop.sh dashboard --open-browser
```

The dashboard exposes a local URL such as `http://127.0.0.1:43110` and reads only the workspace `.ralph/` state.

## Important Defaults

- Loop `--max-iterations` defaults to `20`
- Campaign `--loop-max-iterations` defaults to `0`
- `--approval-policy` defaults to `never`
- `--sandbox` defaults to `workspace-write`
- `--consecutive-error-limit` defaults to `3`

`approval-policy=never` is intentional: autonomous/background Ralph jobs cannot safely answer approval prompts.
