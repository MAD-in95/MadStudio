import json

import numpy as np

from madstudio_engine import audio
from madstudio_engine.mixdown import duck_envelope, mix


def tone(path, seconds, freq, sr=16000, amp=0.3):
    t = np.arange(int(seconds * sr)) / sr
    audio.save(str(path), (amp * np.sin(2 * np.pi * freq * t)).astype(np.float32), sr)


def test_clips_land_where_placed_with_track_volume(tmp_path):
    tone(tmp_path / "a.wav", 3, 200)
    tone(tmp_path / "b.wav", 3, 300)
    plan = {"sample_rate": 16000, "channels": 1, "duration": 4.0, "tracks": [
        {"gain_db": 0, "clips": [{"file": str(tmp_path / "a.wav"), "src": 1.0, "length": 1.0, "at": 0.0}]},
        {"gain_db": -6, "clips": [{"file": str(tmp_path / "b.wav"), "src": 0.0, "length": 1.0, "at": 2.0}]},
    ]}
    result = mix(plan, str(tmp_path / "out.wav"))
    assert abs(result["duration"] - 4.0) < 1e-6
    out = audio.load(str(tmp_path / "out.wav"))
    rms = lambda a, b: float(np.sqrt(np.mean(out[int(a * 16000):int(b * 16000)] ** 2)))
    assert rms(0.1, 0.9) > 0.15                     # first clip
    assert rms(1.1, 1.9) < 1e-3                     # nothing between
    assert abs(rms(2.1, 2.9) / rms(0.1, 0.9) - 0.5) < 0.05   # -6 dB track


def test_music_ducks_under_speech():
    env = duck_envelope([[2.0, 4.0]], 0.0, 8 * 100, 100, depth_db=12)
    assert env[100] == 1.0                          # 1 s: before speech
    assert abs(env[300] - 10 ** (-12 / 20)) < 1e-3   # 3 s: during speech
    assert env[600] == 1.0                          # 6 s: well after


def test_loudness_target_in_mixdown(tmp_path):
    tone(tmp_path / "quiet.wav", 6, 220, sr=48000, amp=0.02)
    plan = {"sample_rate": 48000, "channels": 2, "duration": 6.0, "loudness": "podcast", "tracks": [
        {"gain_db": 0, "clips": [{"file": str(tmp_path / "quiet.wav"), "src": 0, "length": 6, "at": 0}]}]}
    mix(plan, str(tmp_path / "out.wav"))
    import subprocess
    log = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", str(tmp_path / "out.wav"), "-af",
                          "loudnorm=print_format=json", "-f", "null", "-"], capture_output=True, text=True).stderr
    measured = float(json.loads(log[log.rindex("{"):log.rindex("}") + 1])["input_i"])
    assert abs(measured - (-16)) < 1.0
