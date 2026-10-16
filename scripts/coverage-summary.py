#!/usr/bin/env python3
"""Turns an xccov coverage report into a Markdown summary for the CI job summary.

Reads the JSON of `xcrun xccov view --report --json <result bundle>` from stdin and prints the
line coverage of the app target and its least covered files (only files with enough executable
lines to matter). It never fails: without usable input it prints "no coverage data" and exits 0,
so coverage stays information and never becomes a gate.

    xcrun xccov view --report --json TestResults.xcresult | python3 scripts/coverage-summary.py
    python3 scripts/coverage-summary.py --self-test
"""
import json
import os
import sys

APP_TARGET = "Document Archive.app"
MIN_EXECUTABLE_LINES = 50
LEAST_COVERED_COUNT = 10
NO_DATA = "No coverage data."


def percent(covered: int, executable: int) -> str:
    return f"{100 * covered / executable:.1f} %" if executable else "–"


def display_path(file: dict, root: str) -> str:
    path = file.get("path") or file.get("name", "?")
    # Either side may be reported through a symbolic link (/var and /private/var on macOS).
    relative = os.path.relpath(os.path.realpath(path), os.path.realpath(root))
    return file.get("name", path) if relative.startswith("..") else relative


def summarize(text: str, root: str) -> str:
    # Anything unexpected in the report (missing keys, null instead of a list, strings instead of
    # numbers) means "no coverage data", never a failed job: catch broadly.
    try:
        return format_report(json.loads(text), root)
    except Exception:
        return f"### Code coverage\n\n{NO_DATA}\n"


def format_report(report, root: str) -> str:
    target = next(t for t in report["targets"] if t.get("name") == APP_TARGET)
    covered, executable = target.get("coveredLines", 0), target.get("executableLines", 0)
    lines = [
        "### Code coverage",
        "",
        f"**{APP_TARGET}:** {percent(covered, executable)} of lines ({covered} of {executable}).",
    ]
    files = [f for f in target.get("files", []) if f.get("executableLines", 0) >= MIN_EXECUTABLE_LINES]
    files.sort(key=lambda f: (f.get("coveredLines", 0) / f["executableLines"], display_path(f, root)))
    if files:
        lines += [
            "",
            f"Least covered files with at least {MIN_EXECUTABLE_LINES} executable lines:",
            "",
            "| File | Coverage | Covered lines |",
            "|---|---:|---:|",
        ]
        for f in files[:LEAST_COVERED_COUNT]:
            lines.append(f"| `{display_path(f, root)}` | {percent(f.get('coveredLines', 0), f['executableLines'])} "
                         f"| {f.get('coveredLines', 0)} of {f['executableLines']} |")
    return "\n".join(lines) + "\n"


def self_test() -> None:
    def file(name, covered, executable, folder="/w/DocumentArchive/Views"):
        return {"name": name, "path": f"{folder}/{name}", "coveredLines": covered, "executableLines": executable}

    sample = json.dumps({"targets": [
        # The product name exactly as xccov reports it: a renamed product makes this test fail.
        {"name": "Document Archive.app", "coveredLines": 300, "executableLines": 400, "files": [
            file("Half.swift", 50, 100),
            file("Tenth.swift", 10, 100),
            file("Full.swift", 60, 60),
            file("Small.swift", 0, 49),
            file("Outside.swift", 25, 100, folder="/elsewhere"),
        ]},
        {"name": "DocumentArchiveTests.xctest", "coveredLines": 0, "executableLines": 500, "files": [
            file("Uncovered.swift", 0, 500, folder="/w/DocumentArchiveTests"),
        ]},
    ]})
    out = summarize(sample, "/w")
    assert "**Document Archive.app:** 75.0 % of lines (300 of 400)." in out, out
    rows = [line for line in out.splitlines() if line.startswith("| `")]
    assert rows == [
        "| `DocumentArchive/Views/Tenth.swift` | 10.0 % | 10 of 100 |",
        "| `Outside.swift` | 25.0 % | 25 of 100 |",
        "| `DocumentArchive/Views/Half.swift` | 50.0 % | 50 of 100 |",
        "| `DocumentArchive/Views/Full.swift` | 100.0 % | 60 of 60 |",
    ], rows
    assert "Small.swift" not in out and "Uncovered.swift" not in out, out

    many = json.dumps({"targets": [{"name": APP_TARGET, "coveredLines": 0, "executableLines": 1200,
                                    "files": [file(f"F{i:02}.swift", i, 100) for i in range(12)]}]})
    rows = [line for line in summarize(many, "/w").splitlines() if line.startswith("| `")]
    assert len(rows) == LEAST_COVERED_COUNT and "F00.swift" in rows[0] and "F09.swift" in rows[-1], rows

    # Unusable input of every shape, including wrong types (TypeError) anywhere in the report.
    broken = [
        {"targets": None},
        {"targets": [None]},
        {"targets": [{"name": APP_TARGET, "coveredLines": "300", "executableLines": 400}]},
        {"targets": [{"name": APP_TARGET, "coveredLines": 1, "executableLines": 2, "files": None}]},
        {"targets": [{"name": APP_TARGET, "coveredLines": 1, "executableLines": 2,
                      "files": [{"name": "A.swift", "coveredLines": None, "executableLines": 60}]}]},
        None,
        "text",
        42,
    ]
    for empty in ["", "not json", "[]", "{}", json.dumps({"targets": [{"name": "Other.app"}]})] + \
            [json.dumps(b) for b in broken]:
        assert NO_DATA in summarize(empty, "/w"), empty
    print("self-test passed")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    else:
        print(summarize(sys.stdin.read(), os.getcwd()), end="")
