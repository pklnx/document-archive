#!/usr/bin/env python3
"""Prints the UDID of an available simulator, chosen by screen size, not by name.

    python3 scripts/pick-simulator.py iphone smallest
    python3 scripts/pick-simulator.py ipad largest

Only devices on the newest installed iOS runtime are considered. The screen size (in points)
comes from the device type's capabilities.plist. Exits with an error if no device fits, instead
of silently picking an arbitrary one.
"""
import json
import plistlib
import subprocess
import sys


def main_screen_points(bundle_path):
    """Area of the main screen in points, or None if it cannot be read."""
    try:
        with open(f"{bundle_path}/Contents/Resources/capabilities.plist", "rb") as f:
            data = plistlib.load(f)
    except (OSError, plistlib.InvalidFileException):
        return None
    found = []

    def walk(value):
        if isinstance(value, dict):
            if value.get("screenID") == 1 and {"width", "height", "scale"} <= value.keys():
                found.append(value)
            for child in value.values():
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)

    walk(data)
    if not found:
        return None
    screen = found[0]
    scale = screen["scale"] or 1
    return (screen["width"] / scale) * (screen["height"] / scale)


def simctl(*args):
    return json.loads(subprocess.check_output(["xcrun", "simctl", "list", *args, "-j"]))


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("iphone", "ipad") or sys.argv[2] not in ("smallest", "largest"):
        sys.exit(__doc__)
    family = {"iphone": "iPhone", "ipad": "iPad"}[sys.argv[1]]

    runtimes = [r for r in simctl("runtimes")["runtimes"]
                if r.get("isAvailable") and r.get("platform", "iOS") == "iOS"]
    if not runtimes:
        sys.exit("No available iOS simulator runtime.")
    newest = max(runtimes, key=lambda r: [int(p) for p in r["version"].split(".")])

    types = {t["identifier"]: t for t in simctl("devicetypes")["devicetypes"]}
    candidates = []
    for device in simctl("devices", "available")["devices"].get(newest["identifier"], []):
        device_type = types.get(device.get("deviceTypeIdentifier"))
        if not device_type or device_type.get("productFamily") != family:
            continue
        area = main_screen_points(device_type["bundlePath"])
        if area:
            candidates.append((area, device["name"], device["udid"]))

    if not candidates:
        sys.exit(f"No available {family} simulator on iOS {newest['version']}.")
    area, name, udid = (min if sys.argv[2] == "smallest" else max)(candidates)
    print(f"{name} on iOS {newest['version']}", file=sys.stderr)
    print(udid)


main()
