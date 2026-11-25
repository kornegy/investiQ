#!/usr/bin/env python3
"""Checks localisation completeness:
1. every key in Localization/*.json has en, ru and cs values with matching placeholders;
2. every literal localisation key used in Swift sources exists;
3. the generated Localizable.xcstrings is up to date.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LANGUAGES = ["en", "ru", "cs"]
NAMESPACES = {
    "common", "app", "error", "value", "a11y", "delay", "source", "quality", "status", "demo", "disclaimer",
    "link", "menu", "section", "welcome", "profile", "password", "lock", "auth", "onboarding", "validation",
    "safety", "educationalMode", "settings", "legal", "dashboard", "market", "asset", "portfolio", "transaction",
    "news", "calendar", "risk", "stress", "forecast", "planner", "simulator", "brokers", "learn", "quiz",
    "analytics", "bond", "etf", "stock", "provider", "ai", "backup", "export", "import", "notification",
    "range", "metric", "method", "scenario", "overview", "allocation", "dashboard", "category", "statement", "uncertainty", "instrument",
}
NON_KEY_CONTEXTS = ("systemImage:", "systemName:", "accessibilityIdentifier(", "keyPrefix:", "identifier:")
PLACEHOLDER = re.compile(r"%(?:\d+\$)?[@dlfs]|%lld")
LITERAL = re.compile(r'"([a-z][A-Za-z0-9]*(?:\.[A-Za-z0-9]+)+)"')


def load():
    merged = {}
    for path in sorted((ROOT / "Localization").glob("*.json")):
        merged.update(json.loads(path.read_text(encoding="utf-8")))
    return merged


def main():
    errors = []
    entries = load()
    for key, values in entries.items():
        for lang in LANGUAGES:
            if not values.get(lang, "").strip():
                errors.append(f"{key}: missing {lang}")
        placeholders = {lang: sorted(PLACEHOLDER.findall(values.get(lang, ""))) for lang in LANGUAGES}
        if len({tuple(p) for p in placeholders.values()}) > 1:
            errors.append(f"{key}: placeholder mismatch {placeholders}")

    used = set()
    for directory in [ROOT / "InvestiQ", ROOT / "InvestiQKit" / "Sources"]:
        for path in directory.rglob("*.swift"):
            text = path.read_text(encoding="utf-8")
            for match in LITERAL.finditer(text):
                key = match.group(1)
                context = text[max(0, match.start() - 32):match.start()]
                # SF Symbols, accessibility identifiers and dynamic key prefixes are not localisation keys.
                if any(marker in context for marker in NON_KEY_CONTEXTS):
                    continue
                if key.split(".")[0] in NAMESPACES:
                    used.add((key, path.relative_to(ROOT)))
    for key, path in sorted(used):
        if key not in entries:
            errors.append(f"{path}: key '{key}' not in Localization/*.json")

    catalog_path = ROOT / "InvestiQ" / "Resources" / "Localizable.xcstrings"
    catalog = json.loads(catalog_path.read_text(encoding="utf-8")) if catalog_path.exists() else {"strings": {}}
    if set(catalog["strings"]) != set(entries):
        errors.append("Localizable.xcstrings is out of date: run scripts/build_xcstrings.py")

    if errors:
        print("\n".join(errors))
        sys.exit(1)
    print(f"l10n OK: {len(entries)} keys × {len(LANGUAGES)} languages, {len(used)} literal usages verified")


if __name__ == "__main__":
    main()
