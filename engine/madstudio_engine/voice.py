"""Re-voicing: replaces a piece of the recording with new words in the speaker's own voice.

F5-TTS can "fill in" a gap inside real audio: it hears the speech around the gap and
generates the missing part so that voice, intonation and room sound match. We give it
a window of the recording around the edit, the full text of that window with the new
words, and how long the new part should last.
"""

import os
import re

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

import numpy as np

from . import audio, models

CONTEXT_BEFORE = 8.0   # seconds of real speech the model listens to before the edit...
CONTEXT_AFTER = 3.0    # ...and after it
MIN_CONTEXT = 3.0      # less of the person's own speech around the edit: add a prepared sample
SAMPLE_LEN = (4.0, 10.0)  # a prepared voice sample lasts this long
MARGIN = 0.06          # the piece comes with this much of the voice around it: overlapped with
                       # the recording and crossfaded, the AI voice flows into the real one
LOUDNESS_REF = 0.3     # seconds around the edit used to match the piece's loudness
STEPS = 16             # generator steps: 16 is ~2x faster than 32 with the same measured quality
TARGET_RMS = 0.1       # loudness the model was trained on
# 16-bit signature hidden in every generated piece: "MS" (MadStudio)
WATERMARK = [0, 1, 0, 0, 1, 1, 0, 1, 0, 1, 0, 1, 0, 0, 1, 1]
MIN_MARKED = 0.35      # generated pieces are never shorter than 0.4 s; shorter hits are noise


def spell_numbers(text: str, lang: str = "ru") -> str:
    """'30 секунд' -> 'тридцать секунд', '12 seconds' -> 'twelve seconds': the voice model
    reads letters, and given digits it says them in Russian whatever the language."""
    from num2words import num2words

    def say(m):
        number = m.group().replace(",", ".")
        value = float(number) if "." in number else int(number)
        try:
            return num2words(value, lang=lang)
        except NotImplementedError:
            return num2words(value, lang="en")

    return re.sub(r"\d+(?:[.,]\d+)?", say, text)


def _words(tokens, first, last) -> str:
    return " ".join(t["text"] for t in tokens[first:last + 1] if t["kind"] == "word")


def _context(tokens: list[dict], first: int, last: int) -> tuple[int, int]:
    """Token range around the edit: whole tokens, about CONTEXT_BEFORE/AFTER seconds, and
    only the same person's speech — in a dialogue the other voice would leak into the new words."""
    start, end = tokens[first]["start"], tokens[last]["end"]
    speaker = tokens[first].get("speaker")
    same = lambda t: speaker is None or t.get("speaker", speaker) == speaker
    a = first
    while a > 0 and start - tokens[a - 1]["start"] <= CONTEXT_BEFORE and same(tokens[a - 1]):
        a -= 1
    b = last
    while b + 1 < len(tokens) and tokens[b + 1]["end"] - end <= CONTEXT_AFTER and same(tokens[b + 1]):
        b += 1
    return a, b


def _spoken(tokens: list[dict], a: int, b: int) -> float:
    """Seconds of words in tokens a..b."""
    return sum(t["end"] - t["start"] for t in tokens[a:b + 1] if t["kind"] == "word")


def phrases(tokens: list[dict], speaker) -> list[tuple[int, int, float]]:
    """Clean phrases of one person: (first, last, mean word confidence). A phrase stops at
    another voice, «э-э», clicks, failed takes, parasite words or a pause over 0.8 s, and
    is cut at SAMPLE_LEN[1] seconds."""
    out = []
    n, a = len(tokens), 0
    while a < n:
        t = tokens[a]
        if t["kind"] != "word" or (speaker is not None and t.get("speaker", speaker) != speaker) \
                or t.get("take") is not None or t.get("parasite"):
            a += 1
            continue
        b, probs = a, []
        while b < n:
            u = tokens[b]
            if u.get("speaker", t.get("speaker")) != t.get("speaker") or u["kind"] in ("filler", "click", "speech") \
                    or u.get("take") is not None or u.get("parasite") \
                    or (u["kind"] in ("pause", "breath") and u["end"] - u["start"] > 0.8) \
                    or u["end"] - t["start"] > SAMPLE_LEN[1]:
                break
            if u["kind"] == "word":
                probs.append(u.get("prob", 1.0))
            b += 1
        last = b - 1
        while last > a and tokens[last]["kind"] != "word":
            last -= 1
        if tokens[last]["end"] - t["start"] >= 1.0 and min(probs) >= 0.25:
            out.append((a, last, sum(probs) / len(probs)))
        a = max(b, a + 1)
    return out


