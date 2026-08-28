"""Persistent Copilot answer engine over the Agent Client Protocol (ACP).

Spawning ``copilot.exe -p`` per command costs a fixed ~11s cold start. Running
one long-lived ``copilot.exe --acp`` process and reusing an ACP session removes
that cold start entirely: warmed prompts return in a few seconds and tokens
stream as they are produced.
"""

from __future__ import annotations

import json
import logging
import os
import sqlite3
import subprocess
import threading
import time
import queue
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Optional


_AGENT_MODE = "https://agentclientprotocol.com/protocol/session-modes#agent"


class AcpCopilotSession:
    def __init__(
        self,
        executable: Path,
        cwd: Path,
        model_id: str | None = "gpt-5-mini",
        effort: str | None = "none",
    ) -> None:
        self.executable = executable
        self.cwd = cwd
        self.model_id = model_id
        self.effort = effort
        self._proc: subprocess.Popen | None = None
        self._messages: "queue.Queue[dict]" = queue.Queue()
        self._id = 0
        self._session_id: str | None = None
        self._lock = threading.Lock()
        self._reader: threading.Thread | None = None

    # ---- lifecycle -------------------------------------------------------
    def start(self) -> None:
        """Launch the ACP process and open a reusable session (pre-warm)."""
        with self._lock:
            self._start_locked()

    def _start_locked(self) -> None:
        flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        # Launch flags set the session defaults: `--effort none` cuts model
        # reasoning latency dramatically and `--model` picks a fast model.
        args = [str(self.executable), "--acp"]
        if self.effort:
            args += ["--effort", self.effort]
        if self.model_id:
            args += ["--model", self.model_id]
        # Point the CLI at Scout's own session store so voice commands show up
        # in the Scout desktop "Activity" list (same sessions/turns DB).
        env = os.environ.copy()
        scout_home = Path.home() / ".scout" / "copilot"
        if scout_home.exists():
            env["COPILOT_HOME"] = str(scout_home)
        self._proc = subprocess.Popen(
            args,
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
        self._reader = threading.Thread(target=self._read_loop, daemon=True)
        self._reader.start()

        self._request("initialize", {"protocolVersion": 1, "clientCapabilities": {}}, timeout=30)
        result = self._request(
            "session/new", {"cwd": str(self.cwd), "mcpServers": []}, timeout=45
        )
        self._session_id = result.get("sessionId")
        if not self._session_id:
            raise RuntimeError("ACP session/new returned no sessionId.")
        logging.info(
            "ACP Copilot session ready (model=%s effort=%s)",
            self.model_id,
            self.effort,
        )

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

    # ---- request helpers -------------------------------------------------
    def _send(self, method: str, params: dict) -> int:
        assert self._proc is not None and self._proc.stdin is not None
        self._id += 1
        mid = self._id
        self._proc.stdin.write(
            json.dumps({"jsonrpc": "2.0", "id": mid, "method": method, "params": params})
            + "\n"
        )
        self._proc.stdin.flush()
        return mid

    def _request(self, method: str, params: dict, timeout: float = 60.0) -> dict:
        mid = self._send(method, params)
        end = time.time() + timeout
        while time.time() < end:
            try:
                obj = self._messages.get(timeout=0.2)
            except queue.Empty:
                continue
            if obj.get("id") == mid:
                if "error" in obj:
                    raise RuntimeError(str(obj["error"].get("message", "ACP error")))
                return obj.get("result", {})
            # permission requests etc. are auto-declined by design (read-only voice)
        raise TimeoutError(f"ACP {method} timed out")

    # ---- public API ------------------------------------------------------
    def ask(
        self,
        command: str,
        on_sentence: Optional[Callable[[str], None]] = None,
        timeout: float = 90.0,
        detailed: bool = False,
    ) -> str:
        """Send a prompt and return the full assistant text.

        If ``on_sentence`` is given, completed sentences are delivered as they
        stream so callers can start speaking before the answer finishes. When
        ``detailed`` is true the model is asked for a fuller (~1 minute) spoken
        summary instead of a terse 1-2 sentence reply.
        """
        if detailed:
            style = (
                "This is a summary/briefing request. Give a rich, well-organized "
                "spoken answer of about 150-220 Korean characters per topic, "
                "roughly one minute of speech total. Group related items, mention "
                "the important details (times, people, what to do), and finish "
                "with a short takeaway. Do not use markdown, tables, or URLs; "
                "write flowing sentences suitable for reading aloud."
            )
        else:
            style = (
                "Keep the answer short and natural for text-to-speech: at most 2 "
                "sentences. Do not use markdown, tables, lists, or URLs."
            )
        prompt = "\n".join(
            (
                "Handle the user's voice command.",
                "Reply in the SAME language as the command: if the command is in "
                "Korean, answer in Korean; if it is in English, answer in English.",
                style,
                "User command:",
                command,
            )
        )
        with self._lock:
            if not self._alive() or not self._session_id:
                logging.info("ACP process not alive; restarting")
                self._start_locked()

            mid = self._send(
                "session/prompt",
                {
                    "sessionId": self._session_id,
                    "prompt": [{"type": "text", "text": prompt}],
                },
            )
            collected: list[str] = []
            spoken_upto = 0
            end = time.time() + timeout
            while time.time() < end:
                try:
                    obj = self._messages.get(timeout=0.2)
                except queue.Empty:
                    continue
                if obj.get("method") == "session/update":
                    content = obj.get("params", {}).get("update", {}).get("content", {})
                    if isinstance(content, dict) and content.get("type") == "text":
                        text = content.get("text", "")
                        if text:
                            collected.append(text)
                            if on_sentence is not None:
                                spoken_upto = self._flush_sentences(
                                    "".join(collected), spoken_upto, on_sentence
                                )
                elif obj.get("id") == mid and ("result" in obj or "error" in obj):
                    if "error" in obj:
                        raise RuntimeError(
                            str(obj["error"].get("message", "ACP prompt error"))
                        )
                    full = "".join(collected).strip()
                    if on_sentence is not None and full and spoken_upto < len(full):
                        tail = full[spoken_upto:].strip()
                        if tail:
                            on_sentence(tail)
                    if not full:
                        raise RuntimeError("Copilot returned an empty response.")
                    self._label_activity(command)
                    return full
            raise TimeoutError("Copilot prompt timed out")

    def _label_activity(self, command: str) -> None:
        """Make the voice command readable in Scout Desktop Activity.

        The ACP turn is already stored in Scout's session-store.db because we
        set COPILOT_HOME=~/.scout/copilot. However its auto-summary starts with
        internal prompt instructions. Updating the session summary makes the
        Activity list show the actual spoken command.
        """
        if not self._session_id:
            return
        try:
            db = Path.home() / ".scout" / "copilot" / "session-store.db"
            if not db.exists():
                return
            summary = f"음성: {command.strip()[:120]}"
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            with sqlite3.connect(str(db), timeout=2) as conn:
                conn.execute(
                    "UPDATE sessions SET summary=?, updated_at=? WHERE id=?",
                    (summary, now, self._session_id),
                )
        except Exception:
            logging.exception("Failed to label Scout Activity session")

    @staticmethod
    def _flush_sentences(
        text: str, start: int, on_sentence: Callable[[str], None]
    ) -> int:
        import re

        pos = start
        for match in re.finditer(r".+?(?:다\.|요\.|[.!?])(?:\s|$)", text[start:]):
            sentence = match.group(0).strip()
            if sentence:
                on_sentence(sentence)
                pos = start + match.end()
        return pos

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
