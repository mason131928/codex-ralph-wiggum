#!/usr/bin/env bash

set -euo pipefail

SCRIPT_VERSION="1.2.0"
DEFAULT_MAX_ITERATIONS=20
DEFAULT_SANDBOX_MODE="workspace-write"
DEFAULT_APPROVAL_POLICY="never"
DEFAULT_CONSECUTIVE_ERROR_LIMIT=3
DEFAULT_CAMPAIGN_VERIFY_CMD="npm run verify"
DEFAULT_CAMPAIGN_BOUNDARY_DOC="docs/public-release.md"
DEFAULT_CAMPAIGN_BOUNDARY_SECTION="Current Boundaries"
DEFAULT_CAMPAIGN_PROMISE_PREFIX="SHIPIT"

main() {
  local command="${1:-}"
  if [[ -z "$command" ]]; then
    usage
    exit 1
  fi
  shift || true

  case "$command" in
    start) cmd_start "$@" ;;
    run) cmd_run "$@" ;;
    status) cmd_status "$@" ;;
    watch) cmd_watch "$@" ;;
    cancel) cmd_cancel "$@" ;;
    resume) cmd_resume "$@" ;;
    campaign) cmd_campaign "$@" ;;
    campaign-run) cmd_campaign_run "$@" ;;
    campaign-status) cmd_campaign_status "$@" ;;
    campaign-cancel) cmd_campaign_cancel "$@" ;;
    dashboard) cmd_dashboard "$@" ;;
    dashboard-status) cmd_dashboard_status "$@" ;;
    dashboard-stop) cmd_dashboard_stop "$@" ;;
    help|-h|--help) usage ;;
    *)
      die "Unknown command: $command"
      ;;
  esac
}

usage() {
  cat <<'EOF'
Ralph for Codex

Usage:
  ralph-loop.sh start [options] <task...>
  ralph-loop.sh status [--loop-id ID] [--tail N] [--all]
  ralph-loop.sh watch [--loop-id ID] [--campaign-id ID] [--interval SEC] [--tail N] [--once]
  ralph-loop.sh cancel [--loop-id ID]
  ralph-loop.sh resume [--loop-id ID] [--additional-iterations N] [--max-iterations N] [--foreground]
  ralph-loop.sh campaign [options] <goal...>
  ralph-loop.sh campaign-status [--campaign-id ID] [--tail N]
  ralph-loop.sh campaign-cancel [--campaign-id ID]
  ralph-loop.sh dashboard [--host HOST] [--port PORT] [--foreground] [--open-browser]
  ralph-loop.sh dashboard-status
  ralph-loop.sh dashboard-stop

Start options:
  --max-iterations N         Stop after N iterations. 0 means unlimited. Default: 20
  --completion-promise TEXT  Require exact <promise>TEXT</promise> to stop as complete
  --model MODEL              Override Codex model
  --profile PROFILE          Override Codex profile
  --sandbox MODE             read-only | workspace-write | danger-full-access
  --approval-policy POLICY   never | on-request | on-failure | untrusted
  --consecutive-error-limit N
                             Stop after N consecutive codex exec failures. Default: 3
  --add-dir DIR              Additional writable directory for codex exec (repeatable)
  --cwd DIR                  Workspace to run against. Default: current directory
  --foreground               Run loop in foreground instead of background

Resume options:
  --additional-iterations N  Extend finite max iterations by N. Default when needed: 10
  --max-iterations N         Set a new absolute max iteration value
  --completion-promise TEXT  Replace the completion promise before resuming
  --foreground               Resume in foreground instead of background

Watch options:
  --loop-id ID               Watch this loop instead of the active one
  --campaign-id ID           Also show this campaign instead of the active one
  --interval SEC             Refresh interval in seconds. Default: 3
  --tail N                   Last message or boundary tail size. Default: 20
  --cwd DIR                  Workspace to inspect. Default: current directory
  --once                     Render one snapshot and exit

Campaign options:
  --goal-file PATH           Read the high-level campaign goal from a file
  --watch-active-loop        Watch the current active Ralph loop before launching the next round
  --current-loop-id ID       Watch this existing Ralph loop before launching the next round
  --starting-round N         Force the watched loop's round number instead of inferring it
  --verify-cmd CMD           Command run after each completed round. Default: npm run verify
  --boundary-doc PATH        Markdown doc to inspect for remaining boundaries. Default: docs/public-release.md
  --boundary-section TITLE   Markdown heading title to inspect. Default: Current Boundaries
  --promise-prefix PREFIX    Promise prefix for generated rounds. Default: SHIPIT
  --max-rounds N             Stop after N watched/launched rounds. 0 means unlimited. Default: 0
  --loop-max-iterations N    Max iterations for each generated loop. 0 means unlimited. Default: 0
  --model MODEL              Override Codex model for generated loops
  --profile PROFILE          Override Codex profile for generated loops
  --sandbox MODE             read-only | workspace-write | danger-full-access
  --approval-policy POLICY   never | on-request | on-failure | untrusted
  --consecutive-error-limit N
                             Stop generated loops after N consecutive codex exec failures. Default: 3
  --add-dir DIR              Additional writable directory for generated loops (repeatable)
  --cwd DIR                  Workspace to run against. Default: current directory
  --foreground               Run the campaign in foreground instead of background

Dashboard options:
  --host HOST                Bind host for the local dashboard. Default: 127.0.0.1
  --port PORT                Bind port for the local dashboard. Default: 43110
  --cwd DIR                  Workspace to inspect. Default: current directory
  --foreground               Run the dashboard in foreground instead of background
  --open-browser             Open the dashboard URL after startup

State layout:
  <workspace>/.ralph/active-loop
  <workspace>/.ralph/loops/<loop-id>/
  <workspace>/.ralph/active-campaign
  <workspace>/.ralph/campaigns/<campaign-id>/
  <workspace>/.ralph/dashboard/
EOF
}

