#!/usr/bin/env python3
"""Turn a raw `n8n export:workflow --all --separate` dump into the files in workflows/.

Usage:
    docker exec n8n n8n export:workflow --all --separate --output=/home/node/.n8n/export/
    docker cp n8n:/home/node/.n8n/export ./export
    python3 scripts/sanitize_workflows.py export workflows

What it does:
  * skips archived workflows and anything not tagged `stan-hunter`
  * drops runtime state (pinData, staticData, version ids, timestamps, sharing info)
  * replaces your Telegram chat id with the placeholder 123456789 when the
    TELEGRAM_CHAT_ID environment variable is set
  * writes one pretty-printed file per workflow, named after the workflow
  * FAILS if anything that looks like a secret is found (Telegram bot token,
    Anthropic / Google keys, private keys) — fix the source, never commit it.

Credentials are referenced by name only; after importing, map them in the n8n UI.
"""
import json
import os
import re
import sys
from pathlib import Path

DROP_KEYS = {
    "pinData", "staticData", "versionId", "activeVersionId", "activeVersion",
    "shared", "triggerCount", "createdAt", "updatedAt", "versionCounter",
    "parentFolder", "parentFolderId", "homeProject", "scopes",
}
CHAT_ID_PLACEHOLDER = "123456789"
SECRET_PATTERNS = {
    "Telegram bot token": re.compile(r"\b\d{8,10}:[A-Za-z0-9_-]{30,}\b"),
    "Anthropic API key": re.compile(r"sk-ant-[A-Za-z0-9_-]{10,}"),
    "Google API key": re.compile(r"AIza[0-9A-Za-z_-]{30,}"),
    "Private key": re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
}


def slug(name: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return s or "workflow"


def clean(wf: dict) -> dict:
    out = {k: v for k, v in wf.items() if k not in DROP_KEYS}
    out["tags"] = sorted(t["name"] if isinstance(t, dict) else t for t in wf.get("tags", []))
    meta = dict(out.get("meta") or {})
    meta.pop("instanceId", None)
    out["meta"] = meta
    for node in out.get("nodes", []):
        for cred in (node.get("credentials") or {}).values():
            cred.pop("id", None)  # local ids are meaningless on another instance
    return out


def main(src: str, dst: str) -> int:
    src_dir, dst_dir = Path(src), Path(dst)
    dst_dir.mkdir(parents=True, exist_ok=True)
    problems, written = [], []
    chat_id = os.environ.get("TELEGRAM_CHAT_ID", "").strip()
    if not chat_id:
        print("warning: TELEGRAM_CHAT_ID not set, chat ids are left as exported", file=sys.stderr)
    for path in sorted(src_dir.glob("*.json")):
        wf = json.loads(path.read_text(encoding="utf-8"))
        tags = {t["name"] if isinstance(t, dict) else t for t in wf.get("tags", [])}
        if wf.get("isArchived") or "stan-hunter" not in tags:
            continue
        text = json.dumps(clean(wf), ensure_ascii=False, indent=2) + "\n"
        if chat_id:
            text = text.replace(chat_id, CHAT_ID_PLACEHOLDER)
        for label, rx in SECRET_PATTERNS.items():
            if rx.search(text):
                problems.append(f"{wf['name']}: looks like a {label}")
        target = dst_dir / f"{slug(wf['name'])}.json"
        target.write_text(text, encoding="utf-8")
        written.append(target.name)
    for name in written:
        print("wrote", name)
    if problems:
        print("\nSECRET CHECK FAILED:", *problems, sep="\n  ", file=sys.stderr)
        return 1
    print(f"\n{len(written)} workflows, secret check passed")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1], sys.argv[2]))
