"""Persistent WorkIQ MCP client for M365 questions with live progress.

`workiq.cmd ask` does not stream answer tokens — the final text arrives all at
once after ~15-40s. It DOES emit `notifications/progress` messages every few
seconds ("Searching through your data...", etc.). We keep one `workiq mcp`
stdio server warm and surface those progress notes to the UI/voice so the wait
never feels frozen. The MCP `ask` tool returns the same answer as the CLI but
without paying CLI process startup on every call.
"""

from __future__ import annotations

import json
import logging
import os
import queue
import subprocess
import threading
import time
from pathlib import Path
from typing import Callable, Optional


WORKIQ_PATH = Path.home() / ".scout" / "bin" / "workiq.cmd"


class WorkIQMcpSession:
    def __init__(self, cwd: Path) -> None:
        if not WORKIQ_PATH.exists():
            raise FileNotFoundError("Scout WorkIQ bridge was not found.")
        self.cwd = cwd
        self._proc: subprocess.Popen | None = None
        self._messages: "queue.Queue[dict]" = queue.Queue()
        self._id = 0
        self._lock = threading.Lock()
        self._initialized = False

    def start(self) -> None:
        with self._lock:
            self._start_locked()

    def _start_locked(self) -> None:
        flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        comspec = os.environ.get("COMSPEC", "cmd.exe")
        env = os.environ.copy()
        scout_home = Path.home() / ".scout" / "copilot"
        if scout_home.exists():
            env["COPILOT_HOME"] = str(scout_home)
        self._proc = subprocess.Popen(
            [comspec, "/d", "/c", str(WORKIQ_PATH), "mcp"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
            cwd=str(self.cwd),
            env=env,
            creationflags=flags,
        )
        self._messages = queue.Queue()
        threading.Thread(target=self._read_loop, daemon=True).start()
        self._request(
            "initialize",
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "scout-voice", "version": "1"},
            },
            timeout=30,
        )
        self._initialized = True
        logging.info("WorkIQ MCP session ready")

    def _read_loop(self) -> None:
        proc = self._proc
        if proc is None or proc.stdout is None:
            return
        for line in proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                self._messages.put(json.loads(line))
            except json.JSONDecodeError:
                continue

    def _alive(self) -> bool:
        return self._proc is not None and self._proc.poll() is None

    def _send(self, obj: dict) -> None:
        assert self._proc is not None and self._proc.stdin is not None
        self._proc.stdin.write(json.dumps(obj) + "\n")
        self._proc.stdin.flush()

    def _request(self, method: str, params: dict, timeout: float = 60.0) -> dict:
        self._id += 1
        mid = self._id
        self._send({"jsonrpc": "2.0", "id": mid, "method": method, "params": params})
        end = time.time() + timeout
        while time.time() < end:
            try:
                obj = self._messages.get(timeout=0.2)
            except queue.Empty:
                continue
            if obj.get("id") == mid:
                if "error" in obj:
                    raise RuntimeError(str(obj["error"].get("message", "WorkIQ error")))
                return obj.get("result", {})
        raise TimeoutError(f"WorkIQ {method} timed out")

    def ask(
        self,
        question: str,
        on_progress: Optional[Callable[[str], None]] = None,
        timeout: float = 90.0,
    ) -> str:
        """Ask M365 Copilot, forwarding progress notes to ``on_progress``."""
        with self._lock:
            if not self._alive() or not self._initialized:
                logging.info("WorkIQ MCP not alive; restarting")
                self._start_locked()

            self._id += 1
            mid = self._id
            token = f"voice-{mid}"
            self._send(
                {
                    "jsonrpc": "2.0",
                    "id": mid,
                    "method": "tools/call",
                    "params": {
                        "name": "ask",
                        "arguments": {"question": question},
                        "_meta": {"progressToken": token},
                    },
                }
            )
            end = time.time() + timeout
            while time.time() < end:
                try:
                    obj = self._messages.get(timeout=0.2)
                except queue.Empty:
                    continue
                if obj.get("method") == "notifications/progress":
                    params = obj.get("params", {})
                    if params.get("progressToken") == token and on_progress:
                        msg = params.get("message")
                        if isinstance(msg, str) and msg:
                            on_progress(msg)
                elif obj.get("id") == mid:
                    if "error" in obj:
                        raise RuntimeError(
                            str(obj["error"].get("message", "WorkIQ ask error"))
                        )
                    result = obj.get("result", {})
                    content = result.get("content", [])
                    text = "".join(
                        c.get("text", "")
                        for c in content
                        if isinstance(c, dict) and c.get("type") == "text"
                    )
                    if not text.strip():
                        raise RuntimeError("WorkIQ returned an empty response.")
                    return text.strip()
            raise TimeoutError("WorkIQ ask timed out")

    def close(self) -> None:
        with self._lock:
            if self._proc is not None:
                try:
                    if self._proc.stdin:
                        self._proc.stdin.close()
                    self._proc.wait(timeout=3)
                except Exception:  # noqa: BLE001
                    self._proc.kill()
                self._proc = None