def voice_samples(tokens: list[dict], speaker, near: float,
                  avoid: tuple[int, int] | None = None) -> list[tuple[int, int]]:
    """Clean phrases of one person to show the voice model what they sound like: the
    clearest ones closest to `near` (same mic and mood), SAMPLE_LEN seconds in total —
    one long phrase or several short ones (a guest who answers briefly)."""
    found = [p for p in phrases(tokens, speaker) if not avoid or p[1] < avoid[0] or p[0] > avoid[1]]
    for clear in (0.75, 0.5):
        good = sorted((p for p in found if p[2] >= clear), key=lambda p: abs(tokens[p[0]]["start"] - near))
        chosen, total = [], 0.0
        for a, b, _ in good:
            length = tokens[b]["end"] - tokens[a]["start"]
            if total + length > SAMPLE_LEN[1]:
                continue
            chosen.append((a, b))
            total += length
            if total >= SAMPLE_LEN[0]:
                return sorted(chosen)
        if total >= 2.0:
            return sorted(chosen)
    return []


def _speech_rate(tokens: list[dict], a: int, b: int) -> float:
    """Letters per second of the speaker in the context (pauses excluded)."""
    letters = sum(len(re.sub(r"\W", "", spell_numbers(t["text"])))
                  for t in tokens[a:b + 1] if t["kind"] == "word")
    seconds = sum(t["end"] - t["start"] for t in tokens[a:b + 1] if t["kind"] == "word")
    return letters / seconds if seconds > 0 and letters > 0 else 14.0


