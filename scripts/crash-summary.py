#!/usr/bin/env python3
"""Turns the crash reports of a failed test run into a Markdown summary for the CI job summary.

Reads the folder written by `xcrun xcresulttool export diagnostics` and prints, for every crash
report (`.ips`) in it, the process, the exception, the termination, the application-specific
information (`asi`, where a Swift `fatalError` message lands) and the top frames of the crashed
thread. For a crash of the test host (`app_name` "Document Archive") it also prints the whole
report in a collapsed block. Then the last lines the test host wrote in every test session that
never reported its end (the session that crashed). A crash in a test run (#59) then shows its
message without downloading the result bundle. The input is test data only; nothing from the
environment is printed. It never fails: without usable input it says so and exits 0.

    xcrun xcresulttool export diagnostics --path TestResults.xcresult --output-path diagnostics
    python3 scripts/crash-summary.py diagnostics >> "$GITHUB_STEP_SUMMARY"
    python3 scripts/crash-summary.py --self-test
"""
import json
import os
import re
import sys

HOST_APP = "Document Archive"
TOP_FRAMES = 8
TAIL_LINES = 50
# The job summary takes at most 1 MiB per step; a crash report is a few hundred KB.
MAX_REPORT_CHARS = 600_000
SESSION_START = "◇ Test run started."
SESSION_ENDS = ("✔ Test run with", "✘ Test run with")
NO_CRASH = "No crash report in the result bundle."
# "Document Archive[6985:26512]" in a log line: the process that wrote it.
LOG_PID = re.compile(r"\[(\d+):\d+\]")


def fence(text: str, language: str = "") -> str:
    """A Markdown code block that the text cannot end early."""
    ticks = "```"
    while ticks in text:
        ticks += "`"
    return f"{ticks}{language}\n{text}\n{ticks}"


def find_files(root: str, predicate) -> list:
    found = []
    for folder, _, names in os.walk(root):
        found += [os.path.join(folder, name) for name in names if predicate(name)]
    return sorted(found)


def frame_text(frame: dict, images: list) -> str:
    index = frame.get("imageIndex")
    image = images[index] if isinstance(index, int) and 0 <= index < len(images) else {}
    name = image.get("name") or "?"
    if frame.get("symbol"):
        return f"{name}: {frame['symbol']} + {frame.get('symbolLocation', 0)}"
    offset = frame.get("imageOffset")
    return f"{name} + 0x{offset:x}" if isinstance(offset, int) else name


def describe_report(path: str, root: str) -> list:
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    first, _, rest = text.partition("\n")
    header = json.loads(first)
    body = json.loads(rest)
    app = header.get("app_name") or body.get("procName") or "?"
    exception = body.get("exception") or {}
    termination = body.get("termination") or {}
    asi = body.get("asi")
    lines = [
        f"#### {app}: `{os.path.relpath(path, root)}`",
        "",
        f"- **Exception:** {exception.get('type', '?')} ({exception.get('signal', '?')}), "
        f"codes {exception.get('codes', '?')}",
        f"- **Termination:** {termination.get('indicator', '?')}",
        f"- **Application-specific information:** {json.dumps(asi) if asi else 'none'}",
    ]
    threads = body.get("threads") or []
    crashed = body.get("faultingThread")
    if isinstance(crashed, int) and 0 <= crashed < len(threads):
        thread = threads[crashed] or {}
        state = thread.get("threadState") or {}
        esr = (state.get("esr") or {}).get("description")
        if esr:
            lines.append(f"- **ESR:** {esr}")
        frames = [frame_text(f, body.get("usedImages") or []) for f in (thread.get("frames") or [])[:TOP_FRAMES]]
        lines += ["", f"Crashed thread {crashed} ({thread.get('queue', 'no queue')}):", "",
                  fence("\n".join(frames) or "no frames")]
    if app == HOST_APP:
        report = text if len(text) <= MAX_REPORT_CHARS else text[:MAX_REPORT_CHARS] + "\n… (cut)"
        lines += ["", "<details><summary>The whole crash report</summary>", "", fence(report, "json"), "",
                  "</details>"]
    return lines


def unfinished_sessions(text: str) -> list:
    """The test sessions in a host's output that never reported their end. A session ends early
    where another process (the relaunched host) starts writing."""
    lines = text.splitlines()
    starts = [i for i, line in enumerate(lines) if line.startswith(SESSION_START)]
    if not starts:
        return [lines] if lines else []
    sessions = []
    for start, end in zip(starts, starts[1:] + [len(lines)]):
        session = lines[start:end]
        if any(line.startswith(SESSION_ENDS) for line in session):
            continue
        owner = next((m.group(1) for line in reversed(lines[:start]) if (m := LOG_PID.search(line))), None)
        for i, line in enumerate(session):
            match = LOG_PID.search(line)
            if match and owner is None:
                owner = match.group(1)
            elif match and match.group(1) != owner:
                session = session[:i]
                break
        sessions.append(session)
    return sessions