cmd_start() {
  require_cmd codex
  require_cmd perl

  local max_iterations="$DEFAULT_MAX_ITERATIONS"
  local completion_promise=""
  local model=""
  local profile=""
  local sandbox_mode="$DEFAULT_SANDBOX_MODE"
  local approval_policy="$DEFAULT_APPROVAL_POLICY"
  local consecutive_error_limit="$DEFAULT_CONSECUTIVE_ERROR_LIMIT"
  local workspace="$(pwd -P)"
  local foreground=0
  local -a add_dirs=()
  local -a task_parts=()

  while (($#)); do
    case "$1" in
      --max-iterations)
        max_iterations="$(require_value "$@")"
        shift 2
        ;;
      --completion-promise)
        completion_promise="$(require_value "$@")"
        shift 2
        ;;
      --model)
        model="$(require_value "$@")"
        shift 2
        ;;
      --profile)
        profile="$(require_value "$@")"
        shift 2
        ;;
      --sandbox)
        sandbox_mode="$(require_value "$@")"
        shift 2
        ;;
      --approval-policy)
        approval_policy="$(require_value "$@")"
        shift 2
        ;;
      --consecutive-error-limit)
        consecutive_error_limit="$(require_value "$@")"
        shift 2
        ;;
      --add-dir)
        add_dirs+=("$(abspath "$(require_value "$@")")")
        shift 2
        ;;
      --cwd)
        workspace="$(abspath "$(require_value "$@")")"
        shift 2
        ;;
      --foreground)
        foreground=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      --)
        shift
        while (($#)); do
          task_parts+=("$1")
          shift
        done
        ;;
      *)
        task_parts+=("$1")
        shift
        ;;
    esac
  done

  [[ -n "${task_parts[*]:-}" ]] || die "No task provided. Use: ralph-loop.sh start <task...>"
  validate_non_negative_int "$max_iterations" "max iterations"
  validate_non_negative_int "$consecutive_error_limit" "consecutive error limit"
  validate_sandbox_mode "$sandbox_mode"
  validate_approval_policy "$approval_policy"
  [[ -d "$workspace" ]] || die "Workspace does not exist: $workspace"

  local task="${task_parts[*]}"
  local loop_id
  loop_id="$(new_loop_id)"
  local loop_dir
  loop_dir="$(loop_dir "$workspace" "$loop_id")"
  mkdir -p "$loop_dir/iterations"

  local state_file="$loop_dir/state.env"
  local task_file="$loop_dir/task.md"
  local prompt_file="$loop_dir/prompt.md"
  local handoff_file="$loop_dir/handoff.md"
  local last_output_file="$loop_dir/last-output.txt"
  local completion_promise_file="$loop_dir/completion-promise.txt"
  local add_dirs_file="$loop_dir/add-dirs.txt"
  local runner_log="$loop_dir/runner.log"
  local active_loop_file
  active_loop_file="$(active_loop_file "$workspace")"

  printf '%s\n' "$task" > "$task_file"
  printf '%s\n' "$completion_promise" > "$completion_promise_file"
  : > "$last_output_file"
  : > "$handoff_file"
  if ((${#add_dirs[@]})); then
    write_lines "$add_dirs_file" "${add_dirs[@]}"
  else
    : > "$add_dirs_file"
  fi
  write_prompt_file "$prompt_file" "$loop_id" "$task_file" "$handoff_file" "$completion_promise_file"

  local status="created"
  local created_at updated_at
  created_at="$(timestamp_utc)"
  updated_at="$created_at"
  local iteration=0
  local pid=""
  local last_exit_code=""
  local consecutive_errors=0

  write_state "$state_file" \
    LOOP_ID "$loop_id" \
    STATUS "$status" \
    WORKSPACE "$workspace" \
    CREATED_AT "$created_at" \
    UPDATED_AT "$updated_at" \
    ITERATION "$iteration" \
    MAX_ITERATIONS "$max_iterations" \
    MODEL "$model" \
    PROFILE "$profile" \
    SANDBOX_MODE "$sandbox_mode" \
    APPROVAL_POLICY "$approval_policy" \
    PID "$pid" \
    LAST_EXIT_CODE "$last_exit_code" \
    LAST_OUTPUT_FILE "$last_output_file" \
    CONSECUTIVE_ERRORS "$consecutive_errors" \
    CONSECUTIVE_ERROR_LIMIT "$consecutive_error_limit" \
    SCRIPT_VERSION "$SCRIPT_VERSION"

  mkdir -p "$(dirname "$active_loop_file")"
  printf '%s\n' "$loop_id" > "$active_loop_file"

  if ((foreground)); then
    printf 'Started Ralph loop %s in foreground\n' "$loop_id"
    cmd_run --workspace "$workspace" --loop-id "$loop_id"
    return
  fi

  local script_path
  script_path="$(abspath "${BASH_SOURCE[0]}")"
  pid="$(spawn_background_runner "$workspace" "$loop_id" "$runner_log" "$script_path")"
  updated_at="$(timestamp_utc)"
  status="running"

  write_state "$state_file" \
    LOOP_ID "$loop_id" \
    STATUS "$status" \
    WORKSPACE "$workspace" \
    CREATED_AT "$created_at" \
    UPDATED_AT "$updated_at" \
    ITERATION "$iteration" \
    MAX_ITERATIONS "$max_iterations" \
    MODEL "$model" \
    PROFILE "$profile" \
    SANDBOX_MODE "$sandbox_mode" \
    APPROVAL_POLICY "$approval_policy" \
    PID "$pid" \
    LAST_EXIT_CODE "$last_exit_code" \
    LAST_OUTPUT_FILE "$last_output_file" \
    CONSECUTIVE_ERRORS "$consecutive_errors" \
    CONSECUTIVE_ERROR_LIMIT "$consecutive_error_limit" \
    SCRIPT_VERSION "$SCRIPT_VERSION"

  cat <<EOF
Started Ralph loop $loop_id
Status: running
Workspace: $workspace
State: $loop_dir
Runner log: $runner_log
Next:
  /ralph:status
  /ralph:cancel
  /ralph:resume
EOF
}

cmd_run() {
  require_cmd codex
  require_cmd perl

  local workspace=""
  local loop_id=""

  while (($#)); do
    case "$1" in
      --workspace)
        workspace="$(abspath "$(require_value "$@")")"
        shift 2
        ;;
      --loop-id)
        loop_id="$(require_value "$@")"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown run option: $1"
        ;;
    esac
  done

  [[ -n "$workspace" ]] || die "--workspace is required"
  [[ -n "$loop_id" ]] || die "--loop-id is required"

  local loop_dir
  loop_dir="$(loop_dir "$workspace" "$loop_id")"
  local state_file="$loop_dir/state.env"
  local task_file="$loop_dir/task.md"
  local prompt_file="$loop_dir/prompt.md"
  local handoff_file="$loop_dir/handoff.md"
  local last_output_file="$loop_dir/last-output.txt"
  local completion_promise_file="$loop_dir/completion-promise.txt"
  local add_dirs_file="$loop_dir/add-dirs.txt"
  local cancel_flag="$loop_dir/cancel-requested"
  [[ -f "$state_file" ]] || die "Loop state not found: $state_file"

  local child_pid=""
  trap 'handle_signal "$state_file" "$cancel_flag" "$child_pid"' INT TERM

  load_state "$state_file"
  local created_at="$CREATED_AT"
  local max_iterations="$MAX_ITERATIONS"
  local model="$MODEL"
  local profile="$PROFILE"
  local sandbox_mode="$SANDBOX_MODE"
  local approval_policy="$APPROVAL_POLICY"
  local iteration="$ITERATION"
  local consecutive_errors="$CONSECUTIVE_ERRORS"
  local consecutive_error_limit="$CONSECUTIVE_ERROR_LIMIT"
  local status="running"
  local updated_at
  updated_at="$(timestamp_utc)"

  write_state "$state_file" \
    LOOP_ID "$LOOP_ID" \
    STATUS "$status" \
    WORKSPACE "$WORKSPACE" \
    CREATED_AT "$created_at" \
    UPDATED_AT "$updated_at" \
    ITERATION "$iteration" \
    MAX_ITERATIONS "$max_iterations" \
    MODEL "$model" \
    PROFILE "$profile" \
    SANDBOX_MODE "$sandbox_mode" \
    APPROVAL_POLICY "$approval_policy" \
    PID "$$" \
    LAST_EXIT_CODE "$LAST_EXIT_CODE" \
    LAST_OUTPUT_FILE "$LAST_OUTPUT_FILE" \
    CONSECUTIVE_ERRORS "$consecutive_errors" \
    CONSECUTIVE_ERROR_LIMIT "$consecutive_error_limit" \
    SCRIPT_VERSION "$SCRIPT_VERSION"

  while true; do
    if [[ -f "$cancel_flag" ]]; then
      mark_terminal_state "$state_file" "cancelled" "$iteration" "$max_iterations" "$created_at" "$model" "$profile" "$sandbox_mode" "$approval_policy" "$LAST_EXIT_CODE" "$LAST_OUTPUT_FILE" "$consecutive_errors" "$consecutive_error_limit"
      rm -f "$cancel_flag"
      printf 'Loop %s cancelled before next iteration\n' "$loop_id"
      return 0
    fi

    if [[ "$max_iterations" != "0" ]] && (( iteration >= max_iterations )); then
      mark_terminal_state "$state_file" "max-iterations-reached" "$iteration" "$max_iterations" "$created_at" "$model" "$profile" "$sandbox_mode" "$approval_policy" "$LAST_EXIT_CODE" "$LAST_OUTPUT_FILE" "$consecutive_errors" "$consecutive_error_limit"
      printf 'Loop %s reached max iterations (%s)\n' "$loop_id" "$max_iterations"
      return 0
    fi

    local next_iteration=$((iteration + 1))
    local iter_dir="$loop_dir/iterations/$(printf '%04d' "$next_iteration")"
    mkdir -p "$iter_dir"
    cp "$prompt_file" "$iter_dir/prompt.md"
    cp "$task_file" "$iter_dir/task.md"

    local final_message_file="$iter_dir/final-message.txt"
    local session_output_file="$iter_dir/session-output.txt"
    local stderr_file="$iter_dir/stderr.txt"
    local git_status_file="$iter_dir/git-status.txt"
    local git_diff_stat_file="$iter_dir/git-diff-stat.txt"
    local started_at ended_at exit_code promise_text completion_promise
    started_at="$(timestamp_utc)"
    completion_promise="$(read_text_file "$completion_promise_file")"

    local prompt_text
    prompt_text="$(<"$prompt_file")"

    printf '[%s] Iteration %s started\n' "$(timestamp_utc)" "$next_iteration"
    run_codex_iteration "$workspace" "$sandbox_mode" "$approval_policy" "$model" "$profile" "$add_dirs_file" "$prompt_text" "$final_message_file" "$session_output_file" "$stderr_file" child_pid
    exit_code="$RUN_CODEX_ITERATION_EXIT_CODE"
    if (( exit_code == 0 )); then
      consecutive_errors=0
    else
      consecutive_errors=$((consecutive_errors + 1))
    fi

    ended_at="$(timestamp_utc)"
    printf '%s\n' "$started_at" > "$iter_dir/started-at.txt"
    printf '%s\n' "$ended_at" > "$iter_dir/ended-at.txt"
    printf '%s\n' "$exit_code" > "$iter_dir/exit-code.txt"

    git -C "$workspace" status --short >"$git_status_file" 2>/dev/null || true
    git -C "$workspace" diff --stat >"$git_diff_stat_file" 2>/dev/null || true

    if [[ ! -f "$final_message_file" ]]; then
      : > "$final_message_file"
    fi
    cp "$final_message_file" "$last_output_file"
    write_handoff_file "$handoff_file" "$loop_id" "$next_iteration" "$exit_code" "$started_at" "$ended_at" "$git_status_file" "$git_diff_stat_file" "$final_message_file" "$stderr_file"

    iteration="$next_iteration"
    updated_at="$(timestamp_utc)"
    write_state "$state_file" \
      LOOP_ID "$LOOP_ID" \
      STATUS "running" \
      WORKSPACE "$WORKSPACE" \
      CREATED_AT "$created_at" \
      UPDATED_AT "$updated_at" \
      ITERATION "$iteration" \
      MAX_ITERATIONS "$max_iterations" \
      MODEL "$model" \
      PROFILE "$profile" \
      SANDBOX_MODE "$sandbox_mode" \
      APPROVAL_POLICY "$approval_policy" \
      PID "$$" \
      LAST_EXIT_CODE "$exit_code" \
      LAST_OUTPUT_FILE "$last_output_file" \
      CONSECUTIVE_ERRORS "$consecutive_errors" \
      CONSECUTIVE_ERROR_LIMIT "$consecutive_error_limit" \
      SCRIPT_VERSION "$SCRIPT_VERSION"

    promise_text="$(extract_promise "$final_message_file")"
    if [[ -n "$completion_promise" ]] && [[ -n "$promise_text" ]] && [[ "$promise_text" == "$completion_promise" ]]; then
      mark_terminal_state "$state_file" "completed" "$iteration" "$max_iterations" "$created_at" "$model" "$profile" "$sandbox_mode" "$approval_policy" "$exit_code" "$last_output_file" "$consecutive_errors" "$consecutive_error_limit"
      printf 'Loop %s completed at iteration %s\n' "$loop_id" "$iteration"
      return 0
    fi

    if (( exit_code != 0 )) && (( consecutive_errors >= consecutive_error_limit )); then
      mark_terminal_state "$state_file" "failed" "$iteration" "$max_iterations" "$created_at" "$model" "$profile" "$sandbox_mode" "$approval_policy" "$exit_code" "$last_output_file" "$consecutive_errors" "$consecutive_error_limit"
      printf 'Loop %s failed after %s consecutive codex exec errors\n' "$loop_id" "$consecutive_errors"
      return "$exit_code"
    fi
  done
}

cmd_status() {
  local requested_loop_id=""
  local tail_lines=20
  local show_all=0
  local workspace="$(pwd -P)"

  while (($#)); do
    case "$1" in
      --loop-id)
        requested_loop_id="$(require_value "$@")"
        shift 2
        ;;
      --tail)
        tail_lines="$(require_value "$@")"
        shift 2
        ;;
      --all)
        show_all=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown status option: $1"
        ;;
    esac
  done

  validate_non_negative_int "$tail_lines" "tail lines"

  if ((show_all)); then
    print_all_loops "$workspace"
    return
  fi

  local loop_id
  loop_id="$(resolve_loop_id "$workspace" "$requested_loop_id")"
  local loop_dir
  loop_dir="$(loop_dir "$workspace" "$loop_id")"
  local state_file="$loop_dir/state.env"
  [[ -f "$state_file" ]] || die "Loop state not found: $state_file"
  refresh_state_if_stale "$state_file"
  load_state "$state_file"

  local completion_promise_file="$loop_dir/completion-promise.txt"
  local completion_promise
  completion_promise="$(read_text_file "$completion_promise_file")"

  cat <<EOF
Loop ID: $LOOP_ID
Status: $STATUS
Workspace: $WORKSPACE
Iteration: $ITERATION / $(format_max_iterations "$MAX_ITERATIONS")
Created: $CREATED_AT
Updated: $UPDATED_AT
PID: ${PID:-}
Model: ${MODEL:-default}
Profile: ${PROFILE:-default}
Sandbox: $SANDBOX_MODE
Approval policy: $APPROVAL_POLICY
Completion promise: ${completion_promise:-<none>}
Consecutive exec errors: $CONSECUTIVE_ERRORS / $CONSECUTIVE_ERROR_LIMIT
State dir: $loop_dir
EOF

  if [[ -f "$LAST_OUTPUT_FILE" ]] && [[ -s "$LAST_OUTPUT_FILE" ]]; then
    printf '\nLast message tail (%s lines):\n' "$tail_lines"
    tail -n "$tail_lines" "$LAST_OUTPUT_FILE"
  fi
}

cmd_watch() {
  local requested_loop_id=""
  local requested_campaign_id=""
  local interval_seconds=3
  local tail_lines=20
  local once=0
  local workspace="$(pwd -P)"

  while (($#)); do
    case "$1" in
      --loop-id)
        requested_loop_id="$(require_value "$@")"
        shift 2
        ;;
      --campaign-id)
        requested_campaign_id="$(require_value "$@")"
        shift 2
        ;;
      --interval)
        interval_seconds="$(require_value "$@")"
        shift 2
        ;;
      --tail)
        tail_lines="$(require_value "$@")"
        shift 2
        ;;
      --cwd)
        workspace="$(abspath "$(require_value "$@")")"
        shift 2
        ;;
      --once)
        once=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown watch option: $1"
        ;;
    esac
  done

  validate_non_negative_int "$interval_seconds" "watch interval"
  validate_non_negative_int "$tail_lines" "tail lines"
  [[ -d "$workspace" ]] || die "Workspace does not exist: $workspace"

  while true; do
    if (( ! once )); then
      clear_screen
    fi

    printf 'Ralph Watch\n\n'
    printf 'Workspace: %s\n' "$workspace"
    printf 'Rendered: %s\n' "$(timestamp_utc)"

    local campaign_id=""
    if [[ -n "$requested_campaign_id" ]]; then
      campaign_id="$requested_campaign_id"
    else
      campaign_id="$(resolve_active_campaign_id_optional "$workspace")"
    fi

    if [[ -n "$campaign_id" ]] && [[ -f "$(campaign_dir "$workspace" "$campaign_id")/state.env" ]]; then
      printf '\n=== Campaign ===\n'
      cmd_campaign_status --campaign-id "$campaign_id" --tail "$tail_lines"
    fi

    local loop_id=""
    if [[ -n "$requested_loop_id" ]]; then
      loop_id="$requested_loop_id"
    elif [[ -n "$campaign_id" ]] && [[ -f "$(campaign_dir "$workspace" "$campaign_id")/state.env" ]]; then
      local campaign_state_file
      campaign_state_file="$(campaign_dir "$workspace" "$campaign_id")/state.env"
      load_state "$campaign_state_file"
      loop_id="${CURRENT_LOOP_ID:-}"
    else
      loop_id="$(resolve_active_loop_id_optional "$workspace")"
    fi

    if [[ -n "$loop_id" ]] && [[ -f "$(loop_dir "$workspace" "$loop_id")/state.env" ]]; then
      printf '\n=== Loop ===\n'
      cmd_status --loop-id "$loop_id" --tail "$tail_lines"
    fi

    if [[ -z "$campaign_id" ]] && [[ -z "$loop_id" ]]; then
      printf '\nNo active Ralph loop or campaign found in %s\n' "$workspace"
    fi

    if (( once )); then
      return 0
    fi
    sleep "$interval_seconds"
  done
}

