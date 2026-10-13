"""Speech to text with a timing for every word."""

import contextlib
import io
import re
import sys
import time

from . import audio, events, markers, models, repeats

# Transcript format version. Older transcripts are upgraded by `reanalyze` (no re-transcription).
# 2: failed takes ("take") are marked.
VERSION = 2

# Makes Whisper write speech verbatim: keeps "ну", "вот", "значит" and repeats
# instead of tidying them away.
VERBATIM_PROMPT = "Ээ, ну, вот... Мм, значит, эээ, как бы это сказать... Эм, ну да."


class _ProgressBar:
    """Stands in for tqdm inside mlx_whisper to forward its progress to us."""

    def __init__(self, on_progress, total=None, **_):
        self.total, self.n, self.on_progress = total or 1, 0, on_progress

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def update(self, n=1):
        self.n += n
        self.on_progress(self.n / self.total)


class _SegmentPrinter(io.TextIOBase):
    """mlx_whisper prints "[00:01.000 --> 00:04.000] text" when verbose; we catch those lines."""

    LINE = re.compile(r"^\[(\d+):(\d+\.\d+) --> (\d+):(\d+\.\d+)\]\s*(.*)$")

    def __init__(self, on_partial):
        self.on_partial, self.buffer = on_partial, ""

    def write(self, s):
        self.buffer += s
        while "\n" in self.buffer:
            line, self.buffer = self.buffer.split("\n", 1)
            m = self.LINE.match(line.strip())
            if m and self.on_partial:
                start = int(m[1]) * 60 + float(m[2])
                self.on_partial(start, m[5])
        return len(s)


def detect_language(samples, model_dir) -> str:
    """The language of a recording, heard from 30 s in its middle (the start is often music)."""
    import mlx.core as mx
    from mlx_whisper.audio import N_FRAMES, N_SAMPLES, log_mel_spectrogram, pad_or_trim
    from mlx_whisper.transcribe import ModelHolder

    model = ModelHolder.get_model(str(model_dir), mx.float16)
    if not model.is_multilingual:
        return "en"
    sr, mid = audio.SAMPLE_RATE, len(samples) // 2
    piece = samples[max(0, mid - 15 * sr):mid + 15 * sr]
    mel = log_mel_spectrogram(piece, n_mels=model.dims.n_mels, padding=N_SAMPLES)
    _, probs = model.detect_language(pad_or_trim(mel, N_FRAMES, axis=-2).astype(mx.float16))
    return max(probs, key=probs.get)


