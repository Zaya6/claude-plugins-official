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

# Write a fake access.json with a sentinel numeric user ID so that
# fireStallAlert enters its send loop on stdin_end. The bot can't actually
# message itself, so stall_alert.failed is expected — but stall_alert.attempt
# MUST fire. Using a clearly-fake ID (00000) to avoid an accidental live send.
cat > "$SMOKE_DIR/access.json" <<'EOF'
{"allowlist":{"00000":{"approved_at":"1970-01-01T00:00:00Z"}}}
EOF
chmod 600 "$SMOKE_DIR/access.json"

# The server.ts .env loader is non-overriding (process.env wins), so if the
# caller's environment already has TELEGRAM_BOT_TOKEN set the plugin would
# silently use that instead of the sandbox token — exactly the bug Patch 1
# is trying to expose elsewhere. Explicitly unset+export to bind cleanly.
unset TELEGRAM_BOT_TOKEN
export TELEGRAM_BOT_TOKEN="$TELEGRAM_SMOKE_TOKEN"

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

# Requires Task 1.2's heartbeat.tick setInterval to be in place — will fail until then.
# Verify heartbeat fires within 75 seconds of start
echo "--- waiting for first heartbeat.tick (max 75s) ---"
for i in $(seq 1 75); do
  if grep -q '"event":"heartbeat.tick"' "$SMOKE_DIR/plugin.log"; then
    echo "heartbeat seen at $i seconds"
    break
  fi
  sleep 1
done
grep -q '"event":"heartbeat.tick"' "$SMOKE_DIR/plugin.log" || { echo "FAIL: no heartbeat.tick in 75s"; exit 1; }

# Task 1.5: verify fireStallAlert fires on stdin_end shutdown.
# access.json was written before plugin start with a fake allowlist entry (00000).
# stdin_end hits SHUTDOWN_ALERT_REASONS → stall_alert.attempt must appear.
# The actual send will fail (00000 is not a real Telegram user) and that's expected.
echo "--- testing stall_alert.attempt fires on stdin_end ---"
grep -q '"event":"stall_alert.attempt"' "$SMOKE_DIR/plugin.log" || {
  echo "FAIL: no stall_alert.attempt fired on stdin_end"
  echo "--- plugin.log ---" >&2
  cat "$SMOKE_DIR/plugin.log" >&2
  exit 1
}
echo "stall_alert.attempt seen"

echo "PASS: $(wc -l < "$LOG") events logged, all required events present"
