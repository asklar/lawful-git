# OpenClaw consent_command helper

This integrates lawful-git consent prompts with OpenClaw + Telegram inline buttons.

## Screenshots

> Telegram screenshot is real (with repo name blurred). Windows/console screenshots are illustrative.

### Telegram (OpenClaw inline buttons)

![Telegram consent prompt](./assets/consent-telegram.png)

### Windows native dialog (built-in fallback)

![Windows consent dialog](./assets/consent-windows-dialog.png)

### Console prompt (built-in fallback)

![Console consent prompt](./assets/consent-console.png)

## Prereq: enable Telegram inline buttons in OpenClaw

In your OpenClaw config (JSON/JSON5), enable inline buttons:

```jsonc
{
  "channels": {
    "telegram": {
      "capabilities": {
        "inlineButtons": "dm" // safest starting point
      }
    }
  }
}
```

Then restart the gateway:

```sh
openclaw gateway restart
```

## How it works (lawful-git)
- lawful-git detects a consent rule
- it requires the caller to write a justification file, then retry the exact command
- on retry, lawful-git invokes `consent_command` and pipes a JSON payload to stdin
- exit code determines approval:
  - 0 = approved
  - non-zero = denied

## Helper: `lawful_git_consent_openclaw.py`
This helper:
1. Reads stdin JSON payload from lawful-git
2. Computes a deterministic `action_id`
3. Sends you a Telegram message with inline buttons via `openclaw message send --buttons ...`
4. Waits up to 60s for a decision to appear in `~/.openclaw/consent/decisions.jsonl`
5. Exits 0 if approved, 1 otherwise (timeout blocks)

### Install
From the repo root:

```sh
chmod +x scripts/lawful_git_consent_openclaw.py
sudo ln -sf "$PWD/scripts/lawful_git_consent_openclaw.py" /usr/local/bin/lawful-git-consent-openclaw
```

### Env vars
- `LAWFUL_GIT_CONSENT_TELEGRAM_TARGET` (required)
  - example: `telegram:<your_chat_id>`
- `LAWFUL_GIT_CONSENT_DECISIONS` (optional)
  - defaults to `~/.openclaw/consent/decisions.jsonl`

### lawful-git config
Set `consent_command` globally or per-repo:

```jsonc
{
  "consent_command": "lawful-git-consent-openclaw",
  "blocked": [
    { "command": "push", "flags": ["--force", "-f"], "action": "consent", "message": "Force push requires consent." }
  ]
}
```

## Decision bridge (who writes `decisions.jsonl`?)
The consent helper (`lawful-git-consent-openclaw`) is a separate process. It can send the Telegram buttons, but it **cannot receive** the callback from Telegram directly.

When you click an inline button, OpenClaw delivers `callback_data` back into the OpenClaw runtime (your agent session) as a message:

- `lawful:approve:<action_id>`
- `lawful:deny:<action_id>`

To complete the loop, something running inside OpenClaw must translate that callback into a decision entry by appending a line to the decisions file:

`~/.openclaw/consent/decisions.jsonl`
```json
{"action_id":"<action_id>","decision":"approve|deny","ts":"2026-03-07T16:54:23-0800"}
```

The consent helper tails/polls this file for up to 60s:
- If it sees `approve` for the matching `action_id`, it exits **0** (lawful-git proceeds)
- If it sees `deny`, or times out, it exits **non-zero** (lawful-git blocks)

### Implementing the sink
The simplest approach (works today) is: configure your OpenClaw agent to always write decisions.

**Instruction to give your OpenClaw agent (copy/paste):**

> If you receive a message exactly matching `lawful:approve:<id>` or `lawful:deny:<id>`, append a single JSONL line to `~/.openclaw/consent/decisions.jsonl` with:
> `{ "action_id": "<id>", "decision": "approve"|"deny", "ts": "<ISO timestamp>" }`.
> Do not write anything else.

Without this sink, the helper will always time out and deny.

Longer-term, OpenClaw could provide a built-in callback sink / hook so this doesn't depend on agent instructions.
