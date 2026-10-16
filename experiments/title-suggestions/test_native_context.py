import json
from contextlib import closing
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

from native_context import NativeContextReader, ContextFailure, MAX_TAIL_BYTES, checked_path
from title_service import NativeTitleService, Generator, Failure

THREAD = "aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"


def message(role, text, **extra):
    return {"type": "response_item", "payload": {"type": "message", "role": role,
            "content": [{"type": "input_text" if role == "user" else "output_text", "text": text}], **extra}}


class NativeContextTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / "home"
        self.home.mkdir()
        (self.home / "sessions").mkdir()
        self.rollout = self.home / "sessions" / "test.jsonl"
        self.db = self.home / "state_5.sqlite"
        with closing(sqlite3.connect(self.db)) as con:
            con.execute("CREATE TABLE threads(id TEXT PRIMARY KEY, rollout_path TEXT, archived INTEGER)")
            con.execute("INSERT INTO threads VALUES(?,?,0)", (THREAD, str(self.rollout)))
            con.commit()
        self.reader = NativeContextReader(self.home)
        self.write([message("user", "帮我做标题建议"), message("assistant", "完成了标题建议")])

    def write(self, records, meta_id=THREAD):
        records = [{"type": "session_meta", "payload": {"id": meta_id, "source": "vscode"}}, *records]
        self.rollout.write_text("".join(json.dumps(item, ensure_ascii=False) + "\n" for item in records), encoding="utf8")

    def update(self, path=None, archived=0):
        with closing(sqlite3.connect(self.db)) as con:
            con.execute("UPDATE threads SET rollout_path=?,archived=? WHERE id=?", (str(path or self.rollout), archived, THREAD))
            con.commit()

    def test_plain_text_only_and_last_five_rounds(self):
        records = []
        for number in range(12):
            records += [message("user", "user" + str(number)), message("assistant", "answer" + str(number), phase="final_answer")]
        records += [message("assistant", "private reasoning", channel="analysis"),
                    message("assistant", "progress not answer", phase="commentary"),
                    {"type": "response_item", "payload": {"type": "function_call_output", "output": "secret tool data"}},
                    {"type": "event_msg", "payload": {"type": "user_message", "message": "duplicate user"}},
                    message("user", "# AGENTS.md instructions\nsecret injected rules"),
                    message("developer", "secret config")]
        self.write(records)
        result = self.reader.read(THREAD)
        self.assertEqual(len(result), 10)
        self.assertEqual(result[0]["text"], "user7")
        self.assertEqual(result[-1]["text"], "answer11")
        self.assertNotIn("secret", str(result))

    def test_images_ignored_and_nulls_not_context(self):
        item = message("user", "图片渲染")
        item["payload"]["content"].append({"type": "input_image", "image_url": "data:secret"})
        self.write([item])
        self.assertEqual(self.reader.read(THREAD), [{"role": "user", "text": "图片渲染"}])
        for data in ([], [message("user", "\0" * 500)], [message("user", "<environment_context>injected")]):
            self.write(data)
            with self.assertRaisesRegex(ContextFailure, "empty_context"):
                self.reader.read(THREAD)

    def test_uuid_and_metadata_mismatch(self):
        for value in (None, "", "../../thread", "00000000-0000-0000-0000-000000000000", THREAD.upper()):
            with self.assertRaisesRegex(ContextFailure, "invalid_thread_id"):
                self.reader.read(value)
        with self.assertRaisesRegex(ContextFailure, "thread_not_found"):
            self.reader.read("bbbbbbbb-bbbb-7bbb-8bbb-bbbbbbbbbbbb")
        self.write([message("user", "real")], "bbbbbbbb-bbbb-7bbb-8bbb-bbbbbbbbbbbb")
        with self.assertRaisesRegex(ContextFailure, "session_identity_mismatch"):
            self.reader.read(THREAD)

    @unittest.skipUnless(os.name == "nt", "Windows extended local paths")
    def test_reopened_codex_extended_drive_path(self):
        expected = self.reader.read(THREAD)
        self.update("\\\\?\\" + str(self.rollout))
        self.assertEqual(self.reader.read(THREAD), expected)
        self.assertEqual(checked_path("\\\\?\\" + str(self.home), "dir"), self.home)
        outside = self.root / "outside.jsonl"
        outside.write_bytes(self.rollout.read_bytes())
        self.update("\\\\?\\" + str(outside))
        with self.assertRaisesRegex(ContextFailure, "thread_outside_home"):
            self.reader.read(THREAD)

    def test_extended_namespace_does_not_relax_path_checks(self):
        for value in ("\\\\?\\UNC\\host\\share\\file", "\\\\.\\C:\\file",
                      "\\\\?\\GLOBALROOT\\Device\\HarddiskVolume1\\file",
                      "\\\\?\\C:\\folder\\..\\file", "\\\\?\\C:\\folder\\.\\file",
                      "\\\\?\\C:\\folder\\file.", "\\\\?\\C:\\folder\\file ",
                      "\\\\?\\C:\\folder\\file:stream", "\\\\?\\C:/folder/file"):
            with self.subTest(value=value), self.assertRaisesRegex(ContextFailure, "unsafe_path"):
                checked_path(value, "file")

    def test_archived_and_outside_home(self):
        self.update(archived=1)
        with self.assertRaisesRegex(ContextFailure, "thread_archived"):
            self.reader.read(THREAD)
        outside = self.root / "outside.jsonl"
        outside.write_bytes(self.rollout.read_bytes())
        self.update(outside)
        with self.assertRaisesRegex(ContextFailure, "thread_outside_home"):
            self.reader.read(THREAD)
        self.update(self.home / "sessions" / ".." / "sessions" / "test.jsonl")
        with self.assertRaisesRegex(ContextFailure, "unsafe_path"):
            self.reader.read(THREAD)
        for path in ("\\\\server\\share\\x", "//server/share/x", "relative/x", "\\\\?\\C:\\x"):
            with self.assertRaises(ContextFailure):
                checked_path(path)

    def test_reparse_rejected_even_if_it_resolves_inside(self):
        original = Path.lstat
        def fake_stat(path, *args, **kwargs):
            result = original(path, *args, **kwargs)
            if path == self.home / "sessions":
                class Reparse:
                    st_mode = result.st_mode
                    st_file_attributes = 1024
                return Reparse()
            return result
        with patch.object(Path, "lstat", fake_stat):
            with self.assertRaisesRegex(ContextFailure, "reparse_path_rejected"):
                self.reader.read(THREAD)

    def test_large_file_tail_only_partial_and_limits(self):
        self.write([message("user", "old context"),
                    {"type": "response_item", "payload": {"type": "function_call_output", "output": "x" * (MAX_TAIL_BYTES * 3)}},
                    message("user", "最近标题任务"), message("assistant", "最近回答")])
        with self.rollout.open("ab") as out:
            out.write(b'{"type":"response_item","payload":')
        self.assertEqual(self.reader.read(THREAD)[0]["text"], "最近标题任务")
        self.write([message("user" if i % 2 == 0 else "assistant", "中" * 12000) for i in range(10)])
        result = self.reader.read(THREAD)
        self.assertLessEqual(sum(len(item["text"]) for item in result), 8000)
        self.assertTrue(all(len(item["text"]) <= 2000 for item in result))

    def test_first_user_fallback_when_large_tool_log_displaces_user(self):
        with closing(sqlite3.connect(self.db)) as con:
            con.execute("ALTER TABLE threads ADD COLUMN first_user_message TEXT")
            con.execute("UPDATE threads SET first_user_message=?", ("最初请求" * 1000,))
            con.commit()
        self.write([message("user", "old user outside tail"),
                    {"type": "response_item", "payload": {"type": "function_call_output", "output": "x" * (MAX_TAIL_BYTES * 2)}}])
        result = self.reader.read(THREAD)
        self.assertEqual(result, [{"role": "user", "text": ("最初请求" * 1000)[:2000]}])
        # Recent assistant text remains usable, but its presence never substitutes
        # for verified human intent and cannot expand the total context budget.
        with self.rollout.open("a", encoding="utf8") as stream:
            for number in range(4):
                stream.write(json.dumps(message("assistant", "答" * 2000), ensure_ascii=False) + "\n")
        result = self.reader.read(THREAD)
        self.assertEqual(result[0]["role"], "user")
        self.assertEqual(sum(len(item["text"]) for item in result), 8000)
        self.update(archived=1)
        with self.assertRaisesRegex(ContextFailure, "thread_archived"):
            self.reader.read(THREAD)

    def test_fallback_old_schema_synthetic_and_source_validation(self):
        self.write([{"type": "response_item", "payload": {"type": "function_call_output", "output": "x" * (MAX_TAIL_BYTES * 2)}}])
        with self.assertRaisesRegex(ContextFailure, "empty_context"):
            self.reader.read(THREAD)
        with closing(sqlite3.connect(self.db)) as con:
            con.execute("ALTER TABLE threads ADD COLUMN first_user_message TEXT")
            for value in ("# AGENTS.md instructions\nprivate rules", "<environment_context>private", "\0" * 3000):
                con.execute("UPDATE threads SET first_user_message=?", (value,))
                con.commit()
                with self.assertRaisesRegex(ContextFailure, "empty_context"):
                    self.reader.read(THREAD)
            con.execute("UPDATE threads SET first_user_message='valid initial question'")
            con.commit()
        self.write([], meta_id="bbbbbbbb-bbbb-7bbb-8bbb-bbbbbbbbbbbb")
        with self.assertRaisesRegex(ContextFailure, "session_identity_mismatch"):
            self.reader.read(THREAD)

    def service(self, live=False):
        profile = self.root / "profile"
        profile.mkdir(exist_ok=True)
        cli = self.root / "codex.exe"
        cli.write_text("fixture", encoding="utf8")
        (self.home / "config.toml").write_text('model_provider="test"\nmodel="test-model"\n[model_providers.test]\nbase_url="https://example.com/v1"', encoding="utf8")
        return NativeTitleService(self.home, profile, cli, live=live)

    def test_native_service_rejects_renderer_context_cancel_cache(self):
        service = self.service()
        data = {"threadId": THREAD, "requestId": "request-1", "currentTitle": "旧标题"}
        with self.assertRaisesRegex(Failure, "invalid_native_request"):
            service.suggest({**data, "messages": [{"role": "user", "text": "forged"}]})
        self.assertFalse(service.suggest(data)["cached"])
        self.assertTrue(service.suggest({**data, "requestId": "request-2"})["cached"])
        service.cancel("cancelled-request")
        with self.assertRaisesRegex(Failure, "cancelled"):
            service.suggest({**data, "requestId": "cancelled-request"})
        self.update(archived=1)
        with self.assertRaisesRegex(Failure, "thread_archived"):
            service.suggest({**data, "requestId": "request-3"})

    def test_cached_result_still_checks_provider_and_model_changes(self):
        service = self.service(live=True)
        data = {"threadId": THREAD, "requestId": "request-1", "currentTitle": "旧标题"}
        with patch.object(Generator, "invoke", return_value="Title"):
            self.assertFalse(service.suggest(data)["cached"])
            self.assertTrue(service.suggest({**data, "requestId": "request-2"})["cached"])
            config = self.home / "config.toml"
            config.write_text(config.read_text().replace("test-model", "changed-model"))
            with self.assertRaisesRegex(Failure, "provider_config_changed_restart_required"):
                service.suggest({**data, "requestId": "request-3"})

    def test_runtime_replaced_or_home_renamed_fails_closed(self):
        service = self.service()
        data = {"threadId": THREAD, "requestId": "request-1"}
        # Replacing the profile directory must not silently attach to its successor.
        service.profile.rename(self.root / "old-profile")
        service.profile.mkdir()
        with self.assertRaisesRegex(Failure, "runtime_path_changed_restart_required"):
            service.suggest(data)
        self.home.rename(self.root / "old-home")
        self.home.mkdir()
        with self.assertRaisesRegex(ContextFailure, "home_changed"):
            self.reader.read(THREAD)


if __name__ == "__main__":
    unittest.main(verbosity=2)