class Voice:
    def __init__(self):
        import torch
        from importlib.resources import files

        from f5_tts.infer.utils_infer import load_model, load_vocoder
        from hydra.utils import get_class
        from omegaconf import OmegaConf

        self.torch = torch
        model_id = models.default_for("voice")
        model_dir = models.require(model_id)
        vocoder_dir = models.require("vocoder-vocos")
        model_info = models.get(model_id)
        weights = next(f for f in model_info["files"] if f.endswith(".safetensors"))
        vocab = next(f for f in model_info["files"] if f.endswith("vocab.txt"))

        cfg = OmegaConf.load(str(files("f5_tts").joinpath("configs/F5TTS_v1_Base.yaml")))
        self.mel = cfg.model.mel_spec
        self.model = load_model(get_class(f"f5_tts.model.{cfg.model.backbone}"), cfg.model.arch,
                                str(model_dir / weights), vocab_file=str(model_dir / vocab))
        self.vocoder = load_vocoder("vocos", is_local=True, local_path=str(vocoder_dir))
        self.device = next(self.model.parameters()).device
        self.accentizer = models.load_accentizer(models.model_path("accent-ru")) if models.is_installed("accent-ru") else None
        self.watermarker = models.load_watermarker(models.model_path("watermark"))[0] if models.is_installed("watermark") else None

    def stress(self, text: str) -> str:
        """Puts "+" before stressed vowels, which the Russian model reads best.
        Text where the user already placed "+" is left as they wrote it."""
        if not text or "+" in text or self.accentizer is None:
            return text
        try:
            return self.accentizer.process_all(text)
        except Exception:  # stress marks only improve quality; never fail the re-voicing over them
            return text

    def watermark(self, piece: np.ndarray, sr: int) -> np.ndarray:
        """Adds an inaudible AudioSeal mark so the piece can later be recognised as AI-made."""
        if self.watermarker is None:
            return piece
        torch = self.torch
        x16 = _resample(piece, sr, 16000)
        with torch.inference_mode():
            wm = self.watermarker.get_watermark(torch.from_numpy(x16)[None, None], 16000,
                                                message=torch.tensor([WATERMARK]))[0, 0].numpy()
        wm = _resample(wm.astype(np.float32), 16000, sr)[:len(piece)]
        return piece + np.pad(wm, (0, len(piece) - len(wm)))

    def replace(self, source: str, tokens: list[dict], first: int, last: int, new_text: str,
                out_path: str, on_progress=None, speed: float = 1.0) -> dict:
        """Generates `new_text` in place of tokens first..last and saves just that piece,
        in the original sample rate and channel count, ready to be spliced in."""
        torch = self.torch
        sr = int(self.mel.target_sample_rate)
        hop = int(self.mel.hop_length)
        a, b = _context(tokens, first, last)
        win_start, win_end = tokens[a]["start"], tokens[b]["end"]
        cut_start, cut_end = tokens[first]["start"], tokens[last]["end"]

        full = audio.load(source, sample_rate=sr)
        window = full[int(win_start * sr):int(win_end * sr)]
        # too little of this person's speech around the edit (a short reply in a dialogue):
        # put a prepared clean sample of their voice in front
        samples = []
        if _spoken(tokens, a, first - 1) + _spoken(tokens, last + 1, b) < MIN_CONTEXT:
            samples = voice_samples(tokens, tokens[first].get("speaker"), cut_start, avoid=(a, b))
        gap = np.zeros(int(0.3 * sr), dtype=np.float32)
        sample = np.concatenate([np.concatenate([full[int(tokens[sa]["start"] * sr):int(tokens[sb]["end"] * sr)], gap])
                                 for sa, sb in samples] or [np.zeros(0, dtype=np.float32)])
        sample_text = " ".join(self.stress(spell_numbers(_words(tokens, sa, sb))) for sa, sb in samples)
        del full
        lead = len(sample) / sr
        window = np.concatenate([sample, window])

        rate = _speech_rate(tokens, a, b)
        if samples:   # little speech around the edit: the samples' pace counts too
            rate = (rate + sum(_speech_rate(tokens, sa, sb) for sa, sb in samples) / len(samples)) / 2
        spoken = spell_numbers(new_text)
        # calm pace: a hurried stretch of context mustn't make the new words rushed;
        # `speed` > 1 — faster, < 1 — slower, as the person asked
        rate = float(np.clip(rate, 9.0, 16.0))
        words = len(spoken.split())
        new_duration = float(np.clip((len(re.sub(r"\W", "", spoken)) / rate + 0.04 * words + 0.12) / speed, 0.4, 20.0))

        wav = torch.from_numpy(window.copy())[None].to(self.device)
        rms = float(torch.sqrt(torch.mean(wav ** 2)))
        if rms < TARGET_RMS:
            wav = wav * TARGET_RMS / max(rms, 1e-6)

        text = " ".join(x for x in [
            sample_text,
            self.stress(spell_numbers(_words(tokens, a, first - 1))), self.stress(spoken),
            self.stress(spell_numbers(_words(tokens, last + 1, b)))] if x)

        with torch.inference_mode():
            mel = self.model.mel_spec(wav).permute(0, 2, 1)               # (1, frames, n_mel)
            f0 = round((cut_start - win_start + lead) * sr / hop)
            f1 = round((cut_end - win_start + lead) * sr / hop)
            n_new = round(new_duration * sr / hop)
            n_mel = mel.shape[-1]
            cond = torch.cat([mel[:, :f0], torch.zeros(1, n_new, n_mel, device=self.device), mel[:, f1:]], dim=1)
            keep = torch.cat([torch.ones(1, f0, dtype=torch.bool), torch.zeros(1, n_new, dtype=torch.bool),
                              torch.ones(1, mel.shape[1] - f1, dtype=torch.bool)], dim=1).to(self.device)
            if on_progress:
                on_progress(0.1)
            generated, _ = self.model.sample(
                cond=cond, text=[text], duration=cond.shape[1], steps=STEPS,
                cfg_strength=2.0, sway_sampling_coef=-1.0, edit_mask=keep)
            if on_progress:
                on_progress(0.9)
            # decode with some voice around the new part: the margins overlap the recording
            # (crossfade), the wider part matches the loudness to the real voice there
            ref = round(LOUDNESS_REF * sr / hop)
            pre, post = min(ref, f0), min(ref, generated.shape[1] - f0 - n_new)
            wide_mel = generated[:, f0 - pre:f0 + n_new + post].to(torch.float32).permute(0, 2, 1)
            wide = self.vocoder.decode(wide_mel).squeeze().cpu().numpy().astype(np.float32)
        a_ = pre * hop
        b_ = a_ + n_new * hop
        vocoded = np.concatenate([wide[:a_], wide[b_:]])
        real = np.concatenate([window[max(0, f0 * hop - a_):f0 * hop], window[f1 * hop:f1 * hop + (len(wide) - b_)]])
        gain = 1.0
        if len(vocoded) > hop and len(real) > hop:
            gain = float(np.clip(np.sqrt(np.mean(real ** 2) / max(np.mean(vocoded ** 2), 1e-10)), 0.5, 2.0))
        m = round(MARGIN * sr / hop) * hop
        lead_n, tail_n = min(m, a_), min(m, len(wide) - b_)
        piece = wide[a_ - lead_n:b_ + tail_n] * gain
        piece = self.watermark(piece.astype(np.float32), sr)

        info = audio.probe(source)
        out = _resample(piece.astype(np.float32), sr, info["sample_rate"])
        channels = min(info["channels"], 2)
        if channels > 1:
            out = np.repeat(out[:, None], channels, axis=1)
        audio.save(out_path, out, info["sample_rate"])
        return {"path": out_path, "duration": round(n_new * hop / sr, 3), "text": new_text,
                "lead": round(lead_n / sr, 4), "tail": round(tail_n / sr, 4), "gain_db": round(20 * np.log10(gain), 2),
                "spoken": text, "replaced": [cut_start, cut_end], "watermarked": self.watermarker is not None,
                "samples": [[tokens[sa]["start"], tokens[sb]["end"]] for sa, sb in samples]}


