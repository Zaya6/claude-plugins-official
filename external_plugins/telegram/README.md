# Telegram

Connect a Telegram bot to your Claude Code with an MCP server.

The MCP server logs into Telegram as a bot and provides tools to Claude to reply, react, or edit messages. When you message the bot, the server forwards the message to your Claude Code session.

## Prerequisites

- [Bun](https://bun.sh) — the MCP server runs on Bun. Install with `curl -fsSL https://bun.sh/install | bash`.

## Quick Setup
> Default pairing flow for a single-user DM bot. See [ACCESS.md](./ACCESS.md) for groups and multi-user setups.

**1. Create a bot with BotFather.**

Open a chat with [@BotFather](https://t.me/BotFather) on Telegram and send `/newbot`. BotFather asks for two things:

- **Name** — the display name shown in chat headers (anything, can contain spaces)
- **Username** — a unique handle ending in `bot` (e.g. `my_assistant_bot`). This becomes your bot's link: `t.me/my_assistant_bot`.

BotFather replies with a token that looks like `123456789:AAHfiqksKZ8...` — that's the whole token, copy it including the leading number and colon.

**2. Install the plugin.**

These are Claude Code commands — run `claude` to start a session first.

Install the plugin:
```
/plugin install telegram@claude-plugins-official
/reload-plugins
```

**3. Give the server the token.**

```
/telegram:configure 123456789:AAHfiqksKZ8...
```

Writes `TELEGRAM_BOT_TOKEN=...` to `~/.claude/channels/telegram/.env`. You can also write that file by hand, or set the variable in your shell environment — shell takes precedence.

> To run multiple bots on one machine (different tokens, separate allowlists), point `TELEGRAM_STATE_DIR` at a different directory per instance.

**4. Relaunch with the channel flag.**

The server won't connect without this — exit your session and start a new one:

```sh
claude --channels plugin:telegram@claude-plugins-official
```

**5. Pair.**

With Claude Code running from the previous step, DM your bot on Telegram — it replies with a 6-character pairing code. If the bot doesn't respond, make sure your session is running with `--channels`. In your Claude Code session:

```
/telegram:access pair <code>
```

Your next DM reaches the assistant.

> Unlike Discord, there's no server invite step — Telegram bots accept DMs immediately. Pairing handles the user-ID lookup so you never touch numeric IDs.

**6. Lock it down.**

Pairing is for capturing IDs. Once you're in, switch to `allowlist` so strangers don't get pairing-code replies. Ask Claude to do it, or `/telegram:access policy allowlist` directly.

## Access control

See **[ACCESS.md](./ACCESS.md)** for DM policies, groups, mention detection, delivery config, skill commands, and the `access.json` schema.

Quick reference: IDs are **numeric user IDs** (get yours from [@userinfobot](https://t.me/userinfobot)). Default policy is `pairing`. `ackReaction` only accepts Telegram's fixed emoji whitelist.

## Tools exposed to the assistant

| Tool | Purpose |
| --- | --- |
| `reply` | Send to a chat. Takes `chat_id` + `text`, optionally `reply_to` (message ID) for native threading and `files` (absolute paths) for attachments. Images (`.jpg`/`.png`/`.gif`/`.webp`) send as photos with inline preview; other types send as documents. Max 50MB each. Auto-chunks text; files send as separate messages after the text. Returns the sent message ID(s). |
| `react` | Add an emoji reaction to a message by ID. **Only Telegram's fixed whitelist** is accepted (👍 👎 ❤ 🔥 👀 etc). |
| `edit_message` | Edit a message the bot previously sent. Useful for "working…" → result progress updates. Only works on the bot's own messages. |
| `download_attachment` | Fetch a Telegram attachment by `file_id` to the local inbox. Returns the path. Photos sent during a live session are auto-downloaded — this is for cases where the assistant needs to re-fetch or pull non-photo attachments by ID. |
| `restart_polling` | Recycle the bot's polling loop in-process. Use when polling appears stalled despite the plugin still being alive — no plugin/session restart needed. 10s cooldown. |

Tool errors carry a classification tag: `reply failed [auth 403]: ...` or `reply failed [network]: ...`. Categories are `network` / `rate_limit` / `server` (retry-safe), `malformed` (fix args), `auth` (escalate). Each error includes a one-line action hint.

Inbound messages trigger a typing indicator automatically — Telegram shows
"botname is typing…" while the assistant works on a response.

## Photos

Inbound photos are downloaded to `~/.claude/channels/telegram/inbox/` and the
local path is included in the `<channel>` notification so the assistant can
`Read` it. Telegram compresses photos — if you need the original file, send it
as a document instead (long-press → Send as File).

## Persistent log

The plugin writes one JSON object per line to `~/.claude/channels/telegram/plugin.log`
(or `$TELEGRAM_STATE_DIR/plugin.log` for multi-bot installs). It rotates at
10MB and keeps 3 archives. Every line has at minimum:

```json
{"ts": 1778473356258, "bot_id": "8614860376", "event": "inbound.message", ...}
```

`ts` is Unix milliseconds. `bot_id` is the numeric prefix of the bot token —
useful when several bots share a state-dir ancestor and you need to demux a
shared log path. `event` names the lifecycle stage.

Common events:

| Event | When |
| --- | --- |
| `plugin.start` / `plugin.exit` | Process lifecycle, with `pid`/`ppid`/`code`. |
| `polling.start` | Long-poll loop has connected to Telegram, includes resolved `username`. |
| `polling.error` / `polling.shutdown` / `polling.restart` | Loop transitions. `fatal: true` means the loop is giving up. |
| `reconnect.attempt` / `reconnect.success` | Backoff retries after a transient failure. |
| `inbound.message` / `inbound.delivered_to_mcp` | A message arrived from Telegram and was forwarded to the MCP transport. |
| `tool_call.entry` / `outbound.reply` / `outbound.react` / `outbound.edit` / `outbound.download_attachment` | Tool invocations and their outcomes. |
| `outbound.failure` | A tool throw — includes `kind`, `code`, `error`. |
| `env.load_error` / `env.chmod_error` | The `.env` loader hit something other than ENOENT. |

The log is the forensic ground truth — when a message seems lost, tailing
this file disambiguates "never reached the plugin" from "reached plugin but
the model didn't act."

## No history or search

Telegram's Bot API exposes **neither** message history nor search. The bot
only sees messages as they arrive. If the assistant needs earlier context,
it will ask you to paste or summarize.
