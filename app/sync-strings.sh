#!/bin/zsh
# After adding or changing interface texts: collects them from the last build into
# MadStudio/Localizable.xcstrings (translations already there are kept) and lists the
# Russian texts that still have no English translation.
set -e
cd "$(dirname "$0")"
xcodebuild -project MadStudio.xcodeproj -scheme MadStudio -configuration Debug -derivedDataPath build build -quiet
xcrun xcstringstool sync MadStudio/Localizable.xcstrings \
    --stringsdata build/Build/Intermediates.noindex/MadStudio.build/Debug/MadStudio.build/Objects-normal/arm64/*.stringsdata
python3 - <<'PY'
import json, re
d = json.load(open("MadStudio/Localizable.xcstrings", encoding="utf-8"))
todo = [k for k, v in d["strings"].items()
        if re.search("[А-Яа-яЁё]", k) and "en" not in v.get("localizations", {})]
print(f"Без перевода: {len(todo)}")
for k in todo:
    print("  ", json.dumps(k, ensure_ascii=False))
PY