cmd_cancel() {
  local requested_loop_id=""
  local workspace="$(pwd -P)"

  while (($#)); do
    case "$1" in
      --loop-id)
        requested_loop_id="$(require_value "$@")"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown cancel option: $1"
        ;;
    esac
  done

  local loop_id
  loop_id="$(resolve_loop_id "$workspace" "$requested_loop_id")"
  local loop_dir
  loop_dir="$(loop_dir "$workspace" "$loop_id")"
  local state_file="$loop_dir/state.env"
  local cancel_flag="$loop_dir/cancel-requested"
  [[ -f "$state_file" ]] || die "Loop state not found: $state_file"
  refresh_state_if_stale "$state_file"
  load_state "$state_file"

  if [[ "$STATUS" != "running" ]] && [[ "$STATUS" != "cancel-requested" ]]; then
    cat <<EOF
Loop $LOOP_ID is not running.
Current status: $STATUS
EOF
    return 0
  fi

  : > "$cancel_flag"
  local result="Cancellation requested."
  if is_loop_running "$LOOP_ID" "${PID:-}"; then
    if [[ -n "${PID:-}" ]] && kill -0 "$PID" 2>/dev/null; then
      kill "$PID" 2>/dev/null || true
      local i
      for i in $(seq 1 30); do
        if ! kill -0 "$PID" 2>/dev/null; then
          result="Cancelled."
          break
        fi
        sleep 0.1
      done
      if [[ "$result" != "Cancelled." ]]; then
        result="Cancellation requested; runner still stopping."
        write_state "$state_file" \
          LOOP_ID "$LOOP_ID" \
          STATUS "cancel-requested" \
          WORKSPACE "$WORKSPACE" \
          CREATED_AT "$CREATED_AT" \
          UPDATED_AT "$(timestamp_utc)" \
          ITERATION "$ITERATION" \
          MAX_ITERATIONS "$MAX_ITERATIONS" \
          MODEL "$MODEL" \
          PROFILE "$PROFILE" \
          SANDBOX_MODE "$SANDBOX_MODE" \
          APPROVAL_POLICY "$APPROVAL_POLICY" \
          PID "$PID" \
          LAST_EXIT_CODE "$LAST_EXIT_CODE" \
          LAST_OUTPUT_FILE "$LAST_OUTPUT_FILE" \
          CONSECUTIVE_ERRORS "$CONSECUTIVE_ERRORS" \
          CONSECUTIVE_ERROR_LIMIT "$CONSECUTIVE_ERROR_LIMIT" \
          SCRIPT_VERSION "$SCRIPT_VERSION"
      else
        mark_terminal_state "$state_file" "cancelled" "$ITERATION" "$MAX_ITERATIONS" "$CREATED_AT" "$MODEL" "$PROFILE" "$SANDBOX_MODE" "$APPROVAL_POLICY" "$LAST_EXIT_CODE" "$LAST_OUTPUT_FILE" "$CONSECUTIVE_ERRORS" "$CONSECUTIVE_ERROR_LIMIT"
        rm -f "$cancel_flag"
      fi
    elif is_macos && command -v launchctl >/dev/null 2>&1; then
      if launchctl remove "$(launchd_label_for_loop "$LOOP_ID")" >/dev/null 2>&1; then
        mark_terminal_state "$state_file" "cancelled" "$ITERATION" "$MAX_ITERATIONS" "$CREATED_AT" "$MODEL" "$PROFILE" "$SANDBOX_MODE" "$APPROVAL_POLICY" "$LAST_EXIT_CODE" "$LAST_OUTPUT_FILE" "$CONSECUTIVE_ERRORS" "$CONSECUTIVE_ERROR_LIMIT"
        rm -f "$cancel_flag"
        result="Cancelled."
      else
        result="Cancellation requested; launchctl job still stopping."
      fi
    else
      result="Cancellation requested; runner still stopping."
    fi
  else
    mark_terminal_state "$state_file" "cancelled" "$ITERATION" "$MAX_ITERATIONS" "$CREATED_AT" "$MODEL" "$PROFILE" "$SANDBOX_MODE" "$APPROVAL_POLICY" "$LAST_EXIT_CODE" "$LAST_OUTPUT_FILE" "$CONSECUTIVE_ERRORS" "$CONSECUTIVE_ERROR_LIMIT"
    rm -f "$cancel_flag"
    result="Cancelled."
  fi

  printf 'Loop %s: %s\n' "$LOOP_ID" "$result"
}

cmd_resume() {
  require_cmd codex
  require_cmd perl

  local requested_loop_id=""
  local workspace="$(pwd -P)"
  local max_iterations_override=""
  local additional_iterations=""
  local completion_promise_override=""
  local foreground=0

  while (($#)); do
    case "$1" in
      --loop-id)
        requested_loop_id="$(require_value "$@")"
        shift 2
        ;;
      --max-iterations)
        max_iterations_override="$(require_value "$@")"
        shift 2
        ;;
      --additional-iterations)
        additional_iterations="$(require_value "$@")"
        shift 2
        ;;
      --completion-promise)
        completion_promise_override="$(require_value "$@")"
        shift 2
        ;;
      --foreground)
        foreground=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown resume option: $1"
        ;;
    esac
  done

  if [[ -n "$max_iterations_override" ]]; then
    validate_non_negative_int "$max_iterations_override" "max iterations"
  fi
  if [[ -n "$additional_iterations" ]]; then
    validate_non_negative_int "$additional_iterations" "additional iterations"
  fi

  local loop_id
  loop_id="$(resolve_loop_id "$workspace" "$requested_loop_id")"
  local loop_dir
  loop_dir="$(loop_dir "$workspace" "$loop_id")"
  local state_file="$loop_dir/state.env"
  local completion_promise_file="$loop_dir/completion-promise.txt"
  local task_file="$loop_dir/task.md"
  local prompt_file="$loop_dir/prompt.md"
  local handoff_file="$loop_dir/handoff.md"
  local last_output_file="$loop_dir/last-output.txt"
  local runner_log="$loop_dir/runner.log"
  local cancel_flag="$loop_dir/cancel-requested"
  [[ -f "$state_file" ]] || die "Loop state not found: $state_file"
  refresh_state_if_stale "$state_file"
  load_state "$state_file"

  if [[ "$STATUS" == "running" ]] && is_loop_running "$LOOP_ID" "${PID:-}"; then
    die "Loop $LOOP_ID is already running with PID $PID"
  fi

  local new_max_iterations="$MAX_ITERATIONS"
  if [[ -n "$max_iterations_override" ]]; then
    new_max_iterations="$max_iterations_override"
  elif [[ -n "$additional_iterations" ]]; then
    if [[ "$MAX_ITERATIONS" == "0" ]]; then
      new_max_iterations="0"
    else
      new_max_iterations=$((MAX_ITERATIONS + additional_iterations))
    fi
  elif [[ "$STATUS" == "max-iterations-reached" ]] && [[ "$MAX_ITERATIONS" != "0" ]]; then
    new_max_iterations=$((MAX_ITERATIONS + 10))
  fi

  if [[ -n "$completion_promise_override" ]]; then
    printf '%s\n' "$completion_promise_override" > "$completion_promise_file"
  fi
  write_prompt_file "$prompt_file" "$LOOP_ID" "$task_file" "$handoff_file" "$completion_promise_file"
  rm -f "$cancel_flag"

  write_state "$state_file" \
    LOOP_ID "$LOOP_ID" \
    STATUS "running" \
    WORKSPACE "$WORKSPACE" \
    CREATED_AT "$CREATED_AT" \
    UPDATED_AT "$(timestamp_utc)" \
    ITERATION "$ITERATION" \
    MAX_ITERATIONS "$new_max_iterations" \
    MODEL "$MODEL" \
    PROFILE "$PROFILE" \
    SANDBOX_MODE "$SANDBOX_MODE" \
    APPROVAL_POLICY "$APPROVAL_POLICY" \
    PID "" \
    LAST_EXIT_CODE "$LAST_EXIT_CODE" \
    LAST_OUTPUT_FILE "$last_output_file" \
    CONSECUTIVE_ERRORS 0 \
    CONSECUTIVE_ERROR_LIMIT "$CONSECUTIVE_ERROR_LIMIT" \
    SCRIPT_VERSION "$SCRIPT_VERSION"

  local script_path
  script_path="$(abspath "${BASH_SOURCE[0]}")"

  if ((foreground)); then
    printf 'Resumed Ralph loop %s in foreground\n' "$LOOP_ID"
    cmd_run --workspace "$WORKSPACE" --loop-id "$LOOP_ID"
    return
  fi

  local pid
  pid="$(spawn_background_runner "$WORKSPACE" "$LOOP_ID" "$runner_log" "$script_path")"

  write_state "$state_file" \
    LOOP_ID "$LOOP_ID" \
    STATUS "running" \
    WORKSPACE "$WORKSPACE" \
    CREATED_AT "$CREATED_AT" \
    UPDATED_AT "$(timestamp_utc)" \
    ITERATION "$ITERATION" \
    MAX_ITERATIONS "$new_max_iterations" \
    MODEL "$MODEL" \
    PROFILE "$PROFILE" \
    SANDBOX_MODE "$SANDBOX_MODE" \
    APPROVAL_POLICY "$APPROVAL_POLICY" \
    PID "$pid" \
    LAST_EXIT_CODE "$LAST_EXIT_CODE" \
    LAST_OUTPUT_FILE "$last_output_file" \
    CONSECUTIVE_ERRORS 0 \
    CONSECUTIVE_ERROR_LIMIT "$CONSECUTIVE_ERROR_LIMIT" \
    SCRIPT_VERSION "$SCRIPT_VERSION"

  cat <<EOF
Resumed Ralph loop $LOOP_ID
Status: running
Workspace: $WORKSPACE
State: $loop_dir
Runner log: $runner_log
Max iterations: $(format_max_iterations "$new_max_iterations")
Next:
  /ralph:status
  /ralph:cancel
EOF
}

