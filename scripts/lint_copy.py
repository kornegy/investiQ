#!/usr/bin/env python3
"""Fails if user-facing copy contains manipulative or promissory phrases (spec §23, docs/UI_UX.md §6).

Scans Localization/*.json and bundled content (InvestiQKit/Sources/InvestiQContent/Resources).
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
BANNED = {
    "en": ["buy now", "sell now", "last chance", "you are missing out", "you're missing out", "don't miss",
           "guaranteed return", "guaranteed growth", "guaranteed profit", "risk-free return", "act now",
           "limited time", "hurry"],
    "ru": ["купите сейчас", "продайте сейчас", "последний шанс", "вы упускаете", "не упустите",
           "гарантированный доход", "гарантированная доходность", "гарантированный рост",
           "гарантированная прибыль", "спешите", "успейте"],
    "cs": ["kupte nyní", "kupte teď", "prodejte nyní", "poslední šance", "přicházíte o", "nenechte si ujít",
           "garantovaný výnos", "garantovaný zisk", "garantovaný růst", "pospěšte"],
}


def strings_in(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from strings_in(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings_in(item)


def main():
    files = list((ROOT / "Localization").glob("*.json"))
    files += list((ROOT / "InvestiQKit" / "Sources" / "InvestiQContent" / "Resources").rglob("*.json"))
    problems = []
    for path in files:
        data = json.loads(path.read_text(encoding="utf-8"))
        for text in strings_in(data):
            lowered = text.lower()
            for phrases in BANNED.values():
                for phrase in phrases:
                    if phrase in lowered:
                        problems.append(f"{path.relative_to(ROOT)}: banned phrase '{phrase}' in: {text[:80]}")
    if problems:
        print("\n".join(problems))
        sys.exit(1)
    print(f"copy lint OK ({len(files)} files)")


if __name__ == "__main__":
    main()
