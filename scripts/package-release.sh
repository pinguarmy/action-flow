#!/bin/bash
# One-shot release packager: native arm64 then cross x86_64 app ZIP/DMG plus CLI binaries.
# Run once per release, after the source freeze, from a fully committed tree on an Apple
# Silicon host. Never overwrites existing outputs, never deletes user paths, never runs
# the app or CLI, and never grants permissions or uploads anything.
# Required env: APP_BUILD (positive integer), RELEASE_SUFFIX (for example -alpha.6).
# Optional env: APP_VERSION (default 0.1.0, numeric x.y.z).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
VERSION="${APP_VERSION:-0.1.0}"
BUILD="${APP_BUILD:-}"
SUFFIX="${RELEASE_SUFFIX:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'APP_VERSION must be numeric x.y.z\n' >&2; exit 2; }
[[ -n "$BUILD" && "$BUILD" =~ ^[1-9][0-9]*$ ]] || { printf 'APP_BUILD is required and must be a positive integer\n' >&2; exit 2; }
[[ -n "$SUFFIX" && "$SUFFIX" =~ ^-[A-Za-z0-9]+([.-][A-Za-z0-9]+)*$ ]] || { printf 'RELEASE_SUFFIX is required, for example -alpha.6\n' >&2; exit 2; }
# Native arm64 build comes first, so the host must be Apple Silicon. Intel is cross-built.
[[ "$(uname -m)" == arm64 ]] || { printf 'Unsupported host architecture: only arm64 Apple Silicon hosts can run this packaging order\n' >&2; exit 2; }
NAME="ActionFlow-$VERSION$SUFFIX"
CLI="actionflow-cli-$VERSION$SUFFIX"
OUTPUTS=()
for A in arm64 x86_64; do
 OUTPUTS+=("$DIST/$NAME-macos-$A.zip" "$DIST/$NAME-macos-$A.dmg" "$DIST/$NAME-macos-$A.dmg.sha256" "$DIST/$CLI-macos-$A")
done
OUTPUTS+=("$DIST/$NAME-extra.sha256")
# Refuse any existing file or symlink before building, so a late clash cannot leave half a release.
for OUT in "${OUTPUTS[@]}"; do
 [[ ! -e "$OUT" && ! -L "$OUT" ]] || { printf 'Refusing to overwrite existing release output: %s\n' "$(basename "$OUT")" >&2; exit 1; }
