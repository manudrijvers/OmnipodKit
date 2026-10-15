#!/usr/bin/env python3
"""Stamp/verify exact source hashes without inspecting keys or app data."""
import hashlib
import json
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
kit = root.parents[1]
output = root / 'Sources/O5BenchCore/Resources/source-checksums.json'
paths = sorted(root.glob('Sources/**/*.swift')) + sorted(root.glob('Tests/**/*.swift')) + [
    root / 'Package.swift',
    kit / 'OmnipodKit/PumpManagerUI/Views/OmniSettingsView.swift',
    kit / 'OmnipodKit.xcodeproj/project.pbxproj',
]
files = {str(p.relative_to(kit)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
digest = hashlib.sha256(json.dumps(files, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
value = {'sourceSHA256': digest, 'files': files, 'revisions': {
    'TrioBase': '0b29cd53415e7f0e668677749cad8daf81c68c2f',
    'OmnipodKitBase': '043b91dbf1958d26c55d927a6a8d651bc91f208d',
    'research': 'db92e426b97914ce1c80bdab45a74001a858840a',
    'runnerSourceSHA256': digest,
}}
if '--check' in sys.argv:
    if json.loads(output.read_text()) != value:
        raise SystemExit('Source stamp is stale; run Scripts/stamp-sources.py and rebuild.')
    print('Source stamp verified:', digest)
else:
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')
    print('Source stamp written:', digest)
