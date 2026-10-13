"""Splits a recording into the voice and everything else (music, noises, room) with
HTDemucs. Long recordings are processed in pieces so memory stays small on an 8 GB Mac."""

import numpy as np

from . import audio, models

PIECE = 300.0     # seconds processed at once
OVERLAP = 2.0     # seconds shared by neighbouring pieces, crossfaded


class Separator:
    def __init__(self):
        import torch
        from demucs.hf import load_safetensors_model

        self.torch = torch
        folder = models.require(models.default_for("separate"))
        weights = next(folder.glob("*.safetensors"))
        self.model = load_safetensors_model(str(weights)).eval()
        self.sr = self.model.samplerate
        self.device = "mps" if torch.backends.mps.is_available() else "cpu"
        self.voice_index = self.model.sources.index("vocals")

    def _split(self, x: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        """x: (samples, 2) -> voice, background (same shape)."""
        from demucs.apply import apply_model

        torch = self.torch
        wav = torch.from_numpy(np.ascontiguousarray(x.T))
        ref = wav.mean(0)
        mean, std = ref.mean(), ref.std() + 1e-8
        with torch.inference_mode():
            out = apply_model(self.model, ((wav - mean) / std)[None], device=self.device,
                              split=True, overlap=0.25, progress=False)[0]
        out = out * std + mean
        voice = out[self.voice_index]
        background = out.sum(0) - voice
        return voice.numpy().T, background.numpy().T

    def run(self, source: str, voice_path: str, background_path: str, on_progress=None) -> dict:
        x = audio.load(source, sample_rate=self.sr, channels=2)
        n = len(x)
        piece, overlap = int(PIECE * self.sr), int(OVERLAP * self.sr)
        voice = np.zeros_like(x)
        background = np.zeros_like(x)
        start = 0
        while start < n:
            end = min(n, start + piece + overlap)
            v, b = self._split(x[start:end])
            if start > 0:  # fade the shared part between the previous piece and this one
                k = min(overlap, len(v))
                fade = np.linspace(0, 1, k, dtype=np.float32)[:, None]
                voice[start:start + k] = voice[start:start + k] * (1 - fade) + v[:k] * fade
                background[start:start + k] = background[start:start + k] * (1 - fade) + b[:k] * fade
                voice[start + k:end], background[start + k:end] = v[k:], b[k:]
            else:
                voice[start:end], background[start:end] = v, b
            if on_progress:
                on_progress(min(1.0, end / n))
            if end == n:
                break
            start = end - overlap
        audio.save(voice_path, voice, self.sr)
        audio.save(background_path, background, self.sr)
        return {"voice": voice_path, "background": background_path, "duration": round(n / self.sr, 3)}

