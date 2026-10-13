import numpy as np

from madstudio_engine.transcribe import split_points


def test_short_recording_is_one_piece():
    assert split_points(np.zeros(16000 * 60, dtype=np.float32), 16000) == [(0, 16000 * 60)]


def test_long_recording_is_cut_in_quiet_places():
    sr = 1000
    x = np.ones(sr * 2000, dtype=np.float32)          # "speech" everywhere...
    x[sr * 580:sr * 581] = 0                          # ...except a pause at 580 s
    x[sr * 1150:sr * 1151] = 0                        # ...and at 1150 s
    pieces = split_points(x, sr)
    cuts = [b / sr for _, b in pieces[:-1]]
    assert 580 <= cuts[0] <= 581
    assert 1150 <= cuts[1] <= 1151
    assert pieces[0][0] == 0 and pieces[-1][1] == len(x)
    assert all(a == prev_b for (a, _), (_, prev_b) in zip(pieces[1:], pieces))
