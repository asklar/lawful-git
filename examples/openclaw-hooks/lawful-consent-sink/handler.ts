import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";

// Matches: lawful:approve:<id> / lawful:deny:<id>
const RE = /^lawful:(approve|deny):([a-f0-9]{6,64})$/;

type HookEvent = {
  type: string;
  action: string;
  sessionKey: string;
  timestamp: Date;
  messages: string[];
  context?: {
    content?: string;
  };
};

export default async function handler(event: HookEvent) {
  if (event?.type !== "message" || event?.action !== "received") return;

  const content = String(event?.context?.content ?? "").trim();
  const m = content.match(RE);
  if (!m) return;

  const decision = m[1] === "approve" ? "approve" : "deny";
  const action_id = m[2];

  const decisionsPath =
    process.env.LAWFUL_GIT_CONSENT_DECISIONS?.trim() ||
    path.join(os.homedir(), ".openclaw", "consent", "decisions.jsonl");

  await fs.mkdir(path.dirname(decisionsPath), { recursive: true });

  // Keep it minimal + machine readable.
  const line = JSON.stringify({
    action_id,
    decision,
    ts: new Date().toISOString(),
  });

  await fs.appendFile(decisionsPath, line + "\n", { encoding: "utf-8" });
}
