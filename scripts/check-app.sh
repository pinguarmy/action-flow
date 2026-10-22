#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$ROOT" --target ActionFlowCore
BIN="$(swift build --package-path "$ROOT" --show-bin-path)"
TMP="$(mktemp -d "${TMPDIR:-/tmp/}actionflow-appcheck.XXXXXX")"
swiftc -swift-version 5 -parse-as-library -I "$BIN/Modules" \
 "$ROOT/scripts/AppChecks.swift" \
 "$ROOT/Sources/ActionFlowApp/AppModel.swift" \
 "$ROOT/Sources/ActionFlowApp/AppLocalization.swift" \
 "$ROOT"/Sources/ActionFlowApp/Runtime/*.swift \
 "$ROOT"/Sources/ActionFlowApp/Views/*.swift \
 "$BIN/ActionFlowCore.build/Models.swift.o" \
 "$BIN/ActionFlowCore.build/MenuCommandPath.swift.o" \
 "$BIN/ActionFlowCore.build/RuleValidator.swift.o" \
 "$BIN/ActionFlowCore.build/ConfigurationStore.swift.o" \
 "$BIN/ActionFlowCore.build/RuleScheduler.swift.o" \
 "$BIN/ActionFlowCore.build/WindowLayout.swift.o" \
 "$BIN/ActionFlowCore.build/RuleRequirements.swift.o" \
 "$BIN/ActionFlowCore.build/ActionPreflight.swift.o" \
 "$BIN/ActionFlowCore.build/RuleTemplates.swift.o" \
 "$BIN/ActionFlowCore.build/ExecutionProgress.swift.o" \
 "$BIN/ActionFlowCore.build/SessionTransition.swift.o" \
 "$BIN/ActionFlowCore.build/RuleQuery.swift.o" \
 "$BIN/ActionFlowCore.build/GestureRecognition.swift.o" \
 "$BIN/ActionFlowCore.build/ConfigurationLease.swift.o" \
 -o "$TMP/AppChecks"
for LANGUAGE in en zh-Hans; do
 mkdir -p "$TMP/$LANGUAGE.lproj"
 cp "$ROOT/Sources/ActionFlowApp/Resources/$LANGUAGE.lproj/Localizable.strings" "$TMP/$LANGUAGE.lproj/Localizable.strings"
done
OUT="${1:-$TMP/editor.png}"
ACTIONFLOW_MENU_IMAGE="${ACTIONFLOW_MENU_IMAGE:-${OUT%.png}-menu.png}" \
ACTIONFLOW_MENU_PREVIEW_IMAGE="${ACTIONFLOW_MENU_PREVIEW_IMAGE:-${OUT%.png}-menu-preview.png}" \
ACTIONFLOW_LOCALIZATION_ROOT="$ROOT/Sources/ActionFlowApp/Resources" "$TMP/AppChecks" "$OUT" -AppleLanguages "(${ACTIONFLOW_LANGUAGE:-en})"
printf 'App check binary: %s\n' "$TMP/AppChecks"
