import json

import numpy as np
import pytest

from madstudio_engine import audio, cli


def run(capsys, *argv):
    cli.main(list(argv))
    return [json.loads(line) for line in capsys.readouterr().out.splitlines()]


def test_models_list(capsys):
    out = run(capsys, "models", "list")
    assert out[-1]["event"] == "done"
    assert any(m["id"] == "whisper-turbo" for m in out[-1]["result"])


def test_export(tmp_path, capsys):
    src = tmp_path / "a.wav"
    audio.save(str(src), np.zeros(16000, dtype=np.float32), 16000)
    ranges = tmp_path / "r.json"
    ranges.write_text(json.dumps({"ranges": [[0, 0.5]]}))
    out = run(capsys, "export", str(src), str(ranges), str(tmp_path / "b.wav"))
    assert out[-1]["event"] == "done"
    assert abs(out[-1]["result"]["duration"] - 0.5) < 0.01


def test_transcribe_without_model_reports_error(tmp_path, capsys):
    src = tmp_path / "a.wav"
    audio.save(str(src), np.zeros(16000, dtype=np.float32), 16000)
    with pytest.raises(SystemExit):
        cli.main(["transcribe", str(src), str(tmp_path / "t.json")])
    last = json.loads(capsys.readouterr().out.splitlines()[-1])
    assert last["event"] == "error"
    assert "ещё не скачана" in last["message"]
    assert last["model"]          # the app offers to download exactly this model


def test_reanalyze_upgrades_old_transcript(tmp_path, capsys):
    path = tmp_path / "t.json"
    words = ["я", "я", "думаю"]
    tokens = [{"kind": "word", "text": w, "start": i * 0.3, "end": (i + 1) * 0.3} for i, w in enumerate(words)]
    path.write_text(json.dumps({"version": 1, "tokens": tokens}), encoding="utf-8")
    out = run(capsys, "reanalyze", str(path))
    assert out[-1]["result"]["takes"] == 1
    data = json.loads(path.read_text(encoding="utf-8"))
    assert data["version"] == 2 and data["tokens"][0]["take"] == 1


def test_serve_answers_each_request_and_quits_when_the_app_closes():
    import json
    import subprocess
    import sys

    p = subprocess.run([sys.executable, "-m", "madstudio_engine", "serve"], input='["device"]\n',
                       capture_output=True, text=True, timeout=60)
    lines = [json.loads(line) for line in p.stdout.splitlines() if line.startswith("{")]
    # only re-voicing is kept warm; anything else is refused, and the server keeps going
    assert lines[0]["event"] == "error" and lines[-1]["event"] == "end"
    assert p.returncode == 0          # stdin closed (the app quit) → the server stops


def test_estimates_scale_with_the_speed_of_the_mac():
    from madstudio_engine.device import REFERENCE, estimates

    same = {e["id"]: e["seconds"] for e in estimates(REFERENCE)}
    assert same["transcribe"] == 180 and same["revoice"] == 24
    twice = {e["id"]: e["seconds"] for e in estimates({"compute_tflops": 4.0, "bandwidth_gbs": 36.0})}
    assert twice["transcribe"] == 90 and twice["shorts"] == same["shorts"]   # text work depends on memory speed
