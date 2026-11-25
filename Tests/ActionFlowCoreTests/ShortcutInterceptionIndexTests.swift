import Foundation
import XCTest
@testable import ActionFlowCore

final class ShortcutInterceptionIndexTests: XCTestCase {
    /// Deterministic generator so failures reproduce exactly. Never seeded from the system.
    private struct LinearCongruentialGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
        mutating func int(_ upperBound: Int) -> Int { Int(next() % UInt64(upperBound)) }
        mutating func chance(_ numerator: Int, in denominator: Int) -> Bool { int(denominator) < numerator }
        mutating func pick<T>(_ values: [T]) -> T { values[int(values.count)] }
        mutating func subset(_ values: [String]) -> [String] {
            var output: [String] = []
            for value in values where chance(1, in: 3) { output.append(value) }
            return output
        }
    }

    private let app = "com.example.Editor"

    private func rule(kind: TriggerKind = .shortcut, keyCode: UInt16 = 123, modifiers: ModifierKeys = [.control, .option],
                      enabled: Bool = true, passThrough: Bool = false,
                      conditions: RuleConditions = RuleConditions()) -> AutomationRule {
        AutomationRule(enabled: enabled,
                       trigger: Trigger(kind: kind, keyCode: keyCode, modifiers: modifiers, passThrough: passThrough),
                       conditions: conditions,
                       actions: [AutomationAction(kind: .delay, delaySeconds: 0)])
    }

    private func indexConsumes(_ rules: [AutomationRule], keyCode: UInt16 = 123,
                               modifiers: ModifierKeys = [.control, .option], bundleIdentifier: String? = nil) -> Bool {
        ShortcutInterceptionIndex(rules: rules).consumes(keyCode: keyCode, modifiers: modifiers, bundleIdentifier: bundleIdentifier ?? app)
    }

    func testEmptyIndex() {
        XCTAssertTrue(ShortcutInterceptionIndex.empty.isEmpty)
        XCTAssertTrue(ShortcutInterceptionIndex(rules: []).isEmpty)
        XCTAssertFalse(ShortcutInterceptionIndex.empty.consumes(keyCode: 123, modifiers: [.control, .option], bundleIdentifier: app))
        XCTAssertEqual(ShortcutInterceptionIndex.empty, ShortcutInterceptionIndex(rules: []))
    }

    func testExactChordIsConsumed() {
        XCTAssertFalse(ShortcutInterceptionIndex(rules: [rule()]).isEmpty)
        XCTAssertTrue(indexConsumes([rule()]))
        XCTAssertFalse(indexConsumes([rule()], keyCode: 124))
        XCTAssertFalse(indexConsumes([rule()], modifiers: [.control]))
        XCTAssertFalse(indexConsumes([rule()], modifiers: [.control, .option, .shift]))
    }

    func testInvalidChordDisabledPassThroughAndDoublePressNeverConsume() {
        XCTAssertTrue(ShortcutInterceptionIndex(rules: [rule(modifiers: [.shift])]).isEmpty)
        XCTAssertFalse(indexConsumes([rule(modifiers: [.shift])], modifiers: [.shift]))
        XCTAssertFalse(indexConsumes([rule(modifiers: [])], modifiers: []))
        XCTAssertFalse(indexConsumes([rule(keyCode: 200)], keyCode: 200))
        XCTAssertFalse(indexConsumes([rule(enabled: false)]))
        XCTAssertFalse(indexConsumes([rule(passThrough: true)]))
        XCTAssertFalse(indexConsumes([rule(kind: .doubleShortcut)]))
        XCTAssertFalse(indexConsumes([rule(kind: .mouseButton)]))
        XCTAssertTrue(ShortcutInterceptionIndex(rules: [rule(enabled: false), rule(passThrough: true), rule(kind: .doubleShortcut)]).isEmpty)
    }

    func testConditionsAreNormalizedLikeTheRuleList() {
        let included = rule(conditions: RuleConditions(appBundleIdentifiers: [" COM.Example.EDITOR "]))
        XCTAssertTrue(indexConsumes([included], bundleIdentifier: "com.example.editor"))
        XCTAssertTrue(indexConsumes([included], bundleIdentifier: "  Com.Example.Editor\n"))
        XCTAssertFalse(indexConsumes([included], bundleIdentifier: "com.example.other"))
        let excluded = rule(conditions: RuleConditions(excludedAppBundleIdentifiers: [" COM.Example.EDITOR "]))
        XCTAssertFalse(indexConsumes([excluded], bundleIdentifier: "com.example.editor"))
        XCTAssertTrue(indexConsumes([excluded], bundleIdentifier: "com.example.other"))
        // Two rules on one chord: any matching rule keeps the key press.
        XCTAssertTrue(indexConsumes([excluded, included], bundleIdentifier: "com.example.editor"))
    }

    // MARK: - Generated comparison with the rule-list implementation

    private func randomRule(_ index: Int, using generator: inout LinearCongruentialGenerator) -> AutomationRule {
        let apps = ["com.apple.Safari", " COM.apple.safari ", "com.apple.Terminal", "com.example.Editor", ""]
        let modifierChoices: [ModifierKeys] = [[], [.command], [.control, .option], [.shift], [.command, .shift]]
        let trigger = Trigger(kind: generator.pick([TriggerKind.shortcut, .shortcut, .shortcut, .doubleShortcut, .scroll]),
                              keyCode: generator.pick([0, 1, 2, 126, 127, 128]),
                              modifiers: generator.pick(modifierChoices),
                              passThrough: generator.chance(1, in: 4))
        let conditions = RuleConditions(appBundleIdentifiers: generator.chance(1, in: 2) ? [] : generator.subset(apps),
                                        excludedAppBundleIdentifiers: generator.chance(1, in: 2) ? [] : generator.subset(apps))
        return AutomationRule(name: "Rule \(index)", enabled: generator.chance(3, in: 4), trigger: trigger, conditions: conditions)
    }

    func testIndexMatchesRuleListImplementation() {
        var generator = LinearCongruentialGenerator(state: 0x1D3A_5EED_0000_0042)
        let apps = ["com.apple.Safari", "com.apple.safari", " COM.APPLE.TERMINAL\n", "com.example.Editor", "", "com.unknown.app"]
        let chordModifiers: [ModifierKeys] = [[], [.command], [.control, .option], [.shift], [.command, .shift]]
        var consumed = 0
        var checked = 0
        for iteration in 0..<300 {
            var rules: [AutomationRule] = []
            for index in 0..<generator.int(25) { rules.append(randomRule(index, using: &generator)) }
            let index = ShortcutInterceptionIndex(rules: rules)
            for keyCode: UInt16 in [0, 1, 2, 3, 126, 127, 128] {
                for modifiers in chordModifiers {
                    for bundle in apps {
                        let expected = ShortcutInterception.consumes(keyCode: keyCode, modifiers: modifiers, rules: rules, bundleIdentifier: bundle)
                        let actual = index.consumes(keyCode: keyCode, modifiers: modifiers, bundleIdentifier: bundle)
                        XCTAssertEqual(actual, expected, "Mismatch in generated set \(iteration) for key \(keyCode)")
                        checked += 1
                        if expected { consumed += 1 }
                    }
                }
            }
            XCTAssertEqual(index.isEmpty, !rules.contains { $0.enabled && ShortcutInterception.canConsume($0.trigger) })
        }
        // The generator must exercise both outcomes, or the comparison proves nothing.
        XCTAssertGreaterThan(consumed, 100)
        XCTAssertGreaterThan(checked - consumed, 100)
    }
}
