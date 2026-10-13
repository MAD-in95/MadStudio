"""Moments for Shorts/Reels: the local language model reads the edited text sentence by
sentence and picks self-contained pieces of 20–60 s; the program then fits them to
sentence boundaries and the length limits, removes overlaps and ranks them."""

import re

from .i18n import tr
from .text_ai import _json, stamp

MIN_LEN = 20.0       # shorter pieces are extended with the next sentences
MAX_LEN = 60.0       # YouTube Shorts / Reels limit for a comfortable clip
MAX_SENTENCE = 20.0  # a sentence longer than this is split at its longest pause
BLOCK_WORDS = 600    # words the model reads at once (fits an 8 GB Mac, keeps numbers accurate)
OVERLAP_WORDS = 100  # blocks overlap so a moment on a border is not lost
PAD_START = 0.2     # a little air before the first word and after the last one,
PAD_END = 0.5       # never reaching into the neighbouring sentences


def _join(words: list[dict]) -> str:
    text = ""
    for w in words:
        t = w["text"]
        text += t if (not text or t.startswith("-") or t in ",.?!…") else " " + t
    return text


def sentences(words: list[dict]) -> list[dict]:
    """Words -> sentences with times: split at sentence ends, pauses ≥ 1 s and speaker changes."""
    out, current = [], []

    def flush(part):
        if part:
            out.append({"start": part[0]["start"], "end": part[-1]["end"], "text": _join(part),
                        "speaker": part[0].get("speaker"), "words": part})

    for w in words:
        if current:
            last = current[-1]
            if (w["start"] - last["end"] >= 1.0 or w.get("speaker") != last.get("speaker")
                    or last["text"][-1:] in ".?!…"):
                flush(current)
                current = []
        current.append(w)
    flush(current)

    # very long sentences: cut at the longest pause until every piece is short enough
    result = []
    stack = list(reversed(out))
    while stack:
        s = stack.pop()
        ws = s["words"]
        if s["end"] - s["start"] <= MAX_SENTENCE or len(ws) < 2:
            result.append(s)
            continue
        k = max(range(1, len(ws)), key=lambda i: (ws[i]["start"] - ws[i - 1]["end"], ws[i - 1]["text"][-1:] == ","))
        a, b = ws[:k], ws[k:]
        for part in (b, a):
            stack.append({"start": part[0]["start"], "end": part[-1]["end"], "text": _join(part),
                          "speaker": part[0].get("speaker"), "words": part})
    for s in result:
        del s["words"]
    return result


def blocks(items: list[dict], words: int = BLOCK_WORDS, overlap: int = OVERLAP_WORDS) -> list[tuple[int, int]]:
    """Index ranges [a, b) of sentences, about `words` words each, overlapping a little."""
    sizes = [len(s["text"].split()) for s in items]
    out, a = [], 0
    while a < len(items):
        b, count = a, 0
        while b < len(items) and count < words:
            count += sizes[b]
            b += 1
        out.append((a, b))
        if b >= len(items):
            break
        back, count = b, 0
        while back > a + 1 and count < overlap:
            back -= 1
            count += sizes[back]
        a = back
    return out


def _clean_start(items: list[dict], i: int) -> bool:
    return i == 0 or items[i - 1]["text"][-1:] in ".?!…" or items[i - 1].get("speaker") != items[i].get("speaker")


def _clean_end(items: list[dict], i: int) -> bool:
    return (i == len(items) - 1 or items[i]["text"][-1:] in ".?!…"
            or items[i + 1].get("speaker") != items[i].get("speaker"))


def fit(items: list[dict], a: int, b: int) -> tuple[int, int]:
    """Moves the borders of sentences a..b (inclusive) so the piece lasts MIN_LEN..MAX_LEN
    and, where possible, starts at the beginning of a sentence and ends at its end."""
    a, b = max(0, min(a, len(items) - 1)), max(0, min(b, len(items) - 1))
    if b < a:
        a, b = b, a
    length = lambda a, b: items[b]["end"] - items[a]["start"]
    while length(a, b) > MAX_LEN and b > a:
        b -= 1
    while length(a, b) < MIN_LEN:
        if b + 1 < len(items) and length(a, b + 1) <= MAX_LEN:
            b += 1
        elif a > 0 and length(a - 1, b) <= MAX_LEN:
            a -= 1
        else:
            break
    ok = lambda a, b: a <= b and MIN_LEN * 0.75 <= length(a, b) <= MAX_LEN
    if not _clean_start(items, a):
        for c in sorted(range(max(0, a - 3), min(b, a + 2) + 1), key=lambda c: (abs(c - a), c > a)):
            if _clean_start(items, c) and ok(c, b):
                a = c
                break
    if not _clean_end(items, b):
        for c in sorted(range(max(a, b - 2), min(len(items) - 1, b + 3) + 1), key=lambda c: (abs(c - b), c < b)):
            if _clean_end(items, c) and ok(a, c):
                b = c
                break
    return a, b


def _overlap(x: dict, y: dict) -> float:
    inter = min(x["end"], y["end"]) - max(x["start"], y["start"])
    return max(0.0, inter) / min(x["end"] - x["start"], y["end"] - y["start"])


def pick(found: list[dict], limit: int) -> list[dict]:
    """Best moments first, no two covering the same stretch; then in time order."""
    chosen = []
    for m in sorted(found, key=lambda m: -m["score"]):
        if all(_overlap(m, c) < 0.15 for c in chosen):
            chosen.append(m)
        if len(chosen) >= limit:
            break
    return sorted(chosen, key=lambda m: m["start"])


