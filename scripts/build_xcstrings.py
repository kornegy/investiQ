#!/usr/bin/env python3
"""Builds InvestiQ/Resources/Localizable.xcstrings from Localization/*.json.

Source format: {"key": {"en": "...", "ru": "...", "cs": "..."}, ...}. All three languages are
mandatory (docs/UI_UX.md, spec §28). Arguments are pre-formatted strings: use %@ or %1$@, %2$@.
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Localization"
OUTPUT = ROOT / "InvestiQ" / "Resources" / "Localizable.xcstrings"
LANGUAGES = ["en", "ru", "cs"]


def load_sources():
    merged = {}
    for path in sorted(SOURCES.glob("*.json")):
        data = json.loads(path.read_text(encoding="utf-8"))
        for key, values in data.items():
            if key in merged:
                sys.exit(f"duplicate key {key} in {path.name}")
            merged[key] = values
    return merged


def main():
    entries = load_sources()
    strings = {}
    for key in sorted(entries):
        values = entries[key]
        missing = [lang for lang in LANGUAGES if not values.get(lang)]
        if missing:
            sys.exit(f"key {key} misses translations: {missing}")
        strings[key] = {
            "extractionState": "manual",
            "localizations": {
                lang: {"stringUnit": {"state": "translated", "value": values[lang]}} for lang in LANGUAGES
            },
        }
    catalog = {"sourceLanguage": "en", "strings": strings, "version": "1.0"}
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"wrote {len(strings)} keys to {OUTPUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
