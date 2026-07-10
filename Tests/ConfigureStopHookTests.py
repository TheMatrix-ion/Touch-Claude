#!/usr/bin/env python3
import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "configure_stop_hook.py"
CURRENT = '"$HOME/.claude-touchbar/bin/ClaudeTouchBar" _record-stop'


class ConfigureStopHookTests(unittest.TestCase):
    def run_script(self, settings: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
        environment = dict(os.environ)
        environment["CLAWD_CLAUDE_SETTINGS_PATH"] = str(settings)
        return subprocess.run(
            ["python3", str(SCRIPT), *arguments],
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_migrate_idempotently_and_preserve_other_hooks(self) -> None:
        with tempfile.TemporaryDirectory(prefix="clawd-hook-test-") as temporary:
            settings = Path(temporary) / "settings.json"
            original = {
                "theme": "dark",
                "hooks": {
                    "Stop": [
                        {
                            "matcher": "",
                            "hooks": [
                                {
                                    "type": "command",
                                    "command": 'mkdir -p "$HOME/.claude-touchbar" && touch "$HOME/.claude-touchbar/poke"',
                                    "timeout": 3,
                                },
                                {"type": "command", "command": "other-stop-hook"},
                            ],
                        }
                    ],
                    "PreToolUse": [{"matcher": "Bash", "hooks": []}],
                },
            }
            settings.write_text(json.dumps(original), encoding="utf-8")

            first = self.run_script(settings)
            self.assertEqual(first.returncode, 0, first.stderr)
            migrated_bytes = settings.read_bytes()
            migrated = json.loads(migrated_bytes)
            commands = [
                hook.get("command")
                for group in migrated["hooks"]["Stop"]
                for hook in group.get("hooks", [])
            ]
            self.assertEqual(commands.count(CURRENT), 1)
            self.assertIn("other-stop-hook", commands)
            self.assertEqual(migrated["hooks"]["PreToolUse"], original["hooks"]["PreToolUse"])
            self.assertEqual(stat.S_IMODE(settings.stat().st_mode), 0o600)

            second = self.run_script(settings)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(settings.read_bytes(), migrated_bytes)

            removed = self.run_script(settings, "--remove")
            self.assertEqual(removed.returncode, 0, removed.stderr)
            cleaned = json.loads(settings.read_text(encoding="utf-8"))
            remaining = [
                hook.get("command")
                for group in cleaned["hooks"]["Stop"]
                for hook in group.get("hooks", [])
            ]
            self.assertEqual(remaining, ["other-stop-hook"])
            self.assertEqual(cleaned["theme"], "dark")
            self.assertIn("PreToolUse", cleaned["hooks"])

    def test_invalid_json_is_not_overwritten(self) -> None:
        with tempfile.TemporaryDirectory(prefix="clawd-hook-invalid-") as temporary:
            settings = Path(temporary) / "settings.json"
            invalid = b"{ definitely not json\n"
            settings.write_bytes(invalid)
            result = self.run_script(settings)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(settings.read_bytes(), invalid)


if __name__ == "__main__":
    unittest.main(verbosity=2)
