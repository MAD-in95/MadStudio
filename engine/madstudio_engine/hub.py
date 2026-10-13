"""Finding models on Hugging Face, like LM Studio: every task looks only in the family of
models MadStudio can run for it (a text model never shows up for re-voicing). A model
installed from here joins the library next to the built-in catalog."""

import json
import re
import urllib.parse
import urllib.request

from . import models, paths
from .i18n import tr

API = "https://huggingface.co/api/models"

# task -> how to look for models MadStudio can run for it
FAMILIES = {
    "transcribe": {"family": "whisper-mlx", "title": "Whisper (MLX)", "author": "mlx-community",
                   "search": "whisper", "pipeline": "automatic-speech-recognition"},
    "text": {"family": "mlx-lm", "title": "Языковые модели MLX", "author": "mlx-community",
             "search": "", "pipeline": "text-generation"},
    "voice": {"family": "f5-tts", "title": "F5-TTS", "author": None, "search": "F5-TTS",
              "pipeline": None, "experimental": True},
    "align": {"family": "wav2vec2-ctc", "title": "wav2vec2 (CTC)", "author": None,
              "search": "wav2vec2", "pipeline": "automatic-speech-recognition"},
}

WHISPER_SIZES = {"tiny": 0.039, "base": 0.074, "small": 0.244, "medium": 0.769, "turbo": 0.809, "large": 1.55}


def _get(url: str, timeout: float = 15):
    request = urllib.request.Request(url, headers={"User-Agent": "MadStudio"})
    with urllib.request.urlopen(request, timeout=timeout) as r:
        return json.loads(r.read().decode())


def describe(repo: str, task: str, info: dict | None = None) -> dict:
    """Size, number format and memory of a model, read from its name (the way MLX models are named)."""
    name = repo.split("/")[-1]
    low = name.lower()
    bits = 4 if re.search(r"4[-_]?bit|q4", low) else 8 if re.search(r"8[-_]?bit|q8", low) else \
        6 if re.search(r"6[-_]?bit", low) else 3 if re.search(r"3[-_]?bit", low) else 16
    params = None
    m = re.search(r"(\d+(?:\.\d+)?)\s*([bm])(?![a-z])", low.replace("_", "-"))
    if m:
        params = float(m[1]) / (1000 if m[2] == "m" else 1)
    if task == "transcribe":
        params = next((v for k, v in WHISPER_SIZES.items() if k in low), params)
    if task == "voice":
        params = params or 0.34
    if task == "align":
        params = params or (0.32 if "large" in low else 0.095)
    size = round(params * bits / 8 * 1.08, 1) if params else None
    out = {"params_b": params, "precision": tr("{bits} бит", bits=bits) if bits < 16 else "FP16",
           "size_gb": size, "ram_gb": round(size * 1.25 + 0.5, 1) if size else None}
    if info:
        out.update({"downloads": info.get("downloads", 0), "likes": info.get("likes", 0),
                    "updated": (info.get("lastModified") or "")[:10]})
    return out


def search(task: str, query: str = "", limit: int = 30) -> list[dict]:
    """Models of this task's family on Hugging Face, most downloaded first."""
    from .device import device_info

    fam = FAMILIES.get(task)
    if not fam:
        return []
    q = " ".join(x for x in (fam["search"], query.strip()) if x)
    params = {"search": q, "sort": "downloads", "direction": "-1", "limit": str(limit)}
    if fam["author"]:
        params["author"] = fam["author"]
    if fam["pipeline"]:
        params["pipeline_tag"] = fam["pipeline"]
    url = API + "?" + urllib.parse.urlencode(params) + "&expand[]=downloads&expand[]=likes&expand[]=lastModified"
    device = device_info()
    installed = {m.get("repo") for m in models.catalog() if models.is_installed(m["id"])}
    known = {m.get("repo") for m in models.catalog()}
    out = []
    for info in _get(url):
        repo = info["id"]
        if re.search(r"embed|rerank|guard|vision|-vl-|ocr", repo.lower()):
            continue          # can't write text: search, safety and picture models
        d = describe(repo, task, info)
        entry = {"repo": repo, "title": repo.split("/")[-1], "author": repo.split("/")[0], "task": task,
                 "family": fam["family"], "installed": repo in installed, "in_catalog": repo in known,
                 "experimental": fam.get("experimental", False), **d}
        if d["size_gb"]:
            entry.update(models.fit({"size_gb": d["size_gb"], "ram_gb": d["ram_gb"] or 0}, device))
        out.append(entry)
    # what this Mac can run comes first; popularity decides within each group
    rank = {"ok": 0, "slow": 1}
    return sorted(out, key=lambda m: rank.get(m.get("fit"), 2))


def _entry_id(repo: str) -> str:
    return "hub--" + repo.replace("/", "--")


def _pick_files(task: str, repo: str) -> list[str]:
    """Which files of the repository are needed (re-voicing repositories keep many checkpoints)."""
    info = _get(f"{API}/{repo}?blobs=true")
    files = [(s["rfilename"], s.get("size") or 0) for s in info.get("siblings", [])
             if not s["rfilename"].startswith(".")]
    if task != "voice":
        return []          # everything
    weights = [f for f in files if f[0].endswith(".safetensors")]
    vocab = [f for f in files if f[0].endswith("vocab.txt")]
    if not weights or not vocab:
        raise RuntimeError(tr("В этом репозитории нет весов F5-TTS (.safetensors) и словаря vocab.txt"))
    newest = sorted(weights, key=lambda f: (re.findall(r"\d+", f[0])[-1:] or ["0"])[0].zfill(9))[-1]
    return [newest[0], vocab[0][0]]


def install(task: str, repo: str, on_progress=None) -> dict:
    """Adds a model from Hugging Face to the library and downloads it."""
    fam = FAMILIES[task]
    model_id = _entry_id(repo)
    d = describe(repo, task)
    entry = {
        "id": model_id, "family": fam["family"], "task": task, "title": repo.split("/")[-1],
        "description": tr("Из Hugging Face: {repo}", repo=repo) + (tr(" (экспериментально)") if fam.get("experimental") else ""),
        "repo": repo, "files": _pick_files(task, repo), "size_gb": d["size_gb"] or 1.0, "ram_gb": d["ram_gb"] or 2.0,
        "russian": tr("проверьте"), "license": tr("см. страницу модели"), "model_name": repo,
        "params_b": d["params_b"], "precision": d["precision"], "source": "hub",
    }
    if task == "voice":
        entry["requires"] = ["vocoder-vocos"]
    models.add_user_model(entry)
    models.install(model_id, on_progress=on_progress)
    models.remember_revision(model_id)
    return entry


STATS_DAYS = 1   # download counts are asked again after a day


def stats() -> dict:
    """How many people downloaded each catalog model (Hugging Face counts the last 30 days)."""
    import time

    cache = paths.models_dir() / "stats.json"
    try:
        saved = json.loads(cache.read_text(encoding="utf-8"))
        if time.time() - saved.get("time", 0) < STATS_DAYS * 86400:
            return saved["models"]
    except (OSError, ValueError, KeyError):
        pass
    out = {}
    for m in models.catalog():
        repo = m.get("repo")
        if not repo or m["id"] in out:
            continue
        try:
            info = _get(f"{API}/{repo}?expand[]=downloads&expand[]=likes", timeout=8)
            out[m["id"]] = {"downloads": info.get("downloads", 0), "likes": info.get("likes", 0)}
        except Exception:  # noqa: BLE001 — offline: show the list without counts
            continue
    if out:
        cache.write_text(json.dumps({"time": time.time(), "models": out}), encoding="utf-8")
    return out
