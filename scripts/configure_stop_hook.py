#!/usr/bin/env python3
"""Install or remove the Claude Code ``Stop`` hook used by Touch Claude.

The installed hook passes Claude Code's JSON stdin to the private
``_record-stop`` command in the installed helper. Existing non-Touch-Claude
hooks are preserved, and the legacy poke-only hook is migrated in place.

Usage:
    configure_stop_hook.py            # install or migrate (idempotent)
    configure_stop_hook.py --remove   # remove legacy and current hooks
"""
from __future__ import annotations

import fcntl
import json
import os
import shutil
import sys
import tempfile
import time
from contextlib import contextmanager
from collections.abc import Iterator
from typing import Optional


SETTINGS_PATH = os.path.abspath(os.path.expanduser(
    os.environ.get("CLAWD_CLAUDE_SETTINGS_PATH", "~/.claude/settings.json")
))
LOCK_PATH = f"{SETTINGS_PATH}.clawd.lock"

LEGACY_MARKER = ".claude-touchbar/poke"
CURRENT_BINARY_MARKER = ".claude-touchbar/bin/ClaudeTouchBar"
CURRENT_COMMAND_MARKER = "_record-stop"
COMMAND = '"$HOME/.claude-touchbar/bin/ClaudeTouchBar" _record-stop'
HOOK_TIMEOUT_SECONDS = 5


@contextmanager
def _settings_lock() -> Iterator[None]:
    directory = os.path.dirname(SETTINGS_PATH)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    descriptor = os.open(LOCK_PATH, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def _load() -> dict:
    if not os.path.exists(SETTINGS_PATH):
        return {}
    with open(SETTINGS_PATH, encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"{SETTINGS_PATH} must contain a JSON object")
    return data


def _backup() -> Optional[str]:
    if not os.path.exists(SETTINGS_PATH):
        return None
    stamp = time.strftime("%Y%m%d-%H%M%S")
    backup_path = f"{SETTINGS_PATH}.bak-{stamp}-{os.getpid()}"
    shutil.copy2(SETTINGS_PATH, backup_path)
    os.chmod(backup_path, 0o600)
    return backup_path


def _save(data: dict) -> None:
    directory = os.path.dirname(SETTINGS_PATH)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    descriptor, temporary_path = tempfile.mkstemp(
        prefix=".settings.json.clawd-",
        dir=directory,
    )
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, SETTINGS_PATH)
        os.chmod(SETTINGS_PATH, 0o600)
    except BaseException:
        try:
            os.unlink(temporary_path)
        except FileNotFoundError:
            pass
        raise


def _ensure_private_permissions() -> None:
    if os.path.exists(SETTINGS_PATH):
        os.chmod(SETTINGS_PATH, 0o600)


def _is_touch_claude_hook(hook: object) -> bool:
    if not isinstance(hook, dict):
        return False
    command = hook.get("command")
    if not isinstance(command, str):
        return False
    return (
        LEGACY_MARKER in command
        or (
            CURRENT_BINARY_MARKER in command
            and CURRENT_COMMAND_MARKER in command
        )
    )


def _canonical_hook(existing: Optional[dict] = None) -> dict:
    hook = dict(existing or {})
    hook["type"] = "command"
    hook["command"] = COMMAND
    hook["timeout"] = HOOK_TIMEOUT_SECONDS
    hook.pop("async", None)
    return hook


def _install_hook(data: dict) -> tuple[bool, bool]:
    hooks = data.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError("settings key 'hooks' must be a JSON object")
    stop_groups = hooks.setdefault("Stop", [])
    if not isinstance(stop_groups, list):
        raise ValueError("settings key 'hooks.Stop' must be a JSON array")

    found = False
    migrated_legacy = False
    changed = False
    rewritten_groups: list[object] = []

    for group in stop_groups:
        if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
            rewritten_groups.append(group)
            continue

        group_changed = False
        rewritten_hooks: list[object] = []
        for hook in group["hooks"]:
            if not _is_touch_claude_hook(hook):
                rewritten_hooks.append(hook)
                continue

            command = hook.get("command", "")
            migrated_legacy = migrated_legacy or LEGACY_MARKER in command
            group_changed = True
            if not found:
                canonical = _canonical_hook(hook)
                rewritten_hooks.append(canonical)
                changed = changed or canonical != hook
                found = True
            else:
                # Collapse duplicate legacy/current registrations while leaving
                # every unrelated hook in its original order.
                changed = True

        if group_changed:
            changed = changed or rewritten_hooks != group["hooks"]
            if rewritten_hooks:
                rewritten_group = dict(group)
                rewritten_group["hooks"] = rewritten_hooks
                rewritten_groups.append(rewritten_group)
        else:
            rewritten_groups.append(group)

    if found:
        if rewritten_groups != stop_groups:
            hooks["Stop"] = rewritten_groups
    else:
        stop_groups.append({
            "matcher": "",
            "hooks": [_canonical_hook()],
        })
        changed = True

    return changed, migrated_legacy


def _remove_hook(data: dict) -> bool:
    hooks = data.get("hooks")
    if hooks is None:
        return False
    if not isinstance(hooks, dict):
        raise ValueError("settings key 'hooks' must be a JSON object")
    stop_groups = hooks.get("Stop")
    if stop_groups is None:
        return False
    if not isinstance(stop_groups, list):
        raise ValueError("settings key 'hooks.Stop' must be a JSON array")

    changed = False
    rewritten_groups: list[object] = []
    for group in stop_groups:
        if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
            rewritten_groups.append(group)
            continue
        rewritten_hooks = [
            hook for hook in group["hooks"]
            if not _is_touch_claude_hook(hook)
        ]
        if rewritten_hooks == group["hooks"]:
            rewritten_groups.append(group)
            continue
        changed = True
        if rewritten_hooks:
            rewritten_group = dict(group)
            rewritten_group["hooks"] = rewritten_hooks
            rewritten_groups.append(rewritten_group)

    if not changed:
        return False
    if rewritten_groups:
        hooks["Stop"] = rewritten_groups
    else:
        hooks.pop("Stop", None)
        if not hooks:
            data.pop("hooks", None)
    return True


def install() -> int:
    with _settings_lock():
        data = _load()
        changed, migrated_legacy = _install_hook(data)
        if not changed:
            _ensure_private_permissions()
            print("Stop hook already installed — nothing to do.")
            return 0

        backup_path = _backup()
        _save(data)

    action = "Migrated legacy Stop hook" if migrated_legacy else "Installed Stop hook"
    print(f"{action} in {SETTINGS_PATH}")
    if backup_path:
        print(f"Backup written to {backup_path}")
    print("Open a new Claude Code session for it to take effect.")
    return 0


def remove() -> int:
    with _settings_lock():
        data = _load()
        if not _remove_hook(data):
            print("Stop hook not present — nothing to remove.")
            return 0

        backup_path = _backup()
        _save(data)

    print(f"Removed Touch Claude Stop hook from {SETTINGS_PATH}")
    if backup_path:
        print(f"Backup written to {backup_path}")
    return 0


def main(argv: list[str]) -> int:
    try:
        if argv and argv[0] in {"--remove", "remove", "--uninstall"}:
            return remove()
        if argv and argv[0] in {"-h", "--help"}:
            print(__doc__)
            return 0
        return install()
    except (OSError, ValueError) as error:
        print(f"Failed to update {SETTINGS_PATH}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
