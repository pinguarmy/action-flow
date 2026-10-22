#!/bin/bash
set -euo pipefail
[[ "$#" -eq 1 && -n "$1" ]] || { printf 'Usage: check-bundle.sh <app-path>\n' >&2; exit 2; }
APP="$1"
EXPECTED_ARCH="${EXPECTED_ARCH:-}"
case "$EXPECTED_ARCH" in
 ''|arm64|x86_64) ;;
 native)
  EXPECTED_ARCH="$(uname -m)"
  case "$EXPECTED_ARCH" in arm64|x86_64) ;; *) printf 'Unsupported native architecture\n' >&2; exit 2;; esac
  ;;
 *) printf 'EXPECTED_ARCH must be native, arm64, or x86_64\n' >&2; exit 2;;
esac
[[ -d "$APP" && ! -L "$APP" ]] || { printf 'Choose a real app bundle directory\n' >&2; exit 1; }
APP="$(cd "$APP" && pwd -P)"
INFO="$APP/Contents/Info.plist"
[[ -f "$INFO" && ! -L "$INFO" ]] || { printf 'Missing regular Info.plist\n' >&2; exit 1; }
plutil -lint "$INFO"
export INFO
python3 - <<'PY'
import os
from pathlib import Path
import plistlib
import re

info = Path(os.environ['INFO'])
with info.open('rb') as stream:
    metadata = plistlib.load(stream)
required = {
    'CFBundleExecutable': 'ActionFlow',
    'CFBundleIdentifier': 'io.github.pinguarmy.actionflow',
    'CFBundlePackageType': 'APPL',
    'CFBundleDevelopmentRegion': 'en',
    'LSMinimumSystemVersion': '14.0',
}
for key, expected in required.items():
    if metadata.get(key) != expected:
        raise SystemExit(f'Invalid bundle metadata {key}: expected {expected}')
if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', str(metadata.get('CFBundleShortVersionString', ''))):
    raise SystemExit('Invalid bundle short version')
if not re.fullmatch(r'[0-9]+', str(metadata.get('CFBundleVersion', ''))):
    raise SystemExit('Invalid bundle build number')
if not re.fullmatch(r'[0-9a-f]{40}', str(metadata.get('ActionFlowBuildCommit', ''))):
    raise SystemExit('Missing full Git commit provenance')
if set(metadata.get('CFBundleLocalizations', [])) != {'en', 'zh-Hans'}:
    raise SystemExit('Bundle localizations must contain en and zh-Hans')
resources = info.parent / 'Resources'
privacy = resources / 'PrivacyInfo.xcprivacy'
if not privacy.is_file() or privacy.is_symlink():
    raise SystemExit('Missing regular privacy manifest')
with privacy.open('rb') as stream:
    if not isinstance(plistlib.load(stream), dict):
        raise SystemExit('Invalid privacy manifest')
for language in ['en', 'zh-Hans']:
    directory = resources / f'{language}.lproj'
    strings = directory / 'Localizable.strings'
    if directory.is_symlink() or not strings.is_file() or strings.is_symlink() or strings.stat().st_size == 0:
        raise SystemExit(f'Missing nonempty regular localization for {language}')
print('PASS bundle metadata, provenance, privacy manifest, and bilingual resources')
PY
EXECUTABLE="$APP/Contents/MacOS/ActionFlow"
[[ -f "$EXECUTABLE" && -x "$EXECUTABLE" && ! -L "$EXECUTABLE" ]] || { printf 'Missing regular executable\n' >&2; exit 1; }
ARCHS="$(lipo -archs "$EXECUTABLE")"
case "$ARCHS" in arm64|x86_64) ;; *) printf 'Expected a single supported architecture, got: %s\n' "$ARCHS" >&2; exit 1;; esac
if [[ -n "$EXPECTED_ARCH" && "$ARCHS" != "$EXPECTED_ARCH" ]]; then
 printf 'Architecture mismatch: expected %s, got %s\n' "$EXPECTED_ARCH" "$ARCHS" >&2
 exit 1
fi
for LANGUAGE in en zh-Hans; do
 plutil -lint "$APP/Contents/Resources/$LANGUAGE.lproj/Localizable.strings"
done
codesign --verify --deep --strict "$APP"
printf 'PASS strict code signature and %s executable: %s\n' "$ARCHS" "$APP"
