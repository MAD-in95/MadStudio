"""Text helpers with a small local language model (Qwen, MLX): chapters, titles,
description and tags for YouTube. Works on an 8 GB Mac: one model, short prompts,
long scripts are read in blocks."""

import json
import re

from .i18n import tr

BLOCK_WORDS = 1200   # words of the script the model reads at once
MIN_CHAPTER = 10.0   # YouTube needs chapters at least 10 s long


def written_in(text: str) -> str:
    """How to tell the model which language to write in: the video's own language."""
    letters = re.findall(r"[a-zа-яё]", text.lower())
    cyrillic = sum(ch >= "а" for ch in letters)
    return "по-русски" if cyrillic > len(letters) / 2 else "на том же языке, что и расшифровка (не по-русски)"


def parse_script(text: str) -> list[tuple[float, str]]:
    """Lines like "[1:02:05] text" -> [(3725.0, "text"), ...]."""
    out = []
    for line in text.splitlines():
        m = re.match(r"\[(\d+(?::\d+){1,2})\]\s*(.*)", line.strip())
        if m:
            parts = [int(p) for p in m[1].split(":")]
            seconds = sum(p * 60 ** i for i, p in enumerate(reversed(parts)))
            out.append((float(seconds), m[2]))
    return out


def stamp(seconds: float) -> str:
    s = int(seconds)
    return f"{s // 3600}:{s // 60 % 60:02d}:{s % 60:02d}" if s >= 3600 else f"{s // 60}:{s % 60:02d}"


def _json(answer: str):
    """The first JSON object or list in the model's answer."""
    answer = re.sub(r"<think>.*?</think>", "", answer, flags=re.S)
    pairs = sorted((("{", "}"), ("[", "]")), key=lambda p: (answer.find(p[0]) == -1, answer.find(p[0])))
    for opener, closer in pairs:  # whichever starts first: a list of objects or an object
        a, b = answer.find(opener), answer.rfind(closer)
        if a != -1 and b > a:
            try:
                return json.loads(answer[a:b + 1])
            except json.JSONDecodeError:
                continue
    return None


def blocks(lines: list[tuple[float, str]], words: int = BLOCK_WORDS) -> list[list[tuple[float, str]]]:
    out, current, count = [], [], 0
    for line in lines:
        current.append(line)
        count += len(line[1].split())
        if count >= words:
            out.append(current)
            current, count = [], 0
    if current:
        out.append(current)
    return out


def clean_chapters(chapters: list[dict], duration: float) -> list[dict]:
    """YouTube rules: first chapter at 0:00, at least 3 chapters, each ≥ 10 s."""
    items = sorted((float(c["time"]), str(c["title"]).strip()) for c in chapters
                   if c.get("title") and 0 <= float(c.get("time", -1)) < duration)
    out = []
    for t, title in items:
        if out and t - out[-1][0] < MIN_CHAPTER:
            continue
        out.append((t, title))
    if out:
        out[0] = (0.0, out[0][1])
    return [{"time": t, "stamp": stamp(t), "title": title} for t, title in out]


class TextModel:
    def __init__(self, model_dir: str):
        from mlx_lm import load

        self.model, self.tokenizer = load(model_dir)

    def ask(self, prompt: str, max_tokens: int = 600) -> str:
        from mlx_lm import generate
        from mlx_lm.sample_utils import make_sampler

        messages = [{"role": "user", "content": prompt}]
        text = self.tokenizer.apply_chat_template(messages, add_generation_prompt=True, tokenize=False)
        return generate(self.model, self.tokenizer, prompt=text, max_tokens=max_tokens,
                        sampler=make_sampler(temp=0.3))

    def youtube(self, script: str, on_progress=None) -> dict:
        lines = parse_script(script)
        if not lines:
            raise RuntimeError(tr("Нет текста для описания"))
        lang = written_in(script)
        duration = lines[-1][0] + 30
        parts = blocks(lines)
        steps = len(parts) + 1
        chapters = []
        for n, part in enumerate(parts):
            text = "\n".join(f"[{stamp(t)}] {s}" for t, s in part)
            answer = self.ask(
                "Это кусок расшифровки видео с таймкодами. Выдели 1–3 главные темы этого куска. "
                "Для каждой темы возьми таймкод строки, где тема начинается, и придумай короткое "
                f"название главы (2–6 слов, {lang}, без кавычек). Ответь только JSON-списком вида "
                '[{"time": "м:сс", "title": "Название"}].\n\n' + text)
            for c in _json(answer) or []:
                try:
                    t = parse_script(f"[{c['time']}] x")[0][0]
                except (IndexError, KeyError, TypeError):
                    continue
                chapters.append({"time": t, "title": c.get("title", "")})
            if on_progress:
                on_progress((n + 1) / steps)

        overview = "\n".join(s for _, s in lines)
        overview = " ".join(overview.split()[:BLOCK_WORDS])
        topics = "; ".join(c["title"] for c in chapters)
        answer = self.ask(
            "Ты помогаешь блогеру оформить видео для YouTube. Вот начало расшифровки и список тем видео. "
            "Ответь только JSON-объектом с полями: "
            '"titles" — 5 вариантов названия видео (цепкие, честные, до 70 символов), '
            '"description" — описание на 2–4 предложения от лица автора, '
            f'"tags" — 15 тегов (слова и короткие фразы). Всё {lang}.\n\n'
            f"Темы: {topics}\n\nНачало расшифровки:\n{overview}", max_tokens=700)
        meta = _json(answer) or {}
        if on_progress:
            on_progress(1.0)
        return {
            "chapters": clean_chapters(chapters, duration),
            "titles": [str(t) for t in meta.get("titles", [])][:5],
            "description": str(meta.get("description", "")),
            "tags": [str(t) for t in meta.get("tags", [])][:20],
        }
