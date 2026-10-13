from madstudio_engine.text_ai import _json, blocks, clean_chapters, parse_script, stamp


def test_parse_script_and_stamps():
    lines = parse_script("[0:00] Привет\n[1:05] Дальше\n[1:02:05] Конец")
    assert lines == [(0.0, "Привет"), (65.0, "Дальше"), (3725.0, "Конец")]
    assert stamp(65) == "1:05" and stamp(3725) == "1:02:05"


def test_json_is_found_inside_chatter():
    assert _json('Вот ответ: [{"time": "0:00", "title": "Начало"}] Готово.') == [{"time": "0:00", "title": "Начало"}]
    assert _json("<think>хм {не то}</think>{\"a\": 1}") == {"a": 1}
    assert _json("нет json") is None


def test_chapters_follow_youtube_rules():
    raw = [{"time": 5, "title": "Вступление"}, {"time": 8, "title": "Слишком близко"},
           {"time": 120, "title": "Марафон"}, {"time": 9999, "title": "За концом"}]
    chapters = clean_chapters(raw, duration=600)
    assert [c["stamp"] for c in chapters] == ["0:00", "2:00"]
    assert chapters[0]["title"] == "Вступление"


def test_blocks_split_long_scripts():
    lines = [(float(i), "слово " * 100) for i in range(30)]
    parts = blocks(lines, words=1000)
    assert len(parts) == 3 and sum(len(p) for p in parts) == 30