def summarize(root: str) -> str:
    out = ["### Crash reports", ""]
    try:
        reports = find_files(root, lambda name: name.endswith(".ips"))
        for path in reports:
            try:
                out += describe_report(path, root) + [""]
            except Exception as error:
                out += [f"#### `{os.path.relpath(path, root)}`", "", f"Could not read it: {type(error).__name__}", ""]
        if not reports:
            out += [NO_CRASH, ""]
        for path in find_files(root, lambda name: name.startswith("StandardOutputAndStandardError")):
            try:
                with open(path, encoding="utf-8", errors="replace") as f:
                    sessions = unfinished_sessions(f.read())
            except OSError:
                continue
            for session in sessions:
                out += [f"#### Last {TAIL_LINES} lines of an unfinished session: `{os.path.relpath(path, root)}`", "",
                        fence("\n".join(session[-TAIL_LINES:])), ""]
    except Exception as error:
        out += [f"Could not read the diagnostics: {type(error).__name__}", ""]
    return "\n".join(out)


def self_test() -> None:
    import tempfile

    with tempfile.TemporaryDirectory() as root:
        # Nothing exported at all, or a folder without crash reports.
        assert NO_CRASH in summarize(os.path.join(root, "missing")), summarize(os.path.join(root, "missing"))
        assert NO_CRASH in summarize(root)

        reports = os.path.join(root, "Test_Diagnostics", "DiagnosticReports")
        os.makedirs(reports)
        header = {"app_name": HOST_APP, "bug_type": "309"}
        body = {
            "procName": HOST_APP,
            "exception": {"type": "EXC_BREAKPOINT", "signal": "SIGTRAP", "codes": "0x1, 0x1d2651490"},
            "termination": {"indicator": "Trace/BPT trap: 5"},
            "faultingThread": 0,
            "threads": [{"queue": "com.apple.main-thread",
                         "threadState": {"esr": {"description": "(Breakpoint) brk 1"}},
                         "frames": [{"imageIndex": 0, "imageOffset": 562320},
                                    {"imageIndex": 1, "symbol": "__NSFireTimer", "symbolLocation": 56},
                                    {"imageIndex": 7}]}],
            "usedImages": [{"name": "SwiftData"}, {"name": "Foundation"}],
            "note": "```",
        }
        with open(os.path.join(reports, "Document Archive-1.ips"), "w") as f:
            f.write(json.dumps(header) + "\n" + json.dumps(body, indent=2))
        other = dict(body, asi={"libswiftCore.dylib": ["Fatal error: boom"]})
        with open(os.path.join(reports, "Helper-1.ips"), "w") as f:
            f.write(json.dumps({"app_name": "Helper"}) + "\n" + json.dumps(other))
        with open(os.path.join(reports, "Broken.ips"), "w") as f:
            f.write("not json")

        session = os.path.join(root, "Test_Diagnostics", "Iteration-1", "DocumentArchiveTests-1")
        os.makedirs(session)
        crashed = [SESSION_START] + [f"line {i}" for i in range(80)] + ["Document Archive[6985:26512] host log"]
        relaunched = ["Document Archive[10558:37486] relaunched host", "relaunch",
                      SESSION_START, "✔ Test run with 0 tests in 24 suites passed after 0.281 seconds."]
        with open(os.path.join(session, "StandardOutputAndStandardError.txt"), "w") as f:
            f.write("\n".join(["Document Archive[6985:26512] preamble"] + crashed + relaunched))

        out = summarize(root)
        assert NO_CRASH not in out, out
        assert "EXC_BREAKPOINT (SIGTRAP), codes 0x1, 0x1d2651490" in out, out
        assert "SwiftData + 0x89490" in out and "Foundation: __NSFireTimer + 56" in out, out
        assert "\n?\n" in out, out   # a frame whose image is unknown
        assert "(Breakpoint) brk 1" in out and "Trace/BPT trap: 5" in out, out
        assert "**Application-specific information:** none" in out, out
        assert '"Fatal error: boom"' in out, out
        assert "Could not read it: JSONDecodeError" in out, out
        # The whole report only for the test host, in a fence its own backticks cannot close.
        assert out.count("<details>") == 1 and "````json" in out, out
        # Only the session that never ended, and only its last lines.
        assert "line 79" in out and "host log" in out and "line 31" in out and "line 30" not in out, out
        assert "0 tests in 24 suites" not in out and "preamble" not in out, out
        assert "relaunch" not in out, out

        # Output without session markers (an XCTest-only host) is shown as one session.
        assert unfinished_sessions("a\nb") == [["a", "b"]]
        assert unfinished_sessions("") == []
    print("self-test passed")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    elif len(sys.argv) == 2:
        print(summarize(sys.argv[1]))
    else:
        print(__doc__)
