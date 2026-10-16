"""Read a small, local-only text excerpt for one explicitly selected native thread.

No database writes, tool output, attachments, or renderer-supplied excerpts.
"""
from __future__ import annotations

import json
from contextlib import closing
import os
from pathlib import Path
import re
import sqlite3
import stat
import uuid


class ContextFailure(Exception):
    pass


MAX_TAIL_BYTES = 2 * 1024 * 1024
MAX_RECORD_BYTES = 64 * 1024
MAX_TEXT = 2000
MAX_TOTAL_TEXT = 8000
MAX_ROUNDS = 5
SYNTHETIC_PREFIXES = (
    "# AGENTS.md instructions", "<environment_context>", "<permissions instructions>",
    "<turn_aborted>", "<system-reminder>", "<INSTRUCTIONS>",
    "<user_instructions>", "<local-command-caveat>",
)


def checked_path(value, kind=None):
    """Reject device/network paths, traversal, and all symlink/reparse components."""
    try:
        raw = os.fspath(value)
        if not isinstance(raw, str):
            raise ContextFailure("unsafe_path")
        if raw.startswith("\\\\?\\"):
            # Codex writes local extended-length paths after reopening a thread.
            # Normalize only an ordinary drive path. UNC, device namespaces and
            # names whose meaning changes without the prefix remain forbidden.
            local = raw[4:]
            if os.name != "nt" or not re.match(r"^[A-Za-z]:\\", local) or "/" in local:
                raise ContextFailure("unsafe_path")
            if any(part in (".", "..") or part.endswith((".", " ")) or ":" in part
                   for part in local[3:].split("\\") if part):
                raise ContextFailure("unsafe_path")
            raw = local
        path = Path(raw)
        if not path.is_absolute() or raw.startswith(("\\\\", "//")) or ".." in path.parts:
            raise ContextFailure("unsafe_path")
        for item in reversed((path, *path.parents)):
            info = item.lstat()
            if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT:
                raise ContextFailure("reparse_path_rejected")
        if kind == "file" and not path.is_file() or kind == "dir" and not path.is_dir():
            raise ContextFailure("invalid_path_type")
        return path.resolve(strict=True)
    except (OSError, TypeError, ValueError):
        raise ContextFailure("path_unavailable") from None


def _identity(path):
    info = path.stat()
    return info.st_dev, info.st_ino


