import numpy as np

from madstudio_engine.translate import SR, phrases, place


def w(text, start, end, speaker=0):
    return {"text": text, "start": start, "end": end, "speaker": speaker}


def test_phrases_split_at_sentences_and_speakers():
    words = [w("Привет,", 0, 0.5), w("как", 0.6, 0.8), w("дела?", 0.8, 2.0),
             w("Отлично.", 2.2, 3.0, speaker=1), w("А", 3.1, 3.2, speaker=1), w("ты?", 3.2, 3.6, speaker=1)]
    out = phrases(words)
    assert [p["text"] for p in out] == ["Привет, как дела?", "Отлично. А ты?"]
    assert out[1]["speaker"] == 1


def test_place_keeps_order_and_speeds_up_overflow():
    one = np.ones(int(1.0 * SR), dtype=np.float32)
    long = np.ones(int(2.4 * SR), dtype=np.float32)       # 2.4 s for a 2 s slot -> sped up
    track = place([(0.0, long), (2.0, one)], total=3.0)
    assert len(track) >= int(3.0 * SR)
    second = np.flatnonzero(track[int(1.9 * SR):] > 0.5)
    assert second.size and abs(second[0] / SR - 0.1) < 0.12   # next phrase still near 2.0 s


def test_pause_inside_a_sentence_does_not_split_it():
    words = [w("текст,", 0, 0.5), w("который", 0.6, 1.0), w("ты", 2.4, 2.6), w("отправил.", 2.6, 3.2)]
    assert [p["text"] for p in phrases(words)] == ["текст, который ты отправил."]
