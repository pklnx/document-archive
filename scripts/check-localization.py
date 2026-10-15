#!/usr/bin/env python3
"""Checks that every UI string used in the code has a German translation.

Swift writes the strings it localizes into `.stringsdata` files during the build. Xcode's IDE
adds new ones to the String Catalog automatically, but `xcodebuild` does not, so a new UI text
could ship untranslated. This script compares both after a build:

    xcodebuild ... -derivedDataPath build build
    python3 scripts/check-localization.py build

Exit code 1 lists the keys that are missing from DocumentArchive/Localizable.xcstrings or have
no finished German translation.
"""
import json
import pathlib
import sys

derived_data = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "build")
catalog_path = pathlib.Path(__file__).resolve().parent.parent / "DocumentArchive" / "Localizable.xcstrings"

used = {}
for path in derived_data.glob("**/DocumentArchive.build/**/*.stringsdata"):
    data = json.loads(path.read_text(encoding="utf-8"))
    for entry in data.get("tables", {}).get("Localizable", []):
        used.setdefault(entry["key"], data.get("source", str(path)))

if not used:
    sys.exit(f"No .stringsdata files found under {derived_data} – build first with -derivedDataPath {derived_data}.")

catalog = json.loads(catalog_path.read_text(encoding="utf-8"))["strings"]
problems = []
for key, source in sorted(used.items()):
    unit = catalog.get(key, {}).get("localizations", {}).get("de", {}).get("stringUnit", {})
    if unit.get("state") != "translated" or not unit.get("value"):
        problems.append(f"  {key!r}  (used in {pathlib.Path(source).name})")

if problems:
    print("UI strings without a German translation in Localizable.xcstrings:")
    print("\n".join(problems))
    print("Add them in Xcode (the catalog editor lists new strings after a build) or by hand.")
    sys.exit(1)
print(f"All {len(used)} UI strings have a German translation.")
