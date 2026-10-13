"""Adds English translations to MadStudio/Localizable.xcstrings.
   python3 app/add-translations.py '{"Русский текст": "English text", …}'"""
import json
import sys
from pathlib import Path

catalog = Path(__file__).parent / "MadStudio" / "Localizable.xcstrings"
d = json.loads(catalog.read_text(encoding="utf-8"))
for key, value in json.loads(sys.argv[1]).items():
    entry = d["strings"].setdefault(key, {})
    loc = entry.setdefault("localizations", {})
    loc["en"] = {"stringUnit": {"state": "translated", "value": value}}
    loc["ru"] = {"stringUnit": {"state": "translated", "value": key}}
catalog.write_text(json.dumps(d, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")
