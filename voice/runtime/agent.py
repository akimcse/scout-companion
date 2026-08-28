from __future__ import annotations

import logging
import logging.handlers
import msvcrt
import os
import re
import sqlite3
import sys
import threading
import time
import winsound
import uuid
from datetime import datetime, timezone
from difflib import SequenceMatcher
from pathlib import Path

import numpy as np
import sounddevice as sd

from voice_runtime import (
    APP_DIR,
    COPILOT_WORKING_DIR,
    RISKY_COMMAND,
    SAMPLE_RATE,
    OnlineSpeaker,
    StreamingSpeaker,
    VoiceModels,
    WorkIQSession,
    cosine_similarity,
    find_copilot,
    load_profile,
    play_chime,
    split_wake_command,
)
from acp_client import AcpCopilotSession
from workiq_mcp import WorkIQMcpSession


LOG_PATH = APP_DIR / "voice-agent.log"
LOCK_PATH = APP_DIR / "voice-agent.lock"


def choose_input_device() -> tuple[int | None, object | None, str]:
    """Prefer the Windows WASAPI Qualcomm microphone over legacy MME.

    On this Snapdragon X Elite machine the default input is the MME endpoint
    (device 1), which measured higher echo peaks. The WASAPI microphone array
    endpoint (device 12) measured lower echo and is the correct path for any
    Windows audio enhancements/Voice Clarity that may be active.
    """
    try:
        devices = sd.query_devices()
        candidates = []
        for index, device in enumerate(devices):
            if device["max_input_channels"] <= 0:
                continue
            host = sd.query_hostapis(device["hostapi"])["name"]
            name = str(device["name"])
            score = 0
            if host == "Windows WASAPI":
                score += 100
            if "Microphone Array" in name:
                score += 30
            if "Qualcomm" in name or "Aqstic" in name:
                score += 20
            if "WDM-KS" in host:
                score -= 50
            if "Headset" in name:
                score -= 20
            candidates.append((score, index, host, name))
        if candidates:
            _, index, host, name = sorted(candidates, reverse=True)[0]
            extra = sd.WasapiSettings(auto_convert=True) if host == "Windows WASAPI" else None
            return index, extra, f"{index}: {host} / {name}"
    except Exception:
        logging.exception("Failed to choose preferred input device")
    return None, None, "system default"


def configure_logging() -> None:
    handler = logging.handlers.RotatingFileHandler(
        LOG_PATH, maxBytes=1_000_000, backupCount=3, encoding="utf-8"
    )
    handler.setFormatter(
        logging.Formatter("%(asctime)s %(levelname)s %(message)s")
    )
    logging.basicConfig(level=logging.INFO, handlers=[handler])


def acquire_singleton():
    lock = LOCK_PATH.open("a+b")
    lock.seek(0)
    if lock.tell() == 0:
        lock.write(b"0")
        lock.flush()
    lock.seek(0)
    try:
        msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
    except OSError:
        lock.close()
        return None
    return lock


