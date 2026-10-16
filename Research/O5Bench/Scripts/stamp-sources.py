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
    kit / 'OmnipodKit/Bluetooth/O5AidCommands.swift',
    kit / 'OmnipodKit/Bluetooth/BleMessageTransport.swift',
    kit / 'OmnipodKit/Bluetooth/BlePodComms.swift',
    kit / 'OmnipodKit/Bluetooth/PeripheralManager.swift',
    kit / 'OmnipodKit/PumpManagerUI/ViewModels/OmniSettingsViewModel.swift',
    kit / 'OmnipodKit/PumpManager/OmniPumpManager.swift',
    kit / 'OmnipodKit/PumpManager/PodCommsSession.swift',
    kit / 'OmnipodKit/PumpManagerUI/Views/PodDiagnosticsView.swift',
    kit / 'OmniTests/O5/O5AidCommandsTests.swift',
]
files = {str(p.relative_to(kit)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
digest = hashlib.sha256(json.dumps(files, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
value = {'sourceSHA256': digest, 'files': files, 'revisions': {
    'TrioBase': '80b79cb0085505edce278216063d2bb2e64c7191',
    'OmnipodKitBase': '363f75ae02be15ff3f2ef2b5b0a1d7fbfeebb54e',
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
