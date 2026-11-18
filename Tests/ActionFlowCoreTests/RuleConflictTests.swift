import Foundation
import XCTest
@testable import ActionFlowCore

final class RuleConflictTests: XCTestCase {
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

    // MARK: - Reference: the original all-pairs algorithm

    private func referenceSameTrigger(_ first: Trigger, _ second: Trigger) -> Bool {
        let shortcutKinds: Set<TriggerKind> = [.shortcut, .doubleShortcut]
        if shortcutKinds.contains(first.kind) && shortcutKinds.contains(second.kind) {
            return first.keyCode == second.keyCode && first.modifiers == second.modifiers
        }
        guard first.kind == second.kind else { return false }
        switch first.kind {
        case .shortcut, .doubleShortcut: return first.keyCode == second.keyCode && first.modifiers == second.modifiers
        case .mouseButton: return first.mouseButton == second.mouseButton && first.modifiers == second.modifiers
        case .scroll: return first.scrollDirection == second.scrollDirection && first.modifiers == second.modifiers
        case .appActivated, .appLaunched, .appTerminated:
            return RuleConditions.normalized(first.appBundleIdentifier) == RuleConditions.normalized(second.appBundleIdentifier)
        case .interval: return first.intervalSeconds == second.intervalSeconds
        }
    }

    private func referenceConditionsOverlap(_ first: AutomationRule, _ second: AutomationRule) -> Bool {
        if first.trigger.kind == .appActivated {
            return first.conditions.matches(bundleIdentifier: first.trigger.appBundleIdentifier) &&
                second.conditions.matches(bundleIdentifier: first.trigger.appBundleIdentifier)
        }
        let firstIncluded = Set(first.conditions.appBundleIdentifiers.map(RuleConditions.normalized))
        let secondIncluded = Set(second.conditions.appBundleIdentifiers.map(RuleConditions.normalized))
        let excluded = Set((first.conditions.excludedAppBundleIdentifiers + second.conditions.excludedAppBundleIdentifiers).map(RuleConditions.normalized))
        if firstIncluded.isEmpty && secondIncluded.isEmpty { return true }
        let candidates: Set<String>
        if firstIncluded.isEmpty { candidates = secondIncluded }
        else if secondIncluded.isEmpty { candidates = firstIncluded }
        else { candidates = firstIncluded.intersection(secondIncluded) }
        return !candidates.subtracting(excluded).isEmpty
    }

    private func referenceConflicts(in rules: [AutomationRule]) -> [String] {
        let enabled = rules.filter(\.enabled)
        var messages: [String] = []
        for firstIndex in enabled.indices {
            for secondIndex in enabled.indices where secondIndex > firstIndex {
                let first = enabled[firstIndex]
                let second = enabled[secondIndex]
                if referenceSameTrigger(first.trigger, second.trigger), referenceConditionsOverlap(first, second) {
                    messages.append("\"\(first.name)\" and \"\(second.name)\" share \(first.trigger.summary) in overlapping apps.")
                }
            }
        }
        return messages
    }

    // MARK: - Generation

    private func randomRule(_ index: Int, using generator: inout LinearCongruentialGenerator) -> AutomationRule {
        let apps = ["com.apple.Safari", " COM.apple.safari ", "com.apple.Terminal", "com.example.Editor", ""]
        let modifierChoices: [ModifierKeys] = [[], [.command], [.control, .option]]
        let intervals: [Double] = [60, 30, Double.nan, 0, -0.0, 1]
        let trigger = Trigger(kind: generator.pick(TriggerKind.allCases),
                              keyCode: UInt16(generator.int(3)),
                              modifiers: generator.pick(modifierChoices),
                              mouseButton: generator.int(3),
                              scrollDirection: generator.pick([ScrollDirection.up, .down]),
                              intervalSeconds: generator.pick(intervals),
                              appBundleIdentifier: generator.pick(apps))
        let conditions = RuleConditions(appBundleIdentifiers: generator.chance(1, in: 2) ? [] : generator.subset(apps),
                                        excludedAppBundleIdentifiers: generator.chance(1, in: 2) ? [] : generator.subset(apps))
        return AutomationRule(name: "Rule \(index)", enabled: generator.chance(3, in: 4),
                              trigger: trigger, conditions: conditions)
    }

    // MARK: - Tests

    func testBucketedConflictsMatchAllPairsReference() {
        var generator = LinearCongruentialGenerator(state: 0x5EED_1234_ABCD_0001)
        var totalConflicts = 0
        for iteration in 0..<400 {
            let count = generator.int(40)
            var rules: [AutomationRule] = []
            for index in 0..<count { rules.append(randomRule(index, using: &generator)) }
            let expected = referenceConflicts(in: rules)
            XCTAssertEqual(RuleValidator.conflicts(in: rules), expected, "Mismatch in generated set \(iteration)")
            let pairs = RuleValidator.conflictPairs(in: rules)
            XCTAssertEqual(pairs.map(\.message), expected, "Pair messages mismatch in generated set \(iteration)")
            for pair in pairs {
                let firstPosition = rules.firstIndex(where: { $0.id == pair.first.id })
                let secondPosition = rules.firstIndex(where: { $0.id == pair.second.id })
                XCTAssertNotNil(firstPosition)
                XCTAssertNotNil(secondPosition)
                if let firstPosition, let secondPosition { XCTAssertLessThan(firstPosition, secondPosition) }
                XCTAssertTrue(pair.first.enabled && pair.second.enabled)
            }
            totalConflicts += expected.count
        }
        // Guard against a generator that never produces conflicts, which would make the comparison vacuous.
        XCTAssertGreaterThan(totalConflicts, 100)
    }

