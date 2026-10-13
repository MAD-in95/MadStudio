"""Basic info about the Mac the engine runs on."""

import os
import platform
import shutil
import subprocess

from .i18n import tr


def _sysctl(name: str) -> str:
    return subprocess.run(["sysctl", "-n", name], capture_output=True, text=True).stdout.strip()


def device_info() -> dict:
    return {
        "chip": _sysctl("machdep.cpu.brand_string"),
        "ram_gb": round(int(_sysctl("hw.memsize")) / 1024**3),
        "disk_free_gb": round(shutil.disk_usage(os.path.expanduser("~")).free / 1024**3),
        "macos": platform.mac_ver()[0],
        "python": platform.python_version(),
    }


if __name__ == "__main__":
    for key, value in device_info().items():
        print(f"{key}: {value}")


# MacBook Air M1 (8 GB) — the reference: what the speed test shows there and how long the
# real work took there (measured on 10-minute recordings while building MadStudio).
REFERENCE = {"compute_tflops": 2.0, "bandwidth_gbs": 36.0}
TASKS = [
    # id, title, seconds on the reference Mac, per what, limited by: compute (GPU) / memory
    ("transcribe", "Расшифровка", 180, "10 мин записи", "compute"),
    ("revoice", "Переозвучка фразы", 24, "фразу (первая — ещё ~20 с на загрузку)", "compute"),
    ("translate", "Перевод голосом", 26, "фразу", "compute"),
    ("separate", "Отделение фона", 120, "10 мин записи", "compute"),
    ("denoise", "Шумоподавление", 35, "10 мин записи", "compute"),
    ("shorts", "Моменты для Shorts", 95, "10 мин записи", "memory"),
    ("youtube", "Главы и описание", 70, "10 мин записи", "memory"),
]


def benchmark() -> dict:
    """A few seconds of work on the graphics chip: how fast it multiplies (what speech and
    voice models need) and how fast memory moves (what text models need)."""
    import time

    import mlx.core as mx

    n, reps = 2048, 20
    a = mx.random.normal((n, n)).astype(mx.float16)
    b = mx.random.normal((n, n)).astype(mx.float16)
    mx.eval(a @ b)
    t = time.perf_counter()
    for _ in range(reps):
        mx.eval(a @ b)
    compute = 2 * n ** 3 * reps / (time.perf_counter() - t) / 1e12

    x = mx.random.normal((64 * 1024 * 1024,)).astype(mx.float16)
    mx.eval(x.sum())
    t = time.perf_counter()
    for _ in range(reps):
        mx.eval((x * 1.0001).sum())
    bandwidth = x.nbytes * 2 * reps / (time.perf_counter() - t) / 1e9
    return {"compute_tflops": round(compute, 2), "bandwidth_gbs": round(bandwidth, 1)}


def estimates(bench: dict) -> list[dict]:
    """How long each kind of work will take on this Mac, scaled from the reference."""
    speed = {
        "compute": bench["compute_tflops"] / REFERENCE["compute_tflops"],
        "memory": bench["bandwidth_gbs"] / REFERENCE["bandwidth_gbs"],
    }
    return [{"id": i, "title": tr(title), "seconds": round(base / max(speed[kind], 0.05)), "per": tr(per)}
            for i, title, base, per, kind in TASKS]


def speed_test() -> dict:
    runs = [benchmark() for _ in range(3)]          # the best of three: background apps add noise
    bench = {k: max(r[k] for r in runs) for k in runs[0]}
    return {**device_info(), **bench, "estimates": estimates(bench),
            "relative": round(bench["compute_tflops"] / REFERENCE["compute_tflops"], 2)}
