# OpenClaw consent_command helper

This integrates lawful-git consent prompts with OpenClaw + Telegram inline buttons.

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

## Decision bridge
When you click an inline button, OpenClaw delivers `callback_data` back into the agent session as text:

- `lawful:approve:<action_id>`
- `lawful:deny:<action_id>`

The agent should append a JSONL decision entry to the decisions file.
