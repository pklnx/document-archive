#!/usr/bin/env python3
"""Checks the app's logging rules (docs/development/index.md -> Logging and diagnostics).

Searches the app's Swift files (DocumentArchive/**/*.swift; the unit and UI tests are not
checked) and fails on:
- `print(`, `debugPrint(`, `NSLog(` and `dump(` calls: the app logs through `Log` (os.Logger),
  so messages have a category, a level and privacy annotations;
- a `Log.<category>.<level>(...)` call whose interpolations mention `apiKey`, `key)` or
  `Authorization`: the API key and request headers are never logged.

    python3 scripts/check-logging.py            # from the repository root
    python3 scripts/check-logging.py --self-test

What counts as a call: the name not preceded by a letter, digit, "_" or "." (so
`DocumentPrinter.print(job)` and `Self.print(document)` are other functions), and not a
declaration (`func print(`). Comment lines (starting with `//`) are skipped. A log call is read
up to its closing parenthesis, also across lines.
"""
import os
import re
import sys
import tempfile

SOURCES = "DocumentArchive"

FORBIDDEN_CALL = re.compile(r"(?<![A-Za-z0-9_.])(print|debugPrint|NSLog|dump)\(")
DECLARATION = re.compile(r"\bfunc\s+$")
LOG_CALL = re.compile(r"\bLog\.[A-Za-z_]+\.[A-Za-z_]+\(")
SECRET_TERMS = ["apiKey", "key)", "Authorization"]


def strip_comments(text: str) -> str:
    """Blanks out comment lines, keeping the line numbers."""
    return "\n".join("" if line.strip().startswith("//") else line for line in text.split("\n"))


def call_arguments(text: str, open_paren: int) -> str:
    """The text between the parenthesis at `open_paren` and its matching closing one."""
    depth = 0
    for index in range(open_paren, len(text)):
        if text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                return text[open_paren + 1:index]
    return text[open_paren + 1:]


def interpolations(arguments: str):
    r"""The contents of every `\( ... )` in the arguments, with balanced parentheses."""
    found = []
    index = arguments.find("\\(")
    while index != -1:
        found.append(call_arguments(arguments, index + 1) + ")")
        index = arguments.find("\\(", index + 2)
    return found


def problems_in(text: str, path: str):
    text = strip_comments(text)
    problems = []
    for match in FORBIDDEN_CALL.finditer(text):
        line_start = text.rfind("\n", 0, match.start()) + 1
        if DECLARATION.search(text[line_start:match.start()]):
            continue
        number = text.count("\n", 0, match.start()) + 1
        problems.append(f"{path}:{number}: {match.group(1)}( in app code; log through Log (os.Logger) instead")
    for match in LOG_CALL.finditer(text):
        arguments = call_arguments(text, match.end() - 1)
        for part in interpolations(arguments):
            for term in SECRET_TERMS:
                if term in part:
                    number = text.count("\n", 0, match.start()) + 1
                    problems.append(f"{path}:{number}: log call interpolates {term!r}; never log the API key or headers")
    return problems


def check(source_root: str):
    problems = []
    for directory, _, files in sorted(os.walk(source_root)):
        for name in sorted(files):
            if name.endswith(".swift"):
                path = os.path.join(directory, name)
                with open(path, encoding="utf-8") as handle:
                    problems += problems_in(handle.read(), path)
    return problems


def self_test() -> None:
    cases = [
        # (description, Swift source in the app, expected problem count)
        ("print in app code", 'print("hello")\n', 1),
        ("indented print", '    if x { print(error) }\n', 1),
        ("debugPrint", "debugPrint(value)\n", 1),
        ("NSLog", 'NSLog("%@", value)\n', 1),
        ("dump", "dump(value)\n", 1),
        ("method named print", "DocumentPrinter.print(job)\nSelf.print(document)\n", 0),
        ("declaration", "static func print(_ job: PrintJob) {}\n", 0),
        ("other identifiers", "blueprint(x); reprint(y); dumpState()\n", 0),
        ("comment line", '// print("debug")\n', 0),
        ("API key in a log call", 'Log.mistral.debug("\\(config.apiKey)")\n', 1),
        ("key in a log call", 'Log.store.notice("key \\(key)")\n', 1),
        ("header in a log call", 'Log.mistral.notice("\\(request.value(forHTTPHeaderField: "Authorization") ?? "")")\n', 1),
        ("API key across lines", 'Log.mistral.error(\n    "failed \\(config.apiKey, privacy: .private)"\n)\n', 1),
        ("allowed log call", 'Log.mistral.notice("\\(endpoint, privacy: .public): status \\(status, privacy: .public)")\n', 0),
        ("key name outside an interpolation", 'Log.store.notice("API key saved")\n', 0),
        ("apiKey outside a log call", "let fingerprint = MistralConfig.fingerprint(config.apiKey)\n", 0),
    ]
    for description, source, expected in cases:
        with tempfile.TemporaryDirectory() as root:
            app = os.path.join(root, "DocumentArchive", "Services")
            os.makedirs(app)
            with open(os.path.join(app, "File.swift"), "w", encoding="utf-8") as handle:
                handle.write(source)
            problems = check(os.path.join(root, "DocumentArchive"))
            assert len(problems) == expected, f"{description}: expected {expected} problem(s), got {problems}"
    # Tests may print: only the app folder is checked.
    with tempfile.TemporaryDirectory() as root:
        os.makedirs(os.path.join(root, "DocumentArchive"))
        tests = os.path.join(root, "DocumentArchiveTests")
        os.makedirs(tests)
        with open(os.path.join(tests, "SomeTests.swift"), "w", encoding="utf-8") as handle:
            handle.write('print("in a test")\n')
        problems = check(os.path.join(root, "DocumentArchive"))
        assert problems == [], f"print in tests: expected no problems, got {problems}"
    print(f"self-test passed ({len(cases) + 1} cases)")


def main() -> int:
    problems = check(SOURCES)
    for problem in problems:
        print(f"error: {problem}")
    if problems:
        return 1
    print("logging rules hold")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    else:
        sys.exit(main())