PICK = (
    "Ты монтажёр коротких вертикальных роликов (YouTube Shorts, Reels, TikTok). Ниже пронумерованные "
    "фразы из видео с таймкодами. Найди {n} фрагмента, которые можно выложить отдельным роликом на "
    "20–60 секунд: понятен без остального видео, первая фраза цепляет, внутри законченная мысль — "
    "история с развязкой, яркое мнение, шутка, неожиданный факт или полезный совет. Рекламу и "
    "спонсорские вставки не бери. Ответь только JSON-списком: "
    '[{{"from": номер первой фразы, "to": номер последней фразы}}], например '
    '[{{"from": {a}, "to": {b}}}]\n\n'
)


def ranges(answer: str) -> list[tuple[int, int]]:
    """Sentence number ranges from the model's answer, whatever shape it chose:
    [{"from": 3, "to": 7}], [["3", "7"]], [3:7] or "3–7"."""
    out = []
    data = _json(answer)
    for m in data if isinstance(data, list) else []:
        try:
            if isinstance(m, dict):
                out.append((int(m["from"]), int(m["to"])))
            elif isinstance(m, (list, tuple)) and m:
                out.append((int(m[0]), int(m[-1])))
        except (KeyError, TypeError, ValueError):
            continue
    if not out:
        for group in re.findall(r"\d+(?:\s*[:\-–—]\s*\d+)+", answer):
            numbers = re.findall(r"\d+", group)
            out.append((int(numbers[0]), int(numbers[-1])))
    return out

JUDGE = (
    "Вот фрагмент из видео длиной {length} секунд. Оцени строго, насколько он хорош как отдельный "
    "короткий ролик (Shorts, Reels): понятен ли без остального видео, цепляет ли первая фраза, есть ли "
    "законченная мысль, эмоция, польза или юмор. Шкала: 1–3 — скучно или непонятно без контекста, "
    "4–6 — нормально, 7–8 — хорошо, 9–10 — очень сильно (редкость). Реклама или спонсорская вставка — 1.\n"
    "Ответь только JSON-объектом: "
    '{{"score": оценка, "title": "цепляющее название ролика по содержанию фрагмента, на языке фрагмента, до 60 символов", '
    '"why": "чем фрагмент хорош или плох, одно короткое предложение"}}\n\nФрагмент:\n{text}'
)


def candidates(model, items: list[dict], on_progress=None) -> list[tuple[int, int]]:
    """First pass: the model points at promising stretches, block by block."""
    parts = blocks(items)
    found: list[tuple[int, int]] = []
    for n, (a, b) in enumerate(parts):
        lines = "\n".join(f"{i + 1}. [{stamp(items[i]['start'])}] {items[i]['text']}" for i in range(a, b))
        want = 3 if b - a > 40 else 2 if b - a > 15 else 1
        example = (a + 1 + (b - a) // 3, a + 1 + (b - a) // 3 + 5)
        for first, last in ranges(model.ask(PICK.format(n=want, a=example[0], b=example[1]) + lines, max_tokens=300)):
            first, last = first - 1, last - 1
            if not (a <= first < b):
                continue
            first, last = fit(items, first, min(max(last, first), b - 1))
            span = {"start": items[first]["start"], "end": items[last]["end"]}
            if all(_overlap(span, {"start": items[x]["start"], "end": items[y]["end"]}) < 0.5 for x, y in found):
                found.append((first, last))
        if on_progress:
            on_progress((n + 1) / len(parts))
    return found


def judge(model, items: list[dict], first: int, last: int) -> dict:
    """Second pass: the model rates one stretch on its own and names it."""
    start, end = items[first]["start"], items[last]["end"]
    text = " ".join(items[i]["text"] for i in range(first, last + 1))
    answer = _json(model.ask(JUDGE.format(length=round(end - start), text=text), max_tokens=200))
    answer = answer if isinstance(answer, dict) else {}
    try:
        score = float(answer.get("score", 1))
    except (TypeError, ValueError):
        score = 1.0
    prev_end = items[first - 1]["end"] if first > 0 else 0.0
    next_start = items[last + 1]["start"] if last + 1 < len(items) else end + 2 * PAD_END
    start = max(0.0, start - PAD_START, (prev_end + start) / 2)
    end = min(end + PAD_END, (end + next_start) / 2)
    return {"start": round(start, 3), "end": round(end, 3), "score": max(1.0, min(10.0, score)),
            "title": str(answer.get("title", "")).strip().strip('"«»'),
            "why": str(answer.get("why", "")).strip(), "text": text}


GOOD = 7      # moments rated this well are always offered
ENOUGH = 3    # if fewer are that good, add the best "decent" ones (rated 5+) up to this many


def choose(rated: list[dict], limit: int) -> list[dict]:
    good = pick([m for m in rated if m["score"] >= GOOD], limit)
    if len(good) >= ENOUGH:
        return good
    return pick([m for m in rated if m["score"] >= 5], ENOUGH)   # best first, so the good ones stay


def find(model, words: list[dict], on_progress=None, limit: int | None = None) -> list[dict]:
    """Moments for Shorts. `model` answers prompts (TextModel); `words` are the edited
    recording's words with times."""
    items = sentences(words)
    if not items:
        raise RuntimeError(tr("Нет текста для поиска моментов"))
    if limit is None:
        limit = int(min(10, max(3, round(items[-1]["end"] / 120))))
    report = (lambda share: on_progress(share)) if on_progress else (lambda share: None)
    spans = candidates(model, items, on_progress=lambda v: report(0.5 * v))
    rated = []
    for n, (a, b) in enumerate(spans):
        rated.append(judge(model, items, a, b))
        report(0.5 + 0.5 * (n + 1) / len(spans))
    return choose(rated, limit)