cmd_campaign() {
  require_cmd codex
  require_cmd perl

  local workspace="$(pwd -P)"
  local goal_file_input=""
  local verify_cmd="$DEFAULT_CAMPAIGN_VERIFY_CMD"
  local boundary_doc_input="$DEFAULT_CAMPAIGN_BOUNDARY_DOC"
  local boundary_section="$DEFAULT_CAMPAIGN_BOUNDARY_SECTION"
  local promise_prefix="$DEFAULT_CAMPAIGN_PROMISE_PREFIX"
  local requested_current_loop_id=""
  local watch_active_loop=0
  local starting_round=""
  local max_rounds=0
  local loop_max_iterations=0
  local model=""
  local profile=""
  local sandbox_mode="$DEFAULT_SANDBOX_MODE"
  local approval_policy="$DEFAULT_APPROVAL_POLICY"
  local consecutive_error_limit="$DEFAULT_CONSECUTIVE_ERROR_LIMIT"
  local foreground=0
  local -a add_dirs=()
  local -a goal_parts=()

  while (($#)); do
    case "$1" in
      --goal-file)
        goal_file_input="$(require_value "$@")"
        shift 2
        ;;
      --watch-active-loop)
        watch_active_loop=1
        shift
        ;;
      --current-loop-id)
        requested_current_loop_id="$(require_value "$@")"
        shift 2
        ;;
      --starting-round)
        starting_round="$(require_value "$@")"
        shift 2
        ;;
      --verify-cmd)
        verify_cmd="$(require_value "$@")"
        shift 2
        ;;
      --boundary-doc)
        boundary_doc_input="$(require_value "$@")"
        shift 2
        ;;
      --boundary-section)
        boundary_section="$(require_value "$@")"
        shift 2
        ;;
      --promise-prefix)
        promise_prefix="$(require_value "$@")"
        shift 2
        ;;
      --max-rounds)
        max_rounds="$(require_value "$@")"
        shift 2
        ;;
      --loop-max-iterations)
        loop_max_iterations="$(require_value "$@")"
        shift 2
        ;;
      --model)
        model="$(require_value "$@")"
        shift 2
        ;;
      --profile)
        profile="$(require_value "$@")"
        shift 2
        ;;
      --sandbox)
        sandbox_mode="$(require_value "$@")"
        shift 2
        ;;
      --approval-policy)
        approval_policy="$(require_value "$@")"
        shift 2
        ;;
      --consecutive-error-limit)
        consecutive_error_limit="$(require_value "$@")"
        shift 2
        ;;
      --add-dir)
        add_dirs+=("$(abspath "$(require_value "$@")")")
        shift 2
        ;;
      --cwd)
        workspace="$(abspath "$(require_value "$@")")"
        shift 2
        ;;
      --foreground)
        foreground=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      --)
        shift
        while (($#)); do
          goal_parts+=("$1")
          shift
        done
        ;;
      *)
        goal_parts+=("$1")
        shift
        ;;
    esac
  done

  [[ -d "$workspace" ]] || die "Workspace does not exist: $workspace"
  validate_non_negative_int "$max_rounds" "max rounds"
  validate_non_negative_int "$loop_max_iterations" "loop max iterations"
  validate_non_negative_int "$consecutive_error_limit" "consecutive error limit"
  if [[ -n "$starting_round" ]]; then
    validate_non_negative_int "$starting_round" "starting round"
  fi
  validate_sandbox_mode "$sandbox_mode"
  validate_approval_policy "$approval_policy"
  [[ -n "$verify_cmd" ]] || die "--verify-cmd requires a non-empty command"
  [[ -n "$boundary_section" ]] || die "--boundary-section requires a non-empty heading title"
  [[ -n "$promise_prefix" ]] || die "--promise-prefix requires a non-empty value"

  local goal=""
  if [[ -n "$goal_file_input" ]]; then
    local goal_file_abs
    goal_file_abs="$(abspath_from "$workspace" "$goal_file_input")"
    [[ -f "$goal_file_abs" ]] || die "Goal file not found: $goal_file_abs"
    goal="$(<"$goal_file_abs")"
  elif [[ -n "${goal_parts[*]:-}" ]]; then
    goal="${goal_parts[*]}"
  fi
  [[ -n "$goal" ]] || die "No campaign goal provided. Use positional text or --goal-file PATH"

  local current_loop_id=""
  if ((watch_active_loop)); then
    current_loop_id="$(resolve_loop_id "$workspace" "")"
  elif [[ -n "$requested_current_loop_id" ]]; then
    current_loop_id="$requested_current_loop_id"
  fi

  local boundary_doc
  boundary_doc="$(abspath_from "$workspace" "$boundary_doc_input")"
  [[ -f "$boundary_doc" ]] || die "Boundary doc not found: $boundary_doc"
  require_markdown_heading "$boundary_doc" "$boundary_section"

  local campaign_id
  campaign_id="$(new_campaign_id)"
  local campaign_dir_path
  campaign_dir_path="$(campaign_dir "$workspace" "$campaign_id")"
  mkdir -p "$campaign_dir_path/prompts" "$campaign_dir_path/verify"

  local state_file="$campaign_dir_path/state.env"
  local goal_file="$campaign_dir_path/goal.md"
  local boundary_snapshot_file="$campaign_dir_path/current-boundaries.md"
  local add_dirs_file="$campaign_dir_path/add-dirs.txt"
  local runner_log="$campaign_dir_path/runner.log"
  local active_campaign
  active_campaign="$(active_campaign_file "$workspace")"

  printf '%s\n' "$goal" > "$goal_file"
  if ((${#add_dirs[@]})); then
    write_lines "$add_dirs_file" "${add_dirs[@]}"
  else
    : > "$add_dirs_file"
  fi

  local round=0
  if [[ -n "$current_loop_id" ]]; then
    [[ -d "$(loop_dir "$workspace" "$current_loop_id")" ]] || die "Loop not found: $current_loop_id"
    if [[ -n "$starting_round" ]]; then
      round="$starting_round"
    else
      round="$(infer_round_number "$workspace" "$current_loop_id" "$promise_prefix")"
    fi
  fi

  local boundary_count
  boundary_count="$(write_boundary_snapshot "$boundary_doc" "$boundary_section" "$boundary_snapshot_file")"
  local created_at
  created_at="$(timestamp_utc)"

  write_state "$state_file" \
    CAMPAIGN_ID "$campaign_id" \
    STATUS "created" \
    WORKSPACE "$workspace" \
    CREATED_AT "$created_at" \
    UPDATED_AT "$created_at" \
    ROUND "$round" \
    CURRENT_LOOP_ID "$current_loop_id" \
    MAX_ROUNDS "$max_rounds" \
    LOOP_MAX_ITERATIONS "$loop_max_iterations" \
    MODEL "$model" \
    PROFILE "$profile" \
    SANDBOX_MODE "$sandbox_mode" \
    APPROVAL_POLICY "$approval_policy" \
    CONSECUTIVE_ERROR_LIMIT "$consecutive_error_limit" \
    PID "" \
    LAST_VERIFY_EXIT_CODE "" \
    LAST_VERIFY_LOG "" \
    VERIFY_CMD "$verify_cmd" \
    BOUNDARY_DOC "$boundary_doc" \
    BOUNDARY_SECTION "$boundary_section" \
    LAST_BOUNDARY_COUNT "$boundary_count" \
    BOUNDARY_SNAPSHOT_FILE "$boundary_snapshot_file" \
    PROMISE_PREFIX "$promise_prefix" \
    GOAL_FILE "$goal_file" \
    ADD_DIRS_FILE "$add_dirs_file" \
    SCRIPT_VERSION "$SCRIPT_VERSION"

  mkdir -p "$(dirname "$active_campaign")"
  printf '%s\n' "$campaign_id" > "$active_campaign"

  if ((foreground)); then
    printf 'Started Ralph campaign %s in foreground\n' "$campaign_id"
    cmd_campaign_run --workspace "$workspace" --campaign-id "$campaign_id"
    return
  fi

  local script_path
  script_path="$(abspath "${BASH_SOURCE[0]}")"
  local pid
  pid="$(spawn_background_job "$(launchd_label_for_campaign "$campaign_id")" "$runner_log" bash "$script_path" campaign-run --workspace "$workspace" --campaign-id "$campaign_id")"

  write_state "$state_file" \
    CAMPAIGN_ID "$campaign_id" \
    STATUS "running" \
    WORKSPACE "$workspace" \
    CREATED_AT "$created_at" \
    UPDATED_AT "$(timestamp_utc)" \
    ROUND "$round" \
    CURRENT_LOOP_ID "$current_loop_id" \
    MAX_ROUNDS "$max_rounds" \
    LOOP_MAX_ITERATIONS "$loop_max_iterations" \
    MODEL "$model" \
    PROFILE "$profile" \
    SANDBOX_MODE "$sandbox_mode" \
    APPROVAL_POLICY "$approval_policy" \
    CONSECUTIVE_ERROR_LIMIT "$consecutive_error_limit" \
    PID "$pid" \
    LAST_VERIFY_EXIT_CODE "" \
    LAST_VERIFY_LOG "" \
    VERIFY_CMD "$verify_cmd" \
    BOUNDARY_DOC "$boundary_doc" \
    BOUNDARY_SECTION "$boundary_section" \
    LAST_BOUNDARY_COUNT "$boundary_count" \
    BOUNDARY_SNAPSHOT_FILE "$boundary_snapshot_file" \
    PROMISE_PREFIX "$promise_prefix" \
    GOAL_FILE "$goal_file" \
    ADD_DIRS_FILE "$add_dirs_file" \
    SCRIPT_VERSION "$SCRIPT_VERSION"

  cat <<EOF
Started Ralph campaign $campaign_id
Status: running
Workspace: $workspace
State: $campaign_dir_path
Runner log: $runner_log
Next:
  /ralph:campaign-status
  /ralph:campaign-cancel
  /ralph:status
EOF
}

cmd_campaign_run() {
  require_cmd codex
  require_cmd perl

  local workspace=""
  local campaign_id=""

  while (($#)); do
    case "$1" in
      --workspace)
        workspace="$(abspath "$(require_value "$@")")"
        shift 2
        ;;
      --campaign-id)
        campaign_id="$(require_value "$@")"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown campaign-run option: $1"
        ;;
    esac
  done

  [[ -n "$workspace" ]] || die "--workspace is required"
  [[ -n "$campaign_id" ]] || die "--campaign-id is required"

  local campaign_dir_path
  campaign_dir_path="$(campaign_dir "$workspace" "$campaign_id")"
  local state_file="$campaign_dir_path/state.env"
  local cancel_flag="$campaign_dir_path/cancel-requested"
  local boundary_snapshot_file="$campaign_dir_path/current-boundaries.md"
  [[ -f "$state_file" ]] || die "Campaign state not found: $state_file"

  trap 'handle_campaign_signal "$workspace" "$campaign_id"' INT TERM

  load_state "$state_file"

  write_state "$state_file" \
    CAMPAIGN_ID "$CAMPAIGN_ID" \
    STATUS "running" \
    WORKSPACE "$WORKSPACE" \
    CREATED_AT "$CREATED_AT" \
    UPDATED_AT "$(timestamp_utc)" \
    ROUND "$ROUND" \
    CURRENT_LOOP_ID "$CURRENT_LOOP_ID" \
    MAX_ROUNDS "$MAX_ROUNDS" \
    LOOP_MAX_ITERATIONS "$LOOP_MAX_ITERATIONS" \
    MODEL "$MODEL" \
    PROFILE "$PROFILE" \
    SANDBOX_MODE "$SANDBOX_MODE" \
    APPROVAL_POLICY "$APPROVAL_POLICY" \
    CONSECUTIVE_ERROR_LIMIT "$CONSECUTIVE_ERROR_LIMIT" \
    PID "$$" \
    LAST_VERIFY_EXIT_CODE "$LAST_VERIFY_EXIT_CODE" \
    LAST_VERIFY_LOG "$LAST_VERIFY_LOG" \
    VERIFY_CMD "$VERIFY_CMD" \
    BOUNDARY_DOC "$BOUNDARY_DOC" \
    BOUNDARY_SECTION "$BOUNDARY_SECTION" \
    LAST_BOUNDARY_COUNT "$LAST_BOUNDARY_COUNT" \
    BOUNDARY_SNAPSHOT_FILE "$BOUNDARY_SNAPSHOT_FILE" \
    PROMISE_PREFIX "$PROMISE_PREFIX" \
    GOAL_FILE "$GOAL_FILE" \
    ADD_DIRS_FILE "$ADD_DIRS_FILE" \
    SCRIPT_VERSION "$SCRIPT_VERSION"

  while true; do
    if [[ -f "$cancel_flag" ]]; then
      cancel_campaign_current_loop "$workspace" "$campaign_id"
      mark_campaign_terminal_state "$state_file" "cancelled"
      rm -f "$cancel_flag"
      printf 'Campaign %s cancelled\n' "$campaign_id"
      return 0
    fi

    load_state "$state_file"

    if [[ -z "$CURRENT_LOOP_ID" ]]; then
      local boundary_count_before
      boundary_count_before="$(write_boundary_snapshot "$BOUNDARY_DOC" "$BOUNDARY_SECTION" "$boundary_snapshot_file")"
      update_campaign_state_value "$state_file" LAST_BOUNDARY_COUNT "$boundary_count_before"

      if (( boundary_count_before == 0 )); then
        local verify_log
        verify_log="$campaign_dir_path/verify/round-$(printf '%04d' "$ROUND")-final.log"
        if run_verify_command "$WORKSPACE" "$VERIFY_CMD" "$verify_log"; then
          update_campaign_state_value "$state_file" LAST_VERIFY_EXIT_CODE "0"
          update_campaign_state_value "$state_file" LAST_VERIFY_LOG "$verify_log"
          mark_campaign_terminal_state "$state_file" "completed"
          printf 'Campaign %s completed; no remaining boundaries in %s\n' "$campaign_id" "$BOUNDARY_DOC"
          return 0
        fi
        update_campaign_state_value "$state_file" LAST_VERIFY_EXIT_CODE "$RUN_VERIFY_EXIT_CODE"
        update_campaign_state_value "$state_file" LAST_VERIFY_LOG "$verify_log"
        mark_campaign_terminal_state "$state_file" "failed"
        printf 'Campaign %s failed verification with exit code %s\n' "$campaign_id" "$RUN_VERIFY_EXIT_CODE"
        return "$RUN_VERIFY_EXIT_CODE"
      fi

      local next_round=$((ROUND + 1))
      if [[ "$MAX_ROUNDS" != "0" ]] && (( next_round > MAX_ROUNDS )); then
        mark_campaign_terminal_state "$state_file" "max-rounds-reached"
        printf 'Campaign %s reached max rounds (%s)\n' "$campaign_id" "$MAX_ROUNDS"
        return 0
      fi

      local round_prompt_file
      round_prompt_file="$campaign_dir_path/prompts/round-$(printf '%04d' "$next_round").md"
      local completion_promise="${PROMISE_PREFIX}${next_round}"
      write_campaign_round_prompt \
        "$round_prompt_file" \
        "$GOAL_FILE" \
        "$BOUNDARY_DOC" \
        "$BOUNDARY_SECTION" \
        "$boundary_snapshot_file" \
        "$campaign_id" \
        "$next_round" \
        "$completion_promise"

      printf '[%s] Campaign %s launching round %s\n' "$(timestamp_utc)" "$campaign_id" "$next_round"

      local launched_loop_id=""
      launch_generated_round \
        "$WORKSPACE" \
        "$round_prompt_file" \
        "$completion_promise" \
        "$LOOP_MAX_ITERATIONS" \
        "$MODEL" \
        "$PROFILE" \
        "$SANDBOX_MODE" \
        "$APPROVAL_POLICY" \
        "$CONSECUTIVE_ERROR_LIMIT" \
        "$ADD_DIRS_FILE" \
        launched_loop_id
      local launch_exit_code="$LAUNCH_GENERATED_ROUND_EXIT_CODE"
      local resolved_loop_id="$launched_loop_id"
      [[ -n "$resolved_loop_id" ]] || resolved_loop_id="$(resolve_loop_id "$WORKSPACE" "")"

      write_state "$state_file" \
        CAMPAIGN_ID "$CAMPAIGN_ID" \
        STATUS "running" \
        WORKSPACE "$WORKSPACE" \
        CREATED_AT "$CREATED_AT" \
        UPDATED_AT "$(timestamp_utc)" \
        ROUND "$next_round" \
        CURRENT_LOOP_ID "$resolved_loop_id" \
        MAX_ROUNDS "$MAX_ROUNDS" \
        LOOP_MAX_ITERATIONS "$LOOP_MAX_ITERATIONS" \
        MODEL "$MODEL" \
        PROFILE "$PROFILE" \
        SANDBOX_MODE "$SANDBOX_MODE" \
        APPROVAL_POLICY "$APPROVAL_POLICY" \
        CONSECUTIVE_ERROR_LIMIT "$CONSECUTIVE_ERROR_LIMIT" \
        PID "$$" \
        LAST_VERIFY_EXIT_CODE "$LAST_VERIFY_EXIT_CODE" \
        LAST_VERIFY_LOG "$LAST_VERIFY_LOG" \
        VERIFY_CMD "$VERIFY_CMD" \
        BOUNDARY_DOC "$BOUNDARY_DOC" \
        BOUNDARY_SECTION "$BOUNDARY_SECTION" \
        LAST_BOUNDARY_COUNT "$LAST_BOUNDARY_COUNT" \
        BOUNDARY_SNAPSHOT_FILE "$BOUNDARY_SNAPSHOT_FILE" \
        PROMISE_PREFIX "$PROMISE_PREFIX" \
        GOAL_FILE "$GOAL_FILE" \
        ADD_DIRS_FILE "$ADD_DIRS_FILE" \
        SCRIPT_VERSION "$SCRIPT_VERSION"

      if (( launch_exit_code != 0 )); then
        printf '[%s] Campaign %s round %s exited non-zero (%s); inspecting loop state\n' "$(timestamp_utc)" "$campaign_id" "$next_round" "$launch_exit_code"
      fi
    fi

    load_state "$state_file"
    local loop_state_file
    loop_state_file="$(loop_dir "$WORKSPACE" "$CURRENT_LOOP_ID")/state.env"
    [[ -f "$loop_state_file" ]] || die "Tracked loop state not found: $loop_state_file"
    refresh_state_if_stale "$loop_state_file"
    load_state "$loop_state_file"

    case "$STATUS" in
      running|cancel-requested)
        sleep 15
        continue
        ;;
      stopped)
        printf '[%s] Campaign %s detected stopped loop %s; resuming in foreground\n' "$(timestamp_utc)" "$campaign_id" "$LOOP_ID"
        bash "$(abspath "${BASH_SOURCE[0]}")" resume --loop-id "$LOOP_ID" --foreground
        continue
        ;;
      max-iterations-reached)
        printf '[%s] Campaign %s detected max-iterations on loop %s; resuming in foreground\n' "$(timestamp_utc)" "$campaign_id" "$LOOP_ID"
        bash "$(abspath "${BASH_SOURCE[0]}")" resume --loop-id "$LOOP_ID" --foreground
        continue
        ;;
      completed)
        local completed_round="$ROUND"
        local verify_log
        verify_log="$campaign_dir_path/verify/round-$(printf '%04d' "$completed_round").log"
        if run_verify_command "$WORKSPACE" "$VERIFY_CMD" "$verify_log"; then
          local boundary_count_after
          boundary_count_after="$(write_boundary_snapshot "$BOUNDARY_DOC" "$BOUNDARY_SECTION" "$boundary_snapshot_file")"
          write_state "$state_file" \
            CAMPAIGN_ID "$CAMPAIGN_ID" \
            STATUS "running" \
            WORKSPACE "$WORKSPACE" \
            CREATED_AT "$CREATED_AT" \
            UPDATED_AT "$(timestamp_utc)" \
            ROUND "$completed_round" \
            CURRENT_LOOP_ID "" \
            MAX_ROUNDS "$MAX_ROUNDS" \
            LOOP_MAX_ITERATIONS "$LOOP_MAX_ITERATIONS" \
            MODEL "$MODEL" \
            PROFILE "$PROFILE" \
            SANDBOX_MODE "$SANDBOX_MODE" \
            APPROVAL_POLICY "$APPROVAL_POLICY" \
            CONSECUTIVE_ERROR_LIMIT "$CONSECUTIVE_ERROR_LIMIT" \
            PID "$$" \
            LAST_VERIFY_EXIT_CODE "0" \
            LAST_VERIFY_LOG "$verify_log" \
            VERIFY_CMD "$VERIFY_CMD" \
            BOUNDARY_DOC "$BOUNDARY_DOC" \
            BOUNDARY_SECTION "$BOUNDARY_SECTION" \
            LAST_BOUNDARY_COUNT "$boundary_count_after" \
            BOUNDARY_SNAPSHOT_FILE "$BOUNDARY_SNAPSHOT_FILE" \
            PROMISE_PREFIX "$PROMISE_PREFIX" \
            GOAL_FILE "$GOAL_FILE" \
            ADD_DIRS_FILE "$ADD_DIRS_FILE" \
            SCRIPT_VERSION "$SCRIPT_VERSION"
          continue
        fi

        write_state "$state_file" \
          CAMPAIGN_ID "$CAMPAIGN_ID" \
          STATUS "failed" \
          WORKSPACE "$WORKSPACE" \
          CREATED_AT "$CREATED_AT" \
          UPDATED_AT "$(timestamp_utc)" \
          ROUND "$ROUND" \
          CURRENT_LOOP_ID "$LOOP_ID" \
          MAX_ROUNDS "$MAX_ROUNDS" \
          LOOP_MAX_ITERATIONS "$LOOP_MAX_ITERATIONS" \
          MODEL "$MODEL" \
          PROFILE "$PROFILE" \
          SANDBOX_MODE "$SANDBOX_MODE" \
          APPROVAL_POLICY "$APPROVAL_POLICY" \
          CONSECUTIVE_ERROR_LIMIT "$CONSECUTIVE_ERROR_LIMIT" \
          PID "" \
          LAST_VERIFY_EXIT_CODE "$RUN_VERIFY_EXIT_CODE" \
          LAST_VERIFY_LOG "$verify_log" \
          VERIFY_CMD "$VERIFY_CMD" \
          BOUNDARY_DOC "$BOUNDARY_DOC" \
          BOUNDARY_SECTION "$BOUNDARY_SECTION" \
          LAST_BOUNDARY_COUNT "$LAST_BOUNDARY_COUNT" \
          BOUNDARY_SNAPSHOT_FILE "$BOUNDARY_SNAPSHOT_FILE" \
          PROMISE_PREFIX "$PROMISE_PREFIX" \
          GOAL_FILE "$GOAL_FILE" \
          ADD_DIRS_FILE "$ADD_DIRS_FILE" \
          SCRIPT_VERSION "$SCRIPT_VERSION"
        printf 'Campaign %s failed verification after round %s\n' "$campaign_id" "$ROUND"
        return "$RUN_VERIFY_EXIT_CODE"
        ;;
      cancelled)
        mark_campaign_terminal_state "$state_file" "cancelled"
        printf 'Campaign %s stopped because loop %s was cancelled\n' "$campaign_id" "$LOOP_ID"
        return 0
        ;;
      failed)
        mark_campaign_terminal_state "$state_file" "failed"
        printf 'Campaign %s stopped because loop %s failed\n' "$campaign_id" "$LOOP_ID"
        return "${LAST_EXIT_CODE:-1}"
        ;;
      *)
        die "Unsupported loop status while running campaign: $STATUS"
        ;;
    esac
  done
}

