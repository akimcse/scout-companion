from __future__ import annotations

import argparse
import ctypes
import json
import os
import re
import sys
import threading
import time
import uuid
from pathlib import Path


PROCESS_QUERY_LIMITED_INFORMATION = 0x1000


def write_json(path: Path, value: dict) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, ensure_ascii=False), encoding="utf-8"
    )
    os.replace(temporary, path)


def clean_for_speech(text: str) -> str:
    text = re.sub(r"```.*?```", " ", text, flags=re.DOTALL)
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    text = re.sub(r"https?://\S+", "", text)
    text = re.sub(r"(?m)^\s{0,3}#{1,6}\s*", "", text)
    text = re.sub(r"(?m)^\s*[-*+]\s+", "", text)
    text = re.sub(r"[*_`>|]", "", text)
    return re.sub(r"\s+", " ", text).strip()


def process_exists(pid: int) -> bool:
    handle = ctypes.windll.kernel32.OpenProcess(
        PROCESS_QUERY_LIMITED_INFORMATION, False, pid
    )
    if not handle:
        return False
    ctypes.windll.kernel32.CloseHandle(handle)
    return True


class VoiceState:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.lock = threading.Lock()
        self.active_until = 0.0
        self.data = {
            "active": False,
            "stage": "starting",
            "status": "음성 엔진을 준비하는 중",
            "command": "",
            "answer": "",
            "updatedAt": time.time(),
        }

    def publish(self) -> None:
        with self.lock:
            self.data["updatedAt"] = time.time()
            write_json(self.path, self.data)

    def activate(self, seconds: float = 30.0) -> None:
        self.data["active"] = True
        self.active_until = time.monotonic() + seconds

    def handle(self, kind: str, value: object) -> None:
        with self.lock:
            if kind == "level":
                return
            text = str(value)
            if kind == "wake":
                self.activate()
                self.data["stage"] = "listening"
                self.data["status"] = "명령을 말씀하세요"
                self.data["command"] = ""
                self.data["answer"] = ""
            elif kind == "command":
                self.activate(120.0)
                self.data["stage"] = "processing"
                self.data["status"] = "처리 중"
                self.data["command"] = text
                self.data["answer"] = ""
            elif kind == "answer":
                self.activate(120.0)
                self.data["stage"] = "speaking"
                self.data["status"] = "말하는 중"
                self.data["answer"] = text
            elif kind == "transcript":
                if not self.data["active"]:
                    return
                self.data["transcript"] = text
            elif kind == "status":
                self.data["status"] = text
                if "처리" in text or "확인" in text or "검색" in text:
                    self.activate(120.0)
                    self.data["stage"] = "processing"
                elif "말하는" in text:
                    self.activate(120.0)
                    self.data["stage"] = "speaking"
                elif "명령" in text or "듣고" in text:
                    self.activate()
                    self.data["stage"] = "listening"
                elif "기다리는" in text:
                    self.data["stage"] = "idle"
                    if self.data["active"]:
                        self.active_until = time.monotonic() + 8.0
            self.data["updatedAt"] = time.time()
            write_json(self.path, self.data)

    def expire_if_idle(self) -> None:
        with self.lock:
            if (
                self.data["active"]
                and self.data["stage"] == "idle"
                and time.monotonic() >= self.active_until
            ):
                self.data["active"] = False
                self.data["command"] = ""
                self.data["answer"] = ""
                self.data["updatedAt"] = time.time()
                write_json(self.path, self.data)


