"""Messages for the app in its interface language (MADSTUDIO_LANG, set by the app): the engine
writes Russian; when the interface is English, the same messages come out in English."""

import os

EN = {
    # errors
    "В этом файле нет звуковой дорожки": "This file has no audio track",
    "В этом репозитории нет весов F5-TTS (.safetensors) и словаря vocab.txt":
        "This repository has no F5-TTS weights (.safetensors) and vocab.txt",
    "ffmpeg не смог записать файл": "ffmpeg couldn't write the file",
    "Эта папка с моделями — ссылка на другую; переносить её отсюда нельзя":
        "This models folder is a link to another one; it can't be moved from here",
    "Старая папка с моделями недоступна — подключите диск, на котором она была":
        "The old models folder is unavailable — connect the disk it was on",
    "В выбранной папке не хватит места: нужно {need} ГБ, свободно {free} ГБ":
        "Not enough space in the chosen folder: {need} GB needed, {free} GB free",
    "Копия не совпала с оригиналом — модели остались на старом месте":
        "The copy didn't match the original — the models stayed where they were",
    "Нет текста, чтобы озвучить": "There is no text to speak",
    "Неизвестная модель: {id}": "Unknown model: {id}",
    "Нет моделей для задачи: {task}": "No models for the task: {task}",
    "Для этого нужна модель «{title}» — она ещё не скачана.":
        "This needs the “{title}” model — it isn't downloaded yet.",
    "Не хватит места: нужно {need} ГБ, свободно {free} ГБ": "Not enough space: {need} GB needed, {free} GB free",
    "Нужно ~{need} ГБ памяти из {ram} — может не запуститься": "Needs ~{need} GB of memory out of {ram} — may not run",
    "Будет медленно на этом компьютере": "Will be slow on this computer",
    "Подходит для этого компьютера": "Suits this computer",
    "Скачанный файл не совпал с опубликованным — установка отменена":
        "The downloaded file didn't match the published one — installation cancelled",
    "Нет текста для поиска моментов": "There is no text to look for moments in",
    "Нет речи для перевода": "There is no speech to translate",
    "Нет текста для описания": "There is no text to describe",
    # Hugging Face
    "Языковые модели MLX": "MLX language models",
    "{bits} бит": "{bits}-bit",
    "4 бита": "4-bit",
    "Из Hugging Face: {repo}": "From Hugging Face: {repo}",
    " (экспериментально)": " (experimental)",
    "проверьте": "check",
    "см. страницу модели": "see the model page",
    # time estimates
    "Расшифровка": "Transcription",
    "Переозвучка фразы": "Re-voicing a phrase",
    "Перевод голосом": "Voice translation",
    "Отделение фона": "Background separation",
    "Шумоподавление": "Noise removal",
    "Моменты для Shorts": "Shorts moments",
    "Главы и описание": "Chapters and description",
    "10 мин записи": "10 min of audio",
    "фразу (первая — ещё ~20 с на загрузку)": "phrase (the first one ~20 s more to load)",
    "фразу": "phrase",
    # model catalog
    "Расшифровка: быстрая": "Transcription: fast",
    "Хорошо понимает русский, быстрая. Рекомендуется по умолчанию.":
        "Fast, understands Russian and English well. Recommended by default.",
    "Расшифровка: точная": "Transcription: accurate",
    "Немного точнее, но в 3–4 раза медленнее.": "A little more accurate, but 3–4 times slower.",
    "Расшифровка: лёгкая": "Transcription: light",
    "Для слабых компьютеров. Заметно больше ошибок в русском.": "For weaker computers. Noticeably more mistakes.",
    "Точная разметка слов (русский)": "Precise word alignment (Russian)",
    "Находит точные границы каждого слова — чтобы вырезать, не задевая соседние слова.":
        "Finds the exact boundaries of every word — to cut without touching the neighbouring words.",
    "Голос: высокое качество (русский)": "Voice: high quality (Russian)",
    "Переозвучивает фразы голосом автора записи. Только для некоммерческого использования.":
        "Re-voices phrases in the voice of the recording's author. Non-commercial use only.",
    "Вокодер Vocos": "Vocos vocoder",
    "Превращает результат голосовой модели в звук. Нужен для переозвучки.":
        "Turns the voice model's output into sound. Needed for re-voicing.",
    "Ударения (русский)": "Stress marks (Russian)",
    "Расставляет ударения в тексте для переозвучки.": "Places stress marks in Russian text for re-voicing.",
    "Метка сгенерированного звука": "Generated sound watermark",
    "Незаметная метка в каждом сгенерированном куске — чтобы ИИ-голос можно было распознать.":
        "An inaudible mark in every generated piece — so an AI voice can be recognised.",
    "Разделение по спикерам": "Speaker separation",
    "Узнаёт, кто говорит: отмечает в тексте реплики каждого собеседника.":
        "Recognises who is speaking: marks each speaker's lines in the text.",
    "Текст: качественно": "Text: quality",
    "Главы, названия, описание и теги для YouTube. Хорошо пишет по-русски.":
        "Chapters, titles, description and tags for YouTube. Writes Russian and English well.",
    "Текст: быстро": "Text: fast",
    "В 2–3 раза быстрее, но тексты проще и ошибается чаще.": "2–3 times faster, but simpler texts and more mistakes.",
    "Отделение голоса от фона": "Voice and background separation",
    "Разделяет запись на голос и всё остальное (музыка, шумы). Нужна, чтобы сохранить фон при переводе.":
        "Splits a recording into the voice and everything else (music, noise). Needed to keep the background when translating.",
    "Убирает гул, шипение, шум улицы и вентилятора из голоса. Очень быстрое.":
        "Removes hum, hiss, street and fan noise from the voice. Very fast.",
    "хорошо": "good",
    "отлично": "excellent",
    "средне": "fair",
    "не зависит от языка": "any language",
    "CC BY-NC 4.0 (некоммерческая)": "CC BY-NC 4.0 (non-commercial)",
}


def english() -> bool:
    return os.environ.get("MADSTUDIO_LANG") == "en"


def tr(text: str, **values) -> str:
    """`text` in the interface language, with {values} filled in."""
    out = EN.get(text, text) if english() else text
    return out.format(**values) if values else out
