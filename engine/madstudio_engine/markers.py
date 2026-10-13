"""Turns Whisper words into an editable timeline.

Whisper drops non-speech sounds ("э-э", breaths, clicks) and long pauses from its text.
Here we look at the audio between words and add tokens for what was left out, so the
user can delete them like words. The tokens cover the whole recording without gaps:
deleting a token cuts exactly its piece of audio.
"""

import re

import numpy as np

HOP = 0.01          # analysis step, seconds
WIN = 0.02          # analysis window, seconds
MIN_GAP = 0.12      # shorter gaps between words are not analysed
MIN_PAUSE = 0.25    # shorter silences are not worth a token
MIN_SOUND = 0.06    # shorter sounds are ignored
MIN_RUN = 0.05      # silence/sound flickers shorter than this are smoothed out
CLICK_MAX = 0.1     # a sound shorter than this is a click
MIN_FILLER = 0.25   # a shorter voiced sound is more likely a word edge than "э-э"
MIN_BREATH = 0.15
EDGE_SOUND = 0.25   # Whisper's word edges are approximate: a shorter sound touching
                    # a word is treated as part of that word, so we never clip words
VOICED_ZCR = 0.1    # "э-э" is voiced: few zero crossings; breath is noisy: many
PARA_PAUSE = 1.2     # a sentence end followed by such a pause starts a paragraph...
PARA_MIN_WORDS = 30  # ...but paragraphs are not shorter than this
PARA_MAX_WORDS = 120 # and a long monologue is split at the next sentence end anyway
HESITATION = re.compile(r"^[эмаыхн ]*$")  # what "э-э", "мм", "а-а", "хм" sound like to a letter model
PARASITES = re.compile(r"^(э+|э+м+|м{2,}|хм+|ммм?)$")
SENTENCE_END = re.compile(r"[.?!…]$")