cmd_campaign_status() {
  local requested_campaign_id=""
  local tail_lines=20
  local workspace="$(pwd -P)"

  while (($#)); do
    case "$1" in
      --campaign-id)
        requested_campaign_id="$(require_value "$@")"
        shift 2
        ;;
      --tail)
        tail_lines="$(require_value "$@")"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown campaign-status option: $1"
        ;;
    esac
  done

  validate_non_negative_int "$tail_lines" "tail lines"

  local campaign_id
  campaign_id="$(resolve_campaign_id "$workspace" "$requested_campaign_id")"
  local campaign_dir_path
  campaign_dir_path="$(campaign_dir "$workspace" "$campaign_id")"
  local state_file="$campaign_dir_path/state.env"
  [[ -f "$state_file" ]] || die "Campaign state not found: $state_file"
  refresh_campaign_state_if_stale "$state_file"
  load_state "$state_file"

  cat <<EOF
Campaign ID: $CAMPAIGN_ID
Status: $STATUS
Workspace: $WORKSPACE
Round: $ROUND / $(format_max_rounds "$MAX_ROUNDS")
Current loop: ${CURRENT_LOOP_ID:-<none>}
Created: $CREATED_AT
Updated: $UPDATED_AT
PID: ${PID:-}
Loop model: ${MODEL:-default}
Loop profile: ${PROFILE:-default}
Loop sandbox: $SANDBOX_MODE
Loop approval policy: $APPROVAL_POLICY
Loop max iterations: $(format_max_iterations "$LOOP_MAX_ITERATIONS")
Loop consecutive error limit: $CONSECUTIVE_ERROR_LIMIT
Verify command: $VERIFY_CMD
Boundary doc: $BOUNDARY_DOC
Boundary section: $BOUNDARY_SECTION
Remaining boundaries: $LAST_BOUNDARY_COUNT
Last verify exit code: ${LAST_VERIFY_EXIT_CODE:-<none>}
Last verify log: ${LAST_VERIFY_LOG:-<none>}
State dir: $campaign_dir_path
EOF

  if [[ -f "$BOUNDARY_SNAPSHOT_FILE" ]] && [[ -s "$BOUNDARY_SNAPSHOT_FILE" ]]; then
    printf '\nCurrent boundaries snapshot (%s lines):\n' "$tail_lines"
    tail -n "$tail_lines" "$BOUNDARY_SNAPSHOT_FILE"
  fi
}

cmd_campaign_cancel() {
  local requested_campaign_id=""
  local workspace="$(pwd -P)"

  while (($#)); do
    case "$1" in
      --campaign-id)
        requested_campaign_id="$(require_value "$@")"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown campaign-cancel option: $1"
        ;;
    esac
  done

  local campaign_id
  campaign_id="$(resolve_campaign_id "$workspace" "$requested_campaign_id")"
  local campaign_dir_path
  campaign_dir_path="$(campaign_dir "$workspace" "$campaign_id")"
  local state_file="$campaign_dir_path/state.env"
  local cancel_flag="$campaign_dir_path/cancel-requested"
  [[ -f "$state_file" ]] || die "Campaign state not found: $state_file"
  refresh_campaign_state_if_stale "$state_file"
  load_state "$state_file"

  if [[ "$STATUS" != "running" ]] && [[ "$STATUS" != "cancel-requested" ]]; then
    cat <<EOF
Campaign $CAMPAIGN_ID is not running.
Current status: $STATUS
EOF
    return 0
  fi

  : > "$cancel_flag"
  cancel_campaign_current_loop "$workspace" "$campaign_id"

  local result="Cancellation requested."
  if is_campaign_running "$CAMPAIGN_ID" "${PID:-}"; then
    if [[ -n "${PID:-}" ]] && kill -0 "$PID" 2>/dev/null; then
      kill "$PID" 2>/dev/null || true
      local i
      for i in $(seq 1 30); do
        if ! kill -0 "$PID" 2>/dev/null; then
          result="Cancelled."
          break
        fi
        sleep 0.1
      done
    elif is_macos && command -v launchctl >/dev/null 2>&1; then
      if launchctl remove "$(launchd_label_for_campaign "$CAMPAIGN_ID")" >/dev/null 2>&1; then
        result="Cancelled."
      fi
    fi
  else
    result="Cancelled."
  fi

  if [[ "$result" == "Cancelled." ]]; then
    mark_campaign_terminal_state "$state_file" "cancelled"
    rm -f "$cancel_flag"
  else
    write_state "$state_file" \
      CAMPAIGN_ID "$CAMPAIGN_ID" \
      STATUS "cancel-requested" \
      WORKSPACE "$WORKSPACE" \
      CREATED_AT "$CREATED_AT" \
      UPDATED_AT "$(timestamp_utc)" \
      ROUND "$ROUND" \
      CURRENT_LOOP_ID "$CURRENT_LOOP_ID" \
      MAX_ROUNDS "$MAX_ROUNDS" \
      LOOP_MAX_ITERATIONS "$LOOP_MAX_ITERATIONS" \
      MODEL "$MODEL" \
      PROFILE "$PROFILE" \
      SANDBOX_MODE "$SANDBOX_MODE" \
      APPROVAL_POLICY "$APPROVAL_POLICY" \
      CONSECUTIVE_ERROR_LIMIT "$CONSECUTIVE_ERROR_LIMIT" \
      PID "$PID" \
      LAST_VERIFY_EXIT_CODE "$LAST_VERIFY_EXIT_CODE" \
      LAST_VERIFY_LOG "$LAST_VERIFY_LOG" \
      VERIFY_CMD "$VERIFY_CMD" \
      BOUNDARY_DOC "$BOUNDARY_DOC" \
      BOUNDARY_SECTION "$BOUNDARY_SECTION" \
      LAST_BOUNDARY_COUNT "$LAST_BOUNDARY_COUNT" \
      BOUNDARY_SNAPSHOT_FILE "$BOUNDARY_SNAPSHOT_FILE" \
      PROMISE_PREFIX "$PROMISE_PREFIX" \
      GOAL_FILE "$GOAL_FILE" \
      ADD_DIRS_FILE "$ADD_DIRS_FILE" \
      SCRIPT_VERSION "$SCRIPT_VERSION"
    result="Cancellation requested; campaign still stopping."
  fi

  printf 'Campaign %s: %s\n' "$CAMPAIGN_ID" "$result"
}

cmd_dashboard() {
  require_cmd node

  local workspace="$(pwd -P)"
  local host="127.0.0.1"
  local port="43110"
  local foreground=0
  local open_browser=0

  while (($#)); do
    case "$1" in
      --cwd)
        workspace="$(abspath "$(require_value "$@")")"
        shift 2
        ;;
      --host)
        host="$(require_value "$@")"
        shift 2
        ;;
      --port)
        port="$(require_value "$@")"
        shift 2
        ;;
      --foreground)
        foreground=1
        shift
        ;;
      --open-browser)
        open_browser=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown dashboard option: $1"
        ;;
    esac
  done

  validate_non_negative_int "$port" "dashboard port"
  [[ -d "$workspace" ]] || die "Workspace does not exist: $workspace"

  local dashboard_root
  dashboard_root="$(dashboard_dir "$workspace")"
  mkdir -p "$dashboard_root"
  local info_file="$dashboard_root/server-info.json"
  local pid_file="$dashboard_root/server.pid"
  local log_file="$dashboard_root/server.log"
  local node_script
  node_script="$(dashboard_script_path)"

  if is_dashboard_process_running "$pid_file"; then
    local existing_url
    existing_url="$(dashboard_url_from_info "$info_file")"
    cat <<EOF
