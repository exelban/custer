#!/usr/bin/env python3
"""Check the built artifact, including absence of updater code in store builds."""

import argparse
import plistlib
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("channel", choices=["github", "appstore"])
parser.add_argument("app", type=Path)
parser.add_argument("--signed", action="store_true")
args = parser.parse_args()

contents = args.app / "Contents"
info = plistlib.loads((contents / "Info.plist").read_bytes())
store = args.channel == "appstore"
expected_id = "eu.exelban.custer"
assert info["CFBundleIdentifier"] == expected_id, "Wrong distribution bundle identifier"
assert info["CFBundleVersion"].isdigit(), "Build number is unresolved"

manifest = plistlib.loads((contents / "Resources/PrivacyInfo.xcprivacy").read_bytes())
assert any(
    entry["NSPrivacyAccessedAPIType"] == "NSPrivacyAccessedAPICategoryUserDefaults"
    and "CA92.1" in entry["NSPrivacyAccessedAPITypeReasons"]
    for entry in manifest["NSPrivacyAccessedAPITypes"]
), "Missing defaults privacy reason"

scripts = list(contents.rglob("updater.sh"))
binary = contents / "MacOS" / info["CFBundleExecutable"]

# Inspect mangled names in both symbols and Swift runtime metadata: archives strip
# local symbols, but retain runtime type names. Swift small string literals may be
# encoded as instructions, so searching for "Custer.dmg" is unreliable.
has_updater = b"7Updater" in binary.read_bytes()
if store:
    assert not scripts, "App Store bundle contains updater.sh"
    assert not has_updater, "App Store executable links the Updater package"
else:
    assert scripts, "GitHub bundle is missing updater.sh"
    assert has_updater, "GitHub executable is missing Updater code"

if args.signed:
    subprocess.run(
        ["codesign", "--verify", "--deep", "--strict", str(args.app)],
        check=True,
    )
    if store:
        raw = subprocess.check_output(
            ["codesign", "-d", "--entitlements", "-", "--xml", str(args.app)]
        )
        entitlements = plistlib.loads(raw)
        assert entitlements.get("com.apple.security.app-sandbox") is True
        assert entitlements.get("com.apple.security.network.client") is True

print(
    f"Verified {args.channel}: "
    f"{info['CFBundleShortVersionString']} ({info['CFBundleVersion']})"
)
