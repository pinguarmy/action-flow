#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$ROOT" --target ActionFlowCore
BIN="$(swift build --package-path "$ROOT" --show-bin-path)"
TMP="$(mktemp -d "${TMPDIR:-/tmp/}actionflow-runtime.XXXXXX")"
swiftc -swift-version 5 -parse-as-library -I "$BIN/Modules" \
 "$ROOT/scripts/RuntimeChecks.swift" \
 "$ROOT/Sources/ActionFlowApp/Runtime/FocusContext.swift" \
 "$ROOT/Sources/ActionFlowApp/Runtime/FocusedElementGuard.swift" \
 "$ROOT/Sources/ActionFlowApp/Runtime/SessionSafety.swift" \
 "$ROOT/Sources/ActionFlowApp/Runtime/ActionExecutor.swift" \
 "$ROOT/Sources/ActionFlowApp/Runtime/InputMonitor.swift" \
 "$ROOT/Sources/ActionFlowApp/Runtime/InputDecoder.swift" \
 "$ROOT/Sources/ActionFlowApp/Runtime/WindowController.swift" \
 "$ROOT/Sources/ActionFlowApp/Runtime/MenuCommandController.swift" \
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
 -o "$TMP/RuntimeChecks"
ACTIONFLOW_TEST_SECRET=DO_NOT_INHERIT "$TMP/RuntimeChecks"
printf 'Runtime check binary: %s\n' "$TMP/RuntimeChecks"