Ralph dashboard is already running
Workspace: $workspace
URL: ${existing_url:-<see $info_file>}
PID: $(<"$pid_file")
Log: $log_file
EOF
    if ((open_browser)) && [[ -n "$existing_url" ]]; then
      open_browser_url "$existing_url"
    fi
    return 0
  fi

  rm -f "$info_file" "$pid_file"

  if ((foreground)); then
    node "$node_script" --workspace "$workspace" --host "$host" --port "$port" --info-file "$info_file" --pid-file "$pid_file"
    return
  fi

  spawn_background_job "$(launchd_label_for_dashboard "$workspace")" "$log_file" node "$node_script" --workspace "$workspace" --host "$host" --port "$port" --info-file "$info_file" --pid-file "$pid_file" >/dev/null

  local i
  for i in $(seq 1 50); do
    if [[ -f "$info_file" ]] && [[ -f "$pid_file" ]]; then
      break
    fi
    sleep 0.1
  done

  if [[ ! -f "$info_file" ]]; then
    if [[ -f "$log_file" ]] && [[ -s "$log_file" ]]; then
      printf 'Dashboard failed to start. Recent log:\n' >&2
      tail -n 40 "$log_file" >&2
    fi
    die "Dashboard did not report a URL. Check $log_file"
  fi

  local url
  url="$(dashboard_url_from_info "$info_file")"
  local pid=""
  if [[ -f "$pid_file" ]]; then
    pid="$(<"$pid_file")"
  fi

  cat <<EOF
Started Ralph dashboard
Workspace: $workspace
URL: ${url:-<see $info_file>}
PID: ${pid:-<unknown>}
State: $dashboard_root
Log: $log_file
EOF

  if ((open_browser)) && [[ -n "$url" ]]; then
    open_browser_url "$url"
  fi
}

