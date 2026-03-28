#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PLUGIN_DIR="$ROOT_DIR/plugins/ralph"
LOOP_SCRIPT="$PLUGIN_DIR/scripts/ralph-loop.sh"
DASHBOARD_SCRIPT="$PLUGIN_DIR/scripts/ralph-dashboard.mjs"
PLUGIN_JSON="$PLUGIN_DIR/.codex-plugin/plugin.json"
INSTALL_SCRIPT="$ROOT_DIR/scripts/install-home-plugin.sh"
ROOT_README="$ROOT_DIR/README.md"
PLUGIN_README="$PLUGIN_DIR/README.md"
TEAM_INSTALL_DOC="$ROOT_DIR/docs/TEAM_INSTALL.md"
RELEASE_CHECKLIST_DOC="$ROOT_DIR/docs/RELEASE_CHECKLIST.md"

PASS_COUNT=0

pass() {
  printf 'ok - %s\n' "$1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

require_file() {
  [[ -f "$1" ]] || fail "missing required file: $1"
}

require_executable() {
  [[ -x "$1" ]] || fail "expected executable file: $1"
}

require_cmd bash
require_cmd node
require_cmd perl
pass "required host commands are available"

require_file "$PLUGIN_JSON"
require_file "$DASHBOARD_SCRIPT"
require_file "$ROOT_README"
require_file "$PLUGIN_README"
require_file "$TEAM_INSTALL_DOC"
require_file "$RELEASE_CHECKLIST_DOC"
require_executable "$LOOP_SCRIPT"
require_executable "$INSTALL_SCRIPT"
pass "core repo files are present"

bash -n "$LOOP_SCRIPT"
pass "ralph-loop.sh parses"

node --check "$DASHBOARD_SCRIPT"
pass "ralph-dashboard.mjs parses"

bash "$LOOP_SCRIPT" help >/dev/null
pass "ralph-loop.sh help renders"

JSON_VERSION="$(node -e 'const fs = require("node:fs"); const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); process.stdout.write(String(data.version || ""));' "$PLUGIN_JSON")"
SCRIPT_VERSION="$(perl -ne 'print "$1" if /^SCRIPT_VERSION=\"([^\"]+)\"/' "$LOOP_SCRIPT")"

[[ -n "$JSON_VERSION" ]] || fail "plugin.json version is empty"
[[ -n "$SCRIPT_VERSION" ]] || fail "SCRIPT_VERSION is empty"
[[ "$JSON_VERSION" == "$SCRIPT_VERSION" ]] || fail "version mismatch: plugin.json=$JSON_VERSION script=$SCRIPT_VERSION"
pass "plugin.json and SCRIPT_VERSION are synchronized ($JSON_VERSION)"

for command in start status watch cancel resume campaign campaign-status campaign-cancel dashboard dashboard-status dashboard-stop; do
  require_file "$PLUGIN_DIR/commands/$command.md"
done
pass "expected command wrappers are present"

if command -v codex >/dev/null 2>&1; then
  codex --version >/dev/null
  pass "codex CLI is installed"
else
  printf 'warn - codex CLI not found; skipped runtime prerequisite check\n'
fi

printf '\nStatic smoke test passed (%s checks).\n' "$PASS_COUNT"
printf 'This script does not run a live Codex loop. Use docs/RELEASE_CHECKLIST.md for foreground, resume, watch, dashboard, and campaign validation.\n'
