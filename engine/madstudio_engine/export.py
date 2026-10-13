"""Builds the edited recording from the kept time ranges of the original.

Works as a stream: the original is never loaded into memory whole, so 3-hour
recordings are fine on 8 GB. Joins get a short crossfade so cuts don't click.
"""

import json
import subprocess

import numpy as np

from . import audio
from .i18n import tr

CROSSFADE = 0.01  # seconds
BLOCK = 1 << 18   # frames read at a time


class _Joiner:
    """Writes blocks to the encoder, crossfading where two cuts meet."""

    def __init__(self, sink, xf: int, channels: int):
        self.sink, self.xf = sink, xf
        self.tail = np.zeros((0, channels), dtype=np.float32)

    def add(self, block: np.ndarray, join: bool) -> None:
        if join and len(self.tail) and len(block):
            n = min(self.xf, len(self.tail), len(block))
            t = np.linspace(0, np.pi / 2, n, dtype=np.float32)[:, None]
            mixed = self.tail[-n:] * np.cos(t) + block[:n] * np.sin(t)
            buf = np.concatenate([self.tail[:-n], mixed, block[n:]])
        else:
            buf = np.concatenate([self.tail, block])
        keep = min(self.xf, len(buf))
        self.sink(buf[:len(buf) - keep])
        self.tail = buf[len(buf) - keep:]

    def close(self) -> None:
        self.sink(self.tail)


# loudness targets of platforms, LUFS (integrated loudness)
PRESETS = {
    "youtube": -14.0,     # YouTube, VK Video, Telegram, Instagram, TikTok
    "podcast": -16.0,     # Apple Podcasts, Spotify, Яндекс Музыка
    "broadcast": -23.0,   # radio and TV (EBU R128)
}
TRUE_PEAK = -1.5


def render(source: str, segments: list, out_path: str, on_progress=None, loudness: float | None = None) -> dict:
    """segments: in playback order; each is [start, end] of the original, or
    {"file": path, "start": s, "end": e} for a generated piece (re-voiced words).
    Original parts must go forward in time — they are read as one stream.
    loudness: target LUFS; the edited audio is measured first, then brought to the
    target in one linear step (speech dynamics stay as they are)."""
    info = audio.probe(source)
    sr, ch = info["sample_rate"], min(info["channels"], 2)
    plan = []
    for seg in segments:
        if isinstance(seg, dict) and seg.get("file"):
            plan.append(("file", seg["file"]))
        else:
            s, e = (seg["start"], seg["end"]) if isinstance(seg, dict) else seg
            if e > s:
                plan.append(("orig", (max(0, round(s * sr)), round(e * sr))))

    codec = {".mp3": ["-b:a", "192k"], ".m4a": ["-c:a", "aac", "-b:a", "192k"]}
    ext = out_path[out_path.rfind("."):].lower()
    encode = [*codec.get(ext, []), "-ar", str(sr), out_path]

    if loudness is None:
        written, _ = _stream(source, plan, sr, ch, encode, on_progress)
        return {"path": out_path, "duration": round(written / sr, 3)}

    passes = 2
    step = lambda k: (lambda v: on_progress((k + v) / passes)) if on_progress else None
    m = _measure(source, plan, sr, ch, None, loudness, step(0))

    # Bring the loudness to the target with one volume change. If that pushes rare loud
    # peaks over the limit, a fast limiter shaves just those peaks; shaving lowers the
    # loudness a bit, so it is measured again and the volume corrected (up to twice).
    gain = loudness - m["input_i"]
    linear = m["input_tp"] + gain <= TRUE_PEAK
    limit = 10 ** ((TRUE_PEAK - 0.5) / 20)   # a little margin: true peaks sit between samples
    chain = lambda g: f"volume={g:.2f}dB" if linear else \
        f"volume={g:.2f}dB,alimiter=limit={limit:.3f}:attack=5:release=50:level=false"
    if not linear:
        passes = 4
        for k in (1, 2):
            got = _measure(source, plan, sr, ch, chain(gain), loudness, step(k))["input_i"]
            if abs(got - loudness) < 0.3:
                break
            gain += loudness - got
    written, _ = _stream(source, plan, sr, ch, ["-af", chain(gain), *encode], step(passes - 1))
    return {"path": out_path, "duration": round(written / sr, 3), "loudness_before": m["input_i"],
            "linear": linear}


