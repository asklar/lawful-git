#!/usr/bin/env python3

import hashlib
import json
import os
import pathlib
import subprocess
import sys
import time


def compute_action_id(payload: dict) -> str:
    repo = payload.get("repo", "")
    args = payload.get("args") or []
    just = payload.get("justification", "")
    s = repo + "\0" + "\0".join(map(str, args)) + "\0" + just
    h = hashlib.sha256(s.encode("utf-8")).hexdigest()
    return h[:12]


def decisions_path() -> pathlib.Path:
    p = os.environ.get("LAWFUL_GIT_CONSENT_DECISIONS", "").strip()
    if p:
        return pathlib.Path(p).expanduser()
    return pathlib.Path.home() / ".openclaw" / "consent" / "decisions.jsonl"


def send_inline_buttons(target: str, action_id: str, payload: dict) -> None:
    approve = f"lawful:approve:{action_id}"
    deny = f"lawful:deny:{action_id}"

    repo = payload.get("repo", "")
    branch = payload.get("branch", "")
    args = payload.get("args") or []
    message = payload.get("message", "")
    justification = payload.get("justification", "")

    text = (
        "lawful-git consent required\n\n"
        f"repo: {repo}\n"
        f"branch: {branch}\n"
        f"action: git {' '.join(map(str, args))}\n\n"
        f"rule: {message}\n\n"
        "justification:\n"
        f"{justification}\n\n"
        "approve? (60s timeout)"
    )

    buttons = [[
        {"text": "Approve", "callback_data": approve},
        {"text": "Reject", "callback_data": deny},
    ]]

    # openclaw expects JSON for --buttons
    buttons_json = json.dumps(buttons, separators=(",", ":"))

    subprocess.run(
        [
            "openclaw",
            "message",
            "send",
            "--channel",
            "telegram",
            "--target",
            target,
            "--message",
            text,
            "--buttons",
            buttons_json,
        ],
        check=True,
    )


def wait_for_decision(decisions_file: pathlib.Path, action_id: str, timeout_s: float = 60.0) -> str:
    deadline = time.time() + timeout_s

    while time.time() < deadline:
        if decisions_file.exists():
            try:
                with decisions_file.open("r", encoding="utf-8") as f:
                    for line in f:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            obj = json.loads(line)
                        except Exception:
                            continue
                        if obj.get("action_id") == action_id:
                            return str(obj.get("decision") or "")
            except Exception:
                pass

        time.sleep(0.3)

    raise TimeoutError("timeout")


def main() -> int:
    raw = sys.stdin.read()
    payload = json.loads(raw)

    target = os.environ.get("LAWFUL_GIT_CONSENT_TELEGRAM_TARGET", "").strip()
    if not target:
        print("LAWFUL_GIT_CONSENT_TELEGRAM_TARGET is required (e.g. telegram:<your_chat_id>)", file=sys.stderr)
        return 2

    action_id = compute_action_id(payload)

    df = decisions_path()
    df.parent.mkdir(parents=True, exist_ok=True)

    try:
        send_inline_buttons(target, action_id, payload)
    except subprocess.CalledProcessError as e:
        print(f"failed to send telegram inline buttons via openclaw: {e}", file=sys.stderr)
        return 2

    try:
        decision = wait_for_decision(df, action_id, timeout_s=60.0)
    except TimeoutError:
        print("consent timed out (blocking)", file=sys.stderr)
        return 1

    return 0 if decision == "approve" else 1


if __name__ == "__main__":
    raise SystemExit(main())
