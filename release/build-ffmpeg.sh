#!/bin/zsh
# Builds our own ffmpeg/ffprobe for the app bundle: static (no Homebrew needed on another
# Mac), LGPL (no GPL parts), audio-only encoders, MP3 through LAME.
# Sources are checked against the sha256 sums Homebrew publishes for the same versions.
# Result: release/build/ffmpeg/bin/{ffmpeg,ffprobe}
set -e
cd "$(dirname "$0")"
ROOT=$PWD/build/ffmpeg
SRC=$PWD/build/sources
mkdir -p "$ROOT" "$SRC"

FFMPEG=ffmpeg-9.0.2;  FFMPEG_SHA=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
LAME=lame-4.0;        LAME_SHA=3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb

fetch() {  # url file sha
    [[ -f "$SRC/$2" ]] || curl -fL --retry 3 -o "$SRC/$2" "$1"
    echo "$3  $SRC/$2" | shasum -a 256 -c - >/dev/null || { echo "Контрольная сумма $2 не совпала"; rm -f "$SRC/$2"; exit 1; }
}
fetch https://ffmpeg.org/releases/$FFMPEG.tar.xz $FFMPEG.tar.xz $FFMPEG_SHA
fetch https://downloads.sourceforge.net/project/lame/lame/4.0/$LAME.tar.gz $LAME.tar.gz $LAME_SHA

export MACOSX_DEPLOYMENT_TARGET=15.0
JOBS=$(sysctl -n hw.ncpu)

if [[ ! -f "$ROOT/deps/lib/libmp3lame.a" ]]; then
    rm -rf "$SRC/$LAME" && tar -xf "$SRC/$LAME.tar.gz" -C "$SRC"
    (cd "$SRC/$LAME" && ./configure --prefix="$ROOT/deps" --disable-shared --enable-static \
        --disable-frontend --disable-decoder >/dev/null && make -j$JOBS >/dev/null && make install >/dev/null)
fi

rm -rf "$SRC/$FFMPEG" && tar -xf "$SRC/$FFMPEG.tar.xz" -C "$SRC"
cd "$SRC/$FFMPEG"
./configure --prefix="$ROOT" --arch=arm64 --cc=clang \
    --disable-autodetect --disable-shared --enable-static \
    --disable-doc --disable-ffplay --disable-network --disable-debug --disable-avdevice \
    --enable-libmp3lame \
    --disable-encoders \
    --enable-encoder=aac,alac,flac,libmp3lame,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le,wavpack,opus,png \
    --extra-cflags="-I$ROOT/deps/include" --extra-ldflags="-L$ROOT/deps/lib" >/dev/null
make -j$JOBS >/dev/null
make install >/dev/null
strip "$ROOT/bin/ffmpeg" "$ROOT/bin/ffprobe"
echo "Готово: $ROOT/bin"
