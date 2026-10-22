import Foundation
import XCTest
@testable import ActionFlowCore

final class RuleTemplateTests: XCTestCase {
    private func encoded(_ template: RuleTemplate) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(template.configuration)
    }

    func testCatalogContainsSixStableUniqueEntries() {
        XCTAssertEqual(RuleTemplates.all.map(\.id), ["window-halves", "window-quarters", "focus-workspace",
                                                    "launch-browser", "meeting-notes", "gentle-reminder"])
        XCTAssertEqual(Set(RuleTemplates.all.map(\.id)).count, RuleTemplates.all.count)
        for template in RuleTemplates.all {
            XCTAssertFalse(template.name.isEmpty)
            XCTAssertFalse(template.detail.isEmpty)
            XCTAssertFalse(template.rules.isEmpty)
            XCTAssertEqual(RuleTemplates.find(id: template.id), template)
        }
        XCTAssertNil(RuleTemplates.find(id: "unknown-pack"))
        XCTAssertNil(RuleTemplates.find(id: "WINDOW-HALVES"))
    }

    func testEveryCanonicalRuleIsDisabledValidAndScriptFree() {
        for template in RuleTemplates.all {
            let configuration = template.configuration
            XCTAssertFalse(configuration.automationEnabled)
            XCTAssertFalse(configuration.allowScripts)
            XCTAssertFalse(configuration.launchAtLogin)
            XCTAssertEqual(configuration.rules, template.rules)
            for rule in template.rules {
                XCTAssertFalse(rule.enabled)
                XCTAssertTrue(RuleValidator.validate(rule).isEmpty, "Invalid template rule: \(rule.name)")
                XCTAssertTrue(ActionPreflight.errors(for: rule.actions).isEmpty)
                XCTAssertFalse(rule.actions.contains(where: { $0.kind == .shellScript }))
                if [.shortcut, .doubleShortcut].contains(rule.trigger.kind) {
                    XCTAssertFalse(rule.trigger.modifiers.intersection([.command, .control, .option]).isEmpty)
                }
            }
            var enabledRules = template.rules
            for index in enabledRules.indices { enabledRules[index].enabled = true }
            XCTAssertTrue(RuleValidator.conflicts(in: enabledRules).isEmpty, "Conflicting template: \(template.id)")
        }
    }

    func testAllCatalogIdentifiersAreUniqueAndRepeatable() throws {
        let rules = RuleTemplates.all.flatMap(\.rules)
        let ruleIDs = rules.map(\.id)
        let actionIDs = rules.flatMap(\.actions).map(\.id)
        XCTAssertEqual(Set(ruleIDs).count, ruleIDs.count)
        XCTAssertEqual(Set(actionIDs).count, actionIDs.count)
        XCTAssertTrue(Set(ruleIDs).isDisjoint(with: Set(actionIDs)))
        for template in RuleTemplates.all {
            XCTAssertEqual(try encoded(template), try encoded(XCTUnwrap(RuleTemplates.find(id: template.id))))
            let decoded = try JSONDecoder().decode(Configuration.self, from: encoded(template))
            XCTAssertEqual(decoded, template.configuration)
        }
        XCTAssertEqual(RuleTemplates.all.first?.rules.first?.id.uuidString, "47465450-0001-0001-8000-000000000000")
        XCTAssertEqual(RuleTemplates.all.first?.rules.first?.actions.first?.id.uuidString, "47465450-0001-0001-8000-000000000001")
    }

    func testMakeRulesUsesFreshIdentitiesAndPreservesPayloads() {
        for template in RuleTemplates.all {
            let first = template.makeRules()
            let second = template.makeRules()
            let originalIDs = Set(template.rules.map(\.id) + template.rules.flatMap(\.actions).map(\.id))
            let firstIDs = first.map(\.id) + first.flatMap(\.actions).map(\.id)
            let secondIDs = second.map(\.id) + second.flatMap(\.actions).map(\.id)
            XCTAssertTrue(Set(firstIDs).isDisjoint(with: originalIDs))
            XCTAssertTrue(Set(secondIDs).isDisjoint(with: originalIDs.union(firstIDs)))
            XCTAssertEqual(Set(firstIDs + secondIDs).count, firstIDs.count + secondIDs.count)
            XCTAssertTrue(first.allSatisfy { !$0.enabled })
            for (copy, original) in zip(first, template.rules) {
                var normalized = copy
                normalized.id = original.id
                for index in normalized.actions.indices { normalized.actions[index].id = original.actions[index].id }
                XCTAssertEqual(normalized, original)
            }
        }
    }

    func testSpecificPackBehaviorAndRequirementsAreHonest() throws {
        let halves = try XCTUnwrap(RuleTemplates.find(id: "window-halves"))
        XCTAssertEqual(halves.rules.flatMap(\.actions).map(\.windowOperation), [.leftHalf, .rightHalf])
        let quarters = try XCTUnwrap(RuleTemplates.find(id: "window-quarters"))
        XCTAssertEqual(quarters.rules.flatMap(\.actions).map(\.windowOperation), [.topLeft, .topRight, .bottomLeft, .bottomRight])
        let launch = try XCTUnwrap(RuleTemplates.find(id: "launch-browser"))
        XCTAssertEqual(launch.rules.first?.actions.first?.kind, .launchApp)
        XCTAssertEqual(launch.rules.first?.actions.first?.text, "com.apple.Safari")
        let notes = try XCTUnwrap(RuleTemplates.find(id: "meeting-notes"))
        XCTAssertEqual(notes.rules.first?.trigger.kind, .doubleShortcut)
        XCTAssertEqual(notes.rules.first?.actions.first?.kind, .insertText)
        XCTAssertEqual(RuleRequirements.capabilities(for: try XCTUnwrap(notes.rules.first), automatic: true), [.inputMonitoring, .accessibility])
        let reminder = try XCTUnwrap(RuleTemplates.find(id: "gentle-reminder"))
        for rule in reminder.rules {
            XCTAssertEqual(rule.trigger.kind, .interval)
            XCTAssertGreaterThanOrEqual(rule.trigger.intervalSeconds, 1_800)
            XCTAssertEqual(rule.actions.first?.kind, .notification)
            XCTAssertEqual(RuleRequirements.capabilities(for: rule, automatic: true), [.notifications])
        }
        for action in RuleTemplates.all.flatMap(\.rules).flatMap(\.actions) {
            if action.kind == .openURL { XCTAssertEqual(action.text, "https://example.com") }
        }
    }
}
