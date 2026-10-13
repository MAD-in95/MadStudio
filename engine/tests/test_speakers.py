import numpy as np

from madstudio_engine.speakers import cluster, units


def test_units_split_at_pauses():
    tokens = [
        {"kind": "word", "text": "а", "start": 0, "end": 1},
        {"kind": "word", "text": "б", "start": 1, "end": 2},
        {"kind": "pause", "start": 2, "end": 2.5},
        {"kind": "breath", "start": 2.5, "end": 2.7},
        {"kind": "word", "text": "в", "start": 2.7, "end": 3},
    ]
    assert units(tokens) == [(0, 1), (3, 4)] or units(tokens) == [(0, 1), (4, 4)]


def test_two_clear_voices_are_found():
    rng = np.random.default_rng(0)
    a, b = rng.normal(size=192), rng.normal(size=192)
    x = np.array([a + 0.3 * rng.normal(size=192) for _ in range(20)] +
                 [b + 0.3 * rng.normal(size=192) for _ in range(15)])
    labels, centers = cluster(x, np.ones(len(x)))
    assert len(set(labels[:20])) == 1 and len(set(labels[20:])) == 1
    assert labels[0] != labels[-1]


def test_one_voice_with_moods_is_still_one_speaker():
    # the same person speaking calmly and excitedly: two sub-groups that are still alike
    rng = np.random.default_rng(2)
    a = rng.normal(size=192)
    calm, loud = a + 0.6 * rng.normal(size=192), a + 0.6 * rng.normal(size=192)
    x = np.array([calm + 0.2 * rng.normal(size=192) for _ in range(20)] +
                 [loud + 0.2 * rng.normal(size=192) for _ in range(20)])
    labels, _ = cluster(x, np.ones(len(x)))
    assert len(set(labels)) == 1


def test_one_voice_stays_one_speaker():
    rng = np.random.default_rng(1)
    a = rng.normal(size=192)
    x = np.array([a + 0.3 * rng.normal(size=192) for _ in range(30)])
    labels, _ = cluster(x, np.ones(len(x)))
    assert len(set(labels)) == 1


def test_unsure_piece_follows_its_neighbours(monkeypatch):
    from madstudio_engine import speakers

    a, b = np.zeros(4), np.zeros(4)
    a[0], b[1] = 1, 1
    middle = np.array([0.48, 0.52, 0, 0])            # a bit closer to b, but not sure
    prints = [a, a, middle, a, b, b]

    class Model:
        def embed(self, piece):
            return prints[int(piece[0])]

    tokens, audio = [], []
    for k in range(6):
        tokens += [{"kind": "word", "text": f"слово{k}.", "start": k * 3.0, "end": k * 3.0 + 2.0},
                   {"kind": "pause", "start": k * 3.0 + 2.0, "end": k * 3.0 + 3.0}]
        audio += [k] * 3
    monkeypatch.setattr(speakers, "cluster", lambda e, w: (np.array([0, 0, 0, 1, 1][:len(e)]), np.array([a, b])))
    samples = np.repeat(np.array(audio, dtype=np.float32), 1000)   # 1000 "samples" per second
    speakers.assign(tokens, samples, 1000, Model())
    words = [t["speaker"] for t in tokens if t["kind"] == "word"]
    assert words[2] == words[1] == words[3]   # the unsure middle piece joins its neighbours
