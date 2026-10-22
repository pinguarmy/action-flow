import Foundation
import XCTest
@testable import ActionFlowCore

final class RuleRequirementsTests: XCTestCase {
    func testEveryAutomaticTriggerRequirement() {
        for kind in TriggerKind.allCases {
            let rule = AutomationRule(trigger: Trigger(kind: kind), actions: [])
            let expected: [AutomationCapability]
            switch kind {
            case .shortcut, .doubleShortcut, .mouseButton, .scroll: expected = [.inputMonitoring]
            case .appActivated, .appLaunched, .appTerminated, .interval: expected = []
            }
            XCTAssertEqual(RuleRequirements.capabilities(for: rule, automatic: true), expected, "Trigger: \(kind)")
        }
    }

    func testManualRunsNeverRequireInputMonitoringFromAnyTrigger() {
        for kind in TriggerKind.allCases {
            let rule = AutomationRule(trigger: Trigger(kind: kind), actions: [])
            XCTAssertEqual(RuleRequirements.capabilities(for: rule, automatic: false), [], "Trigger: \(kind)")
        }
    }

    func testEveryActionRequirementForManualAndAutomaticRuns() {
        for kind in ActionKind.allCases {
            let rule = AutomationRule(trigger: Trigger(kind: .interval), actions: [AutomationAction(kind: kind)])
            let expected: [AutomationCapability]
            switch kind {
            case .window, .keyboardShortcut, .insertText, .menuCommand: expected = [.accessibility]
            case .notification: expected = [.notifications]
            case .shellScript: expected = [.scripts]
            case .openURL, .launchApp, .delay: expected = []
            }
            for automatic in [false, true] {
                XCTAssertEqual(RuleRequirements.capabilities(for: rule, automatic: automatic), expected,
                               "Action: \(kind), automatic: \(automatic)")
            }
        }
    }

    func testMixedAndRepeatedActionsHaveUniqueDeterministicCaseOrder() {
        let kinds: [ActionKind] = [.shellScript, .notification, .insertText, .window, .notification, .shellScript]
        let rule = AutomationRule(actions: kinds.map { AutomationAction(kind: $0) })
        XCTAssertEqual(RuleRequirements.capabilities(for: rule, automatic: true), AutomationCapability.allCases)
        XCTAssertEqual(RuleRequirements.capabilities(for: rule, automatic: false), [.accessibility, .notifications, .scripts])
        let reversed = AutomationRule(actions: rule.actions.reversed())
        XCTAssertEqual(RuleRequirements.capabilities(for: rule, automatic: true),
                       RuleRequirements.capabilities(for: reversed, automatic: true))
    }

    func testDisabledAndIncompleteRulesAreStillAnalyzedWithoutMutation() {
        var rule = AutomationRule(name: "", enabled: false,
                                  actions: [AutomationAction(kind: .shellScript, text: "")])
        let original = rule
        XCTAssertEqual(RuleRequirements.capabilities(for: rule, automatic: true), [.inputMonitoring, .scripts])
        XCTAssertEqual(rule, original)
        rule.enabled = true
        XCTAssertEqual(RuleRequirements.capabilities(for: rule, automatic: true), [.inputMonitoring, .scripts])
    }

    func testMissingFiltersAvailableCapabilitiesAndPreservesOrder() {
        let rule = AutomationRule(actions: [.shellScript, .notification, .window].map { AutomationAction(kind: $0) })
        XCTAssertEqual(RuleRequirements.missing(for: rule, automatic: true, available: []), AutomationCapability.allCases)
        XCTAssertEqual(RuleRequirements.missing(for: rule, automatic: true, available: [.accessibility, .scripts]),
                       [.inputMonitoring, .notifications])
        XCTAssertEqual(RuleRequirements.missing(for: rule, automatic: false, available: [.accessibility, .scripts]),
                       [.notifications])
        XCTAssertTrue(RuleRequirements.missing(for: rule, automatic: true,
                                              available: Set(AutomationCapability.allCases)).isEmpty)
        let noRequirements = AutomationRule(trigger: Trigger(kind: .interval), actions: [])
        XCTAssertTrue(RuleRequirements.missing(for: noRequirements, automatic: true, available: []).isEmpty)
    }

    func testCapabilityMetadataAndCodableAreStable() throws {
        XCTAssertEqual(AutomationCapability.allCases.map(\.rawValue),
                       ["inputMonitoring", "accessibility", "notifications", "scripts"])
        for capability in AutomationCapability.allCases {
            XCTAssertEqual(capability.id, capability.rawValue)
            XCTAssertFalse(capability.title.isEmpty)
            XCTAssertFalse(capability.detail.isEmpty)
            let data = try JSONEncoder().encode(capability)
            XCTAssertEqual(try JSONDecoder().decode(AutomationCapability.self, from: data), capability)
        }
    }
}
