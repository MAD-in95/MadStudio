import numpy as np
import pytest

SR = 16000


@pytest.fixture(autouse=True)
def isolated_home(tmp_path, monkeypatch):
    monkeypatch.setenv("MADSTUDIO_HOME", str(tmp_path / "home"))


def tone(seconds, amp=0.3, freq=150.0, sr=SR):
    t = np.arange(int(seconds * sr)) / sr
    return (amp * np.sin(2 * np.pi * freq * t)).astype(np.float32)


def noise(seconds, amp, sr=SR, seed=0):
    return (amp * np.random.default_rng(seed).standard_normal(int(seconds * sr))).astype(np.float32)


def silence(seconds, sr=SR):
    return np.zeros(int(seconds * sr), dtype=np.float32)
