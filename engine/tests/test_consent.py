from madstudio_engine.consent import text_match, words


def test_words_are_normalised():
    assert words("Ёжик, 17 Лимонов!") == ["ежик", "семнадцать", "лимонов"]


def test_text_match_counts_phrase_words_in_order():
    phrase = "Я разрешаю этой программе говорить моим голосом. Проверочные слова: река, лимон, маяк."
    assert text_match("я разрешаю этой программе говорить моим голосом проверочные слова река лимон маяк", phrase) == 1.0
    # a couple of misheard words still pass, a different text does not
    assert text_match("я разрешаю этой программе говорить моим голосом проверочное слово река лимон маяк", phrase) >= 0.75
    assert text_match("сорок два километра это московский марафон был", phrase) < 0.2
    assert text_match("", phrase) == 0.0
