---
name: lawful-consent-sink
description: "Reference OpenClaw hook: translate lawful:approve/deny:<id> callbacks into decisions.jsonl for lawful-git consent_command helpers."
metadata:
  openclaw:
    emoji: "✅"
    events: ["message:received"]
---

# lawful-consent-sink (reference)

This is a reference implementation of an OpenClaw hook that bridges Telegram inline button callbacks back to the lawful-git consent_command helper process.

## What it does

- Watches inbound messages for:
  - `lawful:approve:<action_id>`
  - `lawful:deny:<action_id>`
- Appends a JSONL decision line to:
  - `~/.openclaw/consent/decisions.jsonl` (default)
  - or `$LAWFUL_GIT_CONSENT_DECISIONS` if set

The lawful-git `consent_command` helper polls this file to decide whether to exit 0 (approve) or non-zero (deny/timeout).

## Install (example)

Copy this folder into one of OpenClaw's hook discovery locations:

- Workspace hooks: `<workspace>/hooks/`
- Managed hooks: `~/.openclaw/hooks/`

Then enable it:

```sh
openclaw hooks list
openclaw hooks enable lawful-consent-sink
openclaw gateway restart
```