def transcribe(path: str, model_id: str | None = None, on_progress=None, on_partial=None,
               language: str | None = None) -> dict:
    import mlx_whisper
    whisper_module = sys.modules["mlx_whisper.transcribe"]

    report = on_progress or (lambda stage, value: None)
    model_id = model_id or models.default_for("transcribe")
    model_dir = models.require(model_id)

    started = time.time()
    report("decode", 0.0)
    samples = audio.load(path)
    duration = len(samples) / audio.SAMPLE_RATE
    report("decode", 1.0)
    # Russian gets the full treatment (exact word borders, «э-э» check, stress marks);
    # other languages are transcribed as they are (for example, to translate into Russian)
    language = language or detect_language(samples, model_dir)

    # Long recordings are transcribed piece by piece (cut in quiet places): Whisper keeps
    # the whole piece in memory, and 3 hours at once took 4 GB of the 8 GB Mac.
    pieces = split_points(samples, audio.SAMPLE_RATE)
    segments, context = [], ""
    original_tqdm = whisper_module.tqdm
    try:
        for n, (a, b) in enumerate(pieces):
            offset = a / audio.SAMPLE_RATE
            part = lambda v, n=n: report("transcribe", (n + v) / len(pieces))
            bar = lambda *args, part=part, **kw: _ProgressBar(part, *args, **kw)
            whisper_module.tqdm = type("tqdm_shim", (), {"tqdm": staticmethod(bar)})
            partial = (lambda start, text, o=offset: on_partial(start + o, text)) if on_partial else None
            with events.pinned_stdout(), contextlib.redirect_stdout(_SegmentPrinter(partial)):
                result = mlx_whisper.transcribe(
                    samples[a:b],
                    path_or_hf_repo=str(model_dir),
                    language=language,
                    word_timestamps=True,
                    # the end of the previous piece keeps names and style consistent
                    # an empty prompt makes Whisper add a stray "!" after sentences: None instead
                    initial_prompt=((VERBATIM_PROMPT if language == "ru" else "") + " " + context).strip() or None,
                    hallucination_silence_threshold=2.0,
                    verbose=True,
                )
            for seg in result["segments"]:
                for w in seg.get("words", []):
                    w["start"] += offset
                    w["end"] += offset
                segments.append(seg)
            context = " ".join(result["text"].split()[-40:])
    finally:
        whisper_module.tqdm = original_tqdm
    result = {"segments": segments}
    report("transcribe", 1.0)
    _unload_whisper(whisper_module)

    words = [
        {"text": w["word"].strip(), "start": float(w["start"]), "end": float(w["end"]),
         "prob": round(float(w["probability"]), 3)}
        for seg in result["segments"] for w in seg.get("words", []) if w["word"].strip()
    ]
    align_model = _installed("align") if language == "ru" else None
    aligner = None
    if align_model and words:
        from .align import Aligner
        report("align", 0.0)
        aligner = Aligner(str(models.model_path(align_model)))
        words = aligner.align(words, samples, audio.SAMPLE_RATE, on_progress=lambda v: report("align", v))
        report("align", 1.0)

    report("analyze", 0.0)
    tokens = markers.build_tokens(words, samples, audio.SAMPLE_RATE,
                                  hear=aligner.hear if aligner else None)
    del aligner
    report("analyze", 1.0)

    speaker_info = None
    if _installed("speakers"):
        report("speakers", 0.0)
        speaker_info = find_speakers(tokens, samples, on_progress=lambda v: report("speakers", v))
        report("speakers", 1.0)
    repeats.mark(tokens)

    return {
        "version": VERSION,
        "source": path,
        "duration": round(duration, 3),
        "language": language,
        "model": model_id,
        "aligned": bool(align_model and words),
        "seconds_spent": round(time.time() - started, 1),
        "speakers": speaker_info,
        "tokens": tokens,
    }


def _installed(task: str) -> str | None:
    try:
        model_id = models.default_for(task)
    except KeyError:
        return None
    return model_id if models.is_installed(model_id) else None


def _unload_whisper(whisper_module) -> None:
    """Frees Whisper's memory before the next model loads (matters on 8 GB)."""
    import gc

    import mlx.core as mx

    holder = getattr(whisper_module, "ModelHolder", None)
    if holder is not None:
        holder.model = None
        holder.model_path = None
    gc.collect()
    mx.clear_cache()


def reanalyze(path: str) -> dict:
    """Re-runs the text-only analyses on an existing transcript and saves it."""
    import json

    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    takes = repeats.mark(data["tokens"])
    data["version"] = VERSION
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    return {"path": path, "takes": takes}


def find_speakers(tokens: list[dict], samples, on_progress=None) -> dict:
    from .speakers import SpeakerModel, assign

    model = SpeakerModel(str(models.model_path(models.default_for("speakers"))))
    return assign(tokens, samples, audio.SAMPLE_RATE, model, on_progress=on_progress)


def speakers_for(path: str, source: str, on_progress=None) -> dict:
    """Adds speakers to an existing transcript (and re-checks failed takes with them)."""
    import json

    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    info = find_speakers(data["tokens"], audio.load(source), on_progress=on_progress)
    repeats.mark(data["tokens"])
    data["speakers"] = info
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    return info


PIECE = 600.0        # seconds of audio Whisper gets at once
SEARCH = 60.0        # look this far back from the piece end for a quiet place to cut


def split_points(samples, sr: int, piece: float = PIECE, search: float = SEARCH) -> list[tuple[int, int]]:
    """Cuts a recording into pieces of about `piece` seconds, each cut in the quietest
    50 ms within the last `search` seconds (a pause between words, never mid-word)."""
    import numpy as np

    total = len(samples)
    if total <= int(piece * 1.5 * sr):
        return [(0, total)]
    win = int(0.05 * sr)
    cuts, start = [], 0
    while total - start > int(piece * 1.5 * sr):
        lo, hi = start + int((piece - search) * sr), start + int(piece * sr)
        n = (hi - lo) // win
        frames = samples[lo:lo + n * win].reshape(n, win)
        quiet = int(np.argmin((frames.astype(np.float64) ** 2).mean(axis=1)))
        cut = lo + quiet * win + win // 2
        cuts.append((start, cut))
        start = cut
    cuts.append((start, total))
    return cuts
