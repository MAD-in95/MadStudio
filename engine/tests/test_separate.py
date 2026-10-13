import numpy as np

from madstudio_engine import separate


class FakeSeparator(separate.Separator):
    """Splits by a known rule (left channel = voice) to test the piecewise processing."""

    def __init__(self):
        self.sr = 1000

    def _split(self, x):
        voice = np.zeros_like(x)
        voice[:, 0] = x[:, 0]
        return voice, x - voice


def test_long_audio_is_processed_in_pieces_without_seams(tmp_path, monkeypatch):
    from madstudio_engine import audio
    monkeypatch.setattr(separate, "PIECE", 3.0)
    monkeypatch.setattr(separate, "OVERLAP", 0.5)
    sr = 1000
    t = np.arange(10 * sr) / sr
    x = np.stack([np.sin(2 * np.pi * 3 * t), 0.5 * np.cos(2 * np.pi * 5 * t)], axis=1).astype(np.float32)
    src = tmp_path / "in.wav"
    audio.save(str(src), x, sr)
    result = FakeSeparator().run(str(src), str(tmp_path / "v.wav"), str(tmp_path / "b.wav"))
    v = audio.load(result["voice"], sample_rate=sr, channels=2)
    b = audio.load(result["background"], sample_rate=sr, channels=2)
    assert len(v) == len(x)
    assert np.abs(v[:, 0] - x[:, 0]).max() < 1e-3
    assert np.abs(b[:, 1] - x[:, 1]).max() < 1e-3
