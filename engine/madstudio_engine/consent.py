"""Voice confirmation: before the program speaks in someone's voice, that person reads a
random phrase aloud. We check that exactly this phrase was said (Whisper) and that it is
the same voice as in the recording (ECAPA voice prints). A pre-made clip of someone else
can't pass: it won't contain the random words."""

import re

import numpy as np

from . import audio, models

TEXT_OK = 0.75      # share of the phrase's words that must be heard, in order
SAME_VOICE = 0.5    # measured: one person through phone/room/laptop mic 0.76–0.87,
MAYBE_VOICE = 0.38  # different people 0.15–0.35; between: ask to read again in a quiet place
MIN_UNIT = 0.8      # pieces of the recording shorter than this give unreliable prints
MAX_UNITS = 60      # enough speech for a stable print, fast on any Mac


def words(text: str) -> list[str]:
    """Lowercase words without punctuation, ё = е, numbers spelled out."""
    from .voice import spell_numbers

    text = spell_numbers(text.lower()).replace("ё", "е")
    return re.findall(r"[a-zа-я]+", text)


def text_match(heard: str, phrase: str) -> float:
    """Share of the phrase's words found in what was heard, in the same order (LCS)."""
    a, b = words(phrase), words(heard)
    if not a:
        return 0.0
    row = [0] * (len(b) + 1)
    for x in a:
        prev = 0
        for j, y in enumerate(b):
            cur = row[j + 1]
            row[j + 1] = prev + 1 if x == y else max(row[j + 1], row[j])
            prev = cur
    return row[-1] / len(a)


def _norm(v: np.ndarray) -> np.ndarray:
    return v / (np.linalg.norm(v) + 1e-9)


def speaker_prints(tokens: list[dict], samples: np.ndarray, sr: int, model) -> dict[int, list[float]]:
    """A voice print for every speaker of a transcript: the average of their longest pieces."""
    from .speakers import units

    by_speaker: dict[int, list[tuple[float, float]]] = {}
    for a, b in units(tokens):
        s, e = tokens[a]["start"], tokens[b]["end"]
        if e - s >= MIN_UNIT and tokens[a]["kind"] == "word":
            by_speaker.setdefault(int(tokens[a].get("speaker", 0)), []).append((s, e))
    prints = {}
    for speaker, spans in by_speaker.items():
        spans = sorted(spans, key=lambda x: x[0] - x[1])[:MAX_UNITS]
        vs = [_norm(model.embed(samples[int(s * sr):int(e * sr)])) * (e - s) for s, e in spans]
        prints[speaker] = _norm(np.sum(vs, axis=0)).round(5).tolist()
    return prints


def _speech_only(samples: np.ndarray, sr: int) -> np.ndarray:
    """Drops silence at the edges of a microphone recording (the click of the button etc.)."""
    frame = int(0.03 * sr)
    if len(samples) < frame * 4:
        return samples
    rms = np.sqrt(np.mean(samples[:len(samples) // frame * frame].reshape(-1, frame) ** 2, axis=1))
    loud = np.flatnonzero(rms > max(rms.max() * 0.05, 1e-4))
    if not len(loud):
        return samples
    return samples[max(0, loud[0] - 5) * frame:(loud[-1] + 6) * frame]


def phrase_language(phrase: str) -> str:
    """The phrase is shown in the program's language: Russian or English."""
    return "ru" if re.search(r"[а-яё]", phrase.lower()) else "en"


def hear(path: str, language: str = "ru") -> str:
    """What was said in a short recording."""
    import mlx_whisper

    model_dir = models.require(models.default_for("transcribe"))
    result = mlx_whisper.transcribe(audio.load(path), path_or_hf_repo=str(model_dir), language=language,
                                    condition_on_previous_text=False)
    return result["text"].strip()


def verify(recording: str, phrase: str, voice_print: list[float] | None, on_progress=None) -> dict:
    """Checks a read-aloud confirmation: the phrase and (if given) the voice."""
    from .speakers import SpeakerModel

    report = on_progress or (lambda v: None)
    samples = audio.load(recording)
    speech = _speech_only(samples, audio.SAMPLE_RATE)
    if len(speech) < audio.SAMPLE_RATE * 1.5 or float(np.sqrt(np.mean(speech ** 2))) < 1e-3:
        return {"ok": False, "reason": "silent", "heard": "", "text_match": 0.0, "similarity": None}
    report(0.1)
    heard = hear(recording, phrase_language(phrase))
    match = text_match(heard, phrase)
    report(0.6)
    model = SpeakerModel(str(models.require(models.default_for("speakers"))))
    rec_print = _norm(model.embed(speech))
    report(0.9)
    similarity = None if voice_print is None else float(rec_print @ _norm(np.asarray(voice_print)))
    text_ok = match >= TEXT_OK
    voice_ok = similarity is None or similarity >= SAME_VOICE
    reason = None if text_ok and voice_ok else ("phrase" if not text_ok else
                                                "maybe_voice" if similarity >= MAYBE_VOICE else "voice")
    report(1.0)
    return {"ok": text_ok and voice_ok, "reason": reason, "heard": heard, "text_match": round(match, 2),
            "similarity": None if similarity is None else round(similarity, 3),
            "print": rec_print.round(5).tolist()}


def prints_for(transcript_path: str, source: str) -> dict:
    """Voice prints of all speakers of a transcript (to recognise already confirmed voices)."""
    import json

    from .speakers import SpeakerModel

    with open(transcript_path, encoding="utf-8") as f:
        tokens = json.load(f)["tokens"]
    model = SpeakerModel(str(models.require(models.default_for("speakers"))))
    prints = speaker_prints(tokens, audio.load(source), audio.SAMPLE_RATE, model)
    return {"prints": {str(k): v for k, v in prints.items()}}
