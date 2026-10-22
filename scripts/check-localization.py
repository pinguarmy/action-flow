#!/usr/bin/env python3
"""Validate matching native localization tables without granting app permissions."""
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
resources = root / 'Sources/ActionFlowApp/Resources'
tables = {}
for language in ['en', 'zh-Hans']:
    file = resources / f'{language}.lproj/Localizable.strings'
    result = subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(file)], capture_output=True, text=True)
    if result.returncode:
        raise SystemExit(result.stderr)
    tables[language] = json.loads(result.stdout)
assert set(tables['en']) == set(tables['zh-Hans']), 'English and Chinese keys differ'
assert len(tables['en']) >= 120, 'Insufficient primary interface coverage'
for key, translated in tables['zh-Hans'].items():
    assert isinstance(translated, str) and translated, f'Empty translation for {key}'
    # printf placeholders must retain type/order to avoid formatting crashes.
    import re
    assert re.findall(r'%(?:\d+\$)?(?:lld|ld|d|u|@|f)', key) == re.findall(r'%(?:\d+\$)?(?:lld|ld|d|u|@|f)', translated), f'Format mismatch: {key}'
assert tables['zh-Hans']['Rules'] == '规则'
assert tables['zh-Hans']['Accessibility'] == '辅助功能'
print(f'Verified {len(tables["en"])} matching English/Simplified Chinese keys, nonempty values and formatting placeholders.')
if len(sys.argv) > 1:
    app = Path(sys.argv[1]).resolve()
    for language in ['en', 'zh-Hans']:
        installed = app / 'Contents/Resources' / f'{language}.lproj/Localizable.strings'
        assert installed.read_bytes() == (resources / f'{language}.lproj/Localizable.strings').read_bytes(), f'Outdated app resource: {language}'
    print('Built app includes matching current localization tables.')
