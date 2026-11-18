import Foundation
import XCTest
@testable import ActionFlowCore

final class ShortcutInterceptionTests: XCTestCase {
    private let app = "com.example.Editor"

    private func rule(kind: TriggerKind = .shortcut, keyCode: UInt16 = 123, modifiers: ModifierKeys = [.control, .option],
                      enabled: Bool = true, passThrough: Bool = false,
                      conditions: RuleConditions = RuleConditions()) -> AutomationRule {
        AutomationRule(enabled: enabled,
                       trigger: Trigger(kind: kind, keyCode: keyCode, modifiers: modifiers, passThrough: passThrough),
                       conditions: conditions,
                       actions: [AutomationAction(kind: .delay, delaySeconds: 0)])
    }

    private func consumes(_ rules: [AutomationRule], keyCode: UInt16 = 123,
                          modifiers: ModifierKeys = [.control, .option], bundleIdentifier: String? = nil) -> Bool {
        ShortcutInterception.consumes(keyCode: keyCode, modifiers: modifiers, rules: rules,
                                      bundleIdentifier: bundleIdentifier ?? app)
    }

    func testExactChordIsConsumed() {
        XCTAssertTrue(consumes([rule()]))
        XCTAssertFalse(consumes([rule()], keyCode: 124))
        XCTAssertFalse(consumes([rule()], modifiers: [.control]))
        XCTAssertFalse(consumes([rule()], modifiers: [.control, .option, .shift]))
        XCTAssertFalse(consumes([]))
    }

    func testDisabledPassThroughAndDoublePressRulesNeverConsume() {
        XCTAssertFalse(consumes([rule(enabled: false)]))
        XCTAssertFalse(consumes([rule(passThrough: true)]))
        XCTAssertFalse(consumes([rule(kind: .doubleShortcut)]))
        XCTAssertFalse(consumes([rule(kind: .doubleShortcut, passThrough: true)]))
        XCTAssertFalse(consumes([rule(kind: .mouseButton)]))
    }

    func testTriggerWithoutCommandOptionOrControlNeverConsumes() {
        // An enabled in-memory draft can briefly hold an invalid shortcut; ordinary typing must still reach the app.
        XCTAssertFalse(consumes([rule(keyCode: 0, modifiers: [])], keyCode: 0, modifiers: []))
        XCTAssertFalse(consumes([rule(keyCode: 0, modifiers: [.shift])], keyCode: 0, modifiers: [.shift]))
        XCTAssertFalse(consumes([rule(keyCode: 200)], keyCode: 200))
    }

    func testAppConditionsAreCaseAndWhitespaceInsensitive() {
        let included = rule(conditions: RuleConditions(appBundleIdentifiers: ["  COM.Example.Editor \n"]))
        XCTAssertTrue(consumes([included]))
        XCTAssertTrue(consumes([included], bundleIdentifier: " com.example.EDITOR "))
        XCTAssertFalse(consumes([included], bundleIdentifier: "com.example.Other"))
        let excluded = rule(conditions: RuleConditions(excludedAppBundleIdentifiers: [" com.EXAMPLE.editor"]))
        XCTAssertFalse(consumes([excluded]))
        XCTAssertTrue(consumes([excluded], bundleIdentifier: "com.example.Other"))
    }

    func testAnyConsumingRuleWinsOverAPassThroughRuleOnTheSameChord() {
        XCTAssertTrue(consumes([rule(passThrough: true), rule()]))
        XCTAssertTrue(consumes([rule(), rule(passThrough: true)]))
        XCTAssertFalse(consumes([rule(passThrough: true), rule(enabled: false)]))
        XCTAssertTrue(consumes([rule(kind: .doubleShortcut), rule()]))
    }

    func testLegacyTriggerJSONDecodesAsKeepingTheKeyPress() throws {
        let legacy: [String: Any] = ["kind": "shortcut", "keyCode": 123, "modifiers": 786432, "mouseButton": 2,
                                     "scrollDirection": "up", "intervalSeconds": 60, "appBundleIdentifier": ""]
        let trigger = try JSONDecoder().decode(Trigger.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertFalse(trigger.passThrough)
        XCTAssertEqual(trigger, Trigger(keyCode: 123))
        for key in legacy.keys {
            var incomplete = legacy
            incomplete.removeValue(forKey: key)
            XCTAssertThrowsError(try JSONDecoder().decode(Trigger.self, from: JSONSerialization.data(withJSONObject: incomplete)), key)
        }
        var explicit = legacy
        explicit["passThrough"] = true
        XCTAssertTrue(try JSONDecoder().decode(Trigger.self, from: JSONSerialization.data(withJSONObject: explicit)).passThrough)
        explicit["passThrough"] = "yes"
        XCTAssertThrowsError(try JSONDecoder().decode(Trigger.self, from: JSONSerialization.data(withJSONObject: explicit)))
    }

    func testPassThroughRoundTrips() throws {
        let trigger = Trigger(keyCode: 3, modifiers: [.command, .option], passThrough: true)
        let data = try JSONEncoder().encode(trigger)
        XCTAssertEqual(try JSONDecoder().decode(Trigger.self, from: data), trigger)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["passThrough"] as? Bool, true)
        let configuration = Configuration(rules: [AutomationRule(trigger: trigger)])
        let decoded = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(decoded, configuration)
        XCTAssertEqual(decoded.rules.first?.trigger.passThrough, true)
    }
}
