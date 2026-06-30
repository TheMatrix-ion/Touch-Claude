#!/usr/bin/env python3
"""Install / remove the Claude Code ``Stop`` hook that nudges the Touch Bar mascot.

When Claude Code finishes a turn it fires the ``Stop`` hook; we register a tiny
command that touches ``~/.claude-touchbar/poke``. The native helper watches that
file's modification time and plays a two-hop bounce on the mascot.

Usage:
    configure_stop_hook.py            # install (idempotent)
    configure_stop_hook.py --remove   # uninstall

The edit is non-destructive: existing hooks are preserved, and a timestamped
backup of settings.json is written before any change.
"""
from __future__ import annotations

import json
import os
import shutil
import sys
import time

SETTINGS_PATH = os.path.expanduser("~/.claude/settings.json")
# Substring that uniquely identifies our hook command (used for idempotency).
MARKER = ".claude-touchbar/poke"
COMMAND = 'mkdir -p "$HOME/.claude-touchbar" && touch "$HOME/.claude-touchbar/poke"'


def _load() -> dict:
    if os.path.exists(SETTINGS_PATH):
        with open(SETTINGS_PATH, encoding="utf-8") as handle:
            return json.load(handle)
    return {}


def _backup() -> None:
    if os.path.exists(SETTINGS_PATH):
        stamp = time.strftime("%Y%m%d-%H%M%S")
        shutil.copy2(SETTINGS_PATH, f"{SETTINGS_PATH}.bak-{stamp}")


def _save(data: dict) -> None:
    os.makedirs(os.path.dirname(SETTINGS_PATH), exist_ok=True)
    with open(SETTINGS_PATH, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, ensure_ascii=False)
        handle.write("\n")


def _has_hook(data: dict) -> bool:
    for group in data.get("hooks", {}).get("Stop", []):
        for hook in group.get("hooks", []):
            if MARKER in (hook.get("command") or ""):
                return True
    return False


def install() -> int:
    data = _load()
    if _has_hook(data):
        print("Stop hook already installed — nothing to do.")
        return 0

    _backup()
    hooks = data.setdefault("hooks", {})
    stop = hooks.setdefault("Stop", [])
    stop.append({
        "matcher": "",
        "hooks": [{"type": "command", "command": COMMAND, "timeout": 5}],
    })
    _save(data)
    print(f"Installed Stop hook into {SETTINGS_PATH}")
    print("Open a new Claude Code session for it to take effect.")
    return 0


def remove() -> int:
    data = _load()
    if not _has_hook(data):
        print("Stop hook not present — nothing to remove.")
        return 0

    _backup()
    stop_groups = data.get("hooks", {}).get("Stop", [])
    cleaned = []
    for group in stop_groups:
        group["hooks"] = [
            hook for hook in group.get("hooks", [])
            if MARKER not in (hook.get("command") or "")
        ]
        if group.get("hooks"):
            cleaned.append(group)

    if cleaned:
        data["hooks"]["Stop"] = cleaned
    else:
        data["hooks"].pop("Stop", None)
        if not data["hooks"]:
            data.pop("hooks", None)

    _save(data)
    print(f"Removed Stop hook from {SETTINGS_PATH}")
    return 0


def main(argv: list[str]) -> int:
    if argv and argv[0] in {"--remove", "remove", "--uninstall"}:
        return remove()
    if argv and argv[0] in {"-h", "--help"}:
        print(__doc__)
        return 0
    return install()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
