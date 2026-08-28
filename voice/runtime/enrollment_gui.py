from __future__ import annotations

import queue
import sys
import threading
import tkinter as tk
from difflib import SequenceMatcher
from tkinter import messagebox, ttk

import numpy as np

from voice_runtime import (
    ENROLLMENT_PHRASES,
    VoiceModels,
    cosine_similarity,
    normalize_text,
    record_utterance,
    save_profile,
)


class EnrollmentApp:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.root.title("Scout Voice Setup")
        self.root.geometry("720x500")
        self.root.minsize(620, 440)
        self.root.protocol("WM_DELETE_WINDOW", self.cancel)
        self.models: VoiceModels | None = None
        self.embeddings: list[np.ndarray] = []
        self.index = 0
        self.completed = False
        self.events: queue.Queue[tuple[str, object]] = queue.Queue()

        frame = ttk.Frame(root, padding=28)
        frame.pack(fill="both", expand=True)

        ttk.Label(
            frame,
            text="내 목소리 등록",
            font=("Segoe UI", 22, "bold"),
        ).pack(anchor="w")
        ttk.Label(
            frame,
            text=(
                "서로 다른 5개 문장을 듣고 음성 특징을 등록합니다. "
                "조용한 곳에서 평소 말투로 읽어 주세요."
            ),
            wraplength=650,
        ).pack(anchor="w", pady=(8, 22))

        self.progress = ttk.Progressbar(
            frame, maximum=len(ENROLLMENT_PHRASES), mode="determinate"
        )
        self.progress.pack(fill="x")

        self.step_label = ttk.Label(frame, text="음성 모델을 준비하고 있습니다…")
        self.step_label.pack(anchor="w", pady=(18, 8))

        self.phrase_label = ttk.Label(
            frame,
            text="",
            font=("Malgun Gothic", 17, "bold"),
            wraplength=650,
            justify="left",
        )
        self.phrase_label.pack(anchor="w", pady=(8, 24))

        self.result_label = ttk.Label(
            frame, text="", wraplength=650, foreground="#555555"
        )
        self.result_label.pack(anchor="w", pady=(0, 18))

        self.record_button = ttk.Button(
            frame,
            text="문장 녹음",
            command=self.start_recording,
            state="disabled",
        )
        self.record_button.pack(anchor="w")

        ttk.Label(
            frame,
            text=(
                "음성 원본은 저장하지 않습니다. 5개 녹음에서 계산한 화자 특징만 "
                "Windows 사용자 계정으로 암호화해 저장합니다."
            ),
            wraplength=650,
            foreground="#666666",
        ).pack(anchor="w", side="bottom")

        threading.Thread(target=self.load_models, daemon=True).start()
        self.root.after(100, self.poll_events)

    def load_models(self) -> None:
        try:
            self.events.put(("ready", VoiceModels()))
        except Exception as error:
            self.events.put(("error", str(error)))

    def start_recording(self) -> None:
        self.record_button.configure(state="disabled")
        self.step_label.configure(
            text=f"{self.index + 1}/5 · 신호음 없이 바로 듣고 있습니다"
        )
        self.result_label.configure(text="문장을 읽은 뒤 잠시 조용히 기다려 주세요.")
        threading.Thread(target=self.record_current, daemon=True).start()

    def record_current(self) -> None:
        try:
            assert self.models is not None
            samples = record_utterance()
            transcript = self.models.transcribe(samples)
            embedding = self.models.embedding(samples)
            expected = normalize_text(ENROLLMENT_PHRASES[self.index])
            recognized = normalize_text(transcript)
            similarity = SequenceMatcher(None, expected, recognized).ratio()
            if similarity < 0.30:
                raise ValueError(
                    f"문장을 충분히 인식하지 못했습니다: “{transcript or '인식 결과 없음'}”"
                )
            if self.embeddings:
                centroid = np.mean(np.stack(self.embeddings), axis=0)
                voice_score = cosine_similarity(embedding, centroid)
                if voice_score < 0.35:
                    raise ValueError(
                        "앞서 등록한 목소리와 차이가 큽니다. 같은 사람이 다시 읽어 주세요."
                    )
            self.events.put(("recorded", (transcript, embedding)))
        except Exception as error:
            self.events.put(("record-error", str(error)))

    def poll_events(self) -> None:
        try:
            while True:
                kind, payload = self.events.get_nowait()
                if kind == "ready":
                    self.models = payload  # type: ignore[assignment]
                    self.show_phrase()
                elif kind == "recorded":
                    transcript, embedding = payload  # type: ignore[misc]
                    self.embeddings.append(embedding)
                    self.index += 1
                    self.progress["value"] = self.index
                    self.result_label.configure(text=f"인식 결과: {transcript}")
                    if self.index == len(ENROLLMENT_PHRASES):
                        profile = save_profile(self.embeddings)
                        self.completed = True
                        self.step_label.configure(text="목소리 등록이 완료되었습니다.")
                        self.phrase_label.configure(
                            text="이제 “헤이 스카웃”이라고 부르면 응답합니다."
                        )
                        self.result_label.configure(
                            text=f"화자 구분 기준값: {profile['threshold']:.2f}"
                        )
                        self.record_button.configure(
                            text="완료", state="normal", command=self.finish
                        )
                    else:
                        self.root.after(700, self.show_phrase)
                elif kind == "record-error":
                    self.result_label.configure(text=str(payload))
                    self.record_button.configure(state="normal", text="다시 녹음")
                elif kind == "error":
                    messagebox.showerror("초기화 실패", str(payload))
                    self.root.destroy()
        except queue.Empty:
            pass
        self.root.after(100, self.poll_events)

    def show_phrase(self) -> None:
        self.step_label.configure(text=f"{self.index + 1}/5 · 아래 문장을 읽어 주세요")
        self.phrase_label.configure(text=ENROLLMENT_PHRASES[self.index])
        self.record_button.configure(state="normal", text="문장 녹음")

    def finish(self) -> None:
        self.root.destroy()

    def cancel(self) -> None:
        if self.completed or messagebox.askyesno(
            "설정 취소", "목소리 등록을 중단할까요?"
        ):
            self.root.destroy()


def main() -> int:
    root = tk.Tk()
    app = EnrollmentApp(root)
    root.mainloop()
    return 0 if app.completed else 1


if __name__ == "__main__":
    sys.exit(main())
