# Ralph for Codex

Ralph is a local plugin for Codex designed to turn "run the same task repeatedly until it's truly done" into a controllable, recoverable, and observable workflow.

It draws inspiration from the Ralph Wiggum concept in Claude Code, but is not a 1:1 port of the stop-hook model. More precisely: same loop philosophy, different runtime model. Ralph for Codex doesn't rely on undocumented stop hooks — instead, it treats every iteration as a fresh `codex exec`, persists state to disk, and exposes explicit `status`, `cancel`, `resume`, `watch`, `dashboard`, and `campaign` operations.

## Relationship to Claude Upstream

If you're familiar with Ralph Wiggum in Claude Code, there's exactly one key difference:

- Claude upstream: uses a stop hook inside the same session to prevent exit, letting the agent loop in place
- Ralph for Codex: uses an external, recoverable state machine to manage multiple fresh `codex exec` invocations

The tradeoff is that each iteration starts a new session. The benefit is transparent state, traceable failures, and the ability to `status` / `resume` / `cancel` — and it's also much easier to build `campaign` and a local dashboard on top.

## What Problem This Solves

A single `codex exec` works great for one-shot tasks. But for work like the following, you typically need a stateful loop:

- Fixing a failing test suite until everything is green
- Performing bounded refactors until a verification condition is met
- Repeating fix-and-verify cycles
- Waiting for a well-defined completion condition to be triggered

Ralph adds several critical capabilities on top of `codex exec`:

- A stable task prompt that doesn't drift across iterations
- Precise completion detection via `<promise>...</promise>`
- Persistent loop state written to `.ralph/`
- Support for pause, track, cancel, and resume
- Preserved handoff and iteration history for debugging and recovery
- Terminal watch and local dashboard so you always know what it's doing

## How It Works

Ralph doesn't intercept your current Codex session. The model is straightforward:

1. Write the task, loop config, and current state into the target workspace.
2. Launch a fresh `codex exec` each iteration.
3. Write output, handoff, and iteration history to `.ralph/loops/<loop-id>/`.
4. Stop only when:
   - The assistant output matches the specified completion promise
   - The maximum iteration count is reached
   - The loop is cancelled
   - Consecutive failures exceed the limit

This approach keeps state transparent, failures traceable, and behavior easy to reason about — without betting on the stability of undocumented runtime internals.

## Installation

### Using within this repo

If you open Codex directly inside this repository, the repo-local plugin is available immediately.

### Installing as a home directory plugin

Recommended approach:

```bash
./scripts/install-home-plugin.sh
```

The install script writes:

- `~/plugins/ralph`
- `~/.agents/plugins/marketplace.json`

Then reopen Codex.

For team installation and rollout guidance, see [docs/TEAM_INSTALL.md](docs/TEAM_INSTALL.md).

## Pre-release Checks

Static smoke test:

```bash
bash ./scripts/smoke-test.sh
```

For the full release process, see [docs/RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md).

## Quick Start

For first-time validation, run in foreground mode:

```text
/ralph:start --foreground --completion-promise DONE --max-iterations 5 fix the failing tests and output <promise>DONE</promise> only when everything is actually green
```

Check status:

```text
/ralph:status
```

Cancel the current loop:

```text
/ralph:cancel
```

Resume the most recent loop:

```text
/ralph:resume --additional-iterations 5
```

## Running via Shell

In addition to slash commands, you can invoke the runner directly:

```bash
./plugins/ralph/scripts/ralph-loop.sh start \
  --foreground \
  --completion-promise DONE \
  --max-iterations 5 \
  "fix the failing tests and output <promise>DONE</promise> only when everything is actually green"
```

Common subcommands:

```bash
./plugins/ralph/scripts/ralph-loop.sh status
./plugins/ralph/scripts/ralph-loop.sh cancel
./plugins/ralph/scripts/ralph-loop.sh resume --additional-iterations 5
```

## Supported Slash Commands

