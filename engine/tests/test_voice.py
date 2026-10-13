from madstudio_engine.voice import _context, _speech_rate, spell_numbers, voice_samples


def test_numbers_are_spelled_out():
    assert spell_numbers("показано 30 секунд") == "показано тридцать секунд"


def tok(text, start, end, kind="word"):
    return {"kind": kind, "text": text, "start": start, "end": end}


def test_context_takes_whole_tokens_around_the_edit():
    tokens = [tok(f"w{i}", i * 1.0, i * 1.0 + 1) for i in range(20)]
    a, b = _context(tokens, 10, 10)
    assert tokens[10]["start"] - tokens[a]["start"] <= 8
    assert tokens[b]["end"] - tokens[10]["end"] <= 3
    assert a < 10 < b


def test_speech_rate_ignores_pauses():
    tokens = [tok("привет", 0, 0.5), {"kind": "pause", "start": 0.5, "end": 3}, tok("мир", 3, 3.25)]
    assert abs(_speech_rate(tokens, 0, 2) - 9 / 0.75) < 1e-6


def test_numbers_are_spelled_in_the_target_language():
    assert spell_numbers("Video 12 seconds", "en") == "Video twelve seconds"
    assert spell_numbers("12 Sekunden", "de") == "zwölf Sekunden"
    assert spell_numbers("2,5 минуты") == "две целых пять десятых минуты"


def test_context_stays_with_the_same_speaker():
    tokens = [dict(tok(f"w{i}", i * 1.0, i * 1.0 + 1), speaker=0 if 6 <= i <= 12 else 1) for i in range(20)]
    a, b = _context(tokens, 10, 10)
    assert (a, b) == (6, 12)


def test_voice_samples_are_clean_speech_of_that_speaker_near_the_edit():
    tokens = []
    t = 0.0
    for i in range(60):
        speaker = 0 if i < 40 else 1
        tokens.append(dict(tok(f"слово{i}", t, t + 0.5), speaker=speaker, prob=0.9))
        t += 0.5
        if i % 12 == 11:   # phrases of 12 words (6 s) separated by long pauses
            tokens.append({"kind": "pause", "start": t, "end": t + 1.0, "speaker": speaker})
            t += 1.0
    tokens[3]["prob"] = 0.2                       # the first phrase has an unclear word
    samples = voice_samples(tokens, 0, near=40.0)
    assert samples
    for a, b in samples:
        assert all(tokens[k].get("speaker") == 0 for k in range(a, b + 1))
        assert a > 3                              # not the phrase with the unclear word
    total = sum(tokens[b]["end"] - tokens[a]["start"] for a, b in samples)
    assert 4.0 <= total <= 10.0
    assert voice_samples(tokens, 5, near=0) == []  # no such speaker


def test_short_answers_are_joined_into_one_sample():
    tokens = []
    t = 0.0
    for i in range(8):   # a guest answering in short 2-word phrases between long pauses
        tokens += [dict(tok("да", t, t + 0.6), speaker=1, prob=0.95), dict(tok("конечно.", t + 0.6, t + 1.4), speaker=1, prob=0.95),
                   {"kind": "pause", "start": t + 1.4, "end": t + 3.0, "speaker": 1}]
        t += 3.0
    samples = voice_samples(tokens, 1, near=10.0)
    assert len(samples) >= 3
    assert 4.0 <= sum(tokens[b]["end"] - tokens[a]["start"] for a, b in samples) <= 10.0