def _measure(source, plan, sr, ch, chain, loudness, on_progress) -> dict:
    """Loudness (LUFS) and true peak of the edited audio, optionally after a filter chain."""
    analyse = f"loudnorm=I={loudness}:TP={TRUE_PEAK}:LRA=11:print_format=json"
    af = f"{chain},{analyse}" if chain else analyse
    _, log = _stream(source, plan, sr, ch, ["-af", af, "-f", "null", "-"], on_progress, verbose=True)
    m = json.loads(log[log.rindex("{"):log.rindex("}") + 1])
    return {"input_i": float(m["input_i"]), "input_tp": float(m["input_tp"])}


def _stream(source, plan, sr, ch, writer_args, on_progress=None, verbose=False) -> tuple[int, str]:
    """Plays the plan into an ffmpeg process with writer_args. Returns frames written and
    ffmpeg's log (needed when measuring loudness)."""
    frame_bytes = 4 * ch
    spans = [p for kind, p in plan if kind == "orig"]
    reader = subprocess.Popen(
        ["ffmpeg", "-v", "error", "-nostdin", "-i", source, "-f", "f32le", "-ac", str(ch), "-ar", str(sr), "-"],
        stdout=subprocess.PIPE)
    log_level = ["-hide_banner", "-nostats", "-v", "info"] if verbose else ["-v", "error"]
    writer = subprocess.Popen(
        ["ffmpeg", *log_level, "-nostdin", "-y", "-f", "f32le", "-ac", str(ch), "-ar", str(sr), "-i", "-",
         *writer_args],
        stdin=subprocess.PIPE, stderr=subprocess.PIPE if verbose else None)

    pos = 0
    total_in = max(spans[-1][1], 1) if spans else 1
    written = 0

    def read(n: int) -> np.ndarray:
        nonlocal pos
        chunks, need = [], n * frame_bytes
        while need > 0:
            data = reader.stdout.read(need)
            if not data:
                break
            chunks.append(data)
            need -= len(data)
        arr = np.frombuffer(b"".join(chunks), dtype=np.float32).reshape(-1, ch)
        pos += len(arr)
        return arr

    def sink(block: np.ndarray) -> None:
        nonlocal written
        writer.stdin.write(np.ascontiguousarray(block).tobytes())
        written += len(block)

    joiner = _Joiner(sink, round(CROSSFADE * sr), ch)
    prev_end = None
    log = ""
    try:
        for kind, item in plan:
            if kind == "file":
                piece = audio.load(item, sample_rate=sr, channels=ch)
                joiner.add(piece.reshape(-1, ch), join=True)
                prev_end = None
                continue
            start, end = item
            while pos < start:                      # skip what was cut
                if not len(read(min(BLOCK, start - pos))):
                    break
            join = prev_end is None and written > 0 or (prev_end is not None and start != prev_end)
            while pos < end:
                block = read(min(BLOCK, end - pos))
                if not len(block):
                    break
                joiner.add(block, join)
                join = False
                if on_progress:
                    on_progress(pos / total_in)
            prev_end = end
        joiner.close()
    finally:
        reader.stdout.close()
        reader.kill()
        reader.wait()
        writer.stdin.close()
        if verbose:
            log = writer.stderr.read().decode("utf-8", "replace")
        writer.wait()
    if writer.returncode != 0:
        raise RuntimeError(tr("ffmpeg не смог записать файл"))
    return written, log