class VoiceAgent:
    def __init__(self, on_event=None) -> None:
        profile = load_profile()
        self.profile = np.asarray(profile["embedding"], dtype=np.float32)
        self.threshold = float(profile["threshold"])
        self.live_speaker_threshold = min(self.threshold, 0.45)
        self.models = VoiceModels()
        self.speaker = OnlineSpeaker(
            voice="ko-KR-SunHiNeural",
            fallback=None,
        )
        self.vad = self.models.create_vad()
        self.copilot = AcpCopilotSession(
            find_copilot(), COPILOT_WORKING_DIR, model_id="gpt-5-mini"
        )
        self.workiq = WorkIQSession()
        self.workiq_mcp = WorkIQMcpSession(COPILOT_WORKING_DIR)
        self.awaiting_command_until = 0.0
        self.pending_command: str | None = None
        self.pending_until = 0.0
        self.ignore_audio_until = 0.0
        self.on_event = on_event or (lambda _kind, _value: None)
        self.stop_event = threading.Event()
        self.pause_event = threading.Event()
        self.input_device, self.input_extra_settings, self.input_device_label = (
            choose_input_device()
        )
        # Barge-in: when Scout is speaking we keep listening; the wake word
        # interrupts playback. `speaking` marks that window; `speak_thread`
        # runs playback off the mic loop so recognition keeps running.
        self.speaking = threading.Event()
        self.speak_thread: threading.Thread | None = None
        self.interrupted = threading.Event()
        self._speaking_text = ""
        # Interrupt-on-owner-voice: any non-echo owner speech during playback
        # ducks/stops Scout, asks a confirm line, then waits for a command.
        self.interrupt_evt = threading.Event()
        self.awaiting_interrupt_command = False
        self.interrupt_command: str | None = None
        # Command handling runs on a worker thread so the mic loop keeps
        # decoding audio (needed for barge-in) while an answer is produced.
        self.worker: threading.Thread | None = None
        self.command_seq = 0
        self._warm()

    def _warm(self) -> None:
        """Pre-warm the TTS and answer engine so the first command is fast."""
        try:
            self.speaker.start()
        except Exception:
            logging.exception("Failed to pre-warm streaming TTS")
        threading.Thread(target=self._warm_copilot, daemon=True).start()

    def _warm_copilot(self) -> None:
        try:
            self.copilot.start()
        except Exception:
            logging.exception("Failed to pre-warm Copilot ACP session")
        try:
            self.workiq_mcp.start()
        except Exception:
            logging.exception("Failed to pre-warm WorkIQ MCP session")

    def emit(self, kind: str, value) -> None:
        try:
            self.on_event(kind, value)
        except Exception:
            logging.exception("Voice UI event handler failed")

    def verified(self, samples: np.ndarray) -> tuple[bool, float]:
        try:
            score = cosine_similarity(self.models.embedding(samples), self.profile)
            return score >= self.live_speaker_threshold, score
        except ValueError:
            return False, 0.0

    def say(self, text: str, block: bool = True) -> None:
        """Speak while still listening, so the wake word can interrupt.

        Playback runs on a background thread and the mic loop keeps decoding.
        A short ``ignore_audio_until`` only suppresses the very start so the
        chime/first syllable doesn't self-trigger; after that the wake word
        can barge in.
        """
        self.interrupted.clear()
        self.interrupt_evt.clear()
        self.speaking.set()
        self._speaking_text = re.sub(r"[^0-9a-zA-Z가-힣]", "", text)
        logging.info("TTS start chars=%d", len(text))
        self.emit("status", "말하는 중")

        def run() -> None:
            try:
                self.speaker.speak(text)
                logging.info("TTS complete chars=%d", len(text))
            finally:
                self.speaking.clear()
                self.vad.reset()
                self.ignore_audio_until = time.monotonic() + 0.4
                if not self.interrupted.is_set():
                    self.emit("status", "“헤이 스카웃”을 기다리는 중")

        self.speak_thread = threading.Thread(target=run, daemon=True)
        self.speak_thread.start()
        if block:
            self.speak_thread.join()

    def stop_speaking(self) -> None:
        """Barge-in: cut off current speech immediately."""
        if self.speaking.is_set():
            self.interrupted.set()
            try:
                self.speaker.stop()
            except Exception:
                logging.exception("Failed to stop speech")
            thread = self.speak_thread
            if thread is not None and thread.is_alive():
                thread.join(timeout=1.5)
            self.speaking.clear()
            self.vad.reset()

    @staticmethod
    def split_sentences(text: str) -> list[str]:
        parts = re.findall(r".+?(?:다\.|요\.|[.!?])(?:\s|$)|.+$", text.strip())
        return [p.strip() for p in parts if p.strip()] or [text.strip()]

    @staticmethod
    def _snap_to_sentence(text: str, approx_char: int) -> int:
        """Return the current sentence's start at/before approx_char."""
        if approx_char <= 0:
            return 0
        if approx_char >= len(text):
            return len(text)
        m = re.compile(r"(?:다\.|요\.|[.!?])(?:\s|$)")
        boundary = 0
        for match in m.finditer(text):
            if match.end() > approx_char:
                break
            boundary = match.end()
        return boundary

    _CHARS_PER_SEC = 6.5  # rough ko-KR-SunHi rate at +8% for resume estimation

    def speak_answer(self, text: str) -> None:
        """Speak the answer as one gapless stream. If the owner interrupts, ask a
        confirm line, wait for a command, then resume the remaining text from an
        estimated sentence boundary."""
        remaining = text.strip()
        logging.info("Speaking answer: %d chars", len(remaining))
        self.emit("status", "말하는 중")
        while remaining:
            self.interrupt_evt.clear()
            self.interrupted.clear()
            self.speaking.set()
            self._speaking_text = re.sub(r"[^0-9a-zA-Z가-힣]", "", remaining)
            t0 = time.monotonic()
            try:
                self.speaker.speak(remaining)
            finally:
                self.speaking.clear()
                self.vad.reset()
            if not self.interrupt_evt.is_set():
                break  # finished normally
            elapsed = time.monotonic() - t0
            # Resume conservatively: replay from the current sentence boundary
            # rather than estimating inside the sentence. This may repeat a few
            # words but prevents the "content passed by while interrupted"
            # problem the user observed.
            spoken = int(elapsed * self._CHARS_PER_SEC)
            cut = self._snap_to_sentence(remaining, spoken)
            remaining = remaining[cut:].strip()
            logging.info("Owner interrupt after ~%ds; %d chars remain", elapsed, len(remaining))
            resumed = self._interrupt_dialog()
            if not resumed:
                return  # a new command took over
            if remaining:
                self.emit("status", "이어서 말하는 중")
        self.ignore_audio_until = time.monotonic() + 0.4
        self.emit("status", "“헤이 스카웃”을 기다리는 중")

    def _interrupt_dialog(self) -> bool:
        """After an owner interrupt: confirm, then wait briefly for a command.

        Returns True to resume the remaining answer, False if a new command was
        given (and dispatched)."""
        self.emit("status", "네, 듣고 있어요")
        confirm = "저를 부르셨어요? 아니라면 1초 후 다시 이어서 말하겠습니다."
        # Speak the confirm line with speaking set so its own echo is filtered.
        self.interrupt_evt.clear()
        self.speaking.set()
        self._speaking_text = re.sub(r"[^0-9a-zA-Z가-힣]", "", confirm)
        try:
            self.speaker.speak(confirm)
        finally:
            self.speaking.clear()
            self.vad.reset()
        # Silent window: now the user can speak a command clearly.
        self.interrupt_command = None
        self.awaiting_interrupt_command = True
        self.emit("status", "명령을 말씀하세요")
        deadline = time.monotonic() + 3.0
        try:
            while time.monotonic() < deadline:
                cmd = self.interrupt_command
                if cmd:
                    self.interrupt_command = None
                    self.awaiting_interrupt_command = False
                    logging.info("Interrupt command captured: %r", cmd[:40])
                    self.handle_command(cmd)
                    return False
                time.sleep(0.1)
        finally:
            self.awaiting_interrupt_command = False
        logging.info("No interrupt command; resuming answer")
        return True

    def execute(self, command: str, seq: int = 0) -> None:
        logging.info("Executing voice command (%d chars)", len(command))
        self.emit("command", command)
        self.emit("status", "처리 중")
        fast_answer = self.fast_response(command)
        if fast_answer:
            play_chime()
            self.emit("answer", fast_answer)
            self.say(fast_answer)
            return

        play_chime()
        detailed = self.is_summary_request(command)
        try:
            if self.is_m365_command(command):
                logging.info("Command backend=workiq detailed=%s", detailed)
                self.emit("status", "Microsoft 365에서 확인 중")
                answer = self.ask_m365(command, detailed=detailed)
                logging.info("WorkIQ response ready chars=%d", len(answer))
                self.log_activity(command, answer)
            else:
                logging.info("Command backend=copilot detailed=%s", detailed)
                answer = self.copilot.ask(command, detailed=detailed)
                logging.info("Copilot response ready chars=%d", len(answer))
            # A newer command superseded this one while it was generating —
            # drop this stale answer instead of speaking over the new one.
            if seq and seq != self.command_seq:
                logging.info("Dropping superseded answer seq=%d", seq)
                return
            self.emit("answer", answer)
            self.speak_answer(answer)
        except Exception:
            logging.exception("Voice command failed")
            if not (seq and seq != self.command_seq):
                self.say("명령을 처리하지 못했습니다. 로그를 확인해 주세요.")

    _PROGRESS_KO = {
        "thinking": "생각하는 중",
        "pondering": "질문을 살펴보는 중",
        "consulting": "Microsoft 365에 확인하는 중",
        "searching": "데이터를 검색하는 중",
        "reading": "내용을 읽는 중",
        "connecting": "정보를 연결하는 중",
        "gathering": "핵심을 정리하는 중",
        "analyzing": "분석하는 중",
        "summar": "요약하는 중",
    }

    def _progress_ko(self, message: str) -> str:
        low = message.lower()
        for key, ko in self._PROGRESS_KO.items():
            if key in low:
                return ko
        return "Microsoft 365에서 확인 중"

    def ask_m365(self, command: str, detailed: bool) -> str:
        """M365 answer with live progress surfaced to the UI while waiting.

        WorkIQ can take 15-40s and does not stream answer text, so we forward
        its progress notes to the ring window/status to keep the wait alive,
        then clean the final answer for speech.
        """
        from voice_runtime import concise_voice_response, detailed_voice_response

        if detailed:
            question = (
                f"{command}\n\n음성 비서가 소리 내어 읽어 줄 요약 브리핑입니다. "
                "핵심을 빠짐없이 정리해 한국어로 약 1분 분량(공백 포함 400~600자)의 "
                "자연스러운 문장으로 설명하세요. 시간·사람·해야 할 일 등 중요한 "
                "세부 정보를 포함하고 마지막에 한 문장으로 정리하세요. URL, 출처 번호, "
                "마크다운, 표, 글머리 기호는 쓰지 마세요."
            )
        else:
            question = (
                f"{command}\n\n음성 비서가 읽을 답변입니다. 핵심만 한국어 최대 3문장, "
                "350자 이내로 답하고 URL·출처·마크다운·표는 쓰지 마세요."
            )
        try:
            raw = self.workiq_mcp.ask(
                question,
                on_progress=lambda m: self.emit("status", self._progress_ko(m)),
            )
        except Exception:
            logging.exception("WorkIQ MCP failed; falling back to CLI")
            return self.workiq.ask(command, detailed=detailed)
        return (
            detailed_voice_response(raw) if detailed else concise_voice_response(raw)
        )

    @staticmethod
    def is_summary_request(command: str) -> bool:
        """True when the user wants a fuller briefing rather than a one-liner."""
        return bool(
            re.search(
                r"정리|요약|브리핑|자세히|상세|설명|알려\s*줘|정리해|"
                r"summar|brief|detail|explain|rundown|overview",
                command,
                re.IGNORECASE,
            )
        )

    @staticmethod
    def fast_response(command: str) -> str | None:
        compact = re.sub(r"\s+", "", command)
        now = datetime.now()
        if re.search(r"(지금|현재)?(몇시|시간)", compact):
            period = "오전" if now.hour < 12 else "오후"
            hour = now.hour % 12 or 12
            return f"현재 시각은 {period} {hour}시 {now.minute}분입니다."
        if re.search(r"(오늘|현재)?(날짜|며칠|몇일)", compact):
            weekdays = "월화수목금토일"
            return (
                f"오늘은 {now.year}년 {now.month}월 {now.day}일 "
                f"{weekdays[now.weekday()]}요일입니다."
            )
        return None

    @staticmethod
    def is_m365_command(command: str) -> bool:
        compact = re.sub(r"[^0-9a-zA-Z가-힣]", "", command).lower()
        if re.search(
                r"메일|이메일|받은\s*편지|아웃룩|일정|캘린더|회의|"
                r"팀즈|원드라이브|쉐어포인트|사내\s*문서|내\s*매니저|"
                r"직속\s*상사|동료|회사\s*사람|읽지\s*않은|받은\s*메일|"
                r"보낸\s*메일|수신\s*메일|발신\s*메일",
                command,
                re.IGNORECASE,
            ):
            return True
        if re.search(
            r"받은|보낸|수신|발신|읽지않|인박스|편지함|회신|답장",
            compact,
        ):
            return True
        if re.search(
            r"(최근|오늘|온|확인|요약|읽어|알려).{0,5}(매일|메인)|"
            r"(매일|메인).{0,5}(확인|요약|읽|알려|왔|온)",
            compact,
        ):
            return True

        # Korean STT commonly confuses 메일 with 매일 or 메인.
        targets = ("메일", "이메일", "아웃룩", "캘린더", "팀즈", "원드라이브")
        for target in targets:
            for width in range(max(2, len(target) - 1), len(target) + 2):
                for start in range(max(0, len(compact) - width + 1)):
                    candidate = compact[start : start + width]
                    if SequenceMatcher(None, candidate, target).ratio() >= 0.67:
                        return True
        return False

    def handle_segment(self, samples: np.ndarray) -> None:
        text = self.models.transcribe(samples)
        if not text:
            return
        verified, score = self.verified(samples)
        logging.info(
            "Segment speakerScore=%.3f verified=%s textChars=%d text=%r",
            score,
            verified,
            len(text),
            text[:80],
        )
        self.emit("transcript", text)
        now = time.monotonic()

        # Capturing a command during the post-interrupt silent window.
        if self.awaiting_interrupt_command:
            raw_len = len(re.sub(r"\s", "", text))
            if verified and raw_len >= 2:
                self.interrupt_command = text
            elif not verified:
                logging.warning("Rejected unverified interrupt command score=%.3f", score)
            return

        # While Scout speaks, only an explicit wake word may interrupt it.
        # Similarity-based echo filtering produced false interruptions whenever
        # STT paraphrased Scout's own TTS, then fed the confirmation prompt back
        # into Scout as a new command.
        if self.speaking.is_set():
            wake_detected, _ = split_wake_command(text)
            logging.info("Interrupt wake detected=%s text=%r", wake_detected, text[:40])
            if wake_detected:
                logging.info("Explicit wake interrupt detected")
                self.interrupt_evt.set()
                try:
                    self.speaker.stop()
                except Exception:
                    logging.exception("Failed to stop speech on interrupt")
            return

        if self.pending_command and now <= self.pending_until:
            if not verified:
                logging.warning("Rejected unverified confirmation score=%.3f", score)
                return
            compact = "".join(text.split())
            if "확인하고실행해" in compact:
                command = self.pending_command
                self.pending_command = None
                self.dispatch_command(command, confirmed=True)
            elif "취소해" in compact or "취소" == compact:
                self.pending_command = None
                self.say("명령을 취소했습니다.")
            return
        self.pending_command = None

        if now <= self.awaiting_command_until:
            wake_detected, command = split_wake_command(text)
            if wake_detected and not command:
                self.awaiting_command_until = now + 10.0
                self.emit("status", "명령을 말씀하세요")
                return
            if not verified:
                self.awaiting_command_until = 0.0
                logging.warning("Rejected unverified command score=%.3f", score)
                self.say("등록된 음성을 확인하지 못했습니다.")
                return
            self.awaiting_command_until = 0.0
            self.dispatch_command(command if wake_detected else text)
            return

        wake_detected, command = split_wake_command(text)
        logging.info(
            "Wake detection detected=%s commandChars=%d",
            wake_detected,
            len(command),
        )
        if not wake_detected:
            return

        self.emit("wake", True)
        if command:
            if not verified:
                logging.warning("Rejected unverified wake command score=%.3f", score)
                self.say("등록된 음성을 확인하지 못했습니다.")
                return
            self.dispatch_command(command)
        else:
            # A one-second wake phrase is often too short for a stable speaker
            # embedding. The following full command must still verify.
            self.awaiting_command_until = now + 10.0
            self.emit("status", "명령을 말씀하세요")

    def dispatch_command(self, command: str, confirmed: bool = False) -> None:
        """Run command handling on a worker thread so the mic loop keeps
        listening (enables barge-in during the answer/speech)."""
        prev = self.worker
        if prev is not None and prev.is_alive():
            # A new command arrived mid-answer: interrupt and supersede. The
            # bumped sequence makes the old worker drop its (possibly still
            # in-flight) answer instead of speaking over the new one.
            self.stop_speaking()
            prev.join(timeout=1.0)
        self.command_seq += 1
        seq = self.command_seq
        self.worker = threading.Thread(
            target=self.handle_command, args=(command, confirmed, seq), daemon=True
        )
        self.worker.start()

    def log_activity(self, command: str, answer: str) -> None:
        """Write non-Copilot backend voice turns (notably WorkIQ) to Activity.

        Copilot ACP turns write their own session records. WorkIQ answers do
        not, so create a lightweight voice session row directly in Scout's
        session store so the user can see the spoken command and answer in the
        Activity list.
        """
        try:
            db = APP_DIR.parent.parent / ".scout" / "copilot" / "session-store.db"
            if not db.exists():
                db = Path.home() / ".scout" / "copilot" / "session-store.db"
            if not db.exists():
                return
            sid = str(uuid.uuid4())
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            summary = f"음성: {command.strip()[:120]}"
            with sqlite3.connect(str(db), timeout=2) as conn:
                conn.execute(
                    "INSERT INTO sessions (id, cwd, repository, host_type, branch, summary, created_at, updated_at) "
                    "VALUES (?, ?, NULL, NULL, NULL, ?, ?, ?)",
                    (sid, str(COPILOT_WORKING_DIR), summary, now, now),
                )
                conn.execute(
                    "INSERT INTO turns (session_id, turn_index, user_message, assistant_response, timestamp) "
                    "VALUES (?, 0, ?, ?, ?)",
                    (sid, command, answer, now),
                )
                conn.execute(
                    "INSERT INTO search_index (content, session_id, source_type, source_id) "
                    "VALUES (?, ?, 'turn', ?)",
                    (f"{command}\n{answer}", sid, sid),
                )
        except Exception:
            logging.exception("Failed to write voice Activity entry")

    def handle_command(self, command: str, confirmed: bool = False, seq: int = 0) -> None:
        command = command.strip()
        if not command:
            self.say("명령을 듣지 못했습니다.")
            return
        if not confirmed and RISKY_COMMAND.search(command):
            self.pending_command = command
            self.pending_until = time.monotonic() + 25.0
            self.emit("status", "실행 확인 대기 중")
            self.say(
                f"확인이 필요한 명령입니다. {command}. 실행하려면 확인하고 실행해라고 말해 주세요."
            )
            return
        self.execute(command, seq)

    def run(self) -> None:
        read_size = 1_600
        pending = np.empty(0, dtype=np.float32)
        window = self.vad.config.silero_vad.window_size
        logging.info(
            "Voice agent ready threshold=%.3f inputDevice=%s",
            self.threshold,
            self.input_device_label,
        )
        self.emit("status", "“헤이 스카웃”을 기다리는 중")
        with sd.InputStream(
            channels=1,
            dtype="float32",
            samplerate=SAMPLE_RATE,
            blocksize=read_size,
            device=self.input_device,
            extra_settings=self.input_extra_settings,
        ) as microphone:
            while not self.stop_event.is_set():
                block, overflowed = microphone.read(read_size)
                if overflowed:
                    logging.warning("Microphone overflow")
                    continue
                if time.monotonic() < self.ignore_audio_until:
                    self.vad.reset()
                    pending = np.empty(0, dtype=np.float32)
                    continue
                mono = np.asarray(block[:, 0], dtype=np.float32).copy()
                rms = float(np.sqrt(np.mean(np.square(mono)) + 1e-12))
                self.emit("level", min(1.0, rms * 28.0))
                if self.pause_event.is_set():
                    self.vad.reset()
                    pending = np.empty(0, dtype=np.float32)
                    continue
                pending = np.concatenate((pending, mono))
                while pending.size >= window:
                    self.vad.accept_waveform(pending[:window])
                    pending = pending[window:]
                while not self.vad.empty():
                    segment = np.asarray(
                        self.vad.front.samples, dtype=np.float32
                    ).copy()
                    self.vad.pop()
                    if segment.size >= int(0.65 * SAMPLE_RATE):
                        self.handle_segment(segment)

    def stop(self) -> None:
        self.stop_event.set()
        try:
            self.speaker.close()
        except Exception:
            pass
        try:
            self.copilot.close()
        except Exception:
            pass
        try:
            self.workiq_mcp.close()
        except Exception:
            pass

    def set_paused(self, paused: bool) -> None:
        if paused:
            self.pause_event.set()
        else:
            self.pause_event.clear()


def main() -> int:
    configure_logging()
    singleton = acquire_singleton()
    if singleton is None:
        logging.info("Another voice agent instance is already running")
        return 0
    try:
        VoiceAgent().run()
    except KeyboardInterrupt:
        return 0
    except Exception:
        logging.exception("Voice agent stopped unexpectedly")
        return 1
    finally:
        singleton.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
