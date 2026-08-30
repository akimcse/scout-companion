from __future__ import annotations

import argparse
import queue
import sys
import threading
import tkinter as tk
from difflib import SequenceMatcher
from tkinter import messagebox, ttk

import numpy as np

from voice_runtime import VoiceModels, cosine_similarity, normalize_text, record_utterance, save_profile


LANGUAGES = {
    "en": {
        "model": "en",
        "title": "Scout Voice Setup",
        "heading": "Register my voice",
        "intro": "Record five different sentences to create your voice profile. Read them naturally in a quiet place.",
        "loading": "Preparing the voice model...",
        "record": "Record sentence",
        "privacy": "Original recordings are not saved. Only the speaker characteristics calculated from the five recordings are encrypted for your Windows account and stored.",
        "listening": "{step}/5 · Listening now without a chime",
        "wait": "Read the sentence, then remain quiet for a moment.",
        "not_recognized": "The sentence was not recognized clearly: “{text}”",
        "no_result": "no recognition result",
        "voice_mismatch": "This voice differs too much from the earlier recordings. Please have the same person try again.",
        "recognized": "Recognized: {text}",
        "complete": "Voice registration is complete.",
        "ready": "You can now say “Hey Scout” to activate voice control.",
        "threshold": "Speaker verification threshold: {value:.2f}",
        "finish": "Done",
        "retry": "Record again",
        "init_failed": "Initialization failed",
        "prompt": "{step}/5 · Read the sentence below",
        "cancel_title": "Cancel setup",
        "cancel": "Stop voice registration?",
        "phrases": (
            "Hey Scout, tell me today's schedule.",
            "Hey Scout, check my important emails.",
            "Hey Scout, tell me the weather in Seoul.",
            "Hey Scout, set a reminder for tomorrow morning.",
            "Hey Scout, respond only to my voice from now on.",
        ),
    },
    "ko": {
        "model": "ko",
        "title": "Scout 음성 설정",
        "heading": "내 목소리 등록",
        "intro": "서로 다른 5개 문장을 듣고 음성 특징을 등록합니다. 조용한 곳에서 평소 말투로 읽어 주세요.",
        "loading": "음성 모델을 준비하고 있습니다...",
        "record": "문장 녹음",
        "privacy": "음성 원본은 저장하지 않습니다. 5개 녹음에서 계산한 화자 특징만 Windows 사용자 계정으로 암호화해 저장합니다.",
        "listening": "{step}/5 · 신호음 없이 바로 듣고 있습니다",
        "wait": "문장을 읽은 뒤 잠시 조용히 기다려 주세요.",
        "not_recognized": "문장을 충분히 인식하지 못했습니다: “{text}”",
        "no_result": "인식 결과 없음",
        "voice_mismatch": "앞서 등록한 목소리와 차이가 큽니다. 같은 사람이 다시 읽어 주세요.",
        "recognized": "인식 결과: {text}",
        "complete": "목소리 등록이 완료되었습니다.",
        "ready": "이제 “헤이 스카웃”이라고 부르면 응답합니다.",
        "threshold": "화자 구분 기준값: {value:.2f}",
        "finish": "완료",
        "retry": "다시 녹음",
        "init_failed": "초기화 실패",
        "prompt": "{step}/5 · 아래 문장을 읽어 주세요",
        "cancel_title": "설정 취소",
        "cancel": "목소리 등록을 중단할까요?",
        "phrases": (
            "헤이 스카웃, 오늘의 일정을 알려줘.",
            "헤이 스카웃, 중요한 이메일을 확인해 줘.",
            "헤이 스카웃, 서울의 날씨를 알려줘.",
            "헤이 스카웃, 내일 아침 알림을 설정해 줘.",
            "헤이 스카웃, 지금부터 내 목소리에만 응답해.",
        ),
    },
    "ja": {
        "model": "ja",
        "title": "Scout 音声設定",
        "heading": "自分の声を登録",
        "intro": "5つの異なる文を録音して音声プロファイルを作成します。静かな場所で自然に読んでください。",
        "loading": "音声モデルを準備しています...",
        "record": "文を録音",
        "privacy": "元の録音は保存されません。5つの録音から計算した話者特徴のみをWindowsアカウント用に暗号化して保存します。",
        "listening": "{step}/5 · 合図音なしで録音中",
        "wait": "文を読んだ後、しばらく静かにしてください。",
        "not_recognized": "文を十分に認識できませんでした: 「{text}」",
        "no_result": "認識結果なし",
        "voice_mismatch": "前の録音と声が大きく異なります。同じ人がもう一度読んでください。",
        "recognized": "認識結果: {text}",
        "complete": "音声登録が完了しました。",
        "ready": "「Hey Scout」と呼びかけると応答します。",
        "threshold": "話者確認のしきい値: {value:.2f}",
        "finish": "完了",
        "retry": "もう一度録音",
        "init_failed": "初期化に失敗しました",
        "prompt": "{step}/5 · 以下の文を読んでください",
        "cancel_title": "設定をキャンセル",
        "cancel": "音声登録を中止しますか？",
        "phrases": (
            "ヘイ スカウト、今日の予定を教えて。",
            "ヘイ スカウト、重要なメールを確認して。",
            "ヘイ スカウト、ソウルの天気を教えて。",
            "ヘイ スカウト、明日の朝にリマインダーを設定して。",
            "ヘイ スカウト、これから私の声だけに応答して。",
        ),
    },
    "zh-Hans": {
        "model": "zh",
        "title": "Scout 语音设置",
        "heading": "注册我的声音",
        "intro": "录制五个不同的句子以创建语音配置。请在安静的地方自然朗读。",
        "loading": "正在准备语音模型...",
        "record": "录制句子",
        "privacy": "不会保存原始录音。仅保存由五次录音计算出的说话人特征，并使用当前Windows账户进行加密。",
        "listening": "{step}/5 · 正在录音，不播放提示音",
        "wait": "读完句子后请保持片刻安静。",
        "not_recognized": "未能清楚识别句子：“{text}”",
        "no_result": "无识别结果",
        "voice_mismatch": "声音与之前的录音差异过大。请由同一个人重新朗读。",
        "recognized": "识别结果：{text}",
        "complete": "语音注册已完成。",
        "ready": "现在说“Hey Scout”即可唤醒语音控制。",
        "threshold": "说话人验证阈值：{value:.2f}",
        "finish": "完成",
        "retry": "重新录制",
        "init_failed": "初始化失败",
        "prompt": "{step}/5 · 请朗读下面的句子",
        "cancel_title": "取消设置",
        "cancel": "停止语音注册吗？",
        "phrases": (
            "嘿 Scout，告诉我今天的日程。",
            "嘿 Scout，查看我的重要邮件。",
            "嘿 Scout，告诉我首尔的天气。",
            "嘿 Scout，设置明天早上的提醒。",
            "嘿 Scout，从现在开始只响应我的声音。",
        ),
    },
}