def detect_watermark(path: str, chunk: float = 30.0) -> dict:
    """Finds where a file contains MadStudio's AI mark. Generated pieces are usually short
    parts of a long recording, so the answer is a list of marked time ranges."""
    import torch

    _, detector = models.load_watermarker(models.model_path("watermark"))
    x = audio.load(path, sample_rate=16000)
    step = int(chunk * 16000)
    frames = []
    with torch.inference_mode():
        for a in range(0, len(x), step):
            piece = torch.from_numpy(np.ascontiguousarray(x[a:a + step]))[None, None]
            if piece.shape[-1] < 1600:
                frames.append(np.zeros(piece.shape[-1]))
                continue
            result, _ = detector(piece, 16000)            # (1, 2, samples): per-sample probability
            frames.append(result[0, 1].numpy())
    prob = np.concatenate(frames) if frames else np.zeros(0)
    marked = prob > 0.5
    segments, start = [], None
    for i in range(0, len(marked), 160):                  # 10 ms steps
        on = marked[i:i + 160].mean() > 0.5
        t = i / 16000
        if on and start is None:
            start = t
        elif not on and start is not None:
            if t - start >= MIN_MARKED:
                segments.append([round(start, 2), round(t, 2)])
            start = None
    if start is not None and len(marked) / 16000 - start >= MIN_MARKED:
        segments.append([round(start, 2), round(len(marked) / 16000, 2)])
    return {"madstudio": bool(segments), "segments": segments}


def _resample(x: np.ndarray, src: int, dst: int) -> np.ndarray:
    if src == dst:
        return x
    import torch
    import torchaudio.functional as F

    return F.resample(torch.from_numpy(x), src, dst).numpy()
