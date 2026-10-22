#!/usr/bin/env python3
"""Check public source and packaged executables for common private-data patterns."""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
excluded = {'.git', '.build', '.build-arm64', '.build-x86_64', '.swiftpm', 'dist', '__pycache__'}
patterns = [re.compile(rb'/(?:Users|home)/[A-Za-z0-9_.-]+/'),
            re.compile(rb'(?:gh[pousr]_[A-Za-z0-9]{28,}|github_pat_[A-Za-z0-9_]{30,})'),
            re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----')]
issues = []
count = 0
for path in root.rglob('*'):
    if set(path.relative_to(root).parts) & excluded or not path.is_file():
        continue
    count += 1
    if path.name in {'.env', 'hosts.yml', '.netrc'} or path.suffix in {'.pem', '.key', '.p12', '.pfx', '.sqlite', '.db'}:
        issues.append(str(path.relative_to(root)))
    if any(p.search(path.read_bytes()) for p in patterns):
        issues.append(str(path.relative_to(root)))
app = root / 'dist/ActionFlow.app'
if app.exists():
    for path in app.rglob('*'):
        if path.is_file() and any(p.search(path.read_bytes()) for p in patterns):
            issues.append(str(path.relative_to(root)))
    subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
if issues:
    raise SystemExit('Private-data pattern in: ' + ', '.join(sorted(set(issues))))
print(f'Privacy check passed: {count} source files; application checked when present.')
