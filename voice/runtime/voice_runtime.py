from __future__ import annotations

import base64
import ctypes
import json
import logging
import math
import os
import queue
import re
import subprocess
import sys
import tempfile
import winsound
import threading
import time
import uuid
from ctypes import wintypes
from datetime import datetime, timezone
from difflib import SequenceMatcher
from pathlib import Path
from typing import Iterable

import numpy as np
import sherpa_onnx
import sounddevice as sd


SAMPLE_RATE = 16_000
WAKE_SENSITIVITY = 65
NOISE_SENSITIVITY = 35
APP_DIR = Path(__file__).resolve().parent
MODELS_DIR = APP_DIR / "models"
PROFILE_PATH = APP_DIR / "voice-profile.dat"
CHIME_PATH = APP_DIR / "scout-listening.wav"
PIPER_EXE = APP_DIR / "tts" / "piper" / "piper.exe"
PIPER_MODEL = APP_DIR / "tts" / "voice" / "ko_KR-kss-medium.onnx"
SHERPA_TTS_DIR = APP_DIR / "tts" / "sherpa-korean"
COPILOT_WORKING_DIR = Path(os.environ.get("SCOUT_VOICE_WORKING_DIR", r"C:\temp"))
WORKIQ_PATH = Path.home() / ".scout" / "bin" / "workiq.cmd"

ENROLLMENT_PHRASES = (
    "헤이 스카웃, 오늘의 일정을 알려줘.",
    "헤이 스카웃, 중요한 이메일을 확인해 줘.",
    "헤이 스카웃, 서울의 날씨를 알려줘.",
    "헤이 스카웃, 내일 아침 알림을 설정해 줘.",
    "헤이 스카웃, 지금부터 내 목소리에만 응답해.",
)

RISKY_COMMAND = re.compile(
    r"삭제|지워|송금|이체|결제|구매|주문|보내|전송|공유|취소|예약|"
    r"승인|거절|설치|제거|종료|재부팅|권한"
)


class DataBlob(ctypes.Structure):
    _fields_ = [
        ("cbData", wintypes.DWORD),
        ("pbData", ctypes.POINTER(ctypes.c_byte)),
    ]


def _make_blob(data: bytes) -> tuple[DataBlob, ctypes.Array]:
    buffer = ctypes.create_string_buffer(data)
    blob = DataBlob(len(data), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_byte)))
    return blob, buffer


def dpapi_protect(data: bytes) -> bytes:
    in_blob, in_buffer = _make_blob(data)
    out_blob = DataBlob()
    description = "Scout Voice Assistant speaker profile"
    if not ctypes.windll.crypt32.CryptProtectData(
        ctypes.byref(in_blob),
        description,
        None,
        None,
        None,
        0,
        ctypes.byref(out_blob),
    ):
        raise ctypes.WinError()
    try:
        return ctypes.string_at(out_blob.pbData, out_blob.cbData)
    finally:
        ctypes.windll.kernel32.LocalFree(out_blob.pbData)
        del in_buffer


def dpapi_unprotect(data: bytes) -> bytes:
    in_blob, in_buffer = _make_blob(data)
    out_blob = DataBlob()
    if not ctypes.windll.crypt32.CryptUnprotectData(
        ctypes.byref(in_blob),
        None,
        None,
        None,
        None,
        0,
        ctypes.byref(out_blob),
    ):
        raise ctypes.WinError()
    try:
        return ctypes.string_at(out_blob.pbData, out_blob.cbData)
    finally:
        ctypes.windll.kernel32.LocalFree(out_blob.pbData)
        del in_buffer


def l2_normalize(value: np.ndarray) -> np.ndarray:
    vector = np.asarray(value, dtype=np.float32)
    norm = float(np.linalg.norm(vector))
    if norm < 1e-12:
        raise ValueError("The speaker embedding is empty.")
    return vector / norm


def cosine_similarity(left: np.ndarray, right: np.ndarray) -> float:
    return float(np.dot(l2_normalize(left), l2_normalize(right)))


