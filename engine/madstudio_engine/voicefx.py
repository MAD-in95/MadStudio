"""Voice processing: noise removal (DeepFilterNet 3) and a "radio voice" chain.

Makes a processed copy of the voice that the speaker tracks play instead of the original;
the original is never changed. Timing stays exactly the same (delay is compensated), so
the text keeps matching the sound.
"""

import os
import subprocess
import tempfile

from . import models

# how much noise may be removed (dB): light keeps some room sound, strong removes all
DENOISE = {"light": 12, "medium": 24, "strong": 100}

# denser, clearer voice like on radio: no rumble, less boom, more presence, softer "с/ш",
# evened-out loudness
RADIO = ("highpass=f=80,equalizer=f=250:t=q:w=1:g=-2,equalizer=f=4000:t=q:w=1.2:g=3,"
         "deesser=i=0.4,acompressor=threshold=-20dB:ratio=3:attack=5:release=80:makeup=3,"
         "alimiter=limit=0.95:level=false:latency=1")


def process(source: str, out_path: str, denoise: str = "off", radio: bool = False, on_progress=None) -> dict:
    with tempfile.TemporaryDirectory() as tmp:
        current = source
        if denoise in DENOISE:
            binary = models.require(models.default_for("denoise")) / "deep-filter"
            wav48 = os.path.join(tmp, "voice.wav")
            # the model works at 48 kHz
            subprocess.run(["ffmpeg", "-v", "error", "-nostdin", "-y", "-i", source, "-ar", "48000",
                            "-c:a", "pcm_f32le", wav48], check=True)
            if on_progress:
                on_progress(0.2)
            out_dir = os.path.join(tmp, "clean")
            subprocess.run([str(binary), "-D", "-a", str(DENOISE[denoise]), "-o", out_dir, wav48],
                           check=True, capture_output=True)
            current = os.path.join(out_dir, "voice.wav")
            if on_progress:
                on_progress(0.8)
        filters = ["-af", RADIO] if radio else []
        subprocess.run(["ffmpeg", "-v", "error", "-nostdin", "-y", "-i", current, *filters, "-c:a", "flac", out_path],
                       check=True)
    if on_progress:
        on_progress(1.0)
    return {"path": out_path, "denoise": denoise, "radio": radio}