class ScoutUiSession:
    def __init__(
        self,
        request_path: Path,
        response_path: Path,
        stop_path: Path,
    ) -> None:
        self.request_path = request_path
        self.response_path = response_path
        self.stop_path = stop_path

    def start(self) -> None:
        return

    def close(self) -> None:
        return

    def ask(
        self,
        command: str,
        on_sentence=None,
        timeout: float = 600.0,
        detailed: bool = False,
    ) -> str:
        del on_sentence, detailed
        request_id = str(uuid.uuid4())
        self.response_path.unlink(missing_ok=True)
        write_json(
            self.request_path,
            {
                "id": request_id,
                "command": command,
                "createdAt": time.time(),
            },
        )
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.stop_path.exists():
                raise RuntimeError("Voice control stopped.")
            if self.response_path.exists():
                try:
                    response = json.loads(
                        self.response_path.read_text(encoding="utf-8-sig")
                    )
                except (OSError, json.JSONDecodeError):
                    time.sleep(0.1)
                    continue
                if response.get("id") != request_id:
                    time.sleep(0.1)
                    continue
                if response.get("error"):
                    raise RuntimeError(str(response["error"]))
                raw_answer = str(response.get("answer", "")).strip()
                answer = clean_for_speech(raw_answer) or raw_answer
                if not answer:
                    raise RuntimeError("Scout returned an empty response.")
                return answer
            time.sleep(0.1)
        raise TimeoutError("Timed out waiting for the current Scout conversation.")


class NullSession:
    def start(self) -> None:
        return

    def close(self) -> None:
        return


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime-dir", type=Path, required=True)
    parser.add_argument("--state-file", type=Path, required=True)
    parser.add_argument("--stop-file", type=Path, required=True)
    parser.add_argument("--request-file", type=Path, required=True)
    parser.add_argument("--response-file", type=Path, required=True)
    parser.add_argument("--reply-enabled", choices=("true", "false"), required=True)
    parser.add_argument("--wake-sensitivity", type=int, required=True)
    parser.add_argument("--noise-sensitivity", type=int, required=True)
    parser.add_argument("--parent-pid", type=int, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    runtime_dir = args.runtime_dir.resolve()
    sys.path.insert(0, str(runtime_dir))
    os.chdir(runtime_dir)

    import agent as agent_module
    from voice_runtime import set_noise_sensitivity, set_wake_sensitivity

    set_wake_sensitivity(args.wake_sensitivity)
    set_noise_sensitivity(args.noise_sensitivity)

    ui_session = ScoutUiSession(
        args.request_file, args.response_file, args.stop_file
    )
    agent_module.AcpCopilotSession = lambda *unused_args, **unused_kwargs: ui_session
    agent_module.WorkIQMcpSession = lambda *unused_args, **unused_kwargs: NullSession()
    agent_module.WorkIQSession = lambda *unused_args, **unused_kwargs: NullSession()
    VoiceAgent = agent_module.VoiceAgent
    acquire_singleton = agent_module.acquire_singleton
    configure_logging = agent_module.configure_logging

    configure_logging()
    singleton = acquire_singleton()
    if singleton is None:
        return 2

    state = VoiceState(args.state_file)
    state.publish()
    agent = VoiceAgent(state.handle)
    agent.is_m365_command = lambda unused_command: False
    agent.fast_response = lambda unused_command: None
    if args.reply_enabled == "false":
        def finish_without_speech(unused_text: str) -> None:
            agent.emit("status", "“헤이 스카웃”을 기다리는 중")

        agent.speak_answer = finish_without_speech
        agent.say = lambda unused_text, block=True: finish_without_speech(
            unused_text
        )

    def monitor_parent() -> None:
        while not agent.stop_event.wait(0.25):
            state.expire_if_idle()
            if args.stop_file.exists() or not process_exists(args.parent_pid):
                agent.stop()
                return

    threading.Thread(target=monitor_parent, daemon=True).start()
    try:
        agent.run()
    finally:
        agent.stop()
        singleton.close()
        args.state_file.unlink(missing_ok=True)
        args.state_file.with_suffix(args.state_file.suffix + ".tmp").unlink(
            missing_ok=True
        )
        args.stop_file.unlink(missing_ok=True)
        args.request_file.unlink(missing_ok=True)
        args.request_file.with_suffix(
            args.request_file.suffix + ".tmp"
        ).unlink(missing_ok=True)
        args.response_file.unlink(missing_ok=True)
        args.response_file.with_suffix(
            args.response_file.suffix + ".tmp"
        ).unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
