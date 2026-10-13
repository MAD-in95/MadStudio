from madstudio_engine.speak import paragraphs


def test_text_is_read_paragraph_by_paragraph():
    text = "Привет всем.\n\nСегодня поговорим о звуке.\nВторая строка."
    assert paragraphs(text) == ["Привет всем.", "Сегодня поговорим о звуке.", "Второя строка.".replace("Второя", "Вторая")]


def test_long_paragraphs_are_split_at_sentence_ends():
    text = " ".join(["Это предложение довольно длинное, чтобы набрать текст."] * 20)
    parts = paragraphs(text)
    assert len(parts) > 1 and all(len(p) <= 460 for p in parts)
    assert all(p.endswith(".") for p in parts)
