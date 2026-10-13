"""Model library: what can be installed, what is installed, download and removal.

Models are interchangeable parts: the rest of the engine asks for a model by task
("transcribe") and gets a local folder, without knowing which family it is.
"""

import json
import shutil
from importlib import resources
from pathlib import Path

from . import paths
from .i18n import tr

_COMPLETE = ".complete"


def _user_file() -> Path:
    return paths.models_dir() / "user_catalog.json"


def _choice_file() -> Path:
    return paths.models_dir() / "choice.json"


def _read(path: Path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def catalog() -> list[dict]:
    """The built-in catalog plus models the person added from Hugging Face."""
    text = resources.files(__package__).joinpath("catalog.json").read_text(encoding="utf-8")
    return json.loads(text)["models"] + _read(_user_file(), [])


def add_user_model(entry: dict) -> None:
    user = [m for m in _read(_user_file(), []) if m["id"] != entry["id"]]
    _user_file().write_text(json.dumps(user + [entry], ensure_ascii=False, indent=1), encoding="utf-8")


def use(model_id: str) -> None:
    """The model this task runs with from now on."""
    task = get(model_id)["task"]
    choice = _read(_choice_file(), {})
    choice[task] = model_id
    _choice_file().write_text(json.dumps(choice, ensure_ascii=False), encoding="utf-8")


def _revision_file(model_id: str) -> Path:
    return model_path(model_id) / ".revision"


def remember_revision(model_id: str) -> None:
    """Notes which version of the files on Hugging Face is installed."""
    from huggingface_hub import HfApi

    repo = get(model_id).get("repo")
    if repo and is_installed(model_id):
        _revision_file(model_id).write_text(HfApi().model_info(repo).sha or "", encoding="utf-8")


def updates() -> list[dict]:
    """Installed models whose files changed on Hugging Face since they were downloaded.
    A model installed before versions were noted gets its current version as the start."""
    from huggingface_hub import HfApi

    api, out = HfApi(), []
    for m in catalog():
        repo = m.get("repo")
        if not repo or not is_installed(m["id"]) or m.get("installer"):
            continue
        try:
            sha = api.model_info(repo).sha or ""
        except Exception:  # noqa: BLE001 — offline or the repository is gone: nothing to offer
            continue
        rev = _revision_file(m["id"])
        if not rev.exists():
            rev.write_text(sha, encoding="utf-8")
        elif rev.read_text(encoding="utf-8").strip() != sha:
            out.append({"id": m["id"], "title": m["title"], "repo": repo})
    return out


def update(model_id: str, on_progress=None) -> Path:
    """Downloads the newer files of an installed model."""
    target = model_path(model_id)
    (target / _COMPLETE).unlink(missing_ok=True)
    path = install(model_id, on_progress=on_progress)
    remember_revision(model_id)
    return path


def get(model_id: str) -> dict:
    for model in catalog():
        if model["id"] == model_id:
            return model
    raise KeyError(tr("Неизвестная модель: {id}", id=model_id))


def model_path(model_id: str) -> Path:
    return paths.models_dir() / model_id


def is_installed(model_id: str) -> bool:
    return (model_path(model_id) / _COMPLETE).exists()


def list_models() -> list[dict]:
    from .device import device_info

    device = device_info()
    out = []
    for m in catalog():
        m = {**m, "installed": is_installed(m["id"])}
        m["chosen"] = m["installed"] and default_for(m["task"]) == m["id"]
        for key in ("title", "description", "russian", "license", "precision"):
            if isinstance(m.get(key), str):
                m[key] = tr(m[key])
        out.append({**m, **fit(m, device)})
    return out


def default_for(task: str) -> str:
    chosen = _read(_choice_file(), {}).get(task)
    if chosen and is_installed(chosen):
        return chosen
    candidates = [m for m in catalog() if m["task"] == task]
    installed = [m for m in candidates if is_installed(m["id"])]
    for pool in (installed, candidates):
        for m in pool:
            if m.get("default"):
                return m["id"]
        if pool:
            return pool[0]["id"]
    raise KeyError(tr("Нет моделей для задачи: {task}", task=task))


def install(model_id: str, on_progress=None) -> Path:
    """Download a model from Hugging Face into the MadStudio models folder."""
    from huggingface_hub import HfApi, hf_hub_download

    model = get(model_id)
    target = model_path(model_id)
    for dependency in model.get("requires", []):
        install(dependency, on_progress=None)
    if is_installed(model_id):
        return target
    target.mkdir(parents=True, exist_ok=True)

    if model.get("installer") == "binary":   # a ready program from the authors' release page
        _install_binary(model, target)
        (target / _COMPLETE).touch()
        if on_progress:
            on_progress(1.0)
        return target
    if model.get("installer"):  # libraries that fetch their own files
        _INSTALLERS[model["installer"]](target)
        (target / _COMPLETE).touch()
        if on_progress:
            on_progress(1.0)
        return target

    wanted = set(model.get("files", []))
    files = [f for f in HfApi().model_info(model["repo"], files_metadata=True).siblings
             if not f.rfilename.startswith(".") and (not wanted or f.rfilename in wanted)]
    total = sum(f.size or 0 for f in files) or 1
    done = 0
    for f in files:
        hf_hub_download(model["repo"], f.rfilename, local_dir=target)
        done += f.size or 0
        if on_progress:
            on_progress(done / total)
    (target / _COMPLETE).touch()
    return target


def remove(model_id: str) -> None:
    shutil.rmtree(model_path(model_id), ignore_errors=True)
    user = _read(_user_file(), [])
    if any(m["id"] == model_id for m in user):   # added from Hugging Face: gone from the list too
        _user_file().write_text(json.dumps([m for m in user if m["id"] != model_id], ensure_ascii=False, indent=1),
                                encoding="utf-8")


class MissingModel(RuntimeError):
    """A model the step needs isn't downloaded yet (the app offers to download it)."""

    def __init__(self, model_id: str):
        self.model_id = model_id
        super().__init__(tr("Для этого нужна модель «{title}» — она ещё не скачана.", title=tr(get(model_id)["title"])))


def require(model_id: str) -> Path:
    if not is_installed(model_id):
        raise MissingModel(model_id)
    return model_path(model_id)


def load_accentizer(target: Path):
    from ruaccent import RUAccent

    accentizer = RUAccent()
    accentizer.load(omograph_model_size="turbo3.1", use_dictionary=True, workdir=str(target))

    # Newer transformers stopped returning token_type_ids, which the accent ONNX model needs.
    import numpy as np

    tokenize = accentizer.accent_model.tokenizer

    def with_type_ids(*args, **kwargs):
        inputs = tokenize(*args, **kwargs)
        if "token_type_ids" not in inputs:
            inputs["token_type_ids"] = np.zeros_like(inputs["input_ids"])
        return inputs

    accentizer.accent_model.tokenizer = with_type_ids
    return accentizer


def load_watermarker(target: Path):
    """AudioSeal generator and detector, kept in the MadStudio models folder."""
    import os

    os.environ["AUDIOSEAL_CACHE_DIR"] = str(target)
    from audioseal import AudioSeal

    return AudioSeal.load_generator("audioseal_wm_16bits"), AudioSeal.load_detector("audioseal_detector_16bits")


_INSTALLERS = {"ruaccent": load_accentizer, "audioseal": load_watermarker}


def fit(model: dict, device: dict) -> dict:
    """How well a model suits this computer: "ok", "slow" or "no_memory"/"no_disk", with
    an honest note. The user may still pick a model that doesn't fit."""
    ram, free = device["ram_gb"], device["disk_free_gb"]
    if not model.get("installed") and model["size_gb"] + 1 > free:
        return {"fit": "no_disk", "note": tr("Не хватит места: нужно {need} ГБ, свободно {free} ГБ", need=model["size_gb"], free=free)}
    if model["ram_gb"] > ram * 0.6:
        return {"fit": "no_memory", "note": tr("Нужно ~{need} ГБ памяти из {ram} — может не запуститься", need=model["ram_gb"], ram=ram)}
    if model["ram_gb"] > ram * 0.35:
        return {"fit": "slow", "note": tr("Будет медленно на этом компьютере")}
    return {"fit": "ok", "note": tr("Подходит для этого компьютера")}


def _install_binary(model: dict, target: Path) -> None:
    """Downloads a program and checks it is exactly the published file (sha256)."""
    import hashlib
    import os
    import urllib.request

    path = target / model["binary"]
    tmp = path.with_suffix(".download")
    urllib.request.urlretrieve(model["url"], tmp)
    digest = hashlib.sha256(tmp.read_bytes()).hexdigest()
    if digest != model["sha256"]:
        tmp.unlink(missing_ok=True)
        raise RuntimeError(tr("Скачанный файл не совпал с опубликованным — установка отменена"))
    os.chmod(tmp, 0o755)
    tmp.replace(path)
