import numpy as np

from madstudio_engine import audio
from madstudio_engine.export import render


def test_cuts_and_joins_without_clicks(tmp_path):
    sr = 44100
    t = np.arange(3 * sr) / sr
    left = 0.5 * np.sin(2 * np.pi * 220 * t)
    right = 0.5 * np.sin(2 * np.pi * 330 * t)
    source = tmp_path / "in.wav"
    audio.save(str(source), np.stack([left, right], axis=1).astype(np.float32), sr)

    out = tmp_path / "out.wav"
    result = render(str(source), [[0.0, 1.0], [2.0, 3.0]], str(out))

    assert abs(result["duration"] - 1.99) < 0.005
    data = audio.load(str(out), sample_rate=sr, channels=2)
    assert abs(len(data) / sr - 1.99) < 0.005
    jumps = np.abs(np.diff(data, axis=0)).max()
    assert jumps < 0.1  # a hard cut between unrelated phases would jump much more


def test_contiguous_ranges_are_joined_seamlessly(tmp_path):
    sr = 16000
    source = tmp_path / "in.wav"
    audio.save(str(source), (0.3 * np.sin(np.arange(2 * sr) / 10)).astype(np.float32), sr)
    out = tmp_path / "out.mp3"
    result = render(str(source), [[0.0, 0.5], [0.5, 2.0]], str(out))
    assert abs(result["duration"] - 2.0) < 0.001
    assert out.stat().st_size > 1000


def test_generated_piece_is_spliced_in(tmp_path):
    sr = 16000
    source = tmp_path / "in.wav"
    audio.save(str(source), np.full(2 * sr, 0.1, dtype=np.float32), sr)
    piece = tmp_path / "piece.wav"
    audio.save(str(piece), np.full(sr // 2, -0.1, dtype=np.float32), sr)
    out = tmp_path / "out.wav"
    segments = [[0.0, 0.5], {"file": str(piece), "start": 0, "end": 0.5}, [1.0, 2.0]]
    result = render(str(source), segments, str(out))
    # 0.5 + 0.5 + 1.0 seconds minus two 10 ms crossfades
    assert abs(result["duration"] - 1.98) < 0.005
    data = audio.load(str(out), sample_rate=sr)
    assert data[int(0.7 * sr)] < 0 < data[int(0.2 * sr)]


def test_loudness_overview():
    sr = 16000
    data = np.concatenate([np.zeros(sr), 0.5 * np.sin(np.arange(sr) / 5)]).astype(np.float32)
    levels = np.frombuffer(audio.loudness(data, sr), dtype=np.uint8)
    assert len(levels) == 40
    assert levels[:20].max() == 0 and levels[20:].min() > 200


def _video(tmp_path, acodec, name):
    import subprocess
    path = tmp_path / name
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=64x64:rate=5",
                    "-f", "lavfi", "-i", "sine=frequency=300:sample_rate=48000", "-t", "2",
                    "-c:v", "mpeg4", "-c:a", acodec, str(path)], check=True)
    return path


def test_extract_copies_aac_from_video(tmp_path):
    out = audio.extract(str(_video(tmp_path, "aac", "v.mp4")), str(tmp_path / "sound"))
    assert out.endswith(".m4a")
    assert abs(audio.probe(out)["duration"] - 2.0) < 0.1


def test_extract_converts_other_codecs_to_flac(tmp_path):
    out = audio.extract(str(_video(tmp_path, "libopus", "v.mkv")), str(tmp_path / "sound"))
    assert out.endswith(".flac")


def test_extract_without_sound_fails_clearly(tmp_path):
    import subprocess
    import pytest
    path = tmp_path / "silent.mp4"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=64x64:rate=5", "-t", "1",
                    "-c:v", "mpeg4", str(path)], check=True)
    with pytest.raises(RuntimeError, match="нет звуковой"):
        audio.extract(str(path), str(tmp_path / "sound"))


def _lufs(path):
    import json as _json
    import subprocess
    out = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", str(path), "-af",
                          "loudnorm=print_format=json", "-f", "null", "-"], capture_output=True, text=True).stderr
    return float(_json.loads(out[out.rindex("{"):out.rindex("}") + 1])["input_i"])


def test_loudness_preset_reaches_target(tmp_path):
    sr = 48000
    t = np.arange(8 * sr) / sr
    quiet = (0.02 * np.sin(2 * np.pi * 220 * t) * (1 + 0.5 * np.sin(2 * np.pi * 0.5 * t))).astype(np.float32)
    source = tmp_path / "quiet.wav"
    audio.save(str(source), quiet, sr)
    out = tmp_path / "loud.wav"
    result = render(str(source), [[0.0, 4.0], [5.0, 8.0]], str(out), loudness=-16.0)
    assert result["loudness_before"] < -30
    assert abs(_lufs(out) - (-16.0)) < 1.0
    assert abs(audio.probe(str(out))["sample_rate"] - sr) == 0


def test_loud_peaks_still_reach_target(tmp_path):
    # quiet speech with sharp loud peaks: a plain volume change can't reach -14 safely
    sr = 48000
    rng = np.random.default_rng(0)
    x = (0.03 * rng.standard_normal(10 * sr)).astype(np.float32)
    x[::sr // 2] = 0.95
    source = tmp_path / "peaky.wav"
    audio.save(str(source), x, sr)
    out = tmp_path / "out.wav"
    result = render(str(source), [[0.0, 10.0]], str(out), loudness=-14.0)
    assert result["linear"] is False
    assert abs(_lufs(out) - (-14.0)) < 1.0
