from madstudio_engine.repeats import mark


def tokens_from(text: str) -> list[dict]:
    """'я | пошёл' — words; '_' is a pause, '≈ма' is unrecognised speech."""
    out, t = [], 0.0
    for piece in text.split():
        if piece == "_":
            out.append({"kind": "pause", "start": t, "end": t + 0.5})
            t += 0.5
        elif piece.startswith("≈"):
            out.append({"kind": "speech", "text": piece[1:], "start": t, "end": t + 0.3})
            t += 0.3
        else:
            out.append({"kind": "word", "text": piece, "start": t, "end": t + 0.3})
            t += 0.3
    return out


def taken(tokens):
    return " ".join(t.get("text", "_") for t in tokens if "take" in t)


def test_restarted_phrase():
    tokens = tokens_from("я пошёл в _ я пошёл в магазин")
    assert mark(tokens) == 1
    assert taken(tokens) == "я пошёл в _"


def test_restart_after_broken_word():
    tokens = tokens_from("я пошёл в ма… я пошёл в магазин")
    mark(tokens)
    assert taken(tokens) == "я пошёл в ма…"


def test_restart_after_word_cut_off_with_dots():
    tokens = tokens_from("я пошёл на... ≈в я пошёл в магазин")
    mark(tokens)
    assert taken(tokens) == "я пошёл на... в"


def test_stutter():
    tokens = tokens_from("я я думаю")
    mark(tokens)
    assert taken(tokens) == "я"


def test_broken_off_word_heard_as_speech():
    tokens = tokens_from("пришла ≈така такая фраза")
    mark(tokens)
    assert taken(tokens) == "така"


def test_word_said_twice_heard_as_speech():
    tokens = tokens_from("сделал ≈весь весь туалет")
    mark(tokens)
    assert taken(tokens) == "весь"


def test_short_word_before_longer_one_is_not_broken():
    tokens = tokens_from("пошёл до дома по полицейским")
    assert mark(tokens) == 0


def test_cut_off_word_with_dots():
    tokens = tokens_from("я ма… магазин")
    mark(tokens)
    assert taken(tokens) == "ма…"


def test_echo_by_other_speaker_is_not_a_take():
    tokens = tokens_from("это сделано это сделано")
    for t in tokens[2:]:
        t["speaker"] = 1
    for t in tokens[:2]:
        t["speaker"] = 0
    assert mark(tokens) == 0


def test_separate_sentences_are_not_takes():
    tokens = tokens_from("Да. _ _ Да. хорошо")
    assert mark(tokens) == 0


def test_normal_speech_has_no_takes():
    tokens = tokens_from("я помню это ощущение и мне тогда пришла такая фраза")
    assert mark(tokens) == 0


def test_rhetorical_repeat_is_still_found():
    # "это сделано, это сделано" — found, but cleanup removes takes only if the user asks
    tokens = tokens_from("это сделано, это сделано.")
    assert mark(tokens) == 1