def _valid_id(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", value):
        raise ContextFailure("invalid_thread_id")
    if uuid.UUID(value).int == 0:
        raise ContextFailure("invalid_thread_id")


def _text_message(record):
    if not isinstance(record, dict) or record.get("type") != "response_item":
        return None
    payload = record.get("payload")
    if not isinstance(payload, dict) or payload.get("type") != "message":
        return None
    role = payload.get("role")
    if role not in ("user", "assistant"):
        return None
    if role == "assistant" and payload.get("phase") not in (None, "final", "final_answer"):
        return None
    if payload.get("channel") not in (None, "final"):
        return None
    content = payload.get("content")
    if not isinstance(content, list):
        return None
    chunks = []
    for block in content:
        if not isinstance(block, dict) or block.get("type") not in ("input_text", "output_text", "text"):
            continue
        value = block.get("text")
        if not isinstance(value, str):
            continue
        # Synthetic injected instructions are never title context, including a block
        # followed by otherwise ordinary user text in the same response item.
        if value.lstrip().startswith(SYNTHETIC_PREFIXES):
            return None
        value = "".join(c for c in value if c in "\n\t" or ord(c) >= 32)
        if value.strip():
            chunks.append(value[:MAX_TEXT])
    text = "\n".join(chunks)[:MAX_TEXT].strip()
    return {"role": role, "text": text} if text else None


class NativeContextReader:
    def __init__(self, home):
        self.home = checked_path(home, "dir")
        self.home_identity = _identity(self.home)

    def _check_home(self):
        if checked_path(self.home, "dir") != self.home or _identity(self.home) != self.home_identity:
            raise ContextFailure("home_changed")

    def _thread_path(self, thread_id):
        self._check_home()
        database = checked_path(self.home / "state_5.sqlite", "file")
        database_identity = _identity(database)
        # SQLite can consult these files for a live WAL database; do not allow a
        # sidecar junction/symlink to bypass the database's own path checks.
        for suffix in ("-wal", "-shm", "-journal"):
            sidecar = Path(str(database) + suffix)
            if os.path.lexists(sidecar):
                checked_path(sidecar, "file")
        try:
            with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=1)) as connection:
                connection.execute("PRAGMA query_only=ON")
                fields = {item[1] for item in connection.execute("PRAGMA table_info(threads)")}
                # Old Codex indexes may not have first_user_message. Ask SQLite
                # for a bounded prefix, never transfer a full initial prompt.
                first_column = "substr(first_user_message,1,2000)" if "first_user_message" in fields else "NULL"
                row = connection.execute(
                    f"SELECT rollout_path, archived, {first_column} FROM threads WHERE id=?", (thread_id,)).fetchone()
        except sqlite3.Error:
            raise ContextFailure("thread_index_unavailable") from None
        self._check_home()
        if checked_path(database, "file") != database or _identity(database) != database_identity:
            raise ContextFailure("thread_index_changed")
        if row is None:
            raise ContextFailure("thread_not_found")
        if row[1] != 0:
            raise ContextFailure("thread_archived")
        path = checked_path(row[0], "file")
        sessions = checked_path(self.home / "sessions", "dir")
        if not path.is_relative_to(sessions) or path.suffix != ".jsonl":
            raise ContextFailure("thread_outside_home")
        first_message = _text_message({"type": "response_item", "payload": {
            "type": "message", "role": "user", "content": [{"type": "input_text", "text": row[2]}]}})
        return path, first_message

    def read(self, thread_id):
        _valid_id(thread_id)
        path, first_message = self._thread_path(thread_id)
        try:
            before = _identity(path)
            with path.open("rb") as stream:
                opened = os.fstat(stream.fileno())
                if (opened.st_dev, opened.st_ino) != before or checked_path(path, "file") != path:
                    raise ContextFailure("thread_file_changed")
                first = stream.readline(MAX_RECORD_BYTES + 1)
                if len(first) > MAX_RECORD_BYTES:
                    raise ContextFailure("invalid_session_metadata")
                try:
                    metadata = json.loads(first)
                except (ValueError, UnicodeError):
                    raise ContextFailure("invalid_session_metadata") from None
                if not isinstance(metadata, dict) or metadata.get("type") != "session_meta" or not isinstance(metadata.get("payload"), dict) or metadata["payload"].get("id") != thread_id:
                    raise ContextFailure("session_identity_mismatch")
                first_end = stream.tell()
                end = stream.seek(0, os.SEEK_END)
                start = max(first_end, end - MAX_TAIL_BYTES)
                stream.seek(start)
                tail = stream.read(MAX_TAIL_BYTES)
                if start > first_end:
                    # The first record can start in the middle of a UTF-8 sequence.
                    tail = tail.partition(b"\n")[2]
                if not tail.endswith(b"\n"):
                    tail = tail.rpartition(b"\n")[0]  # ignore an active partial write
            self._check_home()
            if checked_path(path, "file") != path or _identity(path) != before:
                raise ContextFailure("thread_file_changed")
        except OSError:
            raise ContextFailure("thread_read_failed") from None
        result, rounds, remaining = [], 0, MAX_TOTAL_TEXT
        for line in reversed(tail.splitlines()):
            if not line or len(line) > MAX_RECORD_BYTES:
                continue
            try:
                message = _text_message(json.loads(line))
            except (ValueError, UnicodeError):
                continue
            if not message:
                continue
            if message["role"] == "user":
                rounds += 1
                if rounds > MAX_ROUNDS:
                    break
            if len(result) >= MAX_ROUNDS * 2 or not remaining:
                break
            message["text"] = message["text"][:remaining]
            remaining -= len(message["text"])
            result.append(message)
        if not any(item["role"] == "user" for item in result):
            if not first_message:
                raise ContextFailure("empty_context")
            # A long tool run can push every human prompt outside the bounded
            # tail. Use the verified thread index's initial question, retaining
            # only as much recent assistant text as the same total budget allows.
            remaining = MAX_TOTAL_TEXT - len(first_message["text"])
            recent = []
            for item in result:
                if not remaining:
                    break
                item["text"] = item["text"][:remaining]
                remaining -= len(item["text"])
                recent.append(item)
            return [first_message, *reversed(recent)]
        return list(reversed(result))
