#!/usr/bin/env python3
"""Decides whether a pull request changes anything the app build or tests depend on.

Reads the changed paths (one per line) from stdin and prints "true" when at least one of them
is app-relevant, "false" when the pull request only changes documentation or repository
metadata. CI skips the build and test jobs for "false"; skipped jobs satisfy the required checks.
An empty list prints "true": no pull request changes nothing, so an empty list means the diff
failed, and a broken filter must never skip the build.

    git diff --no-renames --name-only BASE...HEAD | python3 scripts/app-changes.py
    python3 scripts/app-changes.py --self-test

Not app-relevant: docs/, Markdown files anywhere, LICENSE, issue templates, labels, release
notes, Dependabot and the label workflows, the nightly UI test workflow, the gitleaks
configuration and hooks (gitleaks itself always runs). Everything else is relevant, including
ci.yml and scripts/ (a change to CI must prove itself by running it).
"""
import fnmatch
import sys

NOT_APP_RELEVANT = [
    "docs/*",
    "*.md",
    "LICENSE",
    "LICENSE.*",
    ".github/ISSUE_TEMPLATE/*",
    ".github/labels.json",
    ".github/labeler.yml",
    ".github/release.yml",
    ".github/dependabot.yml",
    ".github/workflows/labeler.yml",
    ".github/workflows/labels.yml",
    ".github/workflows/ui-tests.yml",
    ".gitleaks.toml",
    ".githooks/*",
]


def is_app_relevant(path: str) -> bool:
    # fnmatch's "*" also matches "/", so "docs/*" covers every file below docs/.
    return not any(fnmatch.fnmatchcase(path, pattern) for pattern in NOT_APP_RELEVANT)


def needs_app_build(paths) -> bool:
    paths = [p for p in (p.strip() for p in paths) if p]
    return not paths or any(is_app_relevant(p) for p in paths)


def self_test() -> None:
    cases = {
        ("docs/development/index.md",): False,
        ("README.md", "SECURITY.md", "docs/plans/x/y.md"): False,
        ("LICENSE", ".github/ISSUE_TEMPLATE/bug.yml", ".github/labels.json"): False,
        (".github/workflows/labeler.yml", ".github/workflows/ui-tests.yml", ".gitleaks.toml"): False,
        ("DocumentArchive/Notes.md",): False,
        # Empty: the diff failed or listed nothing; build rather than skip.
        (): True,
        ("", "  "): True,
        # A file moved out of the app: `git diff --no-renames` lists the old path too.
        ("DocumentArchive/Services/Old.swift", "docs/old/Old.swift"): True,
        ("DocumentArchive/Views/ContentView.swift",): True,
        ("docs/development/index.md", "DocumentArchive/Localizable.xcstrings"): True,
        ("DocumentArchive.xcodeproj/project.pbxproj",): True,
        (".github/workflows/ci.yml",): True,
        (".xcode-version",): True,
        (".github/actions/select-xcode/action.yml",): True,
        ("scripts/pick-simulator.py",): True,
        ("Config/Project.xcconfig",): True,
        ("DocumentArchiveUITests/MacSmokeTests.swift",): True,
        ("docs.swift",): True,
    }
    for paths, expected in cases.items():
        actual = needs_app_build(paths)
        assert actual == expected, f"{paths}: expected {expected}, got {actual}"
    print(f"self-test passed ({len(cases)} cases)")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    else:
        print("true" if needs_app_build(sys.stdin) else "false")
