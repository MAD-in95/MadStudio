import numpy as np

from madstudio_engine import audio
from madstudio_engine.voicefx import process


def test_radio_voice_keeps_timing(tmp_path):
    sr = 48000
    rng = np.random.default_rng(0)
    x = np.zeros(sr * 3, dtype=np.float32)
    x[sr:sr + 4800] = 0.5 * rng.standard_normal(4800)          # a click at exactly 1.0 s
    src = tmp_path / "in.wav"
    audio.save(str(src), x, sr)
    out = tmp_path / "out.flac"
    process(str(src), str(out), radio=True)
    y = audio.load(str(out), sample_rate=sr)
    onset = int(np.argmax(np.abs(y) > 0.05))
    assert abs(onset - sr) < sr * 0.002                        # within 2 ms