- `/ralph:start <task> [--completion-promise TEXT] [--max-iterations N] [--model MODEL]`
- `/ralph:status [--loop-id ID] [--tail N] [--all]`
- `/ralph:watch [--loop-id ID] [--campaign-id ID] [--interval SEC] [--tail N]`
- `/ralph:cancel [--loop-id ID]`
- `/ralph:resume [--loop-id ID] [--additional-iterations N] [--max-iterations N]`
- `/ralph:campaign <goal> [--watch-active-loop] [--verify-cmd CMD] [--boundary-doc PATH] [--boundary-section TITLE]`
- `/ralph:campaign-status [--campaign-id ID] [--tail N]`
- `/ralph:campaign-cancel [--campaign-id ID]`
- `/ralph:dashboard [--host HOST] [--port PORT] [--open-browser]`
- `/ralph:dashboard-status`
- `/ralph:dashboard-stop`

## Observability

If you'd rather not stare at raw files under `.ralph/`, there are three official entry points:

Live terminal view:

```text
/ralph:watch --tail 16
```

Or run directly via shell:

```bash
./plugins/ralph/scripts/ralph-loop.sh watch --tail 16
```

Local dashboard:

```text
/ralph:dashboard --open-browser
```

Or run directly via shell:

```bash
./plugins/ralph/scripts/ralph-loop.sh dashboard --open-browser
```

The dashboard starts a local HTTP server displaying:

- Active loop / campaign
- Recent iterations
- Last-iteration message summary
- Campaign boundary snapshot
- Verify log tail

Additional commands:

```text
/ralph:dashboard-status
/ralph:dashboard-stop
```

And the corresponding shell commands:

```bash
./plugins/ralph/scripts/ralph-loop.sh dashboard-status
./plugins/ralph/scripts/ralph-loop.sh dashboard-stop
```

## Where State Is Written

Ralph writes loop state into the current workspace:

```text
.ralph/
  active-loop
  loops/
    <loop-id>/
      state.env
      task.md
      prompt.md
      handoff.md
      last-output.txt
      iterations/
        0001/
        0002/
        ...
```

Key files:

- `state.env`: metadata for the current loop
- `handoff.md`: handoff content left by the previous iteration
- `iterations/<n>/final-message.txt`: the assistant's raw final output for that iteration
- `runner.log`: execution log in background mode

## Defaults

- `--max-iterations` = `20`
- `--approval-policy` = `never`
- `--sandbox` = `workspace-write`
- `--consecutive-error-limit` = `3`

`approval-policy=never` is intentional — an unattended loop has no way to answer approval prompts on your behalf.

## Background Mode

To verify stability on a given machine, start with foreground mode first:

```text
/ralph:start --foreground ...
```

Background mode is supported, but whether it stays alive long-term depends on the host environment:

- On macOS, `launchctl submit` is attempted first
- If unavailable, falls back to a detached child process
- Some managed shells or supervisors may still reap background processes

If a loop stops unexpectedly, check:

```text
/ralph:status
/ralph:resume
```

## When Ralph Is the Right Tool

Good fit:

- The task has an objective completion condition
- Completion can be verified by tests, files, or a command
- You want bounded automation with full traceability

Not a good fit:

- The task is fundamentally open-ended or exploratory
- The task requires ongoing human judgment
- The task is high-risk or destructive

## Project Structure

- `plugins/ralph/`: the Codex plugin itself
- `plugins/ralph/scripts/ralph-loop.sh`: the loop runner
- `.agents/plugins/marketplace.json`: repo-local plugin registry
- `scripts/install-home-plugin.sh`: helper to install into the home directory
- `docs/TEAM_INSTALL.md`: team installation guide

## Known Limitations

- This is a local plugin workflow, not a published marketplace package
- Background mode stability depends on the machine and shell supervision model
- The implementation deliberately avoids undocumented Codex stop-hook behavior, so it does not replicate Claude upstream's same-session loop semantics

## License

MIT — see [LICENSE](LICENSE).
