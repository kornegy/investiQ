#!/usr/bin/env python3
"""Builds InvestiQContent lesson resources (one JSON per language) from Content/lessons/*.py.

Language-independent fields (id, order, stage, minutes, calculator, quiz answers) are defined once, so the
three languages cannot drift apart. The script fails on any structural inconsistency.
"""
import importlib, json, pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Content" / "lessons"
OUTPUT = ROOT / "InvestiQKit" / "Sources" / "InvestiQContent" / "Resources" / "lessons"
LANGUAGES = ("en", "ru", "cs")
CALCULATORS = {None, "compoundInterest", "inflation", "diversification", "feeDrag", "currency"}

def load():
    sys.path.insert(0, str(SOURCE))
    for path in sorted(SOURCE.glob("lessons_*.py")):
        importlib.import_module(path.stem)
    return importlib.import_module("lessons_1").LESSONS

def check(lessons):
    errors, seen = [], set()
    for lesson in lessons:
        lid = lesson["id"]
        if lid in seen: errors.append(f"{lid}: duplicate id")
        seen.add(lid)
        if lesson["calculator"] not in CALCULATORS: errors.append(f"{lid}: unknown calculator")
        for lang in LANGUAGES:
            text = lesson[lang]
            for field in ("t", "s", "a"):
                if not text[field].strip(): errors.append(f"{lid}/{lang}: empty {field}")
            if len(text["sec"]) < 2: errors.append(f"{lid}/{lang}: needs at least two sections")
            if len(text["k"]) < 3: errors.append(f"{lid}/{lang}: needs three key points")
            if len(text["q"]) != len(lesson["correct"]): errors.append(f"{lid}/{lang}: quiz length differs from answers")
            for index, (question, options, explanation) in enumerate(text["q"]):
                if len(options) != 3: errors.append(f"{lid}/{lang}: question {index} needs three options")
                if not question.strip() or not explanation.strip(): errors.append(f"{lid}/{lang}: question {index} incomplete")
        if len({len(lesson[lang]["sec"]) for lang in LANGUAGES}) > 1: errors.append(f"{lid}: section count differs between languages")
    return errors

def export(lessons, lang):
    return {"version": 1, "language": lang, "lessons": [{
        "id": lesson["id"], "order": order + 1, "stage": lesson["stage"], "minutes": lesson["minutes"],
        "calculator": lesson["calculator"], "title": lesson[lang]["t"], "summary": lesson[lang]["s"],
        "sections": [{"heading": h, "body": b} for h, b in lesson[lang]["sec"]],
        "analogy": lesson[lang]["a"], "keyPoints": lesson[lang]["k"],
        "quiz": [{"question": q, "options": o, "correctIndex": lesson["correct"][i], "explanation": e}
                 for i, (q, o, e) in enumerate(lesson[lang]["q"])],
    } for order, lesson in enumerate(sorted(lessons, key=lambda l: l["stage"]))]}

def main():
    lessons = load()
    errors = check(lessons)
    if errors:
        print("\n".join(errors)); sys.exit(1)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for lang in LANGUAGES:
        (OUTPUT / f"{lang}.json").write_text(json.dumps(export(lessons, lang), ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"wrote {len(lessons)} lessons × {len(LANGUAGES)} languages")
    if "--answers" in sys.argv:
        for lesson in lessons:
            for i, (q, o, _) in enumerate(lesson["en"]["q"]):
                print(f"{lesson['id']:<26} {q[:70]:<70} -> {o[lesson['correct'][i]]}")

if __name__ == "__main__":
    main()
