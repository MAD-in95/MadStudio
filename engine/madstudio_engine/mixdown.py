"""Multitrack mixdown: several tracks of clips into one file.

Every clip is a piece of some audio file placed at a time of the result, with its own
volume and soft edges; every track has a volume; a music track can duck (get quieter)
while someone speaks. Sources are decoded once into temporary files that are read in
pieces, so long projects fit into 8 GB.
"""

import json
import os
import subprocess
import tempfile

import numpy as np

from . import audio
from .export import PRESETS, TRUE_PEAK

BLOCK = 30.0          # seconds of the result mixed at a time
EDGE_FADE = 0.005     # every clip edge fades this much: cuts never click
DUCK_ATTACK = 0.25    # music goes down this fast when speech starts...
DUCK_RELEASE = 0.8    # ...and comes back this slowly after it
DUCK_HOLD = 0.4       # gaps in speech shorter than this keep the music down


def db(value: float) -> float:
    return 10 ** (value / 20)


class _Sources:
    """Decoded sources as float32 files on disk, read by position (memory-mapped)."""

    def __init__(self, sr: int, ch: int, folder: str):
        self.sr, self.ch, self.folder, self.maps = sr, ch, folder, {}

    def get(self, path: str) -> np.ndarray:
        if path not in self.maps:
            raw = os.path.join(self.folder, f"{len(self.maps)}.f32")
            with open(raw, "wb") as f:
                subprocess.run(["ffmpeg", "-v", "error", "-nostdin", "-i", path, "-f", "f32le",
                                "-ac", str(self.ch), "-ar", str(self.sr), "-"], stdout=f, check=True)
            size = os.path.getsize(raw) // (4 * self.ch)
            self.maps[path] = np.memmap(raw, dtype=np.float32, mode="r", shape=(size, self.ch)) if size else \
                np.zeros((0, self.ch), dtype=np.float32)
        return self.maps[path]


def duck_envelope(speech: list[list[float]], t0: float, n: int, sr: int, depth_db: float) -> np.ndarray:
    """Gain (0…1) for a stretch of n samples starting at t0: 1 in silence, depth during speech."""
    target = np.ones(n, dtype=np.float32)
    low = db(-abs(depth_db))
    merged = []
    for a, b in sorted(speech):
        if merged and a - merged[-1][1] < DUCK_HOLD:
            merged[-1][1] = max(merged[-1][1], b)
        else:
            merged.append([a, b])
    margin = max(DUCK_ATTACK, DUCK_RELEASE) + 1
    for a, b in merged:
        if b < t0 - margin or a > t0 + n / sr + margin:
            continue
        # ramp down before speech starts, back up after it ends
        i0, i1 = int((a - DUCK_ATTACK - t0) * sr), int((a - t0) * sr)
        j0, j1 = int((b - t0) * sr), int((b + DUCK_RELEASE - t0) * sr)
        ramp_down = np.linspace(1, low, max(i1 - i0, 1), dtype=np.float32)
        ramp_up = np.linspace(low, 1, max(j1 - j0, 1), dtype=np.float32)
        for start, values in ((i0, ramp_down), (j0, ramp_up)):
            lo, hi = max(start, 0), min(start + len(values), n)
            if lo < hi:
                target[lo:hi] = np.minimum(target[lo:hi], values[lo - start:hi - start])
        lo, hi = max(i1, 0), min(j0, n)
        if lo < hi:
            target[lo:hi] = np.minimum(target[lo:hi], low)
    return target


