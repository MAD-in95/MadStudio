import numpy as np

from madstudio_engine.align import _chunks, viterbi


def emissions(frames, vocab_size=5):
    """Log-probabilities where each frame clearly 'hears' the given token."""
    lp = np.full((len(frames), vocab_size), np.log(0.01))
    for t, tok in enumerate(frames):
        lp[t, tok] = np.log(0.96)
    return lp


def test_viterbi_finds_where_each_letter_sounds():
    # blank=0; audio: _ _ a a _ b _ _ c c c _
    frames = [0, 0, 1, 1, 0, 2, 0, 0, 3, 3, 3, 0]
    path = viterbi(emissions(frames), [1, 2, 3])
    assert path == [-1, -1, 0, 0, -1, 1, -1, -1, 2, 2, 2, -1]


def test_viterbi_needs_blank_between_repeated_letters():
    # "сс": two identical letters must be separated by a blank
    frames = [1, 1, 0, 1, 0]
    path = viterbi(emissions(frames), [1, 1])
    assert path[:2] == [0, 0] and path[3] == 1


def test_viterbi_rejects_text_longer_than_audio():
    assert viterbi(emissions([1, 2]), [1, 2, 3]) is None


def test_chunks_split_at_pauses():
    words = [{"start": i * 1.0, "end": i * 1.0 + 0.9} for i in range(30)]
    chunks = _chunks(words)
    assert len(chunks) > 1
    assert sum(len(c) for c in chunks) == 30
    assert all(words[c[-1]]["end"] - words[c[0]]["start"] <= 25 for c in chunks)
