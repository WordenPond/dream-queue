"""Unit tests for scripts/parse_telegram.py"""
import base64
import json
import os
import subprocess
import sys
import tempfile

import pytest

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "scripts", "parse_telegram.py")


def _patch_script(script_path: str, tmp_json_path: str) -> str:
    """Return a copy of the script with the hardcoded JSON path replaced."""
    with open(script_path) as f:
        src = f.read()
    # Use repr() so Windows backslashes are properly escaped in the embedded string literal
    return src.replace("'/tmp/telegram-updates.json'", repr(tmp_json_path))


def run_script(updates_data: dict, env_overrides: dict = None) -> dict:
    """Run parse_telegram.py with given Telegram API response, return parsed output."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        json.dump(updates_data, f)
        tmp_json = f.name

    with tempfile.NamedTemporaryFile(mode="w", suffix=".py", delete=False) as sf:
        sf.write(_patch_script(SCRIPT, tmp_json))
        script_path = sf.name

    env = os.environ.copy()
    env["TELEGRAM_CHAT_ID"] = "12345"
    env["LAST_ID"] = "0"
    if env_overrides:
        env.update(env_overrides)

    try:
        result = subprocess.run(
            [sys.executable, script_path], capture_output=True, text=True, env=env
        )
        output = {}
        for line in result.stdout.strip().splitlines():
            if "=" in line:
                key, _, val = line.partition("=")
                output[key.strip()] = val.strip()
        return output
    finally:
        os.unlink(tmp_json)
        os.unlink(script_path)


def decode_commands(b64: str) -> list:
    if not b64:
        return []
    raw = base64.b64decode(b64).decode()
    return [line for line in raw.splitlines() if line]


class TestParseNormalUpdates:
    def test_single_command_from_authorized_chat(self):
        data = {
            "ok": True,
            "result": [{"update_id": 100, "message": {"chat": {"id": 12345}, "text": "status"}}],
        }
        out = run_script(data)
        assert out["NEW_LAST_ID"] == "100"
        assert decode_commands(out.get("COMMANDS_B64", "")) == ["status"]

    def test_multiple_commands_ordered(self):
        data = {
            "ok": True,
            "result": [
                {"update_id": 10, "message": {"chat": {"id": 12345}, "text": "queue 5"}},
                {"update_id": 11, "message": {"chat": {"id": 12345}, "text": "status"}},
            ],
        }
        out = run_script(data)
        assert out["NEW_LAST_ID"] == "11"
        assert decode_commands(out.get("COMMANDS_B64", "")) == ["queue 5", "status"]

    def test_max_update_id_tracked(self):
        data = {
            "ok": True,
            "result": [
                {"update_id": 42, "message": {"chat": {"id": 12345}, "text": "help"}},
                {"update_id": 99, "message": {"chat": {"id": 12345}, "text": "status"}},
            ],
        }
        out = run_script(data)
        assert out["NEW_LAST_ID"] == "99"

    def test_last_id_preserved_when_no_new_updates(self):
        data = {"ok": True, "result": []}
        out = run_script(data, {"LAST_ID": "77"})
        assert out["NEW_LAST_ID"] == "77"
        assert decode_commands(out.get("COMMANDS_B64", "")) == []


class TestAuthorizationFilter:
    def test_unauthorized_chat_ignored(self):
        data = {
            "ok": True,
            "result": [{"update_id": 200, "message": {"chat": {"id": 99999}, "text": "merge 5"}}],
        }
        out = run_script(data)
        assert out["NEW_LAST_ID"] == "200"
        assert decode_commands(out.get("COMMANDS_B64", "")) == []

    def test_mixed_authorized_and_unauthorized(self):
        data = {
            "ok": True,
            "result": [
                {"update_id": 1, "message": {"chat": {"id": 12345}, "text": "status"}},
                {"update_id": 2, "message": {"chat": {"id": 9999}, "text": "merge 1"}},
                {"update_id": 3, "message": {"chat": {"id": 12345}, "text": "pause"}},
            ],
        }
        out = run_script(data)
        assert out["NEW_LAST_ID"] == "3"
        assert decode_commands(out.get("COMMANDS_B64", "")) == ["status", "pause"]

    def test_empty_text_ignored(self):
        data = {
            "ok": True,
            "result": [{"update_id": 5, "message": {"chat": {"id": 12345}, "text": ""}}],
        }
        out = run_script(data)
        assert decode_commands(out.get("COMMANDS_B64", "")) == []

    def test_message_without_text_ignored(self):
        data = {
            "ok": True,
            "result": [{"update_id": 6, "message": {"chat": {"id": 12345}}}],
        }
        out = run_script(data)
        assert decode_commands(out.get("COMMANDS_B64", "")) == []


class TestEdgeCases:
    def test_malformed_json_falls_back_gracefully(self):
        """Script must not crash on bad JSON — emits LAST_ID and empty commands."""
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            f.write("{not valid json}")
            bad_json = f.name

        with tempfile.NamedTemporaryFile(mode="w", suffix=".py", delete=False) as sf:
            sf.write(_patch_script(SCRIPT, bad_json))
            script_path = sf.name

        env = os.environ.copy()
        env["TELEGRAM_CHAT_ID"] = "12345"
        env["LAST_ID"] = "55"

        try:
            result = subprocess.run(
                [sys.executable, script_path], capture_output=True, text=True, env=env
            )
            assert result.returncode == 0, f"stderr: {result.stderr}"
            assert "NEW_LAST_ID=55" in result.stdout
        finally:
            os.unlink(script_path)
            os.unlink(bad_json)

    def test_commands_base64_encoded(self):
        data = {
            "ok": True,
            "result": [{"update_id": 1, "message": {"chat": {"id": 12345}, "text": "queue 1 2 3"}}],
        }
        out = run_script(data)
        b64 = out.get("COMMANDS_B64", "")
        decoded = base64.b64decode(b64).decode()
        assert "queue 1 2 3" in decoded

    def test_whitespace_stripped_from_commands(self):
        data = {
            "ok": True,
            "result": [{"update_id": 1, "message": {"chat": {"id": 12345}, "text": "  status  "}}],
        }
        out = run_script(data)
        assert decode_commands(out.get("COMMANDS_B64", "")) == ["status"]

    def test_non_message_update_type_ignored(self):
        """Updates without a 'message' key (e.g. edited_message) don't crash."""
        data = {
            "ok": True,
            "result": [{"update_id": 50, "edited_message": {"chat": {"id": 12345}, "text": "status"}}],
        }
        out = run_script(data)
        assert out["NEW_LAST_ID"] == "50"
        assert decode_commands(out.get("COMMANDS_B64", "")) == []
