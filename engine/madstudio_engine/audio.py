"""Reading and writing audio through ffmpeg."""

import json
import subprocess

import numpy as np

from .i18n import tr

SAMPLE_RATE = 16000  # what speech models expect


def probe(path: str) -> dict:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "a:0",
         "-show_entries", "stream=sample_rate,channels:format=duration", "-of", "json", path],
        capture_output=True, text=True, check=True,
    ).stdout
    info = json.loads(out)
    stream = info["streams"][0]
    return {
        "duration": float(info["format"]["duration"]),
        "sample_rate": int(stream["sample_rate"]),
        "channels": int(stream["channels"]),
    }


def load(path: str, sample_rate: int = SAMPLE_RATE, channels: int = 1) -> np.ndarray:
    """Decode any audio file to float32; shape (samples,) for mono, (samples, channels) otherwise."""
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-nostdin", "-i", path,
         "-f", "f32le", "-ac", str(channels), "-ar", str(sample_rate), "-"],
        capture_output=True, check=True,
    ).stdout
    data = np.frombuffer(raw, dtype=np.float32)
    return data if channels == 1 else data.reshape(-1, channels)


def save(path: str, data: np.ndarray, sample_rate: int) -> None:
    """Encode float32 audio; the format follows the file extension (.wav, .mp3, .m4a, .flac)."""
    channels = 1 if data.ndim == 1 else data.shape[1]
    codec = {".mp3": ["-b:a", "192k"], ".m4a": ["-c:a", "aac", "-b:a", "192k"]}
    ext = path[path.rfind("."):].lower()
    subprocess.run(
        ["ffmpeg", "-v", "error", "-nostdin", "-y",
         "-f", "f32le", "-ac", str(channels), "-ar", str(sample_rate), "-i", "-",
         *codec.get(ext, []), path],
        input=np.ascontiguousarray(data, dtype=np.float32).tobytes(), check=True,
    )


LOUDNESS_RATE = 20  # values per second


def loudness(samples: np.ndarray, sr: int = SAMPLE_RATE) -> bytes:
    """Waveform overview for the app: RMS of every 1/20 s in dB, -50…0 dB -> 0…255."""
    window = sr // LOUDNESS_RATE
    n = len(samples) // window
    frames = samples[:n * window].reshape(n, window).astype(np.float64)
    tail = samples[n * window:]
    rms = np.sqrt(np.mean(frames ** 2, axis=1))
    if len(tail):
        rms = np.append(rms, np.sqrt(np.mean(tail.astype(np.float64) ** 2)))
    level = np.clip((20 * np.log10(rms + 1e-6) + 50) / 50, 0, 1)
    return (level * 255).astype(np.uint8).tobytes()


# audio codecs that can be copied as is into a container macOS plays; others become FLAC
_COPY = {"aac": ".m4a", "alac": ".m4a", "mp3": ".mp3"}


def extract(source: str, out_base: str) -> str:
    """Takes the sound out of a video (or an audio format macOS can't play) without
    losing quality: copies the audio stream when possible, otherwise converts to FLAC.
    `out_base` is the output path without extension; returns the file written."""
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries", "stream=codec_name",
         "-of", "csv=p=0", source], capture_output=True, text=True)
    codec = out.stdout.strip()
    if not codec:
        raise RuntimeError(tr("В этом файле нет звуковой дорожки"))
    ext = _COPY.get(codec, ".flac")
    path = out_base + ext
    args = ["-c:a", "copy"] if codec in _COPY else ["-c:a", "flac"]
    subprocess.run(["ffmpeg", "-v", "error", "-nostdin", "-y", "-i", source, "-vn", "-map", "0:a:0", *args, path],
                   check=True)
    return path
