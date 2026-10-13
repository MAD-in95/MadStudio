import json

from madstudio_engine import shorts


def words(spec):
    """[(text, start, end)] -> word dicts of one speaker."""
    return [{"text": t, "start": a, "end": b, "speaker": 0} for t, a, b in spec]


def test_sentences_split_at_ends_pauses_and_speakers():
    w = words([("Привет", 0, 0.5), ("всем.", 0.5, 1.0), ("Сегодня", 1.2, 1.6), ("какая", 1.6, 1.9),
               ("-то", 1.9, 2.0), ("тема", 3.5, 4.0)])
    w.append({"text": "Да", "start": 4.1, "end": 4.3, "speaker": 1})
    s = shorts.sentences(w)
    assert [x["text"] for x in s] == ["Привет всем.", "Сегодня какая-то", "тема", "Да"]
    assert s[1]["start"] == 1.2 and s[1]["end"] == 2.0


def test_long_sentence_is_cut_at_its_longest_pause():
    w = words([(f"слово{i}", i * 1.0, i * 1.0 + 0.8) for i in range(30)])
    w[15]["start"], w[15]["end"] = 15.5, 16.3   # the longest pause, before word 15
    s = shorts.sentences(w)
    assert all(x["end"] - x["start"] <= shorts.MAX_SENTENCE for x in s)
    assert s[0]["text"].endswith("слово14")


def items_every(seconds, n, ends=".?!…"):
    return [{"start": i * seconds, "end": i * seconds + seconds - 0.2, "text": f"Фраза {i}.", "speaker": 0}
            for i in range(n)]


def test_fit_keeps_moments_between_20_and_60_seconds():
    items = items_every(5, 40)
    a, b = shorts.fit(items, 3, 3)                 # one 5-second sentence: extended forward
    assert a == 3 and 20 <= items[b]["end"] - items[a]["start"] <= 60
    a, b = shorts.fit(items, 0, 30)                # 150 s: shortened from the end
    assert a == 0 and items[b]["end"] - items[a]["start"] <= 60
    a, b = shorts.fit(items, 39, 39)               # at the very end: extended backwards
    assert b == 39 and items[b]["end"] - items[a]["start"] >= 20


def test_fit_starts_at_a_sentence_beginning():
    items = items_every(5, 20)
    items[4]["text"] = "и тогда я понял"         # no full stop: sentence 5 continues it
    a, b = shorts.fit(items, 5, 9)
    assert a == 4


def test_pick_prefers_better_moments_without_overlaps():
    found = [{"start": 0, "end": 30, "score": 7}, {"start": 10, "end": 40, "score": 9},
             {"start": 100, "end": 130, "score": 5}, {"start": 200, "end": 230, "score": 8}]
    chosen = shorts.pick(found, limit=2)
    assert [m["start"] for m in chosen] == [10, 200]


def test_choose_adds_decent_moments_when_few_are_good():
    rated = [{"start": i * 100, "end": i * 100 + 30, "score": s} for i, s in enumerate([8, 6, 3, 1])]
    assert [m["score"] for m in shorts.choose(rated, limit=5)] == [8, 6]   # time order; 3 and 1 never


class FakeModel:
    """Points at sentences 2..3 of every block and rates by length; ads get 1."""

    def __init__(self):
        self.prompts = []

    def ask(self, prompt, max_tokens=0):
        self.prompts.append(prompt)
        if prompt.startswith("Вот фрагмент"):
            score = 1 if "реклама" in prompt.split("Фрагмент:")[1] else 8
            return json.dumps({"score": score, "title": "«Название»", "why": "Потому что"}, ensure_ascii=False)
        first = int(prompt.split("\n\n")[1].split(".")[0])
        return f'Вот: [{{"from": {first + 1}, "to": {first + 2}}}]'


def test_find_returns_moments_in_time_order_with_titles():
    w = []
    for i in range(200):  # 200 sentences of 4 s, 5 words each
        text = ["Это", "реклама" if 60 <= i < 70 else "фраза", "номер", str(i), "сказана."]
        w += words([(t, i * 4 + k * 0.7, i * 4 + k * 0.7 + 0.6) for k, t in enumerate(text)])
    model = FakeModel()
    progress = []
    moments = shorts.find(model, w, on_progress=progress.append)
    assert moments and progress[-1] == 1.0
    assert all(20 <= m["end"] - m["start"] <= 60 and m["title"] == "Название" for m in moments)
    assert [m["start"] for m in moments] == sorted(m["start"] for m in moments)
    assert not any("реклама" in m["text"] for m in moments)


def test_moments_get_air_at_the_edges_but_not_the_neighbours_words():
    items = [{"start": 0.0, "end": 9.9, "text": "Раз.", "speaker": 0},
             {"start": 10.0, "end": 39.0, "text": "Два.", "speaker": 0},
             {"start": 41.0, "end": 50.0, "text": "Три.", "speaker": 0}]

    class Model:
        def ask(self, prompt, max_tokens=0):
            return '{"score": 7, "title": "Т", "why": "П"}'

    m = shorts.judge(Model(), items, 1, 1)
    assert m["start"] == 9.95 and m["end"] == 39.5


def test_ranges_understand_every_answer_shape():
    assert shorts.ranges('[{"from": 15, "to": 19}, {"from": 21, "to": 24}]') == [(15, 19), (21, 24)]
    assert shorts.ranges('[["113", "115"], ["131", "134"]]') == [(113, 115), (131, 134)]
    assert shorts.ranges("[171:172]  \n[173:174]  \n[180:181:182]") == [(171, 172), (173, 174), (180, 182)]
    assert shorts.ranges("Фразы 40–47 и 60-62") == [(40, 47), (60, 62)]
    assert shorts.ranges("ничего") == []
