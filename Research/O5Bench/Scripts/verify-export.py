#!/usr/bin/env python3
"""Independent checksum, JSON framing and sharing-redaction verification."""
import hashlib
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
names = set()
for line in (root / 'SHA256SUMS').read_text().splitlines():
    digest, name = line.split('  ', 1)
    assert name == Path(name).name, 'Unexpected path in checksum manifest'
    assert name not in names
    names.add(name)
    assert hashlib.sha256((root / name).read_bytes()).hexdigest() == digest, name
assert names == {p.name for p in root.iterdir()} - {'SHA256SUMS'}
manifest = json.loads((root / 'manifest.json').read_text())
assert isinstance(manifest['physicalWritesEnabled'], bool)
if manifest['synthetic']:
    assert manifest['physicalWritesEnabled'] is False
assert manifest['transport'] == ('fake-only' if manifest['synthetic'] else 'BLE')
exchanges = [json.loads(line) for line in (root / 'exchanges.ndjson').read_text().splitlines()]
events = [json.loads(line) for line in (root / 'events.ndjson').read_text().splitlines()]
assert exchanges and events
if manifest['redacted']:
    assert 'private-session.json' not in names
    for op in exchanges:
        for item in op['requests'] + op['replies']:
            assert item['applicationHex'] == 'REDACTED'
        for record in op.get('wireRecords', []):
            assert record['hex'] == 'REDACTED'
        assert 'certificate SHA256' not in op['signingPolicy']
        if 'applicationBatchHex' in op:
            assert op['applicationBatchHex'] == 'REDACTED'
    assert all('note' not in e['fields'] for e in events)
    text = ''.join(p.read_text() for p in root.iterdir())
    for token in ['SYNTHETIC-LOT', 'SYNTHETIC-SEQ', 'SYNTHETIC-BLE', 'SYNTHETIC-CONTEXT',
                  '001234567890', '303031323334353637383930']:
        assert token not in text, 'Synthetic sensitive-field marker leaked'
print(f'Verified {len(names)} files, {len(exchanges)} exchanges, {len(events)} events; redacted={manifest["redacted"]}')
