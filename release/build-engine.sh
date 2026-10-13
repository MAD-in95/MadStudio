#!/bin/zsh
# Puts together the engine for the app bundle: its own Python 3.12 (relocatable build from
# python-build-standalone, the one uv uses), the exact library versions from uv.lock and the
# engine code. Nothing on another Mac is needed. Result: release/build/engine/
set -e
setopt null_glob
cd "$(dirname "$0")"
OUT=$PWD/build/engine
ENGINE=$PWD/../engine
rm -rf "$OUT" && mkdir -p "$OUT"

BASE=$(cd "$(dirname "$(uv python find 3.12)")/.." && pwd -P)
cp -R "$BASE" "$OUT/python"
PY="$OUT/python/bin/python3.12"
rm -f "$OUT/python/lib/python3.12/EXTERNALLY-MANAGED"

(cd "$ENGINE" && uv export --frozen --no-dev --no-hashes --no-emit-project --quiet -o "$OUT/requirements.txt")
uv pip install --quiet --python "$PY" -r "$OUT/requirements.txt"
rm "$OUT/requirements.txt"

# engine code (started as `python -m madstudio_engine` from this folder)
rsync -a --exclude __pycache__ "$ENGINE/madstudio_engine" "$OUT/"

# what the program never uses at run time
SITE="$OUT/python/lib/python3.12/site-packages"
find "$OUT" -name __pycache__ -type d -prune -exec rm -rf {} +
find "$SITE" -type d \( -name tests -o -name test \) -path "*/site-packages/*/*" -prune -exec rm -rf {} + 2>/dev/null || true
rm -rf "$OUT/python/lib/python3.12/test" "$OUT/python/lib/python3.12/idlelib" "$OUT/python/lib/python3.12/tkinter" \
       "$OUT/python/lib/tcl"* "$OUT/python/lib/tk"* "$OUT/python/lib/libtcl"* "$OUT/python/lib/libtk"* "$OUT/python/share" 2>/dev/null || true

# web demo of F5-TTS (never imported by MadStudio)
rm -rf "$SITE"/gradio "$SITE"/gradio-* "$SITE"/gradio_client "$SITE"/gradio_client-*

# compile once so the first start isn't slow (and nothing is written inside the app later)
"$PY" -m compileall -q -j 0 "$OUT/madstudio_engine" "$SITE" >/dev/null 2>&1 || true
du -sh "$OUT"
