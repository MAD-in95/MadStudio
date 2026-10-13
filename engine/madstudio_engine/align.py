"""Exact word boundaries: forced alignment of Whisper's words with a wav2vec2 CTC model.

Whisper knows *what* was said but places word edges only roughly (±0.2 s). A CTC model
hears every letter, so we let it find where each letter of the known text sounds.
With exact edges, cuts don't clip words and the sounds between words become visible.
"""

import re

import numpy as np

FRAME = 0.02          # wav2vec2 gives one prediction per 20 ms
CHUNK_TARGET = 12.0   # seconds of speech aligned at once; split at a pause after this...
CHUNK_MAX = 25.0      # ...and forcibly at this length
MARGIN = 0.4          # extra audio around a chunk, Whisper's edges may be off
PAD_START = 0.04      # CTC models mark letters a little late at word starts...
PAD_END = 0.08        # ...and early at word ends; silence added here is trimmed later


def viterbi(log_probs: np.ndarray, targets: list[int], blank: int = 0) -> list[int] | None:
    """CTC forced alignment. Returns, for each frame, the index into `targets` it sounds,
    or -1 for blank frames. None if the text doesn't fit into the audio."""
    T, n = len(log_probs), len(targets)
    if n == 0 or T < n:
        return None
    ext = np.full(2 * n + 1, blank, dtype=np.int64)    # blank, t0, blank, t1, ..., blank
    ext[1::2] = targets
    S = len(ext)
    # a step over a blank is allowed between different letters only
    skip_ok = np.zeros(S, dtype=bool)
    skip_ok[3::2] = ext[3::2] != ext[1:-2:2]

    neg = -1e30
    score = np.full(S, neg)
    score[0] = log_probs[0, ext[0]]
    score[1] = log_probs[0, ext[1]]
    back = np.zeros((T, S), dtype=np.int8)              # 0 stay, 1 from s-1, 2 from s-2
    for t in range(1, T):
        stay = score
        step = np.concatenate([[neg], score[:-1]])
        jump = np.where(skip_ok, np.concatenate([[neg, neg], score[:-2]]), neg)
        choice = np.argmax(np.stack([stay, step, jump]), axis=0)
        best = np.choose(choice, [stay, step, jump])
        score = best + log_probs[t, ext]
        back[t] = choice

    s = S - 1 if score[S - 1] >= score[S - 2] else S - 2
    if score[s] <= neg / 2:
        return None
    path = np.empty(T, dtype=np.int64)
    for t in range(T - 1, -1, -1):
        path[t] = s
        s -= int(back[t, s])
    return [int(p // 2) if p % 2 == 1 else -1 for p in path]


def _normalize(text: str, vocab: dict) -> str:
    text = text.lower()
    return "".join(ch for ch in text if ch in vocab and ch != "|")


def _chunks(words: list[dict]) -> list[list[int]]:
    """Groups word indices into pieces of continuous speech, split at pauses."""
    chunks, current = [], []
    for i, w in enumerate(words):
        if current:
            length = w["end"] - words[current[0]]["start"]
            gap = w["start"] - words[current[-1]]["end"]
            if (length > CHUNK_TARGET and gap > 0.15) or length > CHUNK_MAX:
                chunks.append(current)
                current = []
        current.append(i)
    if current:
        chunks.append(current)
    return chunks


class Aligner:
    def __init__(self, model_dir: str):
        import torch
        from transformers import Wav2Vec2ForCTC

        self.torch = torch
        self.device = "mps" if torch.backends.mps.is_available() else "cpu"
        self.model = Wav2Vec2ForCTC.from_pretrained(model_dir).to(self.device).eval()
        import json
        with open(f"{model_dir}/vocab.json", encoding="utf-8") as f:
            self.vocab = json.load(f)
        self.blank = self.vocab["<pad>"]
        self.id_to_char = {i: ch for ch, i in self.vocab.items() if len(ch) == 1}
        self.separator = self.vocab["|"]

    def log_probs(self, audio: np.ndarray) -> np.ndarray:
        x = (audio - audio.mean()) / np.sqrt(audio.var() + 1e-7)
        with self.torch.inference_mode():
            inp = self.torch.from_numpy(x.astype(np.float32))[None].to(self.device)
            logits = self.model(inp).logits[0]
            return self.torch.log_softmax(logits, dim=-1).float().cpu().numpy()

    def hear(self, audio: np.ndarray) -> str:
        """What the model hears in a short piece of audio (greedy CTC decoding)."""
        if len(audio) < 800:
            return ""
        ids = self.log_probs(audio).argmax(axis=1)
        letters = []
        prev = None
        for i in ids:
            if i != prev and i != self.blank:
                letters.append(self.id_to_char.get(int(i), ""))
            prev = i
        return "".join(letters).replace("|", " ").strip()

    def align(self, words: list[dict], audio: np.ndarray, sr: int, on_progress=None) -> list[dict]:
        """Returns copies of `words` with exact start/end where alignment succeeded."""
        words = [dict(w) for w in words]
        chunks = _chunks(words)
        total = len(audio) / sr
        for n, idx in enumerate(chunks):
            prev_end = words[idx[0] - 1]["end"] if idx[0] > 0 else 0.0
            next_start = words[idx[-1] + 1]["start"] if idx[-1] + 1 < len(words) else total
            t0 = max(prev_end, words[idx[0]]["start"] - MARGIN, 0.0)
            t1 = min(next_start, words[idx[-1]]["end"] + MARGIN, total)
            self._align_chunk(words, idx, audio[int(t0 * sr):int(t1 * sr)], t0)
            if on_progress:
                on_progress((n + 1) / len(chunks))
        _pad(words)
        return words

    def _align_chunk(self, words, idx, audio, offset):
        if len(audio) < 400:
            return
        targets, owner = [], []
        for i in idx:
            letters = _normalize(words[i]["text"], self.vocab)
            if not letters:
                continue
            if targets:
                targets.append(self.separator)
                owner.append(-1)
            for ch in letters:
                targets.append(self.vocab[ch])
                owner.append(i)
        log_probs = self.log_probs(audio)
        path = viterbi(log_probs, targets, self.blank)
        if path is None:
            return
        first, last = {}, {}
        for frame, k in enumerate(path):
            if k < 0 or owner[k] < 0:
                continue
            i = owner[k]
            first.setdefault(i, frame)
            last[i] = frame
        for i in first:
            words[i]["start"] = round(offset + first[i] * FRAME, 3)
            words[i]["end"] = round(offset + (last[i] + 1) * FRAME, 3)
            words[i]["aligned"] = True


def _pad(words: list[dict]) -> None:
    """Widens aligned words a little, never past the middle of the gap to a neighbour."""
    for i, w in enumerate(words):
        if not w.get("aligned"):
            continue
        lo = (words[i - 1]["end"] + w["start"]) / 2 if i > 0 else 0.0
        hi = (w["end"] + words[i + 1]["start"]) / 2 if i + 1 < len(words) else w["end"] + PAD_END
        w["start"] = round(max(lo, w["start"] - PAD_START), 3)
        w["end"] = round(min(hi, w["end"] + PAD_END), 3)
