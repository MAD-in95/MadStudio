"""Reading a text aloud in a confirmed voice: the reference is the recording where the
voice's owner read the confirmation phrase (their consent), the text is said paragraph by
paragraph with natural pauses in between."""

import re

import numpy as np

from . import audio
from .i18n import tr

PARAGRAPH_PAUSE = 0.45   # seconds between paragraphs
SR = 24000


def paragraphs(text: str) -> list[str]:
    """Paragraphs of the text; very long ones are split at sentence ends (~400 letters)."""
    out = []
    for block in re.split(r"\n\s*\n|\n", text):
        block = " ".join(block.split())
        if not block:
            continue
        current = ""
        for sentence in re.split(r"(?<=[.!?…])\s+", block):
            if current and len(current) + len(sentence) > 400:
                out.append(current)
                current = sentence
            else:
                current = f"{current} {sentence}".strip()
        if current:
            out.append(current)
    return out


def speak(voice, text: str, ref_audio: str, ref_text: str, out_path: str, speed: float = 1.0,
          on_progress=None) -> dict:
    """`voice` is a loaded `Voice` (F5 + vocoder + stress marks + AI mark)."""
    import soundfile
    from f5_tts.infer.utils_infer import chunk_text, infer_process

    from .voice import STEPS, spell_numbers

    parts = paragraphs(text)
    if not parts:
        raise RuntimeError(tr("Нет текста, чтобы озвучить"))
    russian = lambda s: re.search(r"[а-яё]", s.lower()) is not None
    ref = voice.stress(spell_numbers(ref_text)) if russian(ref_text) else ref_text
    # F5 splits long text itself and generates the parts in parallel threads, which the Mac's
    # graphics chip can't take (it crashes); so we split it and give one part at a time
    info = soundfile.info(ref_audio)
    max_chars = max(60, int(len(ref.encode("utf-8")) / info.duration * (22 - info.duration) * speed))
    pieces = []
    for n, p in enumerate(parts):
        for chunk in chunk_text(p, max_chars=max_chars):
            spoken = spell_numbers(chunk, "ru" if russian(chunk) else "en")
            if russian(chunk):
                spoken = voice.stress(spoken)
            wav, _, _ = infer_process(ref_audio, ref.rstrip() + " ", spoken, voice.model, voice.vocoder,
                                      nfe_step=STEPS, speed=speed, show_info=lambda *a: None, progress=None)
            pieces.append(np.asarray(wav, dtype=np.float32))
            pieces.append(np.zeros(int(0.12 * SR), dtype=np.float32))
        pieces[-1] = np.zeros(int(PARAGRAPH_PAUSE * SR), dtype=np.float32)
        if on_progress:
            on_progress((n + 1) / len(parts))
    result = voice.watermark(np.concatenate(pieces[:-1]), SR)
    audio.save(out_path, result, SR)
    return {"path": out_path, "duration": round(len(result) / SR, 2), "paragraphs": len(parts)}
