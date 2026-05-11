#!/usr/bin/env bash
# Smoke test for the persistent-log patch.
#
# Starts the plugin with a sandbox token in a temp state dir, holds stdin
# open just long enough for polling to start, then sends EOF for a clean
# shutdown. Asserts that the expected log events appear in plugin.log.
#
# Required env: TELEGRAM_SMOKE_TOKEN — a bot token nobody else is polling.
#   The test will briefly grab the getUpdates slot, so do NOT use a token
#   that's currently in production use.
#
# Exit 0 on pass, non-zero on fail. ~5s runtime.

set -euo pipefail

if [[ -z "${TELEGRAM_SMOKE_TOKEN:-}" ]]; then
  echo "smoke: set TELEGRAM_SMOKE_TOKEN to a sandbox bot token" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SMOKE_DIR="$(mktemp -d -t telegram-plugin-smoke.XXXXXX)"
trap 'rm -rf "$SMOKE_DIR"' EXIT

echo "TELEGRAM_BOT_TOKEN=$TELEGRAM_SMOKE_TOKEN" > "$SMOKE_DIR/.env"
chmod 600 "$SMOKE_DIR/.env"

# Hold stdin open 4s via `sleep` redirected in — plugin will see EOF when sleep exits.
TELEGRAM_STATE_DIR="$SMOKE_DIR" \
  bun "$SCRIPT_DIR/server.ts" < <(sleep 4) > "$SMOKE_DIR/stdout.log" 2> "$SMOKE_DIR/stderr.log" &
PLUGIN_PID=$!
wait $PLUGIN_PID || true

LOG="$SMOKE_DIR/plugin.log"
if [[ ! -f "$LOG" ]]; then
  echo "FAIL: plugin.log was not created" >&2
  cat "$SMOKE_DIR/stderr.log" >&2
  exit 1
fi

# Each event we expect to see fire during a clean boot + stdin-close cycle.
REQUIRED=(
  plugin.start
  polling.start
  mcp.stdin_end
  polling.shutdown
  plugin.exit
)

missing=()
for evt in "${REQUIRED[@]}"; do
  grep -q "\"event\":\"$evt\"" "$LOG" || missing+=("$evt")
done

if (( ${#missing[@]} > 0 )); then
  echo "FAIL: missing required events: ${missing[*]}" >&2
  echo "--- plugin.log ---" >&2
  cat "$LOG" >&2
  echo "--- stderr ---" >&2
  cat "$SMOKE_DIR/stderr.log" >&2
  exit 1
fi

# JSON-lines integrity check — every line must be valid JSON with ts + event.
if ! awk 'NF { if (!match($0, /"ts":[0-9]+/) || !match($0, /"event":"[^"]+"/)) exit 1 }' "$LOG"; then
  echo "FAIL: plugin.log contains malformed lines" >&2
  cat "$LOG" >&2
  exit 1
fi

echo "PASS: $(wc -l < "$LOG") events logged, all required events present"
