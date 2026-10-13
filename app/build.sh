#!/bin/zsh
# Builds the Mac app and puts MadStudio.app in the project root for double-click launch.
set -e
cd "$(dirname "$0")"
xcodegen generate --quiet
xcodebuild -project MadStudio.xcodeproj -scheme MadStudio -configuration Debug -derivedDataPath build build -quiet
rm -rf ../MadStudio.app
cp -R build/Build/Products/Debug/MadStudio.app ../MadStudio.app
echo "Готово: $(cd .. && pwd)/MadStudio.app"
