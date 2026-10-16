#!/usr/bin/env python3
"""Checks that the container migration manifest ships only in the real Mac app.

DocumentArchive/container-migration.plist moves the archive from ~/Library into the app's sandbox
container on the first launch of a sandboxed build. Its paths are relative to the home folder, not
to the bundle identifier, so a sandboxed TEST build (DA_BUNDLE_ID_SUFFIX=.SandboxTests) that
carried it would move the real archive into the test container. Config/Project.xcconfig excludes
the file from every build with a suffix; this script proves it.

    python3 scripts/check-container-migration.py --app "build/Build/Products/Debug/Document Archive.app"
    python3 scripts/check-container-migration.py --settings     # needs xcodebuild, launches nothing
    python3 scripts/check-container-migration.py --self-test

--app: the built product. The real identifier must contain the manifest, any other identifier
must not. Run it on a sandboxed build before anything launches it (build-for-testing, check,
test-without-building).
--settings: asks xcodebuild for the app target's settings with and without a suffix and checks
that EXCLUDED_SOURCE_FILE_NAMES excludes the manifest exactly when there is a suffix.
"""
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile

REAL_BUNDLE_ID = "de.patrickklein.DocumentArchive"
MANIFEST = "container-migration.plist"


def check_app(app: str) -> list:
    """Returns the problems of a built macOS app bundle (empty when it is fine)."""
    info_path = os.path.join(app, "Contents", "Info.plist")
    try:
        with open(info_path, "rb") as f:
            bundle_id = plistlib.load(f).get("CFBundleIdentifier")
    except (OSError, plistlib.InvalidFileException) as error:
        return [f"cannot read {info_path}: {error}"]
    has_manifest = os.path.exists(os.path.join(app, "Contents", "Resources", MANIFEST))
    if bundle_id == REAL_BUNDLE_ID and not has_manifest:
        return [f"{app} ({bundle_id}) has no {MANIFEST}: the first signed build would start empty"]
    if bundle_id != REAL_BUNDLE_ID and has_manifest:
        return [f"{app} ({bundle_id}) contains {MANIFEST}: its first sandboxed launch would move "
                f"the real archive into its own container. Do not launch it."]
    return []


def excluded_files(suffix: str) -> str:
    output = subprocess.run(
        ["xcodebuild", "-showBuildSettings", "-project", "DocumentArchive.xcodeproj",
         "-target", "DocumentArchive", "-configuration", "Debug", "-sdk", "macosx",
         f"DA_BUNDLE_ID_SUFFIX={suffix}"],
        check=True, capture_output=True, text=True).stdout
    for line in output.splitlines():
        name, _, value = line.strip().partition(" = ")
        if name == "EXCLUDED_SOURCE_FILE_NAMES":
            return value
    return ""


def check_settings() -> list:
    problems = []
    if MANIFEST in excluded_files("").split():
        problems.append(f"the real app (no suffix) excludes {MANIFEST}")
    for suffix in [".SandboxTests", ".Something"]:
        if MANIFEST not in excluded_files(suffix).split():
            problems.append(f"a build with DA_BUNDLE_ID_SUFFIX={suffix} does not exclude {MANIFEST}")
    return problems


def make_app(folder: str, bundle_id: str, with_manifest: bool) -> str:
    app = os.path.join(folder, f"{bundle_id}.app")
    os.makedirs(os.path.join(app, "Contents", "Resources"))
    with open(os.path.join(app, "Contents", "Info.plist"), "wb") as f:
        plistlib.dump({"CFBundleIdentifier": bundle_id}, f)
    if with_manifest:
        with open(os.path.join(app, "Contents", "Resources", MANIFEST), "wb") as f:
            plistlib.dump({"Move": []}, f)
    return app


def self_test() -> None:
    folder = tempfile.mkdtemp()
    try:
        cases = [
            (REAL_BUNDLE_ID, True, True),
            (REAL_BUNDLE_ID, False, False),
            (REAL_BUNDLE_ID + ".SandboxTests", False, True),
            (REAL_BUNDLE_ID + ".SandboxTests", True, False),
            (REAL_BUNDLE_ID + "Other", True, False),
        ]
        for bundle_id, with_manifest, ok in cases:
            sub = tempfile.mkdtemp(dir=folder)
            problems = check_app(make_app(sub, bundle_id, with_manifest))
            assert (not problems) == ok, (bundle_id, with_manifest, problems)
        assert check_app(os.path.join(folder, "missing.app")), "an unreadable app is a problem"
    finally:
        shutil.rmtree(folder)
    print("self-test passed")


def main(args) -> int:
    if args == ["--self-test"]:
        self_test()
        return 0
    if len(args) == 2 and args[0] == "--app":
        problems = check_app(args[1])
    elif args == ["--settings"]:
        problems = check_settings()
    else:
        print(__doc__, file=sys.stderr)
        return 2
    for problem in problems:
        print(f"::error::{problem}")
    if not problems:
        print("container migration manifest: only in the real app")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
