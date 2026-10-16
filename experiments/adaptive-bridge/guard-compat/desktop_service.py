"""Persistent desktop watchdog backend for one fixed Codex Desktop profile."""
from __future__ import annotations

import argparse
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import threading
import time
import uuid
import re
import math

from guard import Singleton, still_waiting, _latest_turn_event
from telemetry import LogReader
from recovery_packet import create_packet, sanitize
from event_dispatch import tick_local_dispatch, has_handoff, handoff_path, MAX_HANDOFF_CHARS, LIVE
from diagnostics import health_report, inspect_event, export_diagnostics

API_HOME = Path(r"E:\Codex-API\CodexHome")
DESKTOP_PROFILE = Path(r"E:\Codex-API\DesktopProfile")
STATE_NAME = Path("plugin-state") / "first-token-guard"
VERSION = "0.3.0"
BRIDGE_PROBE_SHA256 = "5A53705028EC16834A7B62E2863328A2C5421236895A5BFB407A65DB9E352503"


def _atomic_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        with tmp.open("w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        for attempt in range(5):
            try:
                os.replace(tmp, path)
                return
            except PermissionError:
                if attempt == 4:
                    raise
                time.sleep(.05 * (attempt + 1))
    finally:
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass


def _short_error(exc: BaseException) -> str:
    return type(exc).__name__[:80]


def _valid_snapshot(value):
    return (isinstance(value, dict) and value.get("state") in
            ("stopped", "starting", "monitoring", "standby", "paused", "error") and
            type(value.get("last_check")) in (int, float) and
            math.isfinite(value["last_check"]) and value["last_check"] >= 0 and "pid" in value and
            (value["pid"] is None or type(value["pid"]) is int and value["pid"] > 0))


def _write_snapshot(path, value):
    """Preserve invalid derived state; never apply this recovery to settings or ledgers."""
    try:
        with path.open("rb") as stream:
            raw = stream.read(1048577)
    except FileNotFoundError:
        raw = None
    if raw is not None:
        if len(raw) > 1048576:
            raise ValueError("snapshot_too_large")
        try:
            valid = _valid_snapshot(json.loads(raw.decode("utf-8-sig")))
        except (UnicodeError, ValueError, TypeError):
            valid = False
        if not valid:
            backup = path.with_name(path.name + ".corrupt-" + hashlib.sha256(raw).hexdigest() + ".bak")
            try:
                with backup.open("xb") as stream:
                    stream.write(raw)
                    stream.flush()
                    os.fsync(stream.fileno())
            except FileExistsError:
                pass
            with backup.open("rb") as saved:
                preserved = saved.read(1048577)
            if preserved != raw:
                raise ValueError("snapshot_backup_incomplete")
    _atomic_json(path, value)


class DesktopService:
    def __init__(self, home: Path, profile: Path, *, clock=time.time, process_probe=None):
        self.home = Path(home).resolve()
        self.profile = Path(profile).resolve()
        self.state_dir = self.home / STATE_NAME
        self.settings_path = self.state_dir / "desktop-settings.json"
        self.status_path = self.state_dir / "desktop-status.json"
        self.db_path = self.state_dir / "desktop-events.sqlite"
        self.clock = clock
        self.process_probe = process_probe or self._powershell_probe
        self._mutex = threading.RLock()
        self._probe_cache = (0.0, False, None)
        self._cli_probe = (0.0, None)
        self.reader = None
        self.reader_process = None
        self.last_loop = None
        self.pending = []
        self.error = None
        self.config_error = None
        self._event_worker = None
        if not self.settings_path.exists() and (self.db_path.exists() or self.status_path.exists()):
            raise ValueError("settings_unreadable")
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self._init_db()
        if not self.settings_path.exists():
            self._write_settings({"enabled": True, "effort": "low", "native_dispatch_ready": False,
                                  "dispatch_mode": "queue", "cli_executable": None})

    def _connect(self):
        db = sqlite3.connect(self.db_path, timeout=5, isolation_level=None)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA busy_timeout=5000")
        return db

    def _init_db(self):
        with closing(self._connect()) as db:
            db.execute("""CREATE TABLE IF NOT EXISTS incidents(
                event_key TEXT PRIMARY KEY, thread_id TEXT NOT NULL, turn_id TEXT NOT NULL,
                created REAL NOT NULL, status TEXT NOT NULL, folder TEXT NOT NULL,
                owner TEXT, claimed_at REAL, new_thread_id TEXT, result TEXT)""")
            db.execute("CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
            db.execute("CREATE UNIQUE INDEX IF NOT EXISTS one_live_claim ON incidents(status) WHERE status='claimed'")

    def settings(self):
        with self._mutex:
            try:
                value = json.loads(self.settings_path.read_text(encoding="utf-8"))
                if (not isinstance(value, dict) or type(value.get("enabled")) is not bool or
                    value.get("effort") not in ("low", "medium") or
                    value.get("dispatch_mode") not in ("queue", "local_once")):
                    raise ValueError("invalid settings")
                self.config_error = None
            except (OSError, ValueError, TypeError):
                self.config_error = "settings_unreadable"
                value = {"enabled": False, "effort": "low", "native_dispatch_ready": False}
            return {"enabled": value.get("enabled") is True,
                    "effort": value.get("effort") if value.get("effort") in ("low", "medium") else "low",
                    "dispatch_mode": value.get("dispatch_mode") if value.get("dispatch_mode") in ("queue", "local_once") else "queue",
                    "cli_executable": value.get("cli_executable") if isinstance(value.get("cli_executable"), str) and Path(value["cli_executable"]).is_absolute() else None,
                    "guardian_cwd": value.get("guardian_cwd") if isinstance(value.get("guardian_cwd"), str) and Path(value["guardian_cwd"]).is_absolute() else None,
                    "native_dispatch_ready": value.get("native_dispatch_ready") is True,
                    "ready_process_identity": value.get("ready_process_identity"),
                    "ready_verified_at": value.get("ready_verified_at"),
                    "ready_effort": value.get("ready_effort"),
                    "ready_guardian": value.get("ready_guardian")}

    def _write_settings(self, value):
        with self._mutex:
            if self.config_error:
                raise ValueError("settings_unreadable")
            if self.settings_path.exists():
                self.settings()
                if self.config_error:
                    raise ValueError("settings_unreadable")
            _atomic_json(self.settings_path, value)

    def configure(self, enabled=None, effort=None, dispatch_mode=None, cli_executable=None):
        with Singleton(self.state_dir / "desktop-settings.lock"):
            current = self.settings()
            if enabled is not None:
                current["enabled"] = bool(enabled)
            if effort is not None:
                if effort not in ("low", "medium"):
                    raise ValueError("effort must be low or medium")
                current["effort"] = effort
            if dispatch_mode is not None:
                if dispatch_mode not in ("queue", "local_once"):
                    raise ValueError("dispatch mode must be queue or local_once")
                current["dispatch_mode"] = dispatch_mode
            if cli_executable is not None:
                if cli_executable and not Path(cli_executable).is_absolute():
                    raise ValueError("CLI executable must be an absolute path")
                current["cli_executable"] = cli_executable or None
            self._write_settings(current)
        return current

    def set_ready(self, value: bool):
        with Singleton(self.state_dir / "desktop-settings.lock"):
            current = self.settings()
            current["native_dispatch_ready"] = False
            for key in ("ready_process_identity", "ready_verified_at", "ready_effort", "ready_guardian"):
                current[key] = None
            if value:
                guardian = self._guardian()
                info = self._thread(guardian) if guardian else None
                running, identity = self.api_process()
                if not running or not identity or not self._guardian_valid(info):
                    raise RuntimeError("native readiness prerequisites failed")
                current.update({"native_dispatch_ready": True, "ready_process_identity": identity,
                                "ready_verified_at": self.clock(), "ready_effort": current["effort"],
                                "ready_guardian": guardian})
            self._write_settings(current)
        return current

    def _guardian_valid(self, info):
        return bool(info and not info["archived"] and info["source"] == "vscode" and not info.get("agent_path"))

    def readiness(self, cfg, identity=None, now=None):
        if not cfg["native_dispatch_ready"]:
            return False
        now = self.clock() if now is None else now
        guardian = self._guardian()
        info = self._thread(guardian) if guardian else None
        return bool(identity and cfg.get("ready_process_identity") == identity and
                    cfg.get("ready_effort") == cfg["effort"] and cfg.get("ready_guardian") == guardian and
                    isinstance(cfg.get("ready_verified_at"), (int, float)) and 0 <= now - cfg["ready_verified_at"] <= 86400 and
                    self._guardian_valid(info))

    def _thread(self, thread_id):
        db_path = self.home / "state_5.sqlite"
        if not db_path.is_file():
            return None
        with closing(sqlite3.connect(db_path.resolve().as_uri() + "?mode=ro", uri=True, timeout=1)) as db:
            db.row_factory = sqlite3.Row
            row = db.execute("SELECT id,cwd,rollout_path,source,archived,agent_path,created_at,created_at_ms FROM threads WHERE id=?", (thread_id,)).fetchone()
        if not row:
            return None
        info = dict(row)
        try:
            rollout = Path(self._canonical_path(info["rollout_path"])).resolve()
            allowed = [self.home / "sessions", self.home / "archived_sessions"]
            if not any(rollout == Path(self._canonical_path(p)).resolve() or Path(self._canonical_path(p)).resolve() in rollout.parents for p in allowed):
                return None
        except (OSError, TypeError):
            return None
        return info

    def _guardian(self):
        with closing(self._connect()) as db:
            row = db.execute("SELECT value FROM metadata WHERE key='guardian_thread_id'").fetchone()
        return row[0] if row else None

    def bind_guardian(self, thread_id):
        info = self._thread(thread_id)
        if not self._guardian_valid(info):
            raise ValueError("guardian thread is not in the configured API home")
        workspace = Path(self._canonical_path(info["cwd"]))
        if not workspace.is_absolute() or not workspace.is_dir():
            raise ValueError("guardian workspace must be an existing absolute directory")
        workspace = workspace.resolve()
        with closing(self._connect()) as db:
            if db.execute("SELECT 1 FROM incidents WHERE new_thread_id=? LIMIT 1", (thread_id,)).fetchone():
                raise ValueError("diagnostic thread cannot be guardian")
        with Singleton(self.state_dir / "desktop-settings.lock"):
            with closing(self._connect()) as db:
                db.execute("BEGIN IMMEDIATE")
                db.execute("INSERT INTO metadata(key,value) VALUES('guardian_thread_id',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (thread_id,))
                current = self.settings()
                if self.config_error:
                    raise ValueError("settings_unreadable")
                current["guardian_cwd"] = str(workspace)
                self._write_settings(current)
                db.commit()
        return thread_id

    def guardian_workspace(self):
        guardian = self._guardian()
        info = self._thread(guardian) if guardian else None
        candidates = []
        if self._guardian_valid(info):
            candidates.append(info["cwd"])
        if guardian:
            candidates.append(self.settings().get("guardian_cwd"))
        for value in candidates:
            if not value:
                continue
            path = Path(self._canonical_path(value))
            if path.is_absolute() and path.is_dir():
                return path.resolve()
        return None

    def _eligible(self, info):
        return bool(info and not info["archived"] and info["source"] == "vscode" and
                    not info.get("agent_path") and info["id"] != self._guardian())

    @staticmethod
    def _canonical_path(value):
        path = os.path.normpath(str(value))
        if path.startswith("\\\\?\\UNC\\"):
            path = "\\\\" + path[8:]
        elif path.startswith("\\\\?\\"):
            path = path[4:]
        return os.path.normcase(path.rstrip("\\/"))

    @staticmethod
    def _event_key(event):
        return hashlib.sha256((event["thread_id"] + ":" + event["turn_id"]).encode()).hexdigest()[:24]

    def accept(self, event, now=None):
        now = self.clock() if now is None else now
        if event.get("age_seconds", 0) <= 180:
            return None
        info = self._thread(event["thread_id"])
        if not self._eligible(info) or not still_waiting(info, event):
            return None
        key = self._event_key(event)
        folder = self.state_dir / "incidents" / key
        with closing(self._connect()) as db:
            db.execute("BEGIN IMMEDIATE")
            if db.execute("SELECT 1 FROM incidents WHERE event_key=?", (key,)).fetchone():
                db.rollback(); return None
            if db.execute("SELECT 1 FROM incidents WHERE thread_id=? AND created>?", (event["thread_id"], now - 1800)).fetchone():
                db.rollback(); return None
            if db.execute("SELECT count(*) FROM incidents WHERE created>?", (now - 86400,)).fetchone()[0] >= 6:
                db.rollback(); return None
            parent = db.execute("SELECT * FROM incidents WHERE new_thread_id=? ORDER BY created DESC LIMIT 1", (event["thread_id"],)).fetchone()
            lineage = {}
            if parent:
                parent_data = json.loads((Path(parent["folder"]) / "incident.json").read_text(encoding="utf-8"))
                root_thread_id = parent_data.get("root_thread_id") or parent["thread_id"]
                root_info = self._thread(root_thread_id)
                if not root_info:
                    db.rollback(); return None
                work_cwd = parent_data.get("work_cwd") or self._canonical_path(root_info["cwd"])
                handoff = str(handoff_path(self, parent) or Path(parent["folder"]) / "PROJECT_HANDOFF.md")
                lineage = {"parent_event_key": parent["event_key"], "root_thread_id": root_thread_id,
                           "work_cwd": work_cwd, "project_handoff_path": handoff}
            folder.mkdir(parents=True, exist_ok=True)
            _atomic_json(folder / "incident.json", {"event_key": key, "observed_at": now, "request": event,
                         "thread": info, "stage_verified": False, "old_thread_write_state": "unknown", **lineage})
            db.execute("INSERT INTO incidents(event_key,thread_id,turn_id,created,status,folder) VALUES(?,?,?,?,?,?)",
                       (key, event["thread_id"], event["turn_id"], now, "queued", str(folder)))
            db.commit()
        try:
            create_packet(self.home, folder)
        except (OSError, ValueError, sqlite3.Error, KeyError, json.JSONDecodeError):
            with closing(self._connect()) as db:
                db.execute("UPDATE incidents SET status='needs_attention',result='needs_attention' WHERE event_key=?", (key,))
        else:
            if parent:
                with closing(self._connect()) as db:
                    db.execute("BEGIN IMMEDIATE")
                    changed = db.execute("UPDATE incidents SET status='needs_attention',result='needs_attention' "
                                         "WHERE event_key=? AND status='acknowledged'", (parent["event_key"],)).rowcount
                    if changed:
                        db.execute("INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                                   ("superseded_by:" + parent["event_key"], key))
                    db.commit()
        return key

    def _turn_outcome(self, incident, info=None):
        """Return the current turn outcome, or superseded when a newer turn exists."""
        info = info or self._thread(incident["thread_id"])
        if not info:
            return "unknown"
        path = Path(self._canonical_path(info["rollout_path"]))
        try:
            size = path.stat().st_size
            lower = max(0, size - 32 * 1024 * 1024)
            suffix = b""
            with path.open("rb") as stream:
                end = size
                while end > lower:
                    start = max(lower, end - 512 * 1024)
                    stream.seek(start)
                    parts = (stream.read(end - start) + suffix).split(b"\n")
                    suffix = parts.pop(0) if start else b""
                    if len(suffix) > 1024 * 1024:
                        suffix = b""
                    for line in reversed(parts):
                        try:
                            record = json.loads(line)
                        except (ValueError, UnicodeDecodeError):
                            continue
                        if record.get("type") != "event_msg":
                            continue
                        payload = record.get("payload")
                        if not isinstance(payload, dict):
                            continue
                        kind = payload.get("type")
                        if kind not in ("task_started", "task_failed", "turn_aborted", "task_complete", "task_completed"):
                            continue
                        if payload.get("turn_id") != incident["turn_id"]:
                            return "superseded" if payload.get("turn_id") else "unknown"
                        if kind == "task_failed":
                            return "failed"
                        if kind == "turn_aborted":
                            return "failed" if payload.get("error") else "unknown"
                        if kind in ("task_complete", "task_completed"):
                            return "failed" if payload.get("error") else "completed"
                        if kind == "task_started":
                            return "waiting"
                    end = start
        except (OSError, ValueError, TypeError):
            pass
        return "unknown"

    def _refresh_queued(self, db, row):
        info = self._thread(row["thread_id"])
        outcome = self._turn_outcome(row, info)
        if outcome == "failed" and self._eligible(info):
            if row["status"] != "recovery_queued":
                db.execute("UPDATE incidents SET status='recovery_queued',result=NULL WHERE event_key=? AND status IN ('queued','waiting_handoff')", (row["event_key"],))
            return "recovery_queued"
        if outcome == "completed" or (outcome == "waiting" and self._request_finished(row) is True):
            db.execute("UPDATE incidents SET status='closed',result='recovered' WHERE event_key=? AND status IN ('queued','recovery_queued','waiting_handoff')", (row["event_key"],))
            return "closed"
        if row["status"] in ("queued", "waiting_handoff") and outcome == "waiting" and self._eligible(info) and still_waiting(info, {"turn_id": row["turn_id"]}):
            if row["status"] == "waiting_handoff":
                return "waiting_handoff"
            return "queued"
        db.execute("UPDATE incidents SET status='needs_attention',result='needs_attention' WHERE event_key=? AND status IN ('queued','recovery_queued','waiting_handoff')", (row["event_key"],))
        return "needs_attention"

    def submit_handoff(self, event_key, path):
        source = Path(path)
        if (not source.is_absolute() or source.suffix.lower() != ".md" or
                any(part.is_symlink() for part in (source, *source.parents)) or not source.is_file()):
            raise ValueError("handoff must be an existing UTF-8 .md file")
        with source.open("rb") as stream:
            raw = stream.read(MAX_HANDOFF_CHARS * 4 + 1)
        try:
            content = raw.decode("utf-8-sig")
        except UnicodeError as exc:
            raise ValueError("handoff must be UTF-8") from exc
        if not content.strip() or len(content) > MAX_HANDOFF_CHARS:
            raise ValueError("handoff must contain 1 to 16000 characters")
        with closing(self._connect()) as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM incidents WHERE event_key=?", (event_key,)).fetchone()
            allowed = row and (row["status"] in ("queued", "recovery_queued", "waiting_handoff") or
                               (row["status"] == "needs_attention" and row["result"] == "handoff_required"))
            reserved = db.execute("SELECT 1 FROM metadata WHERE key=?", ("local_dispatch:" + event_key,)).fetchone()
            if not allowed or reserved:
                db.rollback()
                raise ValueError("event is not awaiting an unspent handoff")
            folder = Path(row["folder"])
            root = self.state_dir / "incidents"
            target = folder / "PROJECT_HANDOFF.md"
            if (folder.is_symlink() or folder.parent.resolve() != root.resolve() or
                    folder.resolve().parent != root.resolve() or
                    folder.name != event_key or target.is_symlink() or target.is_dir() or
                    source.resolve() == target.resolve()):
                db.rollback()
                raise ValueError("event handoff path is not safe")
            tmp = target.with_name(target.name + "." + uuid.uuid4().hex + ".tmp")
            try:
                with tmp.open("x", encoding="utf-8", newline="") as stream:
                    stream.write(content)
                os.replace(tmp, target)
            finally:
                tmp.unlink(missing_ok=True)
            if row["status"] == "needs_attention":
                db.execute("UPDATE incidents SET status='waiting_handoff' WHERE event_key=?", (event_key,))
            db.commit()
        return {"event_key": event_key, "status": "waiting_handoff" if row["status"] == "needs_attention" else row["status"],
                "has_handoff": True, "project_handoff_path": str(target)}

    def requeue(self, event_key):
        with closing(self._connect()) as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM incidents WHERE event_key=? AND status IN ('queued','needs_attention','recovery_queued')", (event_key,)).fetchone()
            if not row or not self._eligible(self._thread(row["thread_id"])) or self._turn_outcome(row) != "failed":
                db.rollback()
                return False
            db.execute("UPDATE incidents SET status='recovery_queued',result=NULL WHERE event_key=?", (event_key,))
            db.commit()
        return True

    def claim(self, owner, event_key=None):
        cfg = self.settings()
        if not cfg["enabled"] or owner != self._guardian():
            return None
        if not self._thread(owner):
            return None
        try:
            running, identity = self.api_process()
        except (OSError, ValueError, subprocess.SubprocessError, RuntimeError):
            return None
        if not running or not self.readiness(cfg, identity):
            return None
        with closing(self._connect()) as db:
            db.execute("BEGIN IMMEDIATE")
            if db.execute("SELECT 1 FROM incidents WHERE status IN ('claimed','acknowledged','ambiguous','local_dispatching','local_running') LIMIT 1").fetchone():
                db.rollback(); return None
            row = (db.execute("SELECT * FROM incidents WHERE event_key=? AND status IN ('queued','recovery_queued')", (event_key,)).fetchone()
                   if event_key else db.execute("SELECT * FROM incidents WHERE status IN ('queued','recovery_queued') ORDER BY created LIMIT 1").fetchone())
            if not row:
                db.rollback(); return None
            state = self._refresh_queued(db, row)
            if state not in ("queued", "recovery_queued"):
                db.commit(); return None
            try:
                packet = create_packet(self.home, Path(row["folder"]))
            except (OSError, ValueError, sqlite3.Error, KeyError, json.JSONDecodeError):
                db.rollback(); return None
            db.execute("UPDATE incidents SET status='claimed',owner=?,claimed_at=? WHERE event_key=? AND status IN ('queued','recovery_queued')",
                       (owner, self.clock(), row["event_key"]))
            db.commit()
            claimed = dict(row)
        return {"event_key": claimed["event_key"], "thread_id": claimed["thread_id"],
                "folder": claimed["folder"], "packet_path": str(packet)}

    def ack(self, event_key, owner, new_thread_id, projectless=False):
        old = self._incident(event_key)
        new = self._thread(new_thread_id)
        if not old: return {"status": "rejected"}
        if old["status"] == "acknowledged" and old["owner"] == owner and old["new_thread_id"] == new_thread_id:
            return {"status": "acknowledged"}
        if not new: return {"status": "pending"}
        old_thread = self._thread(old["thread_id"])
        created_ms = new.get("created_at_ms")
        created = float(created_ms) / 1000 if created_ms is not None else float(new.get("created_at") or 0)
        old_cwd = self._canonical_path(old_thread["cwd"]) if old_thread else None
        new_cwd = self._canonical_path(new["cwd"])
        different_cwd = old_cwd != new_cwd
        projectless_root = Path(self._canonical_path(self.home.parent / "Projectless")).resolve()
        def within_projectless(value):
            path = Path(value).resolve()
            return path != projectless_root and projectless_root in path.parents
        if (not old_thread or new_thread_id in (old["thread_id"], owner) or new["archived"] or
                new["source"] != "vscode" or new.get("agent_path") or
                math.floor(created) < math.floor(old["created"]) or
                (different_cwd and not (projectless and within_projectless(old_cwd) and within_projectless(new_cwd)))):
            return {"status": "rejected"}
        with closing(self._connect()) as db:
            db.execute("BEGIN IMMEDIATE")
            changed = db.execute("UPDATE incidents SET status='acknowledged',new_thread_id=? WHERE event_key=? AND status='claimed' AND owner=?",
                                 (new_thread_id, event_key, owner)).rowcount
            if changed and different_cwd:
                binding = json.dumps({"old_cwd": old_cwd, "new_cwd": new_cwd, "new_thread_id": new_thread_id})
                db.execute("INSERT INTO metadata(key,value) VALUES(?,?)", ("recovery_binding:" + event_key, binding))
            db.commit()
        return {"status": "acknowledged" if changed == 1 else "rejected"}

    def close_event(self, event_key, result, owner):
        if result not in ("recovered", "needs_attention"):
            raise ValueError("invalid result")
        with closing(self._connect()) as db:
            db.execute("BEGIN IMMEDIATE")
            changed = db.execute("UPDATE incidents SET status='closed',result=? WHERE event_key=? AND owner=? AND status IN ('claimed','acknowledged')",
                                 (result, event_key, owner)).rowcount
            db.commit()
        return changed == 1

    def _incident(self, key):
        with closing(self._connect()) as db:
            row = db.execute("SELECT * FROM incidents WHERE event_key=?", (key,)).fetchone()
        return dict(row) if row else None

    def _request_finished(self, incident):
        """Return True when recovered, False while waiting, and None when evidence is unknown."""
        database = self.home / "logs_2.sqlite"
        try:
            request = json.loads((Path(incident["folder"]) / "incident.json").read_text(encoding="utf-8"))["request"]
            started = float(request["started_at"])
            turn = re.escape(incident["turn_id"])
            start_s = math.floor(started); start_ns = int((started - start_s) * 1_000_000_000)
            with closing(sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True, timeout=1)) as db:
                rows = db.execute("SELECT target,feedback_log_body FROM logs WHERE thread_id=? AND target=? AND (ts>? OR (ts=? AND ts_nanos>=?)) ORDER BY id DESC LIMIT 2000",
                                  (incident["thread_id"], "codex_core::stream_events_utils", start_s, start_s, start_ns)).fetchall()
            if not rows:
                return None
            turn_re = re.compile(r"turn_id=\\?\"?" + turn + r"(?=[\s\\\"}])")
            item_re = re.compile(r'Output item item_type=\\?"(message|function_call|custom_tool_call|tool_call)')
            matching = [body for _target, body in rows if isinstance(body, str) and turn_re.search(body)]
            return None if not matching else any(item_re.search(body) for body in matching)
        except (OSError, ValueError, KeyError, TypeError, sqlite3.Error, json.JSONDecodeError):
            return None

    def _powershell_probe(self):
        script = "[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); Get-CimInstance Win32_Process -Filter \"Name='ChatGPT.exe'\" | Select-Object ProcessId,CommandLine | ConvertTo-Json -Compress"
        powershell = str(Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32/WindowsPowerShell/v1.0/powershell.exe")
        environment = os.environ.copy()
        environment.pop("PSModulePath", None)
        out = subprocess.run([powershell, "-NoProfile", "-Command", script], capture_output=True, text=True, encoding="utf-8", env=environment,
                             timeout=4, creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
        if out.returncode != 0:
            raise RuntimeError("process identity unavailable")
        rows = json.loads(out.stdout or "[]")
        if isinstance(rows, dict): rows = [rows]
        expected = os.path.normcase(os.path.normpath(str(self.profile.resolve())))
        matches = []
        for row in rows:
            import re
            cmd = row.get("CommandLine") or ""
            if re.search(r'(?:^|\s)--type=', cmd, re.I):
                continue
            m = re.search(r'(?:^|\s)--user-data-dir(?:=|\s+)(?:"([^"]+)"|(\S+))', cmd, re.I)
            if m:
                try:
                    candidate = os.path.normcase(os.path.normpath(str(Path(m.group(1) or m.group(2)).resolve())))
                except OSError:
                    continue
                if candidate == expected:
                    matches.append(str(row.get("ProcessId")))
        if not matches:
            return False, None
        return True, ",".join(sorted(matches))

    def api_process(self, now=None):
        now = self.clock() if now is None else now
        if now - self._probe_cache[0] < 5:
            return self._probe_cache[1:]
        running, identity = self.process_probe()
        self._probe_cache = (now, bool(running), identity)
        return bool(running), identity

    def _verified_bridge_backends(self, identity):
        """Read-only pinned probe for the single validated Desktop -> bridge -> CLI chain."""
        if not isinstance(identity, str) or not re.fullmatch(r"\d+(?:,\d+)*", identity):
            return []
        try:
            probe = Path(__file__).with_name("Guard-BridgeRuntime.ps1")
            binding_path = probe.with_name("guard-runtime-binding.json")
            for path in (probe, binding_path):
                if path.is_symlink() or path.stat().st_file_attributes & 0x400:
                    return []
            if hashlib.sha256(probe.read_bytes()).hexdigest().upper() != BRIDGE_PROBE_SHA256:
                return []
            with binding_path.open("rb") as stream:
                raw = stream.read(8193)
            if len(raw) > 8192:
                return []
            binding = json.loads(raw.decode("utf-8-sig"))
            integration = Path(binding.get("integrationPath", ""))
            if (binding.get("schema") != 1 or not integration.is_absolute() or
                    integration.name != "integration.json" or
                    not integration.resolve().is_relative_to(Path(r"E:\Codex-API\AdaptiveBridge").resolve()) or
                    not re.fullmatch(r"[a-fA-F0-9]{64}", binding.get("integrationHash", "")) or
                    not re.fullmatch(r"[a-fA-F0-9]{64}", binding.get("launchHelperHash", ""))):
                return []
            powershell = str(Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32/WindowsPowerShell/v1.0/powershell.exe")
            environment = os.environ.copy()
            environment.pop("PSModulePath", None)
            out = subprocess.run([powershell, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                                  "-File", str(probe), "-ApiHome", str(self.home), "-Profile", str(self.profile),
                                  "-DesktopIds", identity], capture_output=True, text=True, encoding="utf-8",
                                 env=environment, timeout=12, creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
            if out.returncode or len(out.stdout) > 16384:
                return []
            payload = json.loads(out.stdout)
            if (not isinstance(payload, dict) or payload.get("schema") != 1 or
                    self._canonical_path(payload.get("apiHome", "")) != self._canonical_path(str(self.home)) or
                    self._canonical_path(payload.get("profile", "")) != self._canonical_path(str(self.profile))):
                return []
            rows = payload.get("rows")
            if not isinstance(rows, list) or len(rows) != 1:
                return []
            row = rows[0]
            parents = {int(part) for part in identity.split(",")}
            if (not isinstance(row, dict) or row.get("VerifiedBridge") is not True or
                    any(type(row.get(key)) is not int or row[key] <= 0 for key in
                        ("ProcessId", "ParentProcessId", "DesktopProcessId", "BridgeProcessId", "Started")) or
                    row["DesktopProcessId"] not in parents or row["ParentProcessId"] != row["BridgeProcessId"] or
                    len({row["ProcessId"], row["BridgeProcessId"], row["DesktopProcessId"]}) != 3):
                return []
            exe = Path(self._canonical_path(row.get("ExecutablePath", "")))
            if not exe.is_absolute() or exe.name.lower() != "codex.exe" or not exe.is_file():
                return []
            return rows
        except (OSError, ValueError, TypeError, AttributeError, subprocess.SubprocessError):
            return []

    def discover_cli(self, force=False):
        now = self.clock()
        running, identity = self.api_process(now)
        if not running or not isinstance(identity, str) or not re.fullmatch(r"\d+(?:,\d+)*", identity):
            return None
        if not force and self._cli_probe[1] == identity and 0 <= now - self._cli_probe[0] < 30:
            return None
        self._cli_probe = (now, identity)
        parents = {int(part) for part in identity.split(",")}
        script = ("[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); $apiIds=@(" + identity + "); "
                  "Get-CimInstance Win32_Process -Filter \"Name='codex.exe'\" | "
                  "Where-Object {$apiIds -contains $_.ParentProcessId} | "
                  "Select-Object ProcessId,ParentProcessId,ExecutablePath | ConvertTo-Json -Compress")
        powershell = str(Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32/WindowsPowerShell/v1.0/powershell.exe")
        environment = os.environ.copy()
        environment.pop("PSModulePath", None)
        try:
            out = subprocess.run([powershell, "-NoProfile", "-Command", script], capture_output=True,
                                 text=True, encoding="utf-8", env=environment, timeout=4,
                                 creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
            if out.returncode:
                return None
            rows = json.loads(out.stdout or "[]")
            if isinstance(rows, dict):
                rows = [rows]
            if not isinstance(rows, list):
                return None
            candidates = []
            for row in rows:
                if (not isinstance(row, dict) or type(row.get("ParentProcessId")) is not int or
                        row["ParentProcessId"] not in parents or type(row.get("ProcessId")) is not int or
                        row["ProcessId"] <= 0):
                    continue
                path = row.get("ExecutablePath")
                if not isinstance(path, str):
                    continue
                exe = Path(self._canonical_path(path))
                if exe.is_absolute() and exe.name.lower() == "codex.exe" and exe.is_file():
                    candidates.append((row["ProcessId"], exe.resolve()))
            unique = {path for _pid, path in candidates}
            if not candidates:
                verified = self._verified_bridge_backends(identity)
                unique = {Path(self._canonical_path(row["ExecutablePath"])).resolve() for row in verified}
            return next(iter(unique)) if len(unique) == 1 else None
        except (OSError, ValueError, TypeError, subprocess.SubprocessError):
            return None

    def repair_cli(self):
        self.settings()
        if self.config_error:
            raise ValueError("settings_unreadable")
        executable = self.discover_cli(force=True)
        if executable is None:
            raise RuntimeError("API CLI child not found")
        with Singleton(self.state_dir / "desktop-settings.lock"):
            current = self.settings()
            if self.config_error:
                raise ValueError("settings_unreadable")
            current["cli_executable"] = str(executable)
            self._write_settings(current)
        return {"cli_executable": str(executable)}

    def tick(self):
        now = self.clock(); cfg = self.settings()
        try:
            running, identity = self.api_process(now)
            slept = self.last_loop is not None and now - self.last_loop > 30
            if not running:
                if self.reader: self.reader.close(); self.reader = None
            elif self.reader is None or slept or identity != self.reader_process:
                if self.reader: self.reader.close()
                self.reader = LogReader(self.home / "logs_2.sqlite"); self.reader_process = identity
                self._restore_recent_waits(now)
            self.pending = []
            if running and cfg["enabled"]:
                expired = self.reader.poll(now=now, threshold=180)
                for key, request in list(self.reader.pending.items()):
                    info = self._thread(request.key.thread_id)
                    if not self._eligible(info) or not still_waiting(info, {"turn_id": request.key.turn_id}):
                        self.reader.pending.pop(key, None)
                    else:
                        self.pending.append({"thread_id": request.key.thread_id,
                                             "age_seconds": max(0.0, now - request.started_at), "phase": request.phase})
                for event in expired: self.accept(event, now)
                with closing(self._connect()) as db:
                    db.execute("BEGIN IMMEDIATE")
                    queued = db.execute("SELECT * FROM incidents WHERE status IN ('queued','recovery_queued','waiting_handoff') ORDER BY created LIMIT 20").fetchall()
                    for row in queued:
                        self._refresh_queued(db, row)
                    db.commit()
            if (running and cfg["enabled"]) or self._event_worker:
                tick_local_dispatch(self, now)
            self.error = self.config_error
        except (OSError, ValueError, sqlite3.Error, subprocess.SubprocessError, RuntimeError) as exc:
            running = False; self.error = _short_error(exc)
            if self.reader: self.reader.close(); self.reader = None
        self.last_loop = now
        return self.write_status(running)

    def _restore_recent_waits(self, now):
        """Bounded replay after restart; live-turn evidence remains mandatory in accept()."""
        connection = self.reader._connection
        backends = self._backend_processes()
        if not backends:
            return
        with closing(sqlite3.connect((self.home / "state_5.sqlite").resolve().as_uri() + "?mode=ro", uri=True, timeout=1)) as db:
            # Recent root tasks only; never scan the full session store.
            columns = {row[1] for row in db.execute("PRAGMA table_info(threads)")}
            order = "updated_at" if "updated_at" in columns else "created_at"
            ids = db.execute("SELECT id FROM threads WHERE source='vscode' AND archived=0 AND agent_path IS NULL ORDER BY " + order + " DESC LIMIT 32").fetchall()
        for (thread_id,) in ids:
            info = self._thread(thread_id)
            if not self._eligible(info):
                continue
            path = Path(info["rollout_path"])
            try:
                stat = path.stat()
                latest = _latest_turn_event(path, stat.st_size, stat.st_mtime_ns)
            except OSError:
                continue
            if not latest or latest[0] != "task_started":
                continue
            rows = connection.execute(
                "SELECT id,ts,ts_nanos,target,feedback_log_body,thread_id,process_uuid "
                "FROM logs WHERE thread_id=? AND id<=? AND ts>=? AND target IN (?,?,?) "
                "ORDER BY id DESC LIMIT 2000",
                (thread_id, self.reader.cursor, int(now - 86400), "codex_http_client::custom_ca",
                 "codex_core::stream_events_utils", "codex_core::session::turn")).fetchall()
            for row in reversed(rows):
                process = row["process_uuid"] or ""
                if any(process.startswith(prefix) and row["ts"] >= started for prefix, started in backends.items()):
                    self.reader.ingest(row)
        # Historical requests may belong to completed turns or ineligible tasks.
        # Require the latest on-disk turn to match before retaining any candidate.
        for key in list(self.reader.pending):
            info = self._thread(key.thread_id)
            if not self._eligible(info) or not still_waiting(info, {"turn_id": key.turn_id}):
                self.reader.pending.pop(key, None)

    def _backend_processes(self):
        """Only replay logs from live codex children of the verified API desktop."""
        identity = self.reader_process
        if not identity or not re.fullmatch(r"\d+(?:,\d+)*", identity):
            return {}
        script = ("[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); $apiIds=@(" + identity + "); "
                  "Get-CimInstance Win32_Process -Filter \"Name='codex.exe'\" | "
                  "Where-Object {$apiIds -contains $_.ParentProcessId} | "
                  "Select-Object ProcessId,@{Name='Started';Expression={([DateTimeOffset]$_.CreationDate).ToUnixTimeSeconds()}} | ConvertTo-Json -Compress")
        powershell = str(Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32/WindowsPowerShell/v1.0/powershell.exe")
        environment = os.environ.copy(); environment.pop("PSModulePath", None)
        result = subprocess.run([powershell, "-NoProfile", "-Command", script], capture_output=True,
                                text=True, encoding="utf-8", env=environment, timeout=4,
                                creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
        if result.returncode:
            return {}
        rows = json.loads(result.stdout or "[]")
        if isinstance(rows, dict): rows = [rows]
        if not rows:
            rows = self._verified_bridge_backends(identity)
        return {"pid:" + str(row["ProcessId"]) + ":": int(row["Started"]) for row in rows}

    def runtime_status(self, running=None):
        cfg = self.settings()
        if running is None:
            try: running, _ = self.api_process()
            except Exception: running = False
        with closing(self._connect()) as db:
            rows = db.execute("SELECT event_key,thread_id,created,status,folder,new_thread_id,result FROM incidents ORDER BY created DESC LIMIT 20").fetchall()
        error = self.error or self.config_error
        state = "error" if error else ("paused" if not cfg["enabled"] else ("monitoring" if running else "standby"))
        return {"version": VERSION, "enabled": cfg["enabled"], "state": state, "api_running": bool(running), "last_check": int(self.last_loop or self.clock()),
                "pending_requests": [{k: e.get(k) for k in ("thread_id","age_seconds","phase")} for e in self.pending],
                "incidents": [dict(r, has_handoff=has_handoff(self, r)) for r in rows], "effort": cfg["effort"],
                "dispatch_mode": cfg["dispatch_mode"], "cli_executable": cfg["cli_executable"],
                "guardian_thread_id": self._guardian(), "guardian_cwd": cfg["guardian_cwd"],
                "native_dispatch_ready": self.readiness(cfg, self.reader_process if running else None),
                "api_process_identity": self.reader_process if running else None, "error": error, "pid": os.getpid()}

    def status(self):
        cfg = self.settings()
        try:
            snapshot = json.loads(self.status_path.read_text(encoding="utf-8"))
            if not _valid_snapshot(snapshot): raise ValueError("bad status")
        except (OSError, ValueError, TypeError):
            snapshot = {"version": VERSION, "state": "stopped", "api_running": False, "last_check": 0,
                        "pending_requests": [], "error": None, "pid": None}
        with closing(self._connect()) as db:
            rows = db.execute("SELECT event_key,thread_id,created,status,folder,new_thread_id,result FROM incidents ORDER BY created DESC LIMIT 20").fetchall()
        snapshot.update({"enabled": cfg["enabled"], "effort": cfg["effort"],
                         "dispatch_mode": cfg["dispatch_mode"], "cli_executable": cfg["cli_executable"],
                         "guardian_thread_id": self._guardian(), "guardian_cwd": cfg["guardian_cwd"],
                         "native_dispatch_ready": self.readiness(cfg, snapshot.get("api_process_identity")),
                         "incidents": [dict(r, has_handoff=has_handoff(self, r)) for r in rows], "version": VERSION})
        if self.config_error:
            snapshot["state"] = "error"; snapshot["error"] = self.config_error
        snapshot.update(self.dispatch_status(snapshot))
        return snapshot

    def dispatch_status(self, snapshot):
        """Expose dispatch separately: a live detector does not imply recovery is armed."""
        age = self.clock() - float(snapshot.get("last_check") or 0)
        blockers = []
        if not snapshot.get("pid") or not math.isfinite(age) or age < 0 or age >= 20:
            blockers.append("backend_heartbeat_stale")
        if not snapshot.get("enabled"):
            blockers.append("monitor_disabled")
        if not snapshot.get("api_running"):
            blockers.append("api_not_running")
        if snapshot.get("dispatch_mode") == "local_once":
            with closing(self._connect()) as db:
                slot = db.execute("SELECT status FROM incidents WHERE status IN (?,?,?,?,?) LIMIT 1", LIVE).fetchone()
            if slot:
                blockers.append("ambiguous_slot_occupied" if slot[0] == "ambiguous" else "global_slot_occupied")
            guardian = self._thread(snapshot.get("guardian_thread_id")) if snapshot.get("guardian_thread_id") else None
            workspace = self.guardian_workspace()
            if not self._guardian_valid(guardian) and not snapshot.get("guardian_thread_id"):
                blockers.append("guardian_unavailable")
            elif workspace is None:
                blockers.append("guardian_cwd_unavailable")
            executable = snapshot.get("cli_executable")
            if not executable or not Path(executable).is_absolute() or not Path(executable).is_file():
                blockers.append("cli_executable_unavailable")
            return {"backend_heartbeat_age_seconds": round(age, 2),
                    "recovery_dispatch_state": "blocked" if blockers else "ready",
                    "recovery_dispatch_blockers": blockers}
        if not snapshot.get("native_dispatch_ready"):
            blockers.append("native_dispatch_not_verified")
        # This is the one production guardian heartbeat, not a search of other jobs.
        automation = self.home / "automations" / "api" / "automation.toml"
        try:
            import tomllib
            config = tomllib.loads(automation.read_text(encoding="utf-8-sig"))
            if config.get("status") != "ACTIVE":
                blockers.append("guardian_automation_paused")
            if config.get("target_thread_id") != snapshot.get("guardian_thread_id"):
                blockers.append("guardian_automation_target_mismatch")
        except (OSError, ValueError):
            blockers.append("guardian_automation_unavailable")
        return {"backend_heartbeat_age_seconds": round(age, 2),
                "recovery_dispatch_state": "blocked" if blockers else "ready",
                "recovery_dispatch_blockers": blockers}

    def write_status(self, running=None):
        value = self.runtime_status(running)
        value.update(self.dispatch_status(value))
        _write_snapshot(self.status_path, value)
        return value

    def serve(self):
        with Singleton(self.state_dir / "desktop-service.lock"):
            stop = self.state_dir / "desktop-service.shutdown"
            try: stop.unlink()
            except FileNotFoundError: pass
            try:
                while not stop.exists():
                    self.tick()
                    for _ in range(10):
                        if stop.exists(): break
                        time.sleep(.5)
            finally:
                if self.reader: self.reader.close(); self.reader = None
                stopped = self.runtime_status(False)
                stopped.update({"state": "stopped", "api_running": False, "last_check": int(self.clock()), "pid": None})
                _write_snapshot(self.status_path, stopped)

    def shutdown(self):
        marker = self.state_dir / "desktop-service.shutdown"
        tmp = marker.with_name(marker.name + "." + uuid.uuid4().hex + ".tmp")
        tmp.write_text("stop\n", encoding="ascii"); os.replace(tmp, marker)
        return {"shutdown_requested": True}


def _bool(text):
    if text.lower() not in ("true", "false"): raise argparse.ArgumentTypeError("use true or false")
    return text.lower() == "true"


def main():
    parser = argparse.ArgumentParser()
    subs = parser.add_subparsers(dest="command", required=True)
    subs.add_parser("serve"); subs.add_parser("status"); subs.add_parser("shutdown")
    subs.add_parser("health"); subs.add_parser("export-diagnostics")
    subs.add_parser("repair-cli")
    p = subs.add_parser("inspect-event"); p.add_argument("--event", required=True)
    p = subs.add_parser("configure"); p.add_argument("--enabled", type=_bool); p.add_argument("--effort", choices=("low","medium")); p.add_argument("--dispatch-mode", choices=("queue","local_once")); p.add_argument("--cli-executable")
    p = subs.add_parser("set-ready"); p.add_argument("--value", required=True, type=_bool)
    p = subs.add_parser("bind-guardian"); p.add_argument("--thread", required=True)
    p = subs.add_parser("claim"); p.add_argument("--owner", required=True); p.add_argument("--event")
    p = subs.add_parser("requeue"); p.add_argument("--event", required=True)
    p = subs.add_parser("submit-handoff"); p.add_argument("--event", required=True); p.add_argument("--path", required=True)
    p = subs.add_parser("ack"); p.add_argument("--event", required=True); p.add_argument("--owner", required=True); p.add_argument("--new-thread", required=True); p.add_argument("--projectless", action="store_true")
    p = subs.add_parser("close"); p.add_argument("--event", required=True); p.add_argument("--result", choices=("recovered","needs_attention"), required=True); p.add_argument("--owner", required=True)
    args = parser.parse_args(); service = DesktopService(API_HOME, DESKTOP_PROFILE)
    if args.command == "serve": service.serve(); return
    if args.command == "status": result = service.status()
    elif args.command == "health": result = health_report(service)
    elif args.command == "export-diagnostics": result = export_diagnostics(service)
    elif args.command == "repair-cli": result = service.repair_cli()
    elif args.command == "inspect-event": result = inspect_event(service, args.event)
    elif args.command == "shutdown": result = service.shutdown()
    elif args.command == "configure": result = service.configure(args.enabled, args.effort, args.dispatch_mode, args.cli_executable)
    elif args.command == "set-ready": result = service.set_ready(args.value)
    elif args.command == "bind-guardian": result = {"guardian_thread_id": service.bind_guardian(args.thread)}
    elif args.command == "claim": result = service.claim(args.owner, args.event)
    elif args.command == "requeue": result = {"requeued": service.requeue(args.event)}
    elif args.command == "submit-handoff": result = service.submit_handoff(args.event, args.path)
    elif args.command == "ack": result = service.ack(args.event, args.owner, args.new_thread, args.projectless)
    else: result = {"closed": service.close_event(args.event, args.result, args.owner)}
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, sqlite3.Error, RuntimeError) as exc:
        messages = {
            "handoff must be an existing UTF-8 .md file": "请选择现有的 UTF-8 Markdown 交接包，不接受目录或链接。",
            "handoff must be UTF-8": "交接包编码不是 UTF-8，请由项目聊天重新导出。",
            "handoff must contain 1 to 16000 characters": "交接包不能为空，且最多 16000 字符。",
            "event is not awaiting an unspent handoff": "事件已不再等待交接，或单次调用已经使用。请刷新事件详情。",
            "event handoff path is not safe": "交接目标路径无效，未写入文件。",
            "invalid event key": "事件编号无效。", "event not found": "未找到该事件。",
            "settings_unreadable": "配置文件无法读取，已保留原文件；请先检查配置。",
            "API CLI child not found": "未找到可唯一确认的 API 执行入口，请确认 API 实例正在运行。",
        }
        print(json.dumps({"error": _short_error(exc), "message": messages.get(str(exc), sanitize(str(exc))[:240])}, ensure_ascii=False), file=sys.stderr)
        raise SystemExit(1)
