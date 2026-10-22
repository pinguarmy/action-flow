#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/ActionFlow.app"
[ -d "$APP" ] || { printf 'Build the app first.\n' >&2; exit 1; }
SUFFIX="${RELEASE_SUFFIX:-}"
[[ -z "$SUFFIX" || "$SUFFIX" =~ ^-[A-Za-z0-9]+([.-][A-Za-z0-9]+)*$ ]] || { printf 'RELEASE_SUFFIX must be empty or a label such as -alpha.4\n' >&2; exit 2; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'Bundle version must be numeric x.y.z\n' >&2; exit 2; }
bash "$ROOT/scripts/check-bundle.sh" "$APP"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/ActionFlow")"
case "$ARCHS" in arm64|x86_64) ;; *) printf 'Cannot label a DMG for architecture: %s\n' "$ARCHS" >&2; exit 1;; esac
OUT="$ROOT/dist/ActionFlow-$VERSION$SUFFIX-macos-$ARCHS.dmg"
[[ ! -e "$OUT" && ! -L "$OUT" && ! -e "$OUT.sha256" && ! -L "$OUT.sha256" ]] || { printf 'Refusing to overwrite release artifacts for %s\n' "$OUT" >&2; exit 1; }
STAGE="$(mktemp -d "${TMPDIR:-/tmp/}actionflow-dmg.XXXXXX")"
# Only create owned staging data; leave it available for inspection if packaging fails.
ditto --norsrc --noextattr "$APP" "$STAGE/ActionFlow.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/LICENSE" "$STAGE/LICENSE.txt"
# Do not use -ov: a racing process must not overwrite an existing release.
hdiutil create -volname ActionFlow -srcfolder "$STAGE" -format UDZO "$OUT"
hdiutil verify "$OUT"
(set -o noclobber; cd "$ROOT/dist" && shasum -a 256 "$(basename "$OUT")" > "$OUT.sha256")
printf 'Created %s\nStaging directory: %s\n' "$OUT" "$STAGE"
