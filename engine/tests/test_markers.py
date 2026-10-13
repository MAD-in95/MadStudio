import numpy as np

from conftest import SR, noise, silence, tone
from madstudio_engine.markers import build_tokens


def make_recording():
    parts = [
        silence(0.5),        # 0.0-0.5   leading pause
        tone(0.5),           # 0.5-1.0   word "Привет"
        silence(0.8),        # 1.0-1.8   pause
        noise(0.4, 0.05),    # 1.8-2.2   breath
        silence(0.2),        # 2.2-2.4   too short for a pause
        tone(0.5),           # 2.4-2.9   word "это"
        tone(0.5, amp=0.25, freq=120),  # 2.9-3.4   "э-э" Whisper didn't write
        silence(0.2),        # 3.4-3.6
        tone(0.4),           # 3.6-4.0   word "тест."
        silence(0.5),        # 4.0-4.5   trailing pause
    ]
    audio = np.concatenate(parts) + noise(4.5, 1e-4, seed=1)
    words = [
        {"text": "Привет,", "start": 0.40, "end": 1.10, "prob": 0.9},  # sloppy edges
        {"text": "это", "start": 2.40, "end": 2.90, "prob": 0.9},
        {"text": "тест.", "start": 3.60, "end": 4.00, "prob": 0.3},
    ]
    return audio, words


def test_finds_what_whisper_left_out():
    audio, words = make_recording()
    tokens = build_tokens(words, audio, SR)
    kinds = [t["kind"] for t in tokens]
    assert kinds == ["pause", "word", "pause", "breath", "word", "filler", "word", "pause"]


def test_tokens_tile_the_whole_recording():
    audio, words = make_recording()
    tokens = build_tokens(words, audio, SR)
    assert tokens[0]["start"] == 0.0
    assert tokens[-1]["end"] == 4.5
    for a, b in zip(tokens, tokens[1:]):
        assert a["end"] == b["start"]
        assert a["end"] > a["start"]


def test_word_edges_are_trimmed_to_sound():
    audio, words = make_recording()
    tokens = build_tokens(words, audio, SR)
    pause = tokens[2]
    assert abs(pause["start"] - 1.0) < 0.05
    assert abs(pause["end"] - 1.8) < 0.05


def test_word_flags():
    audio = np.concatenate([tone(0.3), silence(1.0), tone(0.3), tone(2.0), silence(0.3)])
    audio = audio + noise(len(audio) / SR, 1e-4, seed=2)
    words = [
        {"text": "Конец.", "start": 0.0, "end": 0.3, "prob": 0.9},
        {"text": "Ээ...", "start": 1.3, "end": 1.6, "prob": 0.9},
        {"text": "да", "start": 1.6, "end": 3.6, "prob": 0.9},
    ]
    tokens = [t for t in build_tokens(words, audio, SR) if t["kind"] == "word"]
    assert tokens[0].get("para")
    assert not tokens[1].get("para")  # paragraphs are never just a couple of words
    assert tokens[1].get("parasite")
    assert tokens[2].get("stretched")
    assert not tokens[0].get("parasite")


def test_silence_only():
    tokens = build_tokens([], silence(2.0), SR)
    assert [t["kind"] for t in tokens] == ["pause"]
    assert tokens[0]["end"] == 2.0


def test_short_sound_next_to_a_word_stays_with_the_word():
    # Whisper ended the word 0.15 s early: the rest of the word must not become "э-э"
    audio = np.concatenate([tone(0.65), silence(0.6), tone(0.4)]) + noise(1.65, 1e-4, seed=3)
    words = [
        {"text": "надо,", "start": 0.0, "end": 0.5, "prob": 0.9},
        {"text": "или", "start": 1.25, "end": 1.65, "prob": 0.9},
    ]
    kinds = [t["kind"] for t in build_tokens(words, audio, SR)]
    assert kinds == ["word", "pause", "word"]


def test_speech_whisper_skipped_is_not_called_filler():
    audio, words = make_recording()
    # pretend the "э-э" spot actually contains a short reply, and the breath is a breath
    def hear(piece):
        return "давай" if len(piece) > 0.55 * SR else ""  # only the 0.5 s "э-э" spot
    tokens = build_tokens(words, audio, SR, hear=hear)
    kinds = [t["kind"] for t in tokens]
    assert kinds == ["pause", "word", "pause", "breath", "word", "speech", "word", "pause"]
    assert tokens[5]["text"] == "давай"


def test_hesitation_heard_as_letters_stays_filler():
    audio, words = make_recording()
    tokens = build_tokens(words, audio, SR, hear=lambda piece: "ээ м")
    assert [t["kind"] for t in tokens][5] == "filler"
