#!/usr/bin/env python3
"""Refresh/check the packaged source stamp. No Git or hardware operations."""
import argparse
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
resource = root / 'Research/O5Bench/Sources/O5BenchCore/Resources/source-checksums.json'
previous = json.loads(resource.read_text())
paths = set(previous['files'])
paths.update(str(p.relative_to(root)) for part in ('Sources', 'Tests')
             for p in (root / 'Research/O5Bench' / part).rglob('*.swift'))
paths.update((
    'OmniTests/PodCommsSessionTests.swift', 'OmniTests/PodStateTests.swift',
    'OmnipodKit/PumpManager/PodState.swift',
    'OmnipodKit/PumpManager/OmniPumpManagerState.swift',
    'OmnipodKit/PumpManagerUI/ViewModels/PairPodViewModel.swift',
    'OmnipodKit/PumpManagerUI/ViewModels/InsertCannulaViewModel.swift',
    'OmnipodKit/PumpManagerUI/Views/PairPodView.swift',
    'Research/O5Bench/update_source_checksums.py',
))
files = {path: hashlib.sha256((root / path).read_bytes()).hexdigest() for path in sorted(paths)}
stamp = hashlib.sha256(json.dumps(files, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
result = dict(previous, files=files, sourceSHA256=stamp,
              sourceHashAlgorithm='SHA256 of compact sorted JSON file-hash map')
result['revisions'] = dict(previous['revisions'], runnerSourceSHA256=stamp,
                           earlyControlEnableProtocol='fresh-control-only-v1')
text = json.dumps(result, indent=2, sort_keys=True) + '\n'
if args.check:
    if resource.read_text() != text:
        raise SystemExit('Source checksums differ; run Research/O5Bench/update_source_checksums.py')
else:
    resource.write_text(text)
print(stamp)
