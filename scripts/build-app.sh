#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${APP_VERSION:-0.1.0}"
BUILD="${APP_BUILD:-1}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'APP_VERSION must be numeric x.y.z\n' >&2; exit 2; }
[[ "$BUILD" =~ ^[0-9]+$ ]] || { printf 'APP_BUILD must be an integer\n' >&2; exit 2; }
MODE="${1:-release}"
[[ "$#" -le 1 ]] || { printf 'Usage: build-app.sh [release|debug]\n' >&2; exit 2; }
case "$MODE" in release|debug) ;; *) printf 'Usage: build-app.sh [release|debug]\n' >&2; exit 2;; esac
ARCH="${ARCH:-native}"
BUILD_ARGUMENTS=(--package-path "$ROOT" -c "$MODE"
 -Xswiftc -file-prefix-map -Xswiftc "$ROOT=/src/ActionFlow"
 -Xswiftc -debug-prefix-map -Xswiftc "$ROOT=/src/ActionFlow")
case "$ARCH" in
 native) ;;
 arm64|x86_64)
  # Explicit cross-architecture builds must not replace native test artifacts.
  BUILD_ARGUMENTS+=(--triple "$ARCH-apple-macosx14.0" --scratch-path "$ROOT/.build-$ARCH")
  ;;
 *) printf 'ARCH must be native, arm64, or x86_64\n' >&2; exit 2;;
esac
COMMIT="$(git -C "$ROOT" rev-parse --verify HEAD)"
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || { printf 'A full Git commit SHA is required for bundle provenance\n' >&2; exit 1; }
swift build "${BUILD_ARGUMENTS[@]}"
BIN="$(swift build "${BUILD_ARGUMENTS[@]}" --show-bin-path)"
APP="$ROOT/dist/ActionFlow.app"
# Staging is additive; no deletion of user paths.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ActionFlow" "$APP/Contents/MacOS/ActionFlow"
cp "$ROOT/Sources/ActionFlowApp/Resources/PrivacyInfo.xcprivacy" "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
for LANGUAGE in en zh-Hans; do
 mkdir -p "$APP/Contents/Resources/$LANGUAGE.lproj"
 cp "$ROOT/Sources/ActionFlowApp/Resources/$LANGUAGE.lproj/Localizable.strings" "$APP/Contents/Resources/$LANGUAGE.lproj/Localizable.strings"
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
<key>CFBundleExecutable</key><string>ActionFlow</string>
<key>CFBundleIdentifier</key><string>io.github.pinguarmy.actionflow</string>
<key>CFBundleName</key><string>ActionFlow</string>
<key>CFBundleDisplayName</key><string>ActionFlow</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 ActionFlow contributors. MIT License.</string>
<key>NSInputMonitoringUsageDescription</key><string>ActionFlow observes shortcuts, mouse buttons and scrolling to run the rules you explicitly enable. It does not record your typing.</string>
<key>NSAppleEventsUsageDescription</key><string>ActionFlow only executes scripts when you explicitly opt in and run a rule.</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :ActionFlowBuildCommit string $COMMIT" "$APP/Contents/Info.plist"
if [ -f "$ROOT/assets/ActionFlow.icns" ]; then
 cp "$ROOT/assets/ActionFlow.icns" "$APP/Contents/Resources/ActionFlow.icns"
 /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string ActionFlow' "$APP/Contents/Info.plist" 2>/dev/null || true
fi
strip -x "$APP/Contents/MacOS/ActionFlow"
codesign --force --sign - "$APP"
EXPECTED_ARCH="$ARCH" bash "$ROOT/scripts/check-bundle.sh" "$APP"
printf '\nBuilt and ad-hoc signed: %s\n' "$APP"
