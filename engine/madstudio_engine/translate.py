"""Translation in the speaker's own voice.

1. Speech is split into phrases (sentence ends, pauses, speaker changes).
2. The local language model translates them in batches, seeing the previous phrases.
3. The language model is unloaded; the voice model says every translated phrase in the
   speaker's voice, using the original phrase itself as the sample — so the intonation
   of that very moment carries over.
4. Each phrase is placed where the original one started; a phrase that came out longer
   than the time it has is sped up a little (at most MAX_SPEEDUP).
"""

import os
import re
import subprocess
import tempfile

import numpy as np

from . import audio, models
from . import voice as voice_module
from .i18n import tr
from .voice import spell_numbers

LANGUAGES = {"ru": "русский", "en": "английский", "de": "немецкий", "es": "испанский", "fr": "французский",
             "it": "итальянский", "pt": "португальский", "tr": "турецкий", "uk": "украинский"}
MAX_PHRASE = 12.0     # seconds; longer speech is split at a comma or word
MIN_SAMPLE = 3.0      # a voice sample shorter than this borrows the speaker's previous phrases
MAX_SPEEDUP = 1.3
SR = 24000            # voice model sample rate


def phrases(words: list[dict]) -> list[dict]:
    """[{text, start, end, speaker}] words -> phrases of the same speaker."""
    out, cur = [], []

    def flush():
        if cur:
            out.append({"text": " ".join(w["text"] for w in cur), "start": cur[0]["start"],
                        "end": cur[-1]["end"], "speaker": cur[0].get("speaker")})
            cur.clear()

    for w in words:
        if cur:
            last = cur[-1]
            sentence_end = re.search(r"[.?!…]$", last["text"])
            gap = w["start"] - last["end"]
            if (w.get("speaker") != last.get("speaker") or gap > 2.5 or (gap > 1.0 and sentence_end)
                    or (sentence_end and w["start"] - cur[0]["start"] > 1.5)
                    or (w["end"] - cur[0]["start"] > MAX_PHRASE and re.search(r"[,;:]$", last["text"]))
                    or w["end"] - cur[0]["start"] > MAX_PHRASE * 1.5):
                flush()
        cur.append(w)
    flush()
    return out


def translate_texts(model, texts: list[str], language: str, on_progress=None) -> list[str]:
    """One phrase at a time (so translations can never shift against the audio), with
    the phrases around it as context."""
    from .text_ai import _json

    lang = LANGUAGES.get(language, language)
    out: list[str] = []
    for i, text in enumerate(texts):
        before = " ".join(texts[max(0, i - 3):i])
        after = texts[i + 1] if i + 1 < len(texts) else ""
        prompt = (
            f"Ты переводишь видео на {lang} язык для озвучки. Переведи ТОЛЬКО реплику в квадратных скобках. "
            "Это живая устная речь: переводи естественно и разговорно, как сказал бы носитель языка; "
            "убирай запинки и слова-паразиты; длина — примерно как у оригинала; имена сохраняй. "
            "Если реплика обрывается на полуслове — переведи так же оборванно.\n"
            + (f"Перед ней говорилось: {before}\n" if before else "")
            + (f"После неё: {after}\n" if after else "")
            + f"\n[{text}]\n\nОтветь только JSON-строкой с переводом, например: \"...\"")
        answer = model.ask(prompt, max_tokens=60 + 4 * len(text))
        result = _json("[" + answer.strip() + "]") if answer.strip().startswith('"') else None
        translation = result[0] if isinstance(result, list) and result else answer
        translation = re.sub(r"<think>.*?</think>", "", str(translation), flags=re.S).strip().strip('"«»[]').strip()
        out.append(translation or text)
        if on_progress:
            on_progress((i + 1) / len(texts))
    return out


def _sample(phrase_index: int, items: list[dict], wav: np.ndarray) -> tuple[np.ndarray, str]:
    """Voice sample for a phrase: the phrase itself, plus the same speaker's previous
    phrases if it is too short to catch the voice."""
    p = items[phrase_index]
    parts = [p]
    k = phrase_index - 1
    while sum(x["end"] - x["start"] for x in parts) < MIN_SAMPLE and k >= 0:
        if items[k].get("speaker") == p.get("speaker"):
            parts.insert(0, items[k])
        k -= 1
    gap = np.zeros(int(0.15 * SR), dtype=np.float32)
    pieces = []
    for x in parts:
        pieces += [wav[int(x["start"] * SR):int(x["end"] * SR)], gap]
    sample = np.concatenate(pieces)[:int(12 * SR)]
    text = " ".join(x["text"] for x in parts)
    return sample, text


def _speed_up(piece: np.ndarray, factor: float) -> np.ndarray:
    """Plays a piece faster without changing the pitch (ffmpeg atempo)."""
    with tempfile.TemporaryDirectory() as d:
        a, b = os.path.join(d, "a.wav"), os.path.join(d, "b.wav")
        audio.save(a, piece, SR)
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", a, "-af", f"atempo={factor:.3f}", b], check=True)
        return audio.load(b, sample_rate=SR)