class Features:
    """Loudness (dB) and zero-crossing rate for every 10 ms of audio."""

    def __init__(self, audio: np.ndarray, sr: int):
        hop, win = int(HOP * sr), int(WIN * sr)
        n = max(1, (len(audio) - win) // hop + 1)
        padded = np.pad(audio, (0, max(0, win - len(audio))))
        frames = np.lib.stride_tricks.as_strided(
            padded, shape=(n, win), strides=(padded.strides[0] * hop, padded.strides[0]))
        rms = np.sqrt(np.mean(frames.astype(np.float64) ** 2, axis=1))
        self.db = 20 * np.log10(rms + 1e-10)
        signs = np.signbit(frames)
        self.zcr = np.mean(signs[:, 1:] != signs[:, :-1], axis=1)
        self.noise_floor = float(np.percentile(self.db, 5))
        self.speech_level = float(np.percentile(self.db, 95))
        spread = max(self.speech_level - self.noise_floor, 1.0)
        self.silence_db = self.noise_floor + max(6.0, 0.3 * spread)
        self.silent = self.db < self.silence_db

    def frame(self, t: float) -> int:
        return int(np.clip(round(t / HOP), 0, len(self.db)))


def _runs(mask: np.ndarray) -> list[list]:
    """Splits a boolean array into [value, start, end) runs."""
    runs = []
    for i, v in enumerate(mask):
        if runs and runs[-1][0] == v:
            runs[-1][2] = i + 1
        else:
            runs.append([bool(v), i, i + 1])
    return runs


def _smooth(runs: list[list]) -> list[list]:
    """Absorbs runs shorter than MIN_RUN into their neighbours."""
    min_frames = round(MIN_RUN / HOP)
    out = []
    for run in runs:
        if out and (run[2] - run[1] < min_frames or out[-1][0] == run[0]):
            out[-1][2] = run[2]
        else:
            out.append(list(run))
    # a short first run is merged forward
    if len(out) > 1 and out[0][2] - out[0][1] < min_frames:
        out[1][1] = out[0][1]
        out.pop(0)
    return out


def _trim_word(word: dict, f: Features) -> None:
    """Moves word edges inward past silence Whisper included in the word."""
    a, b = f.frame(word["start"]), f.frame(word["end"])
    min_len = round(0.06 / HOP)
    while b - a > min_len and f.silent[a]:
        a += 1
    while b - a > min_len and f.silent[b - 1]:
        b -= 1
    word["start"], word["end"] = a * HOP, b * HOP


def _gap_tokens(start: float, end: float, f: Features,
                has_word_before: bool, has_word_after: bool) -> list[dict]:
    """Pause / breath / filler / click tokens found between two words."""
    if end - start < MIN_GAP:
        return []
    a, b = f.frame(start), f.frame(end)
    tokens = []
    for silent, s, e in _smooth(_runs(f.silent[a:b])):
        t0, t1 = (a + s) * HOP, (a + e) * HOP
        dur = t1 - t0
        if silent:
            if dur >= MIN_PAUSE:
                tokens.append({"kind": "pause", "start": t0, "end": t1})
            continue
        touches_word = (s == 0 and has_word_before) or (a + e == b and has_word_after)
        if dur < MIN_SOUND or (touches_word and dur < EDGE_SOUND):
            continue
        loud = float(np.mean(f.db[a + s:a + e]))
        zcr = float(np.mean(f.zcr[a + s:a + e]))
        if dur < CLICK_MAX:
            kind = "click"
        elif zcr < VOICED_ZCR and loud > f.speech_level - 18:
            if dur < MIN_FILLER:
                continue
            kind = "filler"
        elif dur >= MIN_BREATH:
            kind = "breath"
        else:
            continue
        tokens.append({"kind": kind, "start": t0, "end": t1})
    return tokens


def _make_contiguous(tokens: list[dict], duration: float) -> None:
    """Stretches token edges so they tile [0, duration] without holes or overlaps."""
    if not tokens:
        return
    tokens[0]["start"] = 0.0
    for prev, cur in zip(tokens, tokens[1:]):
        if prev["end"] < cur["start"]:
            mid = (prev["end"] + cur["start"]) / 2
            prev["end"] = cur["start"] = mid
        else:
            prev["end"] = cur["start"] = max(cur["start"], prev["start"])
    tokens[-1]["end"] = duration
    for t in tokens:
        t["start"], t["end"] = round(t["start"], 3), round(t["end"], 3)


def _mark_words(tokens: list[dict]) -> None:
    """Flags parasites, stretched words (hidden "э-э" inside) and paragraph starts."""
    words_since_para = 0
    prev_word = None
    pause_before = 0.0
    for t in tokens:
        if t["kind"] != "word":
            if t["kind"] == "pause":
                pause_before += t["end"] - t["start"]
            continue
        bare = re.sub(r"[^\wё-]", "", t["text"].lower()).replace("-", "")
        if PARASITES.match(bare):
            t["parasite"] = True
        letters = len(re.sub(r"\W", "", t["text"]))
        dur = t["end"] - t["start"]
        if dur > 1.0 and dur > 0.35 + 0.09 * letters:
            t["stretched"] = True
        sentence_end = prev_word is not None and SENTENCE_END.search(prev_word["text"])
        long_enough = words_since_para >= PARA_MIN_WORDS
        if prev_word is None or (sentence_end and long_enough
                                 and (pause_before >= PARA_PAUSE or words_since_para >= PARA_MAX_WORDS)):
            t["para"] = True
            words_since_para = 0
        words_since_para += 1
        prev_word = t
        pause_before = 0.0


def _check_with_ears(tokens: list[dict], audio: np.ndarray, sr: int, hear) -> None:
    """Sounds that a letter model hears as words are speech Whisper skipped (often the
    other person's short replies) — they must not be cleaned away as "э-э"."""
    for t in tokens:
        if t["kind"] not in ("filler", "breath"):
            continue
        a, b = int(max(0.0, t["start"] - 0.05) * sr), int((t["end"] + 0.05) * sr)
        heard = hear(audio[a:b])
        letters = heard.replace(" ", "")
        if len(letters) >= 2 and not HESITATION.match(heard):
            t["kind"] = "speech"
            t["text"] = heard


def build_tokens(words: list[dict], audio: np.ndarray, sr: int, hear=None) -> list[dict]:
    """words: [{"text", "start", "end", "prob"}] from Whisper, in order.
    hear(audio) -> letters a speech model hears there; used to tell speech from noise."""
    duration = len(audio) / sr
    f = Features(audio, sr)
    clean = []
    for w in words:
        w = dict(w)
        if clean:
            w["start"] = max(w["start"], clean[-1]["end"])
        w["end"] = max(w["end"], w["start"])
        _trim_word(w, f)
        clean.append(w)

    tokens: list[dict] = []
    cursor = 0.0
    for i, w in enumerate(clean):
        tokens += _gap_tokens(cursor, w["start"], f, i > 0, True)
        tokens.append({"kind": "word", **w})
        cursor = w["end"]
    tokens += _gap_tokens(cursor, duration, f, bool(clean), False)
    if not tokens:
        tokens = [{"kind": "pause", "start": 0.0, "end": duration}]

    if hear is not None:
        _check_with_ears(tokens, audio, sr, hear)
    _make_contiguous(tokens, duration)
    _mark_words(tokens)
    return tokens
