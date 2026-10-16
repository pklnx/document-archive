#!/usr/bin/env python3
"""Checks that the privacy manifest declares exactly the required-reason APIs the app uses.

Searches the app's Swift files (DocumentArchive/**/*.swift) for the symbols of each
required-reason API category and compares the categories found with the ones declared in
DocumentArchive/PrivacyInfo.xcprivacy. Fails when a category is used but not declared (App
Store Connect rejects the upload) or declared but no longer used (the manifest claims more than
the app does). On macOS the manifest is also linted with `plutil -lint`.

    python3 scripts/check-privacy-manifest.py            # from the repository root
    python3 scripts/check-privacy-manifest.py --self-test

What counts as a use:
- a symbol from SYMBOLS below, not preceded by a letter, digit or "_" (so `lstat(` is not
  `stat(`, but `creationDateKey` is `creationDate`);
- not on a comment line (one starting with `//`);
- not on a line with `setAttributes(`: setting a file's modification date is a write, not a
  required-reason read (ArchiveMirror stamps the files it writes).
A new symbol of a category goes into SYMBOLS; a new category needs its manifest entry with the
reason code from Apple's list (https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api).
"""
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

MANIFEST = "DocumentArchive/PrivacyInfo.xcprivacy"
SOURCES = "DocumentArchive"

SYMBOLS = {
    "NSPrivacyAccessedAPICategoryUserDefaults": ["UserDefaults", "@AppStorage"],
    "NSPrivacyAccessedAPICategoryFileTimestamp": [
        "creationDate", "modificationDate", "contentModificationDate", "attributesOfItem",
        "getattrlist", "stat(",
    ],
    "NSPrivacyAccessedAPICategorySystemBootTime": ["systemUptime", "mach_absolute_time"],
    "NSPrivacyAccessedAPICategoryDiskSpace": ["volumeAvailableCapacity", "systemFreeSize", "statfs"],
    "NSPrivacyAccessedAPICategoryActiveKeyboards": ["activeInputModes"],
}

PATTERNS = {
    category: [re.compile(r"(?<![A-Za-z0-9_])" + re.escape(symbol)) for symbol in symbols]
    for category, symbols in SYMBOLS.items()
}

IGNORED_LINE_MARKERS = ["setAttributes("]


def uses_in_line(line: str):
    """The categories a single line of Swift uses."""
    stripped = line.strip()
    if stripped.startswith("//") or any(marker in line for marker in IGNORED_LINE_MARKERS):
        return set()
    return {category for category, patterns in PATTERNS.items() if any(p.search(line) for p in patterns)}


def used_categories(source_root: str):
    """Maps each used category to its first use ("path:line")."""
    found = {}
    for directory, _, files in sorted(os.walk(source_root)):
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(directory, name)
            with open(path, encoding="utf-8") as handle:
                for number, line in enumerate(handle, start=1):
                    for category in uses_in_line(line):
                        found.setdefault(category, f"{path}:{number}")
    return found


def declared_categories(manifest_path: str):
    """The categories of NSPrivacyAccessedAPITypes; each must name at least one reason."""
    with open(manifest_path, "rb") as handle:
        manifest = plistlib.load(handle)
    declared = set()
    errors = []
    for entry in manifest.get("NSPrivacyAccessedAPITypes", []):
        category = entry.get("NSPrivacyAccessedAPIType")
        if not entry.get("NSPrivacyAccessedAPITypeReasons"):
            errors.append(f"{category}: declared without a reason code")
        declared.add(category)
    return declared, errors


def check(source_root: str, manifest_path: str):
    """Returns the list of problems (empty when the manifest matches the code)."""
    used = used_categories(source_root)
    declared, errors = declared_categories(manifest_path)
    for category in sorted(set(used) - declared):
        errors.append(f"{category}: used ({used[category]}) but not declared in {manifest_path}")
    for category in sorted(declared - set(used)):
        if category not in SYMBOLS:
            errors.append(f"{category}: declared, but the check script does not know its symbols")
        else:
            errors.append(f"{category}: declared in {manifest_path} but no longer used")
    return errors