def save_profile(embeddings: list[np.ndarray]) -> dict:
    normalized = [l2_normalize(item) for item in embeddings]
    centroid = l2_normalize(np.mean(np.stack(normalized), axis=0))
    scores = [cosine_similarity(item, centroid) for item in normalized]
    # Enrollment audio is cleaner and longer than a real wake phrase. Keep a
    # conservative floor while allowing for the expected live-microphone drop.
    threshold = min(0.60, max(0.55, min(scores) - 0.25))
    profile = {
        "version": 1,
        "createdAt": datetime.now(timezone.utc).isoformat(),
        "embedding": centroid.tolist(),
        "threshold": threshold,
        "enrollmentScores": scores,
        "phraseCount": len(normalized),
    }
    encrypted = dpapi_protect(json.dumps(profile, ensure_ascii=False).encode("utf-8"))
    PROFILE_PATH.write_bytes(encrypted)
    return profile


def load_profile() -> dict:
    if not PROFILE_PATH.exists():
        raise FileNotFoundError("Voice profile is not enrolled.")
    return json.loads(dpapi_unprotect(PROFILE_PATH.read_bytes()).decode("utf-8"))


def normalize_text(text: str) -> str:
    text = re.sub(r"<\|.*?\|>", "", text)
    return re.sub(
        r"[^0-9a-zA-Z가-힣ぁ-んァ-ヶ\u4e00-\u9fff]+", "", text
    ).lower()


def set_wake_sensitivity(value: int) -> None:
    global WAKE_SENSITIVITY
    WAKE_SENSITIVITY = max(0, min(100, int(value)))


def set_noise_sensitivity(value: int) -> None:
    global NOISE_SENSITIVITY
    NOISE_SENSITIVITY = max(0, min(100, int(value)))


def split_wake_command(text: str) -> tuple[bool, str]:
    patterns = (
        re.compile(
            r"(?:헤이\s*)?스카(?:웃|우트|우)(?:아|야)?",
            re.IGNORECASE,
        ),
        re.compile(r"hey\s+scout", re.IGNORECASE),
    )
    for pattern in patterns:
        match = pattern.search(text)
        if match:
            remainder = text[match.end() :].lstrip(" ,.!?，。")
            return True, remainder
    compact = normalize_text(text)
    variants = (
        "헤이스카웃",
        "헤이스카우트",
        "헤이스카우",
        "에이스카웃",
        "에이스카우트",
        "해이스카웃",
        "스카웃",
        "스카우트",
        "스카우",
        "heyscout",
        "へイスカウト",
        "へイスカ",
        "ヘイスカウト",
        "ヘイスカ",
    )
    for variant in variants:
        index = compact.find(variant)
        if index >= 0:
            remainder = compact[index + len(variant) :]
            return True, remainder
    if len(compact) <= 10:
        wake_score = max(
            SequenceMatcher(None, compact, variant).ratio()
            for variant in variants
        )
        threshold = 0.80 - (WAKE_SENSITIVITY * 0.004)
        if wake_score >= threshold:
            return True, ""
    return False, ""


class VoiceModels:
    def __init__(self, language: str = "ko") -> None:
        sense_dir = next(
            MODELS_DIR.glob("sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-*"),
            None,
        )
        if sense_dir is None:
            raise FileNotFoundError("SenseVoice model is not installed.")
        self.recognizer = sherpa_onnx.OfflineRecognizer.from_sense_voice(
            model=str(sense_dir / "model.int8.onnx"),
            tokens=str(sense_dir / "tokens.txt"),
            num_threads=2,
            sample_rate=SAMPLE_RATE,
            feature_dim=80,
            language=language,
            use_itn=True,
            provider="cpu",
            debug=False,
        )

        speaker_model = MODELS_DIR / (
            "3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx"
        )
        speaker_config = sherpa_onnx.SpeakerEmbeddingExtractorConfig(
            model=str(speaker_model),
            num_threads=2,
            provider="cpu",
            debug=False,
        )
        if not speaker_config.validate():
            raise RuntimeError("Speaker model configuration is invalid.")
        self.speaker_extractor = sherpa_onnx.SpeakerEmbeddingExtractor(
            speaker_config
        )

    def create_vad(self) -> sherpa_onnx.VoiceActivityDetector:
        config = sherpa_onnx.VadModelConfig()
        config.silero_vad.model = str(MODELS_DIR / "silero_vad.int8.onnx")
        config.silero_vad.threshold = 0.80 - (NOISE_SENSITIVITY * 0.006)
        config.silero_vad.min_silence_duration = 0.55
        config.silero_vad.min_speech_duration = 0.25
        config.silero_vad.max_speech_duration = 12.0
        config.sample_rate = SAMPLE_RATE
        return sherpa_onnx.VoiceActivityDetector(
            config, buffer_size_in_seconds=120
        )

    def transcribe(self, samples: np.ndarray) -> str:
        waveform = np.ascontiguousarray(samples, dtype=np.float32)
        stream = self.recognizer.create_stream()
        stream.accept_waveform(SAMPLE_RATE, waveform)
        self.recognizer.decode_stream(stream)
        return re.sub(r"<\|.*?\|>", "", stream.result.text).strip()

    def embedding(self, samples: np.ndarray) -> np.ndarray:
        waveform = np.ascontiguousarray(samples, dtype=np.float32)
        stream = self.speaker_extractor.create_stream()
        stream.accept_waveform(sample_rate=SAMPLE_RATE, waveform=waveform)
        stream.input_finished()
        if not self.speaker_extractor.is_ready(stream):
            raise ValueError("Please speak for at least one second.")
        return l2_normalize(
            np.asarray(self.speaker_extractor.compute(stream), dtype=np.float32)
        )