done
# Provenance: tracked files (including docs) must be committed; new source files must not be untracked.
git -C "$ROOT" diff --quiet && git -C "$ROOT" diff --cached --quiet || { printf 'Tracked working tree changes must be committed before packaging\n' >&2; exit 1; }
[[ -z "$(git -C "$ROOT" ls-files --others --exclude-standard -- Sources Package.swift scripts)" ]] || { printf 'Untracked source files under Sources, Package.swift or scripts must be committed before packaging\n' >&2; exit 1; }
COMMIT="$(git -C "$ROOT" rev-parse --verify HEAD)"
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || { printf 'A full Git commit SHA is required for provenance\n' >&2; exit 1; }
mkdir -p "$DIST"
# Owned staging as a sibling inside dist keeps hardlink publishing on the same filesystem.
STAGE="$(mktemp -d "$DIST/.packaging-XXXXXX")"
SAVED_ARM=""
restore_arm() {
 if [[ -n "$SAVED_ARM" && -d "$SAVED_ARM" ]]; then
  # Additive copy back over the build product; nothing user-owned is deleted.
  ditto "$SAVED_ARM" "$DIST/ActionFlow.app"
  SAVED_ARM=""
  printf 'Restored the native arm64 app in dist without a third build\n'
 fi
}
trap restore_arm EXIT
bin_path() {
 if [[ "$1" == arm64 ]]; then
  swift build --package-path "$ROOT" -c release --show-bin-path
 else
  swift build --package-path "$ROOT" -c release --triple "$1-apple-macosx14.0" --scratch-path "$ROOT/.build-$1" --show-bin-path
 fi
}
package_arch() {
 local A="$1"
 local APP="$DIST/ActionFlow.app"
 local ZIP="$DIST/$NAME-macos-$A.zip"
 # CLI: stage a copy, ad-hoc sign it only if unsigned (cross builds are unsigned), then publish.
 local CLI_STAGE="$STAGE/cli-$A"
 ditto "$(bin_path "$A")/actionflow-cli" "$CLI_STAGE"
 strip -x "$CLI_STAGE"
 codesign --force --sign - "$CLI_STAGE"
 codesign --verify "$CLI_STAGE"
 [[ "$(lipo -archs "$CLI_STAGE")" == "$A" ]] || { printf 'CLI architecture mismatch for %s\n' "$A" >&2; exit 1; }
 ln "$CLI_STAGE" "$DIST/$CLI-macos-$A"
 # ZIP: ditto cannot atomically refuse an existing name, so zip in staging and hardlink-publish.
 local ZIP_STAGE="$STAGE/app-$A.zip"
 python3 "$ROOT/scripts/zip-app.py" "$APP" "$ZIP_STAGE"
 ln "$ZIP_STAGE" "$ZIP"
 # DMG: the existing script already refuses overwrites and writes its own basename sha256.
 RELEASE_SUFFIX="$SUFFIX" bash "$ROOT/scripts/make-dmg.sh"
 # Verify the published ZIP by extracting it: bundle metadata, architecture, build and commit.
 local EXTRACT="$STAGE/extract-$A"
 mkdir "$EXTRACT"
 ditto -x -k "$ZIP" "$EXTRACT"
 EXPECTED_ARCH="$A" bash "$ROOT/scripts/check-bundle.sh" "$EXTRACT/ActionFlow.app"
 local INFO="$EXTRACT/ActionFlow.app/Contents/Info.plist"
 [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")" == "$BUILD" ]] || { printf 'ZIP build number mismatch for %s\n' "$A" >&2; exit 1; }
 [[ "$(/usr/libexec/PlistBuddy -c 'Print :ActionFlowBuildCommit' "$INFO")" == "$COMMIT" ]] || { printf 'ZIP commit provenance mismatch for %s\n' "$A" >&2; exit 1; }
 printf 'Packaged %s: cli, zip, dmg\n' "$A"
}
# 1. Native arm64 build; save the app so dist can be restored after the Intel build.
APP_VERSION="$VERSION" APP_BUILD="$BUILD" ARCH=native bash "$ROOT/scripts/build-app.sh" release
SAVED_ARM="$STAGE/arm64.app"
ditto "$DIST/ActionFlow.app" "$SAVED_ARM"
package_arch arm64
# 2. Cross x86_64 build reuses the same dist app path.
APP_VERSION="$VERSION" APP_BUILD="$BUILD" ARCH=x86_64 bash "$ROOT/scripts/build-app.sh" release
package_arch x86_64
restore_arm
# Extra hashes cover the ZIPs and CLI binaries by basename, created no-clobber like the DMG shas.
(set -o noclobber; cd "$DIST" && shasum -a 256 "$NAME-macos-arm64.zip" "$NAME-macos-x86_64.zip" "$CLI-macos-arm64" "$CLI-macos-x86_64" > "$NAME-extra.sha256")
# Final hash checks: both DMG shas and the extra sha must verify from inside dist.
(cd "$DIST" && shasum -a 256 -c "$NAME-macos-arm64.dmg.sha256" && shasum -a 256 -c "$NAME-macos-x86_64.dmg.sha256" && shasum -a 256 -c "$NAME-extra.sha256")
printf 'Release outputs ready in dist:\n'
for OUT in "${OUTPUTS[@]}"; do printf '  %s\n' "$(basename "$OUT")"; done
printf 'Staging kept for inspection: %s\n' "$(basename "$STAGE")"
