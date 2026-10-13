"""Writes the third-party notices for the app bundle: every Python library inside with its
licence (read from its own metadata) plus ffmpeg/LAME. Run with the bundled Python."""
import sys
from importlib import metadata

HEAD = """MadStudio — third-party components inside the app
=================================================

Neural networks are not part of the app: the user downloads them in “Neural Network
Models”, each under its own licence (shown there). The Russian F5-TTS voice model is
CC BY-NC 4.0: non-commercial use only.

FFmpeg 9.0.2 — LGPL 2.1 or later. Built from unmodified sources
https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz without GPL parts (build script:
release/build-ffmpeg.sh). Shipped as separate programs in Contents/Resources/bin.
LAME 4.0 (MP3 encoder) — LGPL 2.0, https://lame.sourceforge.io

Python 3.12 (python-build-standalone) — PSF licence, https://www.python.org

Python libraries:
"""


def licence(d) -> str:
    m = d.metadata
    text = m.get("License-Expression") or ""
    if not text:
        lic = (m.get("License") or "").strip()
        text = lic if lic and len(lic) < 60 and "\n" not in lic else ""
    if not text:
        cls = [c.split("::")[-1].strip() for c in m.get_all("Classifier") or [] if c.startswith("License ::")]
        text = ", ".join(cls)
    return text or "see the package page"


rows = sorted({(d.metadata["Name"], d.version, licence(d)) for d in metadata.distributions()}, key=lambda r: r[0].lower())
with open(sys.argv[1], "w", encoding="utf-8") as f:
    f.write(HEAD)
    for name, version, lic in rows:
        f.write(f"  {name} {version} — {lic}\n")