class NeuralSpeaker:
    def __init__(self) -> None:
        model_root = next(SHERPA_TTS_DIR.glob("vits-*"), None)
        if model_root is None:
            raise FileNotFoundError("Streaming Korean TTS model is not installed.")
        config = sherpa_onnx.OfflineTtsConfig()
        config.model.vits.model = str(next(model_root.glob("*.onnx")))
        config.model.vits.tokens = str(model_root / "tokens.txt")
        config.model.vits.data_dir = str(model_root / "espeak-ng-data")
        config.model.vits.length_scale = 0.92
        config.model.num_threads = 4
        config.max_num_sentences = 8
        config.silence_scale = 0.15
        if not config.validate():
            raise RuntimeError("Streaming Korean TTS configuration is invalid.")
        self.engine = sherpa_onnx.OfflineTts(config)
        self.lock = threading.Lock()

    def speak(self, text: str) -> None:
        cleaned = speech_text(text)
        chunks: queue.Queue[np.ndarray | None] = queue.Queue(maxsize=12)

        def callback(samples: np.ndarray, _progress: float) -> int:
            chunks.put(np.asarray(samples, dtype=np.float32).copy())
            return 0

        def play() -> None:
            with sd.OutputStream(
                channels=1,
                dtype="float32",
                samplerate=self.engine.sample_rate,
            ) as output:
                while True:
                    samples = chunks.get()
                    if samples is None:
                        return
                    output.write(samples.reshape(-1, 1))

        with self.lock:
            player = threading.Thread(target=play, daemon=True)
            player.start()
            try:
                self.engine.generate(cleaned, speed=1.0, callback=callback)
            finally:
                chunks.put(None)
                player.join()


