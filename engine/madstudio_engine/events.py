"""Progress messages for the app: one JSON object per stdout line."""

import contextlib
import json
import sys

_pinned = None


@contextlib.contextmanager
def pinned_stdout():
    """Keeps events going to the current stdout while libraries' prints are redirected."""
    global _pinned
    _pinned = sys.stdout
    try:
        yield
    finally:
        _pinned = None


def emit(event: str, **data) -> None:
    out = _pinned or sys.stdout
    out.write(json.dumps({"event": event, **data}, ensure_ascii=False) + "\n")
    out.flush()


def progress(stage: str, value: float, **data) -> None:
    emit("progress", stage=stage, value=round(max(0.0, min(1.0, value)), 4), **data)
