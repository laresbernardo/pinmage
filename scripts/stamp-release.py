#!/usr/bin/env python3
"""Emit the hosting manifest from the successfully built app, never a stale source plist."""
import datetime
import json
import pathlib
import plistlib
import sys

bundle = pathlib.Path(sys.argv[1])
manifest = pathlib.Path(sys.argv[2])
info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
assert (bundle / 'Contents/MacOS/Pinmage').stat().st_size > 0
release = json.loads(manifest.read_text())
release.update(version=info['CFBundleShortVersionString'], build=info['CFBundleVersion'],
               appID=info['CFBundleIdentifier'], minimumMacOS=info['LSMinimumSystemVersion'],
               downloadURL='https://pinmage.bervos.org/Pinmage.dmg', architectures=['arm64'],
               date=datetime.date.today().isoformat())
manifest.write_text(json.dumps(release, indent=2) + '\n')