class OnlineSpeaker:
    """Microsoft Edge online neural TTS (edge-tts) with streaming playback.

    Uses the same free neural voices as Edge "Read Aloud" — no API key. Audio
    streams as MP3 chunks into a persistent ffplay pipe, so the first sound is
    audible in ~0.3-0.6s and the voice is far more natural than local Piper.
    Falls back to the offline speaker when the network or service is
    unavailable.
    """

    def __init__(self, voice: str = "ko-KR-SunHiNeural", rate: str = "+8%",
                 english_voice: str = "en-US-AriaNeural",
                 volume: int = 45,
                 fallback: "StreamingSpeaker | None" = None) -> None:
        import edge_tts  # noqa: F401 - fail fast if missing

        self.voice = voice
        self.english_voice = english_voice
        self.rate = rate
        self.volume = volume  # ffplay 0-100; ducked so the user can barge in
        self.fallback = fallback
        self.lock = threading.Lock()
        self._player: subprocess.Popen | None = None
        self._stop = threading.Event()

    def stop(self) -> None:
        """Interrupt any in-progress speech immediately (barge-in)."""
        self._stop.set()
        if self.fallback is not None:
            self.fallback.stop()
        player = self._player
        if player is not None and player.poll() is None:
            try:
                player.kill()
            except Exception:  # noqa: BLE001
                pass

    def _voice_for(self, text: str) -> str:
        # If the text has no Hangul but does have Latin letters, speak English.
        has_hangul = any("\uac00" <= ch <= "\ud7a3" for ch in text)
        has_latin = any(("a" <= ch.lower() <= "z") for ch in text)
        if not has_hangul and has_latin:
            return self.english_voice
        return self.voice

    def speak(self, text: str) -> None:
        cleaned = speech_text(text)
        if not cleaned:
            return
        self._stop.clear()
        with self.lock:
            try:
                self._stream_and_play(cleaned, self._voice_for(cleaned))
                return
            except Exception:  # noqa: BLE001
                logging.warning("Online TTS failed; using offline fallback", exc_info=True)
        # Fallback outside the lock's try so we don't double-hold on failure.
        if self._stop.is_set():
            return
        if self.fallback is not None:
            self.fallback.speak(text)
        else:
            self._speak_with_windows(cleaned)

    def _speak_with_windows(self, text: str) -> None:
        player = start_windows_speech(text)
        self._player = player
        try:
            player.wait()
        finally:
            self._player = None

    def _stream_and_play(self, text: str, voice: str) -> None:
        """Pipe edge-tts MP3 chunks straight into ffplay as they arrive.

        Feeding audio to ffplay incrementally (instead of buffering the whole
        clip first) makes the first word audible in ~0.3-0.6s.
        """
        import asyncio
        import edge_tts

        flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        player = subprocess.Popen(
            ["ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet",
             "-volume", str(self.volume), "-i", "pipe:0"],
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=flags,
        )
        self._player = player

        async def pump() -> int:
            got = 0
            communicate = edge_tts.Communicate(text, voice, rate=self.rate)
            stream = communicate.stream()
            try:
                async for chunk in stream:
                    if self._stop.is_set():
                        break
                    if chunk["type"] == "audio":
                        got += len(chunk["data"])
                        try:
                            player.stdin.write(chunk["data"])
                            player.stdin.flush()
                        except (BrokenPipeError, OSError):
                            break
            finally:
                await stream.aclose()
            return got

        try:
            got = asyncio.run(pump())
            if got == 0 and not self._stop.is_set():
                raise RuntimeError("edge-tts returned no audio.")
        finally:
            try:
                if player.stdin:
                    player.stdin.close()
            except OSError:
                pass
            try:
                player.wait(timeout=60)
            except Exception:  # noqa: BLE001
                pass
            self._player = None

    def start(self) -> None:
        if self.fallback is not None:
            self.fallback.start()

    def synth(self, text: str) -> bytes:
        """Synthesize an utterance to MP3 bytes (no playback) for prefetching."""
        import asyncio
        import edge_tts

        cleaned = speech_text(text)
        if not cleaned:
            return b""
        voice = self._voice_for(cleaned)

        async def collect() -> bytes:
            data = bytearray()
            communicate = edge_tts.Communicate(cleaned, voice, rate=self.rate)
            stream = communicate.stream()
            try:
                async for chunk in stream:
                    if chunk["type"] == "audio":
                        data.extend(chunk["data"])
            finally:
                await stream.aclose()
            return bytes(data)

        return asyncio.run(collect())

    def play_bytes(self, mp3: bytes) -> None:
        """Play pre-synthesized MP3 bytes; interruptible via stop()."""
        if not mp3:
            return
        self._stop.clear()
        flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        player = subprocess.Popen(
            ["ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet",
             "-volume", str(self.volume), "-i", "pipe:0"],
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=flags,
        )
        self._player = player
        try:
            player.stdin.write(mp3)
            player.stdin.close()
        except (BrokenPipeError, OSError):
            pass
        while player.poll() is None:
            if self._stop.is_set():
                try:
                    player.kill()
                except Exception:  # noqa: BLE001
                    pass
                break
            time.sleep(0.05)
        self._player = None

    def close(self) -> None:
        self.stop()
        player = self._player
        if player is not None:
            try:
                player.wait(timeout=2)
            except subprocess.TimeoutExpired:
                player.kill()
                player.wait(timeout=2)
            finally:
                self._player = None
        if self.fallback is not None:
            self.fallback.close()


class NaturalSpeaker:
    def __init__(self) -> None:
        if not PIPER_EXE.exists() or not PIPER_MODEL.exists():
            raise FileNotFoundError("Natural Korean TTS model is not installed.")
        self.lock = threading.Lock()

    def speak(self, text: str) -> None:
        with self.lock:
            speak_with_piper(speech_text(text))