def lint(manifest_path: str):
    """`plutil -lint` on macOS; elsewhere plistlib's parse in check() has to do."""
    if shutil.which("plutil") is None or sys.platform != "darwin":
        print("plutil not available, lint skipped")
        return []
    result = subprocess.run(["plutil", "-lint", manifest_path], capture_output=True, text=True)
    return [] if result.returncode == 0 else [result.stdout.strip() or result.stderr.strip()]


def manifest_text(categories):
    entries = "".join(
        f"<dict><key>NSPrivacyAccessedAPIType</key><string>{c}</string>"
        f"<key>NSPrivacyAccessedAPITypeReasons</key><array><string>X</string></array></dict>"
        for c in categories
    )
    return (
        '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
        f"<key>NSPrivacyAccessedAPITypes</key><array>{entries}</array></dict></plist>"
    )


def self_test() -> None:
    defaults = "NSPrivacyAccessedAPICategoryUserDefaults"
    timestamp = "NSPrivacyAccessedAPICategoryFileTimestamp"
    cases = [
        # (description, Swift source, declared categories, expected problem count)
        ("declared and used", "let d = UserDefaults.standard\n", [defaults], 0),
        ("@AppStorage counts", '@AppStorage("x") var x = false\n', [defaults], 0),
        ("used but not declared", "let d = UserDefaults.standard\n", [], 1),
        ("declared but not used", "let x = 1\n", [defaults], 1),
        ("resource key counts", "let k: URLResourceKey = .contentModificationDateKey\n", [timestamp], 0),
        ("stat( counts", "let r = stat(path, &info)\n", [timestamp], 0),
        # ArchiveMirror stamps written files: a write is not a required-reason read.
        ("write-only match", "try? m.setAttributes([.modificationDate: date], ofItemAtPath: p)\n", [timestamp], 1),
        ("write-only match, undeclared", "try? m.setAttributes([.modificationDate: date], ofItemAtPath: p)\n", [], 0),
        ("createdAt is not creationDate", "let d = document.createdAt\n", [timestamp], 1),
        ("createdAt is not creationDate, undeclared", "let d = document.createdAt\n", [], 0),
        ("other identifiers", "let s = status(); let x = myUserDefaultsKey; lstat(p)\n", [], 0),
        ("comment line", "// UserDefaults are read elsewhere\n", [], 0),
        ("two categories", "UserDefaults.standard\nProcessInfo.processInfo.systemUptime\n",
         [defaults, "NSPrivacyAccessedAPICategorySystemBootTime"], 0),
    ]
    for description, source, declared, expected in cases:
        with tempfile.TemporaryDirectory() as root:
            sources = os.path.join(root, "DocumentArchive", "Services")
            os.makedirs(sources)
            with open(os.path.join(sources, "File.swift"), "w", encoding="utf-8") as handle:
                handle.write(source)
            manifest = os.path.join(root, "PrivacyInfo.xcprivacy")
            with open(manifest, "w", encoding="utf-8") as handle:
                handle.write(manifest_text(declared))
            problems = check(os.path.join(root, "DocumentArchive"), manifest)
            assert len(problems) == expected, f"{description}: expected {expected} problem(s), got {problems}"
    # A declaration without a reason code fails too.
    with tempfile.TemporaryDirectory() as root:
        manifest = os.path.join(root, "PrivacyInfo.xcprivacy")
        with open(manifest, "w", encoding="utf-8") as handle:
            handle.write(manifest_text([defaults]).replace("<string>X</string>", ""))
        with open(os.path.join(root, "File.swift"), "w", encoding="utf-8") as handle:
            handle.write("UserDefaults.standard\n")
        problems = check(root, manifest)
        assert len(problems) == 1 and "reason" in problems[0], problems
    print(f"self-test passed ({len(cases) + 1} cases)")


def main() -> int:
    problems = lint(MANIFEST) + check(SOURCES, MANIFEST)
    for problem in problems:
        print(f"error: {problem}")
    if problems:
        return 1
    used = sorted(used_categories(SOURCES))
    print(f"privacy manifest matches the code ({', '.join(used) or 'no required-reason APIs'})")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    else:
        sys.exit(main())