def mix(plan: dict, out_path: str, on_progress=None) -> dict:
    """plan = {"sample_rate", "channels", "duration", "loudness"?: preset or LUFS,
               "tracks": [{"gain_db", "clips": [{"file", "src", "length", "at",
                           "gain_db"?, "fade_in"?, "fade_out"?}], "duck"?: {"depth_db", "speech": [[a, b]]}}]}"""
    sr, ch = int(plan["sample_rate"]), int(plan.get("channels", 2))
    total = int(round(plan["duration"] * sr))
    block = int(BLOCK * sr)
    with tempfile.TemporaryDirectory() as tmp:
        sources = _Sources(sr, ch, tmp)
        mixed_path = os.path.join(tmp, "mix.f32")
        mixed = np.memmap(mixed_path, dtype=np.float32, mode="w+", shape=(max(total, 1), ch))
        tracks = [t for t in plan["tracks"] if t.get("clips")]
        for b0 in range(0, total, block):
            n = min(block, total - b0)
            out = np.zeros((n, ch), dtype=np.float32)
            for track in tracks:
                lane = np.zeros((n, ch), dtype=np.float32)
                for c in track["clips"]:
                    at, length = int(round(c["at"] * sr)), int(round(c["length"] * sr))
                    lo, hi = max(at, b0), min(at + length, b0 + n)
                    if lo >= hi:
                        continue
                    data = sources.get(c["file"])
                    s0 = int(round(c.get("src", 0) * sr)) + (lo - at)
                    piece = np.array(data[s0:s0 + (hi - lo)], dtype=np.float32)
                    if len(piece) < hi - lo:
                        piece = np.pad(piece, ((0, hi - lo - len(piece)), (0, 0)))
                    pos = np.arange(lo, hi) - at                       # sample index inside the clip
                    fade_in = max(int(c.get("fade_in", 0) * sr), int(EDGE_FADE * sr), 1)
                    fade_out = max(int(c.get("fade_out", 0) * sr), int(EDGE_FADE * sr), 1)
                    gain = np.minimum(1, np.minimum((pos + 1) / fade_in, (length - pos) / fade_out))
                    piece *= (gain * db(c.get("gain_db", 0)))[:, None]
                    lane[lo - b0:hi - b0] += piece
                if track.get("duck"):
                    env = duck_envelope(track["duck"]["speech"], b0 / sr, n, sr, track["duck"].get("depth_db", 12))
                    lane *= env[:, None]
                out += lane * db(track.get("gain_db", 0))
            mixed[b0:b0 + n] = out
            if on_progress:
                on_progress(0.8 * min(1.0, (b0 + n) / max(total, 1)))
        mixed.flush()

        chain = _loudness_chain(mixed_path, sr, ch, plan.get("loudness"))
        codec = {".mp3": ["-b:a", "192k"], ".m4a": ["-c:a", "aac", "-b:a", "192k"]}
        ext = os.path.splitext(out_path)[1].lower()
        subprocess.run(["ffmpeg", "-v", "error", "-nostdin", "-y", "-f", "f32le", "-ac", str(ch), "-ar", str(sr),
                        "-i", mixed_path, *(["-af", chain] if chain else []), *codec.get(ext, []),
                        "-ar", str(sr), out_path], check=True)
        if on_progress:
            on_progress(1.0)
    return {"path": out_path, "duration": round(total / sr, 3)}


def _measure(raw: str, sr: int, ch: int, chain: str | None) -> dict:
    af = (chain + "," if chain else "") + "loudnorm=print_format=json"
    log = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-f", "f32le", "-ac", str(ch), "-ar", str(sr),
                          "-i", raw, "-af", af, "-f", "null", "-"], capture_output=True, text=True).stderr
    m = json.loads(log[log.rindex("{"):log.rindex("}") + 1])
    return {"i": float(m["input_i"]), "tp": float(m["input_tp"])}


def _loudness_chain(raw: str, sr: int, ch: int, target) -> str | None:
    """Same method as the single-track export: one volume change, a limiter for rare
    peaks, measured again and corrected."""
    if target in (None, "none"):
        return None
    loudness = PRESETS.get(target, target)
    m = _measure(raw, sr, ch, None)
    if m["i"] < -70:
        return None   # silence
    gain = loudness - m["i"]
    if m["tp"] + gain <= TRUE_PEAK:
        return f"volume={gain:.2f}dB"
    limit = db(TRUE_PEAK - 0.5)
    chain = lambda g: f"volume={g:.2f}dB,alimiter=limit={limit:.3f}:attack=5:release=50:level=false"
    # the limiter eats part of every extra dB (on short or dense pieces up to 2/3 of it):
    # learn how much from the previous try and step accordingly
    previous = None
    for _ in range(4):
        got = _measure(raw, sr, ch, chain(gain))["i"]
        if abs(got - loudness) < 0.2:
            break
        slope = 1.0
        if previous and abs(got - previous[1]) > 0.05:
            slope = min(max((gain - previous[0]) / (got - previous[1]), 1.0), 4.0)
        previous = (gain, got)
        gain += (loudness - got) * slope
    return chain(gain)
