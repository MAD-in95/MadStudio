#!/bin/zsh
# A build of MadStudio for other people: one app with everything inside (its own Python,
# libraries, engine, ffmpeg) and a .dmg to send. Neural networks are not inside — the program
# downloads them on first use, as before.
# Result: release/build/MadStudio.app and release/MadStudio-<version>.dmg
set -e
cd "$(dirname "$0")"
REL=$PWD
APP_SRC=$REL/../app

[[ -x build/ffmpeg/bin/ffmpeg ]] || ./build-ffmpeg.sh
[[ -x build/engine/python/bin/python3.12 && "$1" != "--fresh" ]] || ./build-engine.sh
# the engine code itself changes often: always take the current one
rsync -a --delete --exclude __pycache__ ../engine/madstudio_engine/ build/engine/madstudio_engine/
build/engine/python/bin/python3.12 -m compileall -q build/engine/madstudio_engine >/dev/null

(cd "$APP_SRC" && xcodegen generate --quiet && \
 xcodebuild -project MadStudio.xcodeproj -scheme MadStudio -configuration Release \
    -derivedDataPath build -quiet build)

APP=$REL/build/MadStudio.app
rm -rf "$APP"
cp -R "$APP_SRC/build/Build/Products/Release/MadStudio.app" "$APP"
RES=$APP/Contents/Resources
mkdir -p "$RES/bin"
cp build/ffmpeg/bin/ffmpeg build/ffmpeg/bin/ffprobe "$RES/bin/"
rsync -a build/engine/ "$RES/engine/"
"$RES/engine/python/bin/python3.12" -I "$REL/licenses.py" "$RES/THIRD-PARTY-LICENSES.txt"
# the developer's engine folder is only for development builds
/usr/libexec/PlistBuddy -c "Delete :MadStudioEngineDir" "$APP/Contents/Info.plist"

# every binary inside has to be signed on Apple Silicon; then the app as a whole.
# "-" is an ad-hoc signature (no Apple developer account yet).
IDENTITY=${MADSTUDIO_SIGN:--}
find "$RES" -type f \( -name "*.so" -o -name "*.dylib" -o -perm -u+x \) -print0 |
    while IFS= read -r -d '' f; do
        file -b "$f" | grep -q "Mach-O" && codesign --force --sign "$IDENTITY" "$f" 2>/dev/null
    done
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG=$REL/MadStudio-$VERSION.dmg
STAGE=$REL/build/dmg
rm -rf "$STAGE" "$DMG" && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$REL/How to open - Как открыть.txt" "$STAGE/"
hdiutil create -quiet -volname "MadStudio $VERSION" -srcfolder "$STAGE" -fs APFS -format ULMO "$DMG"
rm -rf "$STAGE"
du -sh "$APP" "$DMG"