    func testConflictOrderFollowsFirstThenSecondEnabledIndex() {
        let shortcutA = Trigger(keyCode: 1)
        let shortcutB = Trigger(keyCode: 2)
        let rules = [
            AutomationRule(name: "A1", enabled: true, trigger: shortcutA),
            AutomationRule(name: "B1", enabled: true, trigger: shortcutB),
            AutomationRule(name: "Off", enabled: false, trigger: shortcutA),
            AutomationRule(name: "A2", enabled: true, trigger: shortcutA),
            AutomationRule(name: "B2", enabled: true, trigger: shortcutB),
            AutomationRule(name: "A3", enabled: true, trigger: shortcutA)
        ]
        let pairs = RuleValidator.conflictPairs(in: rules).map { [$0.first.name, $0.second.name] }
        XCTAssertEqual(pairs, [["A1", "A2"], ["A1", "A3"], ["B1", "B2"], ["A2", "A3"]])
        XCTAssertEqual(RuleValidator.conflicts(in: rules), referenceConflicts(in: rules))
        XCTAssertEqual(RuleValidator.conflicts(in: rules).first,
                       "\"A1\" and \"A2\" share \(shortcutA.summary) in overlapping apps.")
    }

    func testShortcutAndDoubleShortcutWithSameChordConflict() {
        let single = AutomationRule(name: "Single", enabled: true, trigger: Trigger(kind: .shortcut, keyCode: 4, modifiers: [.command]))
        let double = AutomationRule(name: "Double", enabled: true, trigger: Trigger(kind: .doubleShortcut, keyCode: 4, modifiers: [.command]))
        let pairs = RuleValidator.conflictPairs(in: [double, single])
        XCTAssertEqual(pairs, [RuleConflict(first: double, second: single)])
        XCTAssertEqual(RuleValidator.conflicts(in: [double, single]),
                       ["\"Double\" and \"Single\" share \(double.trigger.summary) in overlapping apps."])
        let otherChord = AutomationRule(name: "Other", enabled: true, trigger: Trigger(kind: .doubleShortcut, keyCode: 4, modifiers: [.option]))
        XCTAssertTrue(RuleValidator.conflicts(in: [single, otherChord]).isEmpty)
    }

    func testNaNIntervalsNeverConflictButSignedZerosDo() {
        let nanFirst = AutomationRule(name: "NaN 1", enabled: true, trigger: Trigger(kind: .interval, intervalSeconds: .nan))
        let nanSecond = AutomationRule(name: "NaN 2", enabled: true, trigger: Trigger(kind: .interval, intervalSeconds: .nan))
        XCTAssertTrue(RuleValidator.conflicts(in: [nanFirst, nanSecond]).isEmpty)
        XCTAssertTrue(RuleValidator.conflictPairs(in: [nanFirst, nanSecond]).isEmpty)
        let zero = AutomationRule(name: "Zero", enabled: true, trigger: Trigger(kind: .interval, intervalSeconds: 0))
        let negativeZero = AutomationRule(name: "Negative zero", enabled: true, trigger: Trigger(kind: .interval, intervalSeconds: -0.0))
        XCTAssertEqual(RuleValidator.conflicts(in: [zero, negativeZero]), referenceConflicts(in: [zero, negativeZero]))
        XCTAssertEqual(RuleValidator.conflicts(in: [zero, negativeZero]).count, 1)
    }

    func testDifferentApplicationTriggerKindsDoNotConflict() {
        let rules = [TriggerKind.appActivated, .appLaunched, .appTerminated].map {
            AutomationRule(name: $0.rawValue, enabled: true, trigger: Trigger(kind: $0, appBundleIdentifier: "com.apple.Safari"))
        }
        XCTAssertTrue(RuleValidator.conflicts(in: rules).isEmpty)
        let normalizedTwin = AutomationRule(name: "Twin", enabled: true,
                                            trigger: Trigger(kind: .appLaunched, appBundleIdentifier: " COM.Apple.Safari "))
        XCTAssertEqual(RuleValidator.conflicts(in: rules + [normalizedTwin]).count, 1)
    }

    func testManyDistinctShortcutsHaveNoConflicts() {
        var rules: [AutomationRule] = []
        let modifierChoices: [ModifierKeys] = [[], [.command], [.option], [.control], [.shift],
                                               [.command, .option], [.command, .shift], [.control, .option]]
        for index in 0..<1_000 {
            let trigger = Trigger(keyCode: UInt16(index / modifierChoices.count),
                                  modifiers: modifierChoices[index % modifierChoices.count])
            rules.append(AutomationRule(name: "Rule \(index)", enabled: true, trigger: trigger))
        }
        XCTAssertTrue(RuleValidator.conflictPairs(in: rules).isEmpty)
        XCTAssertTrue(RuleValidator.conflicts(in: rules).isEmpty)
    }
}