def place(pieces: list[tuple[float, np.ndarray]], total: float) -> np.ndarray:
    """Puts phrases at their start times; a phrase that would run into the next one is
    sped up (up to MAX_SPEEDUP), and if still too long the next phrase waits for it."""
    out = np.zeros(int((total + 30) * SR), dtype=np.float32)
    cursor = 0
    for i, (start, piece) in enumerate(pieces):
        at = max(int(start * SR), cursor)
        room = (int(pieces[i + 1][0] * SR) if i + 1 < len(pieces) else len(out)) - at
        if len(piece) > room > 0:
            piece = _speed_up(piece, min(MAX_SPEEDUP, len(piece) / room))
        out[at:at + len(piece)] += piece[:len(out) - at]
        cursor = at + len(piece) + int(0.05 * SR)
    end = max(cursor, int(total * SR))
    return out[:end]


def dub(source: str, words: list[dict], language: str, out_path: str, on_progress=None,
        keep_background: bool = False) -> dict:
    """keep_background: music and noises of the original stay under the new voice, and the
    voice samples are taken from the cleaned voice (no music in the clone)."""
    report = on_progress or (lambda stage, v: None)
    items = phrases(words)
    if not items:
        raise RuntimeError(tr("Нет речи для перевода"))

    background = None
    voice_source = source
    if keep_background:
        from .separate import Separator
        report("separate", 0.0)
        folder = os.path.dirname(out_path)
        voice_source = os.path.join(folder, "voice_only.flac")
        background = os.path.join(folder, "background.flac")
        separator = Separator()
        separator.run(source, voice_source, background, on_progress=lambda v: report("separate", v))
        del separator
        _free_memory()

    # 1. text (language model), then free its memory before the voice model loads
    from .text_ai import TextModel
    report("translate_load", 0.0)
    text_model = TextModel(str(models.require(models.default_for("text"))))
    translations = translate_texts(text_model, [p["text"] for p in items], language,
                                   on_progress=lambda v: report("translate", v))
    del text_model
    _free_memory()

    # 2. voice
    report("voice_load", 0.0)
    from f5_tts.infer.utils_infer import infer_process

    from .voice import Voice
    voice = Voice()
    wav = audio.load(voice_source, sample_rate=SR)
    pieces = []
    with tempfile.TemporaryDirectory() as tmp:
        for i, (p, text) in enumerate(zip(items, translations)):
            sample, sample_text = _sample(i, items, wav)
            ref = os.path.join(tmp, f"ref{i}.wav")
            audio.save(ref, sample, SR)
            target = p["end"] - p["start"]
            natural = len(re.sub(r"\W", "", spell_numbers(text, language))) / 14.0   # letters/s in calm speech
            length = float(np.clip(natural, target * 0.85, target * 1.25))
            spoken = spell_numbers(text, language)   # "12" -> "twelve", not Russian "двенадцать"
            if language == "ru":
                spoken = voice.stress(spoken)        # stress marks: the Russian voice model reads them best
            cyrillic = re.search(r"[а-яё]", sample_text.lower())
            ref_text = voice.stress(spell_numbers(sample_text)) if cyrillic else spell_numbers(sample_text, "en")
            piece, _, _ = infer_process(
                ref, ref_text.rstrip() + " ", spoken, voice.model, voice.vocoder,
                fix_duration=len(sample) / SR + length, nfe_step=voice_module.STEPS, show_info=lambda *a: None, progress=None)
            pieces.append((p["start"], voice.watermark(np.asarray(piece, dtype=np.float32), SR)))
            report("dub", (i + 1) / len(items))

    total = len(wav) / SR
    track = place(pieces, total)
    info = audio.probe(source)
    sr = info["sample_rate"]
    track = _resample(track, SR, sr)
    if background:
        bg = audio.load(background, sample_rate=sr, channels=2)
        mix = np.zeros((max(len(track), len(bg)), 2), dtype=np.float32)
        mix[:len(bg)] += bg
        mix[:len(track)] += track[:, None]
        peak = float(np.abs(mix).max())
        track = mix / peak * 0.97 if peak > 0.97 else mix
    audio.save(out_path, track, sr)

    srt_path = os.path.splitext(out_path)[0] + ".srt"
    with open(srt_path, "w", encoding="utf-8") as f:
        for n, (p, text) in enumerate(zip(items, translations), 1):
            f.write(f"{n}\n{_stamp(p['start'])} --> {_stamp(p['end'])}\n{text}\n\n")
    return {"path": out_path, "subtitles": srt_path, "background": bool(background), "phrases": [
        {"start": p["start"], "end": p["end"], "original": p["text"], "translation": t}
        for p, t in zip(items, translations)]}


def _free_memory():
    import gc

    gc.collect()
    try:
        import mlx.core as mx
        mx.clear_cache()
    except Exception:
        pass


def _resample(x, src, dst):
    from .voice import _resample as resample

    return resample(x, src, dst)


def _stamp(t: float) -> str:
    ms = int(round(t * 1000))
    return f"{ms // 3600000:02d}:{ms // 60000 % 60:02d}:{ms // 1000 % 60:02d},{ms % 1000:03d}"
