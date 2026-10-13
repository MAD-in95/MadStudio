"""Where MadStudio keeps its data on disk."""

import json
import os
import shutil
from pathlib import Path

from .i18n import tr

MODELS_FOLDER_NAME = "MadStudio — модели"   # created inside the folder the person picks


def home() -> Path:
    """Root data folder; MADSTUDIO_HOME overrides it (used by tests)."""
    override = os.environ.get("MADSTUDIO_HOME")
    root = Path(override) if override else Path.home() / "Library" / "Application Support" / "MadStudio"
    root.mkdir(parents=True, exist_ok=True)
    return root


def _settings_file() -> Path:
    return home() / "settings.json"


def settings() -> dict:
    try:
        return json.loads(_settings_file().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def save_settings(values: dict) -> None:
    _settings_file().write_text(json.dumps({**settings(), **values}, ensure_ascii=False, indent=1), encoding="utf-8")


def default_models_dir() -> Path:
    return home() / "models"


def models_dir() -> Path:
    """The folder with the neural networks: chosen by the person (e.g. on an external disk)
    or inside MadStudio's own folder. A folder on an unplugged disk is not created."""
    custom = settings().get("models_dir")
    path = Path(custom) if custom else default_models_dir()
    if custom and not path.parent.exists():
        return path            # the disk is not connected: nothing installed is found there
    path.mkdir(parents=True, exist_ok=True)
    return path


def models_dir_status() -> dict:
    path = models_dir()
    available = path.exists()
    used = sum(f.stat().st_size for f in path.rglob("*") if f.is_file()) if available else 0
    free = shutil.disk_usage(path if available else Path.home()).free
    return {"path": str(path), "custom": "models_dir" in settings(), "available": available,
            "used_gb": round(used / 1024 ** 3, 2), "free_gb": round(free / 1024 ** 3, 1)}


def move_models(target_parent: str, on_progress=None) -> dict:
    """Moves all models into «MadStudio — модели» inside the chosen folder (or back to the
    default place when it is empty). Copies, checks the copy, then removes the old files."""
    source = models_dir()
    if source.is_symlink():   # a test copy borrowing the real models: never move those from here
        raise RuntimeError(tr("Эта папка с моделями — ссылка на другую; переносить её отсюда нельзя"))
    target = Path(target_parent) / MODELS_FOLDER_NAME if target_parent else default_models_dir()
    if target.resolve() == source.resolve():
        return models_dir_status()
    if not source.exists():
        raise RuntimeError(tr("Старая папка с моделями недоступна — подключите диск, на котором она была"))
    files = [f for f in source.rglob("*") if f.is_file()]
    total = sum(f.stat().st_size for f in files)
    target.mkdir(parents=True, exist_ok=True)
    free = shutil.disk_usage(target).free
    if total > free - 512 * 1024 ** 2:
        raise RuntimeError(tr("В выбранной папке не хватит места: нужно {need} ГБ, свободно {free} ГБ",
                              need=f"{total / 1024 ** 3:.1f}", free=f"{free / 1024 ** 3:.1f}"))
    if _same_disk(source, target):          # same disk: just rename
        for item in source.iterdir():
            shutil.move(str(item), str(target / item.name))
    else:
        done = 0
        for f in files:
            dest = target / f.relative_to(source)
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(f, dest)
            done += f.stat().st_size
            if on_progress:
                on_progress(done / max(total, 1))
        copied = sum((target / f.relative_to(source)).stat().st_size for f in files)
        if copied != total:
            raise RuntimeError(tr("Копия не совпала с оригиналом — модели остались на старом месте"))
        for item in source.iterdir():
            shutil.rmtree(item) if item.is_dir() and not item.is_symlink() else item.unlink()
    s = settings()
    if target_parent:
        s["models_dir"] = str(target)
    else:
        s.pop("models_dir", None)
    _settings_file().write_text(json.dumps(s, ensure_ascii=False, indent=1), encoding="utf-8")
    return models_dir_status()


def _same_disk(a: Path, b: Path) -> bool:
    return os.stat(a).st_dev == os.stat(b).st_dev