class StreamingSpeaker:
    """Persistent Piper ``--output-raw`` process with buffered playback.

    Keeping one Piper process alive and streaming raw PCM into a sounddevice
    output stream drops warm time-to-first-audio to ~0.5s (vs ~5-8s for the
    render-WAV-then-ffplay path). A short pre-buffer prevents the choppy
    underruns that raw streaming to ffplay produced.
    """

    SAMPLE_RATE = 22_050
    _PREBUFFER_BYTES = int(SAMPLE_RATE * 2 * 0.18)  # ~180ms of 16-bit mono
    _IDLE_END_SECONDS = 0.6  # silence gap that marks end of an utterance

    def __init__(self, length_scale: float = 1.0) -> None:
        if not PIPER_EXE.exists() or not PIPER_MODEL.exists():
            raise FileNotFoundError("Natural Korean TTS model is not installed.")
        self.length_scale = length_scale
        self.lock = threading.Lock()
        self._proc: subprocess.Popen | None = None
        self._chunks: "queue.Queue[bytes | None]" = queue.Queue()
        self._stop = threading.Event()

    def stop(self) -> None:
        """Signal the playback loop to abort the current utterance."""
        self._stop.set()

    def start(self) -> None:
        flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        self._proc = subprocess.Popen(
            [
                str(PIPER_EXE),
                "--model",
                str(PIPER_MODEL),
                "--output-raw",
                "--length_scale",
                str(self.length_scale),
                "--sentence_silence",
                "0.15",
                "--quiet",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            creationflags=flags,
        )
        threading.Thread(target=self._read_loop, daemon=True).start()
        # Warm the ONNX graph so the first real utterance is fast.
        try:
            self._synthesize(" ", play=False)
        except Exception:  # noqa: BLE001
            pass

    def _read_loop(self) -> None:
        proc = self._proc
        if proc is None or proc.stdout is None:
            return
        while True:
            data = proc.stdout.read(4096)
            if not data:
                self._chunks.put(None)
                return
            self._chunks.put(data)

    def _alive(self) -> bool:
        return self._proc is not None and self._proc.poll() is None

    def _synthesize(self, text: str, play: bool) -> None:
        assert self._proc is not None and self._proc.stdin is not None
        # Drain any stale chunks before a new utterance.
        while not self._chunks.empty():
            try:
                self._chunks.get_nowait()
            except queue.Empty:
                break
        self._proc.stdin.write((text + "\n").encode("utf-8"))
        self._proc.stdin.flush()

        stream = None
        if play:
            stream = sd.RawOutputStream(
                samplerate=self.SAMPLE_RATE, channels=1, dtype="int16"
            )
            stream.start()
        buffer = b""
        started = False
        got_audio = False
        first_timeout = 8.0  # first PCM chunk can lag under load
        try:
            while True:
                if self._stop.is_set():
                    break
                try:
                    timeout = self._IDLE_END_SECONDS if got_audio else first_timeout
                    data = self._chunks.get(timeout=timeout)
                except queue.Empty:
                    break  # gap -> utterance finished (or never started)
                if data is None:
                    break
                got_audio = True
                if not play:
                    continue
                buffer += data
                if not started and len(buffer) >= self._PREBUFFER_BYTES:
                    started = True
                    stream.write(buffer)
                    buffer = b""
                elif started:
                    stream.write(buffer)
                    buffer = b""
            if play and buffer and not self._stop.is_set():
                stream.write(buffer)
        finally:
            if stream is not None:
                stream.stop()
                stream.close()
        if play and not got_audio and not self._stop.is_set():
            raise RuntimeError("Piper produced no audio.")

    def speak(self, text: str) -> None:
        cleaned = speech_text(text)
        if not cleaned:
            return
        self._stop.clear()
        with self.lock:
            if not self._alive():
                logging.info("Piper stream not alive; restarting")
                self.start()
            try:
                self._synthesize(cleaned, play=True)
            except Exception:  # noqa: BLE001
                logging.exception("Streaming TTS failed; falling back")
                if not self._stop.is_set():
                    speak_with_windows(cleaned)

    def close(self) -> None:
        with self.lock:
            if self._proc is not None:
                try:
                    if self._proc.stdin:
                        self._proc.stdin.close()
                    self._proc.wait(timeout=3)
                except Exception:  # noqa: BLE001
                    self._proc.kill()
                self._proc = None



def record_utterance(
    max_seconds: float = 10.0,
    min_seconds: float = 1.4,
    silence_seconds: float = 0.9,
) -> np.ndarray:
    block_size = 1_600
    pre_roll: list[np.ndarray] = []
    captured: list[np.ndarray] = []
    speech_started = False
    silent_blocks = 0
    max_blocks = math.ceil(max_seconds * SAMPLE_RATE / block_size)
    silence_blocks = math.ceil(silence_seconds * SAMPLE_RATE / block_size)

    with sd.InputStream(
        channels=1,
        dtype="float32",
        samplerate=SAMPLE_RATE,
        blocksize=block_size,
    ) as microphone:
        for _ in range(max_blocks):
            block, overflowed = microphone.read(block_size)
            if overflowed:
                continue
            mono = np.asarray(block[:, 0], dtype=np.float32).copy()
            rms = float(np.sqrt(np.mean(np.square(mono)) + 1e-12))
            if not speech_started:
                pre_roll.append(mono)
                pre_roll = pre_roll[-3:]
                if rms >= 0.012:
                    speech_started = True
                    captured.extend(pre_roll)
            else:
                captured.append(mono)
                silent_blocks = silent_blocks + 1 if rms < 0.009 else 0
                duration = sum(item.size for item in captured) / SAMPLE_RATE
                if duration >= min_seconds and silent_blocks >= silence_blocks:
                    break

    if not speech_started:
        raise ValueError("No speech was detected.")
    waveform = np.concatenate(captured)
    if waveform.size < int(min_seconds * SAMPLE_RATE):
        raise ValueError("The recording is too short.")
    return waveform


def find_copilot() -> Path:
    local_app_data = Path(os.environ["LOCALAPPDATA"])
    base = (
        local_app_data
        / "Programs"
        / "Microsoft Scout"
        / "resources"
        / "app.asar.unpacked"
        / "node_modules"
    )
    candidates = (
        base / "@github" / "copilot-win32-arm64" / "copilot.exe",
        base / "@github" / "copilot-win32-x64" / "copilot.exe",
    )
    for candidate in candidates:
        if candidate.exists():
            return candidate
    raise FileNotFoundError("Scout-bundled Copilot CLI was not found.")


class CopilotSession:
    def __init__(self) -> None:
        self.executable = find_copilot()
        self.name = f"scout-background-voice-{uuid.uuid4()}"
        self.started = False

    def ask(self, command: str) -> str:
        prompt = "\n".join(
            (
                "사용자의 음성 명령을 처리하세요.",
                "최종 답변은 한국어로, 소리 내어 읽기 좋게 간결하게 작성하세요.",
                "마크다운 표는 사용하지 마세요.",
                "사용자 명령:",
                command,
            )
        )
        args = [
            str(self.executable),
            "-p",
            prompt,
            (
                f"--resume={self.name}"
                if self.started
                else f"--name={self.name}"
            ),
            "--output-format=json",
            "--no-color",
            "--no-ask-user",
            "--no-auto-update",
            "--allow-all-tools",
            "-C",
            str(COPILOT_WORKING_DIR),
        ]
        creation_flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        process = subprocess.Popen(
            args,
            cwd=COPILOT_WORKING_DIR,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            creationflags=creation_flags,
        )
        final_text = ""
        assert process.stdout is not None
        for line in process.stdout:
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get("type") == "assistant.message":
                content = event.get("data", {}).get("content")
                if isinstance(content, str):
                    final_text = content
            elif event.get("type") == "result" and event.get("exitCode") == 0:
                self.started = True
        stderr = process.stderr.read() if process.stderr else ""
        exit_code = process.wait()
        if exit_code != 0:
            raise RuntimeError(stderr.strip() or f"Copilot exited with {exit_code}.")
        if not final_text.strip():
            raise RuntimeError("Copilot returned an empty response.")
        return final_text.strip()


class WorkIQSession:
    def __init__(self) -> None:
        if not WORKIQ_PATH.exists():
            raise FileNotFoundError("Scout WorkIQ bridge was not found.")
        self.conversation_id: str | None = None

    def ask(self, command: str, detailed: bool = False) -> str:
        if detailed:
            voice_question = "\n".join(
                (
                    f"사용자 질문: {command}",
                    "",
                    "음성 비서가 소리 내어 읽어 줄 요약 브리핑입니다.",
                    "핵심을 빠짐없이 정리해 한국어로 약 1분 분량(공백 포함 400~600자)으로 "
                    "자연스러운 문장으로 설명하세요.",
                    "항목이 여러 개면 중요도 순으로 묶어, 시간·사람·해야 할 일 등 "
                    "중요한 세부 정보를 포함하고 마지막에 한 문장으로 정리하세요.",
                    "URL, 출처 번호, 인용 표시, 마크다운, 표, 글머리 기호는 쓰지 마세요.",
                )
            )
        else:
            voice_question = "\n".join(
                (
                    f"사용자 질문: {command}",
                    "",
                    "음성 비서가 소리 내어 읽을 답변입니다.",
                    "질문에 직접 답하고 핵심만 한국어 최대 3문장, 350자 이내로 작성하세요.",
                    "URL, 출처 번호, 인용 표시, 마크다운, 표, 긴 목록은 포함하지 마세요.",
                    "여러 항목이 있으면 가장 중요한 것부터 짧게 요약하세요.",
                )
            )
        args = [
            os.environ.get("COMSPEC", "cmd.exe"),
            "/d",
            "/c",
            str(WORKIQ_PATH),
            "ask",
            "--json",
            "--question",
            voice_question,
        ]
        creation_flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        result = subprocess.run(
            args,
            cwd=COPILOT_WORKING_DIR,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            creationflags=creation_flags,
            timeout=180,
            check=False,
        )
        if result.returncode != 0:
            raise RuntimeError(
                result.stderr.strip() or "Scout WorkIQ query failed."
            )
        try:
            payload = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise RuntimeError("Scout WorkIQ returned invalid JSON.") from error
        if payload.get("isError"):
            raise RuntimeError(str(payload.get("response") or "WorkIQ query failed."))
        conversation_id = payload.get("conversationId")
        if isinstance(conversation_id, str):
            self.conversation_id = conversation_id
        response = payload.get("response")
        if not isinstance(response, str) or not response.strip():
            raise RuntimeError("Scout WorkIQ returned an empty response.")
        if detailed:
            return detailed_voice_response(response)
        return concise_voice_response(response)


def detailed_voice_response(text: str, limit: int = 700) -> str:
    """Clean a WorkIQ answer for speech but keep a fuller ~1 minute summary."""
    cleaned = re.sub(r"\s*\[\d+\]\([^)]*\)", "", text)
    cleaned = re.sub(r"https?://\S+", "", cleaned)
    cleaned = re.sub(r"#{1,6}\s*", "", cleaned)
    cleaned = re.sub(r"[*_>`~|\[\]]", "", cleaned)
    cleaned = re.sub(r"(?m)^\s*[-•·]\s*", " ", cleaned)
    cleaned = re.sub(r"(?m)^\s*\d+[.)]\s*", " ", cleaned)
    cleaned = cleaned.replace("---", " ")
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    if not cleaned:
        return "요청하신 내용을 찾지 못했습니다."
    if len(cleaned) <= limit:
        return cleaned
    trimmed = cleaned[:limit]
    boundary = max(trimmed.rfind("다."), trimmed.rfind("요."), trimmed.rfind("."))
    if boundary >= limit // 2:
        return trimmed[: boundary + 1]
    return trimmed


def concise_voice_response(text: str, max_sentences: int = 2, limit: int = 170) -> str:
    conclusion = re.search(
        r"(?:한\s*줄\s*결론|결론|핵심\s*요약)\s*:?\s*(.{1,400}?)(?=\n\s*(?:---|##)|\Z)",
        text,
        re.IGNORECASE | re.DOTALL,
    )
    if conclusion:
        text = conclusion.group(1)

    cleaned = re.sub(r"\s*\[\d+\]\([^)]*\)", "", text)
    cleaned = re.sub(r"https?://\S+", "", cleaned)
    cleaned = re.sub(r"#{1,6}\s*", "", cleaned)
    cleaned = re.sub(r"[*_>`~|\[\]]", "", cleaned)
    # Drop bullet/list markers and section separators that read as noise.
    cleaned = re.sub(r"(?m)^\s*[-•·]\s*", " ", cleaned)
    cleaned = re.sub(r"(?m)^\s*\d+[.)]\s*", " ", cleaned)
    cleaned = cleaned.replace("---", " ")
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    if not cleaned:
        return "요청하신 내용을 찾지 못했습니다."

    # Keep only the first couple of complete sentences for a spoken summary.
    sentences = re.findall(r".+?(?:다\.|요\.|[.!?])(?:\s|$)", cleaned)
    if sentences:
        summary = "".join(sentences[:max_sentences]).strip()
    else:
        summary = cleaned

    if len(summary) <= limit:
        return summary
    trimmed = summary[:limit]
    boundary = max(trimmed.rfind("다."), trimmed.rfind("요."), trimmed.rfind("."))
    if boundary >= 60:
        return trimmed[: boundary + 1]
    return trimmed.rsplit(" ", 1)[0] + " 자세한 내용은 Scout에서 확인해 주세요."


def speech_text(text: str) -> str:
    cleaned = re.sub(r"```[\s\S]*?```", " 코드 블록은 화면에서 확인해 주세요. ", text)
    cleaned = re.sub(r"https?://\S+", " 링크 ", cleaned)
    cleaned = re.sub(r"[*_#>`~|\[\]]", "", cleaned)
    replacements = {
        "ECIF": "이씨아이에프",
        "SOW": "에스오더블유",
        "M365": "엠 삼육오",
        "Microsoft 365": "마이크로소프트 삼육오",
        "FastTrack": "패스트트랙",
        "Copilot": "코파일럿",
        "Teams": "팀즈",
        "Outlook": "아웃룩",
    }
    for source, target in replacements.items():
        cleaned = re.sub(re.escape(source), target, cleaned, flags=re.IGNORECASE)
    # Inline dashes used as list separators read awkwardly; use short pauses.
    cleaned = re.sub(r"\s[-–—]\s", ", ", cleaned)
    cleaned = re.sub(r"[^\w가-힣.,?!:;()'\"%+/\s]", " ", cleaned)
    return re.sub(r"\s+", " ", cleaned).strip()


def play_chime() -> None:
    if CHIME_PATH.exists():
        winsound.PlaySound(
            str(CHIME_PATH),
            winsound.SND_FILENAME | winsound.SND_ASYNC | winsound.SND_NODEFAULT,
        )
    else:
        winsound.MessageBeep(winsound.MB_OK)


def speak(text: str) -> None:
    cleaned = speech_text(text)
    if PIPER_EXE.exists() and PIPER_MODEL.exists():
        speak_with_piper(cleaned)
        return
    speak_with_windows(cleaned)


def speak_with_piper(text: str) -> None:
    # Generate the full WAV first, then play it back. Streaming raw PCM caused
    # buffer underruns that made the voice sound robotic and choppy; rendering
    # the complete file keeps the natural, smooth timbre.
    creation_flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    output = Path(tempfile.gettempdir()) / f"scout-voice-{uuid.uuid4()}.wav"
    try:
        synthesis = subprocess.run(
            [
                str(PIPER_EXE),
                "--model",
                str(PIPER_MODEL),
                "--output_file",
                str(output),
                "--length_scale",
                "1.02",
                "--sentence_silence",
                "0.16",
                "--quiet",
            ],
            input=f"{text}\n",
            text=True,
            encoding="utf-8",
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=creation_flags,
            timeout=90,
            check=False,
        )
        if synthesis.returncode != 0 or not output.exists():
            raise RuntimeError("Piper synthesis failed.")
        playback = subprocess.run(
            [
                "ffplay",
                "-nodisp",
                "-autoexit",
                "-loglevel",
                "quiet",
                str(output),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=creation_flags,
            timeout=180,
            check=False,
        )
        if playback.returncode != 0:
            raise RuntimeError("Piper playback failed.")
    except (OSError, RuntimeError, subprocess.TimeoutExpired):
        speak_with_windows(text)
    finally:
        output.unlink(missing_ok=True)


def start_windows_speech(text: str) -> subprocess.Popen:
    payload = base64.b64encode(speech_text(text).encode("utf-8")).decode("ascii")
    script = (
        "Add-Type -AssemblyName System.Speech;"
        "$s=[System.Speech.Synthesis.SpeechSynthesizer]::new();"
        "try{$s.SelectVoice('Microsoft Heami Desktop')}catch{};"
        "$s.Rate=0;"
        "$b=[Convert]::FromBase64String($env:SCOUT_TTS_TEXT_B64);"
        "$t=[Text.Encoding]::UTF8.GetString($b);"
        "$s.Speak($t);"
        "$s.Dispose();"
    )
    creation_flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    environment = os.environ.copy()
    environment["SCOUT_TTS_TEXT_B64"] = payload
    return subprocess.Popen(
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
        env=environment,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        creationflags=creation_flags,
    )


def speak_with_windows(text: str) -> None:
    start_windows_speech(text).wait()