class EnrollmentApp:
    def __init__(self, root: tk.Tk, language: str) -> None:
        self.root = root
        self.strings = LANGUAGES.get(language, LANGUAGES["en"])
        self.phrases = self.strings["phrases"]
        self.root.title(self.strings["title"])
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
            text=self.strings["heading"],
            font=("Segoe UI", 22, "bold"),
        ).pack(anchor="w")
        ttk.Label(
            frame,
            text=self.strings["intro"],
            wraplength=650,
        ).pack(anchor="w", pady=(8, 22))

        self.progress = ttk.Progressbar(
            frame, maximum=len(self.phrases), mode="determinate"
        )
        self.progress.pack(fill="x")

        self.step_label = ttk.Label(frame, text=self.strings["loading"])
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
            text=self.strings["record"],
            command=self.start_recording,
            state="disabled",
        )
        self.record_button.pack(anchor="w")

        ttk.Label(
            frame,
            text=self.strings["privacy"],
            wraplength=650,
            foreground="#666666",
        ).pack(anchor="w", side="bottom")

        threading.Thread(target=self.load_models, daemon=True).start()
        self.root.after(100, self.poll_events)

    def load_models(self) -> None:
        try:
            self.events.put(("ready", VoiceModels(self.strings["model"])))
        except Exception as error:
            self.events.put(("error", str(error)))

    def start_recording(self) -> None:
        self.record_button.configure(state="disabled")
        self.step_label.configure(
            text=self.strings["listening"].format(step=self.index + 1)
        )
        self.result_label.configure(text=self.strings["wait"])
        threading.Thread(target=self.record_current, daemon=True).start()

    def record_current(self) -> None:
        try:
            assert self.models is not None
            samples = record_utterance()
            transcript = self.models.transcribe(samples)
            embedding = self.models.embedding(samples)
            expected = normalize_text(self.phrases[self.index])
            recognized = normalize_text(transcript)
            similarity = SequenceMatcher(None, expected, recognized).ratio()
            if similarity < 0.30:
                raise ValueError(
                    self.strings["not_recognized"].format(
                        text=transcript or self.strings["no_result"]
                    )
                )
            if self.embeddings:
                centroid = np.mean(np.stack(self.embeddings), axis=0)
                voice_score = cosine_similarity(embedding, centroid)
                if voice_score < 0.35:
                    raise ValueError(
                        self.strings["voice_mismatch"]
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
                    self.result_label.configure(
                        text=self.strings["recognized"].format(text=transcript)
                    )
                    if self.index == len(self.phrases):
                        profile = save_profile(self.embeddings)
                        self.completed = True
                        self.step_label.configure(text=self.strings["complete"])
                        self.phrase_label.configure(text=self.strings["ready"])
                        self.result_label.configure(
                            text=self.strings["threshold"].format(
                                value=profile["threshold"]
                            )
                        )
                        self.record_button.configure(
                            text=self.strings["finish"],
                            state="normal",
                            command=self.finish,
                        )
                    else:
                        self.root.after(700, self.show_phrase)
                elif kind == "record-error":
                    self.result_label.configure(text=str(payload))
                    self.record_button.configure(
                        state="normal", text=self.strings["retry"]
                    )
                elif kind == "error":
                    messagebox.showerror(self.strings["init_failed"], str(payload))
                    self.root.destroy()
        except queue.Empty:
            pass
        self.root.after(100, self.poll_events)

    def show_phrase(self) -> None:
        self.step_label.configure(
            text=self.strings["prompt"].format(step=self.index + 1)
        )
        self.phrase_label.configure(text=self.phrases[self.index])
        self.record_button.configure(state="normal", text=self.strings["record"])

    def finish(self) -> None:
        self.root.destroy()

    def cancel(self) -> None:
        if self.completed or messagebox.askyesno(
            self.strings["cancel_title"], self.strings["cancel"]
        ):
            self.root.destroy()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--language", choices=tuple(LANGUAGES), default="en"
    )
    args = parser.parse_args()
    root = tk.Tk()
    app = EnrollmentApp(root, args.language)
    root.mainloop()
    return 0 if app.completed else 1


if __name__ == "__main__":
    sys.exit(main())
