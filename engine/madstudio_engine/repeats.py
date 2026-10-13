"""Finds failed takes: a phrase started, broken off and said again.

    "я пошёл в ма… я пошёл в магазин"   -> the first "я пошёл в ма…" is a failed take
    "я я думаю"                          -> stutter: the first "я"
    "≈така такая", "≈весь весь"           -> a broken-off or doubled word before the full one

The earlier attempt gets "take": <group number>. The later one is kept: people usually
restart to say it better. Nothing is removed automatically unless the user asks.
"""

import re

MAX_PHRASE = 6    # longest restarted phrase we look for, in words
MAX_JUNK = 1      # broken-off words allowed between the attempt and the restart


def _norm(text: str) -> str:
    return re.sub(r"[^\w-]", "", text.lower().replace("ё", "е")).strip("-")


def mark(tokens: list[dict]) -> int:
    """Adds "take" to the tokens of failed takes. Returns how many takes were found."""
    for t in tokens:
        t.pop("take", None)
    words = [i for i, t in enumerate(tokens) if t["kind"] == "word" and _norm(t.get("text", ""))]
    norm = [_norm(tokens[i]["text"]) for i in words]
    group = 0

    def mark_span(first_token: int, last_token: int) -> None:
        nonlocal group
        group += 1
        for k in range(first_token, last_token + 1):
            tokens[k]["take"] = group

    # whole phrases said again, longest first
    p = 0
    while p < len(words):
        found = False
        for n in range(min(MAX_PHRASE, (len(words) - p) // 2), 0, -1):
            phrase = norm[p:p + n]
            for junk in range(0, MAX_JUNK + 1):
                q = p + n + junk
                if norm[q:q + n] != phrase:
                    continue
                cut_off = [tokens[words[k]]["text"] for k in range(p + n, q)]
                if junk and not _looks_broken(norm[p + n:q], norm[q:q + n + 1], cut_off):
                    continue
                if n == 1 and junk == 0 and not _is_stutter(tokens, words[p], words[q]):
                    continue
                if tokens[words[p]].get("speaker") != tokens[words[q]].get("speaker"):
                    continue  # one person echoing another is not a failed take
                mark_span(words[p], words[q] - 1)
                p = q
                found = True
                break
            if found:
                break
        if not found:
            p += 1

    # a broken-off piece of the next word: "≈така такая", "ма… магазин"
    for i, t in enumerate(tokens):
        if "take" in t or t["kind"] not in ("speech", "word"):
            continue
        # a whole short word like "до" before "дома" is fine; only cut-off pieces count
        if t["kind"] == "word" and not re.search(r"(…|\.\.\.|-)$", t.get("text", "")):
            continue
        piece = _norm(t.get("text", "")).replace(" ", "")
        nxt = next((j for j in range(i + 1, min(i + 4, len(tokens))) if tokens[j]["kind"] == "word"), None)
        if nxt is None or len(piece) < 2:
            continue
        full = _norm(tokens[nxt]["text"])
        # speech Whisper skipped may also be the whole word said twice: "≈весь весь"
        whole_again = t["kind"] == "speech" and full == piece
        if full.startswith(piece) and (len(full) > len(piece) or whole_again):
            mark_span(i, nxt - 1)
    return group


def _looks_broken(junk: list[str], restart: list[str], raw: list[str]) -> bool:
    """Junk between attempts must be cut off: the start of a word said in the restart
    ("ма" -> "магазин") or a word Whisper wrote with a trailing "…" ("на…")."""
    return all(any(w.startswith(j) and w != j for w in restart) or re.search(r"(…|\.\.\.|-)$", r)
               for j, r in zip(junk, raw))


def _is_stutter(tokens: list[dict], a: int, b: int) -> bool:
    """A single repeated word counts only when said right away (not "да. … да.")."""
    between = tokens[a + 1:b]
    if any(t["kind"] == "word" for t in between):
        return False
    gap = sum(t["end"] - t["start"] for t in between)
    return gap < 1.0 and not re.search(r"[.?!…]$", tokens[a]["text"])