cmd_dashboard_status() {
  local workspace="$(pwd -P)"

  while (($#)); do
    case "$1" in
      --cwd)
        workspace="$(abspath "$(require_value "$@")")"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown dashboard-status option: $1"
        ;;
    esac
  done

  local dashboard_root
  dashboard_root="$(dashboard_dir "$workspace")"
  local info_file="$dashboard_root/server-info.json"
  local pid_file="$dashboard_root/server.pid"
  local log_file="$dashboard_root/server.log"
  local status="stopped"
  local url=""
  local pid=""

  if is_dashboard_process_running "$pid_file"; then
    status="running"
    pid="$(<"$pid_file")"
  fi

  if [[ -f "$info_file" ]]; then
    url="$(dashboard_url_from_info "$info_file")"
  fi

  cat <<EOF
Dashboard status: $status
Workspace: $workspace
URL: ${url:-<unknown>}
PID: ${pid:-<none>}
State dir: $dashboard_root
Log: $log_file
EOF
}

cmd_dashboard_stop() {
  local workspace="$(pwd -P)"

  while (($#)); do
    case "$1" in
      --cwd)
        workspace="$(abspath "$(require_value "$@")")"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown dashboard-stop option: $1"
        ;;
    esac
  done

  local dashboard_root
  dashboard_root="$(dashboard_dir "$workspace")"
  local pid_file="$dashboard_root/server.pid"
  local info_file="$dashboard_root/server-info.json"
  local pid=""
  local stopped=0

  if [[ -f "$pid_file" ]]; then
    pid="$(<"$pid_file")"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      local i
      for i in $(seq 1 30); do
        if ! kill -0 "$pid" 2>/dev/null; then
          stopped=1
          break
        fi
        sleep 0.1
      done
    else
      stopped=1
    fi
  fi

  if is_macos && command -v launchctl >/dev/null 2>&1; then
    launchctl remove "$(launchd_label_for_dashboard "$workspace")" >/dev/null 2>&1 || true
  fi

  if (( stopped )); then
    rm -f "$pid_file"
    printf 'Ralph dashboard stopped.\n'
    return 0
  fi

  if [[ -f "$info_file" ]]; then
    printf 'Dashboard stop requested. Inspect %s if it does not exit shortly.\n' "$info_file"
  else
    printf 'Ralph dashboard is not running.\n'
  fi
}

write_campaign_round_prompt() {
  local prompt_file="$1"
  local goal_file="$2"
  local boundary_doc="$3"
  local boundary_section="$4"
  local boundary_snapshot_file="$5"
  local campaign_id="$6"
  local round_number="$7"
  local completion_promise="$8"
  local goal_text
  goal_text="$(<"$goal_file")"

  {
    printf '# Ralph Campaign Round\n\n'
    printf 'You are running inside a multi-round Ralph campaign managed by shell automation.\n'
    printf 'Each round may launch multiple Codex iterations internally, but your job in this round is to materially shrink the remaining global boundaries.\n\n'
    printf '## Campaign Goal\n\n%s\n\n' "$goal_text"
    printf '## Current Global Boundaries\n\n'
    if [[ -s "$boundary_snapshot_file" ]]; then
      cat "$boundary_snapshot_file"
    else
      printf '(none listed)\n'
    fi
    printf '\n## Round Mission\n\n'
    printf -- '- First inspect the real repository state, latest tests, docs, and artifacts before changing code.\n'
    printf -- '- Treat `%s` under the heading `%s` as the authoritative list of remaining global gaps.\n' "$boundary_doc" "$boundary_section"
    printf -- '- Implement the highest-leverage subset of those boundaries end to end in this round.\n'
    printf -- '- Update code, tests, verification, and docs together.\n'
    printf -- '- Narrow or remove a boundary only when it is materially implemented and the repo still verifies.\n'
    printf -- '- Preserve existing functionality and keep the repository honestly documented.\n'
    printf -- '- Do not stop at analysis; land real code, tests, and documentation.\n'
    printf -- '- End every iteration with concise sections named Done, Open, and Next.\n'
    printf -- '- Only when this round is genuinely complete, output exactly: <promise>%s</promise>\n' "$completion_promise"
    printf '\n## Campaign Context\n\n'
    printf -- '- Campaign id: %s\n' "$campaign_id"
    printf -- '- Round: %s\n' "$round_number"
    printf -- '- Boundary doc: %s\n' "$boundary_doc"
    printf -- '- Boundary section: %s\n' "$boundary_section"
  } > "$prompt_file"
}

write_prompt_file() {
  local prompt_file="$1"
  local loop_id="$2"
  local task_file="$3"
  local handoff_file="$4"
  local completion_promise_file="$5"
  local task completion_promise
  task="$(<"$task_file")"
  completion_promise="$(read_text_file "$completion_promise_file")"
  local handoff_rel=".ralph/loops/$loop_id/handoff.md"
  local iterations_rel=".ralph/loops/$loop_id/iterations"

  {
    printf '# Ralph Loop\n\n'
    printf 'You are running inside an external Ralph loop managed by shell automation.\n'
    printf 'Each iteration is a fresh Codex session, so use the repository state and the handoff file to recover context.\n\n'
    printf '## Primary Task\n\n%s\n\n' "$task"
    printf '## Required Workflow\n\n'
    printf -- '- First inspect the relevant repository files before changing code.\n'
    printf -- '- Read this handoff file if it contains prior context: %s\n' "$handoff_rel"
    printf -- '- Use the repository, tests, logs, and git state as ground truth when those sources exist.\n'
    printf -- '- If you are blocked, explain the blocker, what you tried, and the next best move.\n'
    printf -- '- End every iteration with concise sections named Done, Open, and Next.\n'
    if [[ -n "$completion_promise" ]]; then
      printf -- '- Only when the task is genuinely complete, output exactly: <promise>%s</promise>\n' "$completion_promise"
    else
      printf -- '- No completion promise is configured. The loop stops only when cancelled or when max iterations is reached.\n'
    fi
    printf '\n## Loop Context\n\n'
    printf -- '- Loop id: %s\n' "$loop_id"
    printf -- '- Handoff file: %s\n' "$handoff_rel"
    printf -- '- Iteration history: %s\n' "$iterations_rel"
  } > "$prompt_file"
}

write_handoff_file() {
  local handoff_file="$1"
  local loop_id="$2"
  local iteration="$3"
  local exit_code="$4"
  local started_at="$5"
  local ended_at="$6"
  local git_status_file="$7"
  local git_diff_stat_file="$8"
  local final_message_file="$9"
  local stderr_file="${10}"

  {
    printf '# Ralph Handoff\n\n'
    printf -- '- Loop id: %s\n' "$loop_id"
    printf -- '- Iteration: %s\n' "$iteration"
    printf -- '- Codex exit code: %s\n' "$exit_code"
    printf -- '- Started: %s\n' "$started_at"
    printf -- '- Ended: %s\n\n' "$ended_at"

    printf '## Git Status\n\n'
    if [[ -s "$git_status_file" ]]; then
      cat "$git_status_file"
    else
      printf '(clean or unavailable)\n'
    fi
    printf '\n## Git Diff Stat\n\n'
    if [[ -s "$git_diff_stat_file" ]]; then
      cat "$git_diff_stat_file"
    else
      printf '(no diff or unavailable)\n'
    fi
    printf '\n## Final Message\n\n'
    if [[ -s "$final_message_file" ]]; then
      cat "$final_message_file"
    else
      printf '(no final message captured)\n'
    fi
    if [[ -s "$stderr_file" ]]; then
      printf '\n## Stderr\n\n'
      cat "$stderr_file"
    fi
  } > "$handoff_file"
}

mark_terminal_state() {
  local state_file="$1"
  local status="$2"
  local iteration="$3"
  local max_iterations="$4"
  local created_at="$5"
  local model="$6"
  local profile="$7"
  local sandbox_mode="$8"
  local approval_policy="$9"
  local last_exit_code="${10}"
  local last_output_file="${11}"
  local consecutive_errors="${12}"
  local consecutive_error_limit="${13}"

  load_state "$state_file"
  write_state "$state_file" \
    LOOP_ID "$LOOP_ID" \
    STATUS "$status" \
    WORKSPACE "$WORKSPACE" \
    CREATED_AT "$created_at" \
    UPDATED_AT "$(timestamp_utc)" \
    ITERATION "$iteration" \
    MAX_ITERATIONS "$max_iterations" \
    MODEL "$model" \
    PROFILE "$profile" \
    SANDBOX_MODE "$sandbox_mode" \
    APPROVAL_POLICY "$approval_policy" \
    PID "" \
    LAST_EXIT_CODE "$last_exit_code" \
    LAST_OUTPUT_FILE "$last_output_file" \
    CONSECUTIVE_ERRORS "$consecutive_errors" \
    CONSECUTIVE_ERROR_LIMIT "$consecutive_error_limit" \
    SCRIPT_VERSION "$SCRIPT_VERSION"
}

mark_campaign_terminal_state() {
  local state_file="$1"
  local status="$2"
  load_state "$state_file"
  write_state "$state_file" \
    CAMPAIGN_ID "$CAMPAIGN_ID" \
    STATUS "$status" \
    WORKSPACE "$WORKSPACE" \
    CREATED_AT "$CREATED_AT" \
    UPDATED_AT "$(timestamp_utc)" \
    ROUND "$ROUND" \
    CURRENT_LOOP_ID "$CURRENT_LOOP_ID" \
    MAX_ROUNDS "$MAX_ROUNDS" \
    LOOP_MAX_ITERATIONS "$LOOP_MAX_ITERATIONS" \
    MODEL "$MODEL" \
    PROFILE "$PROFILE" \
    SANDBOX_MODE "$SANDBOX_MODE" \
    APPROVAL_POLICY "$APPROVAL_POLICY" \
    CONSECUTIVE_ERROR_LIMIT "$CONSECUTIVE_ERROR_LIMIT" \
    PID "" \
    LAST_VERIFY_EXIT_CODE "$LAST_VERIFY_EXIT_CODE" \
    LAST_VERIFY_LOG "$LAST_VERIFY_LOG" \
    VERIFY_CMD "$VERIFY_CMD" \
    BOUNDARY_DOC "$BOUNDARY_DOC" \
    BOUNDARY_SECTION "$BOUNDARY_SECTION" \
    LAST_BOUNDARY_COUNT "$LAST_BOUNDARY_COUNT" \
    BOUNDARY_SNAPSHOT_FILE "$BOUNDARY_SNAPSHOT_FILE" \
    PROMISE_PREFIX "$PROMISE_PREFIX" \
    GOAL_FILE "$GOAL_FILE" \
    ADD_DIRS_FILE "$ADD_DIRS_FILE" \
    SCRIPT_VERSION "$SCRIPT_VERSION"
}

print_all_loops() {
  local workspace="$1"
  local loops_root
  loops_root="$(loops_root "$workspace")"
  if [[ ! -d "$loops_root" ]]; then
    printf 'No Ralph loops found in %s\n' "$workspace"
    return 0
  fi

  printf 'Known Ralph loops in %s:\n' "$workspace"
  local dir state_file
  for dir in "$loops_root"/*; do
    [[ -d "$dir" ]] || continue
    state_file="$dir/state.env"
    [[ -f "$state_file" ]] || continue
    refresh_state_if_stale "$state_file"
    load_state "$state_file"
    printf -- '- %s | %s | iteration %s / %s | updated %s\n' \
      "$LOOP_ID" "$STATUS" "$ITERATION" "$(format_max_iterations "$MAX_ITERATIONS")" "$UPDATED_AT"
  done
}

resolve_loop_id() {
  local workspace="$1"
  local requested="$2"
  if [[ -n "$requested" ]]; then
    printf '%s\n' "$requested"
    return 0
  fi

  local active_file
  active_file="$(active_loop_file "$workspace")"
  if [[ -f "$active_file" ]]; then
    local active_id
    active_id="$(<"$active_file")"
    if [[ -d "$(loop_dir "$workspace" "$active_id")" ]]; then
      printf '%s\n' "$active_id"
      return 0
    fi
  fi

  local loops_root_dir
  loops_root_dir="$(loops_root "$workspace")"
  [[ -d "$loops_root_dir" ]] || die "No Ralph loops found in $workspace"

  local latest_dir
  latest_dir="$(find "$loops_root_dir" -mindepth 1 -maxdepth 1 -type d -print0 | xargs -0 ls -td 2>/dev/null | head -n 1 || true)"
  [[ -n "$latest_dir" ]] || die "No Ralph loops found in $workspace"
  basename "$latest_dir"
}

resolve_active_loop_id_optional() {
  local workspace="$1"
  local active_file
  active_file="$(active_loop_file "$workspace")"
  if [[ -f "$active_file" ]]; then
    local active_id
    active_id="$(<"$active_file")"
    if [[ -d "$(loop_dir "$workspace" "$active_id")" ]]; then
      printf '%s\n' "$active_id"
      return 0
    fi
  fi
  printf '%s' ""
}

resolve_campaign_id() {
  local workspace="$1"
  local requested="$2"
  if [[ -n "$requested" ]]; then
    printf '%s\n' "$requested"
    return 0
  fi

  local active_file
  active_file="$(active_campaign_file "$workspace")"
  if [[ -f "$active_file" ]]; then
    local active_id
    active_id="$(<"$active_file")"
    if [[ -d "$(campaign_dir "$workspace" "$active_id")" ]]; then
      printf '%s\n' "$active_id"
      return 0
    fi
  fi

  local campaigns_root_dir
  campaigns_root_dir="$(campaigns_root "$workspace")"
  [[ -d "$campaigns_root_dir" ]] || die "No Ralph campaigns found in $workspace"

  local latest_dir
  latest_dir="$(find "$campaigns_root_dir" -mindepth 1 -maxdepth 1 -type d -print0 | xargs -0 ls -td 2>/dev/null | head -n 1 || true)"
  [[ -n "$latest_dir" ]] || die "No Ralph campaigns found in $workspace"
  basename "$latest_dir"
}

resolve_active_campaign_id_optional() {
  local workspace="$1"
  local active_file
  active_file="$(active_campaign_file "$workspace")"
  if [[ -f "$active_file" ]]; then
    local active_id
    active_id="$(<"$active_file")"
    if [[ -d "$(campaign_dir "$workspace" "$active_id")" ]]; then
      printf '%s\n' "$active_id"
      return 0
    fi
  fi
  printf '%s' ""
}

extract_promise() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  perl -0777 -ne 'if (m{<promise>(.*?)</promise>}s) { $x=$1; $x =~ s/^\s+|\s+$//g; $x =~ s/\s+/ /g; print $x; }' "$file"
}

handle_signal() {
  local state_file="$1"
  local cancel_flag="$2"
  local child_pid="$3"
  : > "$cancel_flag"
  if [[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null; then
    kill "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
  fi
  if [[ -f "$state_file" ]]; then
    load_state "$state_file"
    mark_terminal_state "$state_file" "cancelled" "$ITERATION" "$MAX_ITERATIONS" "$CREATED_AT" "$MODEL" "$PROFILE" "$SANDBOX_MODE" "$APPROVAL_POLICY" "$LAST_EXIT_CODE" "$LAST_OUTPUT_FILE" "$CONSECUTIVE_ERRORS" "$CONSECUTIVE_ERROR_LIMIT"
  fi
  exit 130
}

run_codex_iteration() {
  local workspace="$1"
  local sandbox_mode="$2"
  local approval_policy="$3"
  local model="$4"
  local profile="$5"
  local add_dirs_file="$6"
  local prompt_text="$7"
  local final_message_file="$8"
  local session_output_file="$9"
  local stderr_file="${10}"
  local child_pid_var_name="${11}"

  RUN_CODEX_ITERATION_EXIT_CODE=0
  local initial_mode="sandboxed"
  if [[ -n "${CODEX_SANDBOX:-}" ]]; then
    initial_mode="bypass"
  fi

  run_codex_iteration_once "$workspace" "$sandbox_mode" "$approval_policy" "$model" "$profile" "$add_dirs_file" "$prompt_text" "$final_message_file" "$session_output_file" "$stderr_file" "$initial_mode" "$child_pid_var_name"
  RUN_CODEX_ITERATION_EXIT_CODE="$RUN_CODEX_ITERATION_EXIT_CODE"

  if (( RUN_CODEX_ITERATION_EXIT_CODE == 0 )); then
    return 0
  fi

  if [[ "$initial_mode" == "bypass" ]]; then
    return 0
  fi

  if ! grep -q 'sandbox_apply: Operation not permitted' "$stderr_file"; then
    return 0
  fi

  mv "$session_output_file" "${session_output_file%.txt}.sandbox.txt"
  mv "$stderr_file" "${stderr_file%.txt}.sandbox.txt"
  rm -f "$final_message_file"

  run_codex_iteration_once "$workspace" "$sandbox_mode" "$approval_policy" "$model" "$profile" "$add_dirs_file" "$prompt_text" "$final_message_file" "$session_output_file" "$stderr_file" bypass "$child_pid_var_name"
  {
    printf '[Ralph] Retried iteration without inner Codex sandbox after nested sandbox setup failed.\n'
    if [[ -f "${session_output_file%.txt}.sandbox.txt" ]]; then
      printf '[Ralph] Previous sandboxed attempt log: %s\n' "${session_output_file%.txt}.sandbox.txt"
    fi
  } >> "$session_output_file"
}

run_codex_iteration_once() {
  local workspace="$1"
  local sandbox_mode="$2"
  local approval_policy="$3"
  local model="$4"
  local profile="$5"
  local add_dirs_file="$6"
  local prompt_text="$7"
  local final_message_file="$8"
  local session_output_file="$9"
  local stderr_file="${10}"
  local mode="${11}"
  local child_pid_var_name="${12}"
  local -a cmd=()

  cmd+=(codex exec)
  cmd+=(-C "$workspace")
  cmd+=(--color never)
  cmd+=(-o "$final_message_file")
  if [[ "$mode" == "bypass" ]]; then
    cmd+=(--dangerously-bypass-approvals-and-sandbox)
  else
    cmd+=(-s "$sandbox_mode")
    cmd+=(-c "approval_policy=\"$approval_policy\"")
  fi
  if [[ -n "$model" ]]; then
    cmd+=(-m "$model")
  fi
  if [[ -n "$profile" ]]; then
    cmd+=(-p "$profile")
  fi
  if ! git -C "$workspace" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    cmd+=(--skip-git-repo-check)
  fi
  if [[ -f "$add_dirs_file" ]]; then
    while IFS= read -r add_dir; do
      [[ -n "$add_dir" ]] || continue
      cmd+=(--add-dir "$add_dir")
    done < "$add_dirs_file"
  fi
  cmd+=("$prompt_text")

  "${cmd[@]}" >"$session_output_file" 2>"$stderr_file" &
  printf -v "$child_pid_var_name" '%s' "$!"
  local current_child_pid="${!child_pid_var_name}"
  if wait "$current_child_pid"; then
    RUN_CODEX_ITERATION_EXIT_CODE=0
  else
    RUN_CODEX_ITERATION_EXIT_CODE=$?
  fi
  printf -v "$child_pid_var_name" '%s' ""
}

refresh_state_if_stale() {
  local state_file="$1"
  load_state "$state_file"

  if [[ "$STATUS" != "running" ]] && [[ "$STATUS" != "cancel-requested" ]]; then
    return 0
  fi

  if is_loop_running "$LOOP_ID" "${PID:-}"; then
    return 0
  fi

  write_state "$state_file" \
    LOOP_ID "$LOOP_ID" \
    STATUS "stopped" \
    WORKSPACE "$WORKSPACE" \
    CREATED_AT "$CREATED_AT" \
    UPDATED_AT "$(timestamp_utc)" \
    ITERATION "$ITERATION" \
    MAX_ITERATIONS "$MAX_ITERATIONS" \
    MODEL "$MODEL" \
    PROFILE "$PROFILE" \
    SANDBOX_MODE "$SANDBOX_MODE" \
    APPROVAL_POLICY "$APPROVAL_POLICY" \
    PID "" \
    LAST_EXIT_CODE "$LAST_EXIT_CODE" \
    LAST_OUTPUT_FILE "$LAST_OUTPUT_FILE" \
    CONSECUTIVE_ERRORS "$CONSECUTIVE_ERRORS" \
    CONSECUTIVE_ERROR_LIMIT "$CONSECUTIVE_ERROR_LIMIT" \
    SCRIPT_VERSION "$SCRIPT_VERSION"
}

refresh_campaign_state_if_stale() {
  local state_file="$1"
  load_state "$state_file"

  if [[ "$STATUS" != "running" ]] && [[ "$STATUS" != "cancel-requested" ]]; then
    return 0
  fi

  if is_campaign_running "$CAMPAIGN_ID" "${PID:-}"; then
    return 0
  fi

  write_state "$state_file" \
    CAMPAIGN_ID "$CAMPAIGN_ID" \
    STATUS "stopped" \
    WORKSPACE "$WORKSPACE" \
    CREATED_AT "$CREATED_AT" \
    UPDATED_AT "$(timestamp_utc)" \
    ROUND "$ROUND" \
    CURRENT_LOOP_ID "$CURRENT_LOOP_ID" \
    MAX_ROUNDS "$MAX_ROUNDS" \
    LOOP_MAX_ITERATIONS "$LOOP_MAX_ITERATIONS" \
    MODEL "$MODEL" \
    PROFILE "$PROFILE" \
    SANDBOX_MODE "$SANDBOX_MODE" \
    APPROVAL_POLICY "$APPROVAL_POLICY" \
    CONSECUTIVE_ERROR_LIMIT "$CONSECUTIVE_ERROR_LIMIT" \
    PID "" \
    LAST_VERIFY_EXIT_CODE "$LAST_VERIFY_EXIT_CODE" \
    LAST_VERIFY_LOG "$LAST_VERIFY_LOG" \
    VERIFY_CMD "$VERIFY_CMD" \
    BOUNDARY_DOC "$BOUNDARY_DOC" \
    BOUNDARY_SECTION "$BOUNDARY_SECTION" \
    LAST_BOUNDARY_COUNT "$LAST_BOUNDARY_COUNT" \
    BOUNDARY_SNAPSHOT_FILE "$BOUNDARY_SNAPSHOT_FILE" \
    PROMISE_PREFIX "$PROMISE_PREFIX" \
    GOAL_FILE "$GOAL_FILE" \
    ADD_DIRS_FILE "$ADD_DIRS_FILE" \
    SCRIPT_VERSION "$SCRIPT_VERSION"
}

write_state() {
  local state_file="$1"
  shift
  local tmp_file="${state_file}.tmp.$$"
  {
    while (($#)); do
      local key="$1"
      local value="$2"
      shift 2
      printf '%s=%q\n' "$key" "$value"
    done
  } > "$tmp_file"
  mv "$tmp_file" "$state_file"
}

load_state() {
  local state_file="$1"
  # shellcheck disable=SC1090
  source "$state_file"
}

write_lines() {
  local file="$1"
  shift
  : > "$file"
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >> "$file"
  done
}

read_text_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  tr -d '\r' < "$file" | sed 's/[[:space:]]*$//'
}

format_max_iterations() {
  local value="$1"
  if [[ "$value" == "0" ]]; then
    printf 'unlimited\n'
  else
    printf '%s\n' "$value"
  fi
}

format_max_rounds() {
  local value="$1"
  if [[ "$value" == "0" ]]; then
    printf 'unlimited\n'
  else
    printf '%s\n' "$value"
  fi
}

require_cmd() {
  local name="$1"
  command -v "$name" >/dev/null 2>&1 || die "Required command not found: $name"
}

require_value() {
  local option="$1"
  local value="${2:-}"
  [[ -n "$value" ]] || die "$option requires a value"
  printf '%s\n' "$value"
}

validate_non_negative_int() {
  local value="$1"
  local label="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$label must be a non-negative integer: $value"
}

validate_sandbox_mode() {
  local value="$1"
  case "$value" in
    read-only|workspace-write|danger-full-access) ;;
    *)
      die "Invalid sandbox mode: $value"
      ;;
  esac
}

validate_approval_policy() {
  local value="$1"
  case "$value" in
    never|on-request|on-failure|untrusted) ;;
    *)
      die "Invalid approval policy: $value"
      ;;
  esac
}

loops_root() {
  local workspace="$1"
  printf '%s/.ralph/loops\n' "$workspace"
}

campaigns_root() {
  local workspace="$1"
  printf '%s/.ralph/campaigns\n' "$workspace"
}

dashboard_dir() {
  local workspace="$1"
  printf '%s/.ralph/dashboard\n' "$workspace"
}

loop_dir() {
  local workspace="$1"
  local loop_id="$2"
  printf '%s/%s\n' "$(loops_root "$workspace")" "$loop_id"
}

campaign_dir() {
  local workspace="$1"
  local campaign_id="$2"
  printf '%s/%s\n' "$(campaigns_root "$workspace")" "$campaign_id"
}

active_loop_file() {
  local workspace="$1"
  printf '%s/.ralph/active-loop\n' "$workspace"
}

active_campaign_file() {
  local workspace="$1"
  printf '%s/.ralph/active-campaign\n' "$workspace"
}

dashboard_script_path() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
  printf '%s/ralph-dashboard.mjs\n' "$script_dir"
}

abspath() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    local dir
    dir="$(dirname "$path")"
    local base
    base="$(basename "$path")"
    (
      cd "$dir" >/dev/null 2>&1
      printf '%s/%s\n' "$(pwd -P)" "$base"
    )
  fi
}

abspath_from() {
  local base="$1"
  local path="$2"
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    (
      cd "$base" >/dev/null 2>&1
      local dir
      dir="$(dirname "$path")"
      local base_name
      base_name="$(basename "$path")"
      cd "$dir" >/dev/null 2>&1
      printf '%s/%s\n' "$(pwd -P)" "$base_name"
    )
  fi
}

new_loop_id() {
  printf '%s-%s\n' "$(date -u '+%Y%m%dT%H%M%SZ')" "$$"
}

new_campaign_id() {
  printf 'campaign-%s-%s\n' "$(date -u '+%Y%m%dT%H%M%SZ')" "$$"
}

timestamp_utc() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

spawn_detached() {
  local log_file="$1"
  shift

  RALPH_LOG_FILE="$log_file" perl -MPOSIX -e '
use strict;
use warnings;

my @cmd = @ARGV;
my $pid = fork();
die "fork failed: $!" unless defined $pid;
if ($pid) {
  print $pid;
  exit 0;
}

POSIX::setsid() or die "setsid failed: $!";
open STDIN, "<", "/dev/null" or die "stdin: $!";
open STDOUT, ">>", $ENV{RALPH_LOG_FILE} or die "stdout: $!";
open STDERR, ">>", $ENV{RALPH_LOG_FILE} or die "stderr: $!";
exec @cmd or die "exec failed: $!";
' "$@"
}

spawn_background_job() {
  local label="$1"
  local log_file="$2"
  shift 2

  if is_macos && command -v launchctl >/dev/null 2>&1; then
    launchctl remove "$label" >/dev/null 2>&1 || true
    if launchctl submit -l "$label" -o "$log_file" -e "$log_file" -- "$@" >/dev/null 2>&1; then
      printf '%s\n' ""
      return 0
    fi
  fi

  spawn_detached "$log_file" "$@"
}

spawn_background_runner() {
  local workspace="$1"
  local loop_id="$2"
  local runner_log="$3"
  local script_path="$4"

  spawn_background_job "$(launchd_label_for_loop "$loop_id")" "$runner_log" bash "$script_path" run --workspace "$workspace" --loop-id "$loop_id"
}

is_loop_running() {
  local loop_id="$1"
  local pid="${2:-}"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    return 0
  fi

  if is_macos && command -v launchctl >/dev/null 2>&1; then
    launchctl list "$(launchd_label_for_loop "$loop_id")" >/dev/null 2>&1
    return $?
  fi

  return 1
}

is_campaign_running() {
  local campaign_id="$1"
  local pid="${2:-}"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    return 0
  fi

  if is_macos && command -v launchctl >/dev/null 2>&1; then
    launchctl list "$(launchd_label_for_campaign "$campaign_id")" >/dev/null 2>&1
    return $?
  fi

  return 1
}

launchd_label_for_loop() {
  local loop_id="$1"
  local sanitized="${loop_id//[^A-Za-z0-9]/-}"
  printf 'com.ralph.%s\n' "$sanitized"
}

launchd_label_for_campaign() {
  local campaign_id="$1"
  local sanitized="${campaign_id//[^A-Za-z0-9]/-}"
  printf 'com.ralph.campaign.%s\n' "$sanitized"
}

launchd_label_for_dashboard() {
  local workspace="$1"
  local workspace_hash
  workspace_hash="$(printf '%s' "$workspace" | cksum | awk '{print $1}')"
  printf 'com.ralph.dashboard.%s\n' "$workspace_hash"
}

require_markdown_heading() {
  local file="$1"
  local heading="$2"
  awk -v heading="$heading" '
    /^#+[[:space:]]+/ {
      title=$0
      sub(/^#+[[:space:]]+/, "", title)
      sub(/[[:space:]]+$/, "", title)
      if (title == heading) found=1
    }
    END { exit found ? 0 : 1 }
  ' "$file" || die "Heading not found in $file: $heading"
}

write_boundary_snapshot() {
  local file="$1"
  local heading="$2"
  local output_file="$3"
  local tmp_file="${output_file}.tmp.$$"
  awk -v heading="$heading" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    /^#+[[:space:]]+/ {
      match($0, /^#+/)
      current_level = RLENGTH
      title = $0
      sub(/^#+[[:space:]]+/, "", title)
      title = trim(title)
      if (!in_section && title == heading) {
        in_section = 1
        section_level = current_level
        found = 1
        next
      }
      if (in_section && current_level <= section_level) {
        exit
      }
    }
    in_section && /^[[:space:]]*[-*][[:space:]]+/ {
      print
      count++
    }
    END {
      if (!found) exit 2
    }
  ' "$file" > "$tmp_file" || {
    rm -f "$tmp_file"
    die "Failed to extract heading '$heading' from $file"
  }
  mv "$tmp_file" "$output_file"
  awk 'END { print NR + 0 }' "$output_file"
}

infer_round_number() {
  local workspace="$1"
  local loop_id="$2"
  local promise_prefix="$3"
  local completion_promise_file
  completion_promise_file="$(loop_dir "$workspace" "$loop_id")/completion-promise.txt"
  if [[ -f "$completion_promise_file" ]]; then
    local promise
    promise="$(read_text_file "$completion_promise_file")"
    if [[ "$promise" == "$promise_prefix"* ]]; then
      local suffix="${promise#"$promise_prefix"}"
      if [[ "$suffix" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$suffix"
        return 0
      fi
    fi
  fi
  printf '1\n'
}

run_verify_command() {
  local workspace="$1"
  local verify_cmd="$2"
  local log_file="$3"
  mkdir -p "$(dirname "$log_file")"
  if (
    cd "$workspace"
    bash -lc "$verify_cmd"
  ) >"$log_file" 2>&1; then
    RUN_VERIFY_EXIT_CODE=0
    return 0
  fi
  RUN_VERIFY_EXIT_CODE=$?
  return 1
}

launch_generated_round() {
  local workspace="$1"
  local prompt_file="$2"
  local completion_promise="$3"
  local loop_max_iterations="$4"
  local model="$5"
  local profile="$6"
  local sandbox_mode="$7"
  local approval_policy="$8"
  local consecutive_error_limit="$9"
  local add_dirs_file="${10}"
  local loop_id_var_name="${11}"
  local script_path
  script_path="$(abspath "${BASH_SOURCE[0]}")"
  local prompt_text
  prompt_text="$(<"$prompt_file")"
  local -a cmd=(bash "$script_path" start --foreground --cwd "$workspace" --max-iterations "$loop_max_iterations" --completion-promise "$completion_promise" --sandbox "$sandbox_mode" --approval-policy "$approval_policy" --consecutive-error-limit "$consecutive_error_limit")
  if [[ -n "$model" ]]; then
    cmd+=(--model "$model")
  fi
  if [[ -n "$profile" ]]; then
    cmd+=(--profile "$profile")
  fi
  if [[ -f "$add_dirs_file" ]]; then
    while IFS= read -r add_dir; do
      [[ -n "$add_dir" ]] || continue
      cmd+=(--add-dir "$add_dir")
    done < "$add_dirs_file"
  fi
  cmd+=("$prompt_text")

  if "${cmd[@]}"; then
    LAUNCH_GENERATED_ROUND_EXIT_CODE=0
  else
    LAUNCH_GENERATED_ROUND_EXIT_CODE=$?
  fi

  local launched_loop_id=""
  local active_file
  active_file="$(active_loop_file "$workspace")"
  if [[ -f "$active_file" ]]; then
    launched_loop_id="$(<"$active_file")"
  fi
  printf -v "$loop_id_var_name" '%s' "$launched_loop_id"
}

update_campaign_state_value() {
  local state_file="$1"
  local key="$2"
  local value="$3"
  load_state "$state_file"
  printf -v "$key" '%s' "$value"
  write_state "$state_file" \
    CAMPAIGN_ID "$CAMPAIGN_ID" \
    STATUS "$STATUS" \
    WORKSPACE "$WORKSPACE" \
    CREATED_AT "$CREATED_AT" \
    UPDATED_AT "$(timestamp_utc)" \
    ROUND "$ROUND" \
    CURRENT_LOOP_ID "$CURRENT_LOOP_ID" \
    MAX_ROUNDS "$MAX_ROUNDS" \
    LOOP_MAX_ITERATIONS "$LOOP_MAX_ITERATIONS" \
    MODEL "$MODEL" \
    PROFILE "$PROFILE" \
    SANDBOX_MODE "$SANDBOX_MODE" \
    APPROVAL_POLICY "$APPROVAL_POLICY" \
    CONSECUTIVE_ERROR_LIMIT "$CONSECUTIVE_ERROR_LIMIT" \
    PID "$PID" \
    LAST_VERIFY_EXIT_CODE "$LAST_VERIFY_EXIT_CODE" \
    LAST_VERIFY_LOG "$LAST_VERIFY_LOG" \
    VERIFY_CMD "$VERIFY_CMD" \
    BOUNDARY_DOC "$BOUNDARY_DOC" \
    BOUNDARY_SECTION "$BOUNDARY_SECTION" \
    LAST_BOUNDARY_COUNT "$LAST_BOUNDARY_COUNT" \
    BOUNDARY_SNAPSHOT_FILE "$BOUNDARY_SNAPSHOT_FILE" \
    PROMISE_PREFIX "$PROMISE_PREFIX" \
    GOAL_FILE "$GOAL_FILE" \
    ADD_DIRS_FILE "$ADD_DIRS_FILE" \
    SCRIPT_VERSION "$SCRIPT_VERSION"
}

cancel_campaign_current_loop() {
  local workspace="$1"
  local campaign_id="$2"
  local campaign_state_file
  campaign_state_file="$(campaign_dir "$workspace" "$campaign_id")/state.env"
  [[ -f "$campaign_state_file" ]] || return 0
  load_state "$campaign_state_file"
  if [[ -n "${CURRENT_LOOP_ID:-}" ]] && [[ -f "$(loop_dir "$workspace" "$CURRENT_LOOP_ID")/state.env" ]]; then
    bash "$(abspath "${BASH_SOURCE[0]}")" cancel --loop-id "$CURRENT_LOOP_ID" >/dev/null 2>&1 || true
  fi
}

handle_campaign_signal() {
  local workspace="$1"
  local campaign_id="$2"
  local campaign_dir_path
  campaign_dir_path="$(campaign_dir "$workspace" "$campaign_id")"
  : > "$campaign_dir_path/cancel-requested"
  cancel_campaign_current_loop "$workspace" "$campaign_id"
  local state_file="$campaign_dir_path/state.env"
  if [[ -f "$state_file" ]]; then
    mark_campaign_terminal_state "$state_file" "cancelled"
  fi
  exit 130
}

clear_screen() {
  if command -v tput >/dev/null 2>&1; then
    tput clear
  else
    printf '\033[2J\033[H'
  fi
}

dashboard_url_from_info() {
  local info_file="$1"
  [[ -f "$info_file" ]] || return 0
  perl -0ne 'if (/"url"\s*:\s*"([^"]+)"/) { print $1; }' "$info_file"
}

is_dashboard_process_running() {
  local pid_file="$1"
  [[ -f "$pid_file" ]] || return 1
  local pid
  pid="$(<"$pid_file")"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

open_browser_url() {
  local url="$1"
  [[ -n "$url" ]] || return 0
  if is_macos && command -v open >/dev/null 2>&1; then
    open "$url" >/dev/null 2>&1 || true
    return 0
  fi
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" >/dev/null 2>&1 || true
  fi
}

is_macos() {
  [[ "$(uname -s)" == "Darwin" ]]
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

main "$@"
