#!/usr/bin/env python3
"""Checks localisation completeness:
1. every key in Localization/*.json has en, ru and cs values with matching placeholders;
2. every literal localisation key used in Swift sources exists;
3. the generated Localizable.xcstrings is up to date;
4. the app never builds a SwiftUI key from an interpolated literal (`LocalizedStringKey("a.\\(b)")` looks up
   "a.%@" and shows the raw key on screen) and every key assembled at run time can match a real key.
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
    "rule", "thesis", "analysis", "strategy", "notifications", "data",
}
# The first argument of L10n.key(...) is a key prefix, not a complete key (checked by check_dynamic_keys).
NON_KEY_CONTEXTS = ("systemImage:", "systemName:", "accessibilityIdentifier(", "keyPrefix:", "identifier:", "L10n.key(")
PLACEHOLDER = re.compile(r"%(?:\d+\$)?[@dlfs]|%lld")
LITERAL = re.compile(r'"([a-z][A-Za-z0-9]*(?:\.[A-Za-z0-9]+)+)"')
# A dotted key literal with an interpolation right after a dot, e.g. "news.type.\(type.rawValue)".
INTERPOLATED_KEY = re.compile(r'"([a-z][A-Za-z0-9]*(?:\.[A-Za-z0-9]+)*)\.\\\(')
INTERPOLATED_LOCALIZED_KEY = re.compile(r'LocalizedStringKey\("[^"\n]*\\\(')
# Callees whose parameter is a plain String, where interpolation builds the key correctly.
STRING_KEY_CALLEES = ("L10n.string(", ".key(")
NOT_A_KEY_CALLEES = ("accessibilityIdentifier(",)
# One run-time segment of a key: an enum raw value such as "officialRelease" or "FC-NAIVE".
RUNTIME_SEGMENT = r"[A-Za-z0-9_-]+"
L10N_KEY_CALL = re.compile(r'L10n\.key\(')
KEY_PREFIX_ARGUMENT = re.compile(r'keyPrefix: "([a-z][A-Za-z0-9.]*)"')


def load():
    merged = {}
    for path in sorted((ROOT / "Localization").glob("*.json")):
        merged.update(json.loads(path.read_text(encoding="utf-8")))
    return merged


def call_arguments(text, start):
    """Top-level comma-separated arguments of the call whose opening parenthesis ends at `start`."""
    depth, current, arguments, index, in_string = 0, "", [], start, False
    while index < len(text):
        char = text[index]
        if char == '"' and text[index - 1] != "\\":
            in_string = not in_string
        elif not in_string and char in "([{":
            depth += 1
        elif not in_string and char in ")]}":
            if depth == 0:
                arguments.append(current.strip())
                return arguments
            depth -= 1
        elif not in_string and char == "," and depth == 0:
            arguments.append(current.strip())
            current = ""
            index += 1
            continue
        current += char
        index += 1
    return arguments


def dynamic_key_pattern(parts):
    """Regex for a key assembled from literal parts and run-time values (one segment each)."""
    segments = []
    for part in parts:
        literal = re.fullmatch(r'"([^"\\]*)"', part)
        segments.append(re.escape(literal.group(1)) if literal else RUNTIME_SEGMENT)
    return re.compile(r"\.".join(segments))


def check_dynamic_keys(entries, errors):
    keys = list(entries)
    for path in (ROOT / "InvestiQ").rglob("*.swift"):
        # Blank out comment lines (keeping line numbers) so documentation of the pitfall is not flagged.
        text = "\n".join("" if line.lstrip().startswith("//") else line
                         for line in path.read_text(encoding="utf-8").split("\n"))
        relative = path.relative_to(ROOT)
        for match in INTERPOLATED_LOCALIZED_KEY.finditer(text):
            line = text.count("\n", 0, match.start()) + 1
            errors.append(f"{relative}:{line}: interpolated LocalizedStringKey shows the raw key; use L10n.key(...)")
        patterns = []
        for match in INTERPOLATED_KEY.finditer(text):
            preceding = text[:match.start()].rstrip()
            if preceding.endswith(NOT_A_KEY_CALLEES):
                continue
            if preceding.endswith(STRING_KEY_CALLEES):
                patterns.append((match.start(), re.compile(re.escape(match.group(1)) + r"\.[A-Za-z0-9_.-]+")))
                continue
            line = text.count("\n", 0, match.start()) + 1
            errors.append(f"{relative}:{line}: interpolated key literal \"{match.group(1)}.\\(...)\" is looked up as "
                          f"\"{match.group(1)}.%@\" by SwiftUI; use L10n.key(...)")
        for match in L10N_KEY_CALL.finditer(text):
            parts = call_arguments(text, match.end())
            patterns.append((match.start(), dynamic_key_pattern(parts)))
        for match in KEY_PREFIX_ARGUMENT.finditer(text):
            patterns.append((match.start(), re.compile(re.escape(match.group(1)) + r"\." + RUNTIME_SEGMENT)))
        for offset, pattern in patterns:
            if not any(pattern.fullmatch(key) for key in keys):
                line = text.count("\n", 0, offset) + 1
                errors.append(f"{relative}:{line}: no localisation key matches the run-time key /{pattern.pattern}/")
    return errors


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
        # Templates with arguments go through String(format:): a literal percent sign must be written %%.
        for lang in LANGUAGES:
            value = values.get(lang, "")
            if PLACEHOLDER.search(value) and "%" in PLACEHOLDER.sub("", value).replace("%%", ""):
                errors.append(f"{key}: unescaped % in a formatted {lang} template (use %%)")

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

    check_dynamic_keys(entries, errors)

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
