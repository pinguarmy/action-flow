import Foundation
import XCTest
@testable import ActionFlowCore

final class DoubleShortcutTests: XCTestCase {
    private let context = ExecutionContext(processIdentifier: 100, bundleIdentifier: "com.example.Editor")
    private let press = TriggerSignal(kind: .shortcut, keyCode: 0, modifiers: [.command])

    private func rule(kind: TriggerKind = .doubleShortcut, cooldown: Double = 0) -> AutomationRule {
        AutomationRule(enabled: true, trigger: Trigger(kind: kind, keyCode: 0, modifiers: [.command]),
                       actions: [AutomationAction(kind: .delay, delaySeconds: 0)], cooldown: cooldown)
    }

    func testDoublePressIncludesExactBoundaryAndConsumesNonoverlappingPairs() {
        var scheduler = RuleScheduler()
        let double = rule()
        XCTAssertTrue(scheduler.candidates(for: press, rules: [double], context: context, now: 1).isEmpty)
        XCTAssertEqual(scheduler.candidates(for: press, rules: [double], context: context, now: 1.35).map(\.id), [double.id])
        XCTAssertTrue(scheduler.candidates(for: press, rules: [double], context: context, now: 1.6).isEmpty)
        XCTAssertEqual(scheduler.candidates(for: press, rules: [double], context: context, now: 1.7).map(\.id), [double.id])
    }

    func testLateSecondPressBecomesNewFirstPress() {
        var scheduler = RuleScheduler()
        let double = rule()
        XCTAssertTrue(scheduler.candidates(for: press, rules: [double], context: context, now: 1).isEmpty)
        XCTAssertTrue(scheduler.candidates(for: press, rules: [double], context: context, now: 1.350001).isEmpty)
        XCTAssertEqual(scheduler.candidates(for: press, rules: [double], context: context, now: 1.5).count, 1)
    }

    func testDifferentKeyOrModifiersBreakPendingPair() {
        for mismatch in [TriggerSignal(kind: .shortcut, keyCode: 1, modifiers: [.command]),
                         TriggerSignal(kind: .shortcut, keyCode: 0, modifiers: [.option])] {
            var scheduler = RuleScheduler()
            let double = rule()
            XCTAssertTrue(scheduler.candidates(for: press, rules: [double], context: context, now: 1).isEmpty)
            XCTAssertTrue(scheduler.candidates(for: mismatch, rules: [double], context: context, now: 1.1).isEmpty)
            XCTAssertTrue(scheduler.candidates(for: press, rules: [double], context: context, now: 1.2).isEmpty)
            XCTAssertEqual(scheduler.candidates(for: press, rules: [double], context: context, now: 1.3).count, 1)
        }
    }

    func testContextChangeInvalidatesPairEvenIfContextReturnsBeforeNextPress() {
        for other in [ExecutionContext(processIdentifier: 101, bundleIdentifier: context.bundleIdentifier),
                      ExecutionContext(processIdentifier: 100, bundleIdentifier: "com.example.Other"),
                      ExecutionContext(processIdentifier: nil, bundleIdentifier: context.bundleIdentifier)] {
            var scheduler = RuleScheduler()
            let double = rule()
            _ = scheduler.candidates(for: press, rules: [double], context: context, now: 1)
            _ = scheduler.candidates(for: TriggerSignal(kind: .appActivated), rules: [double], context: other, now: 1.1)
            XCTAssertTrue(scheduler.candidates(for: press, rules: [double], context: context, now: 1.2).isEmpty)
            XCTAssertEqual(scheduler.candidates(for: press, rules: [double], context: context, now: 1.3).count, 1)
        }
    }

    func testMouseEventsDoNotBreakPairButIntervalContextChangeDoes() {
        var scheduler = RuleScheduler()
        let double = rule()
        _ = scheduler.candidates(for: press, rules: [double], context: context, now: 1)
        _ = scheduler.candidates(for: TriggerSignal(kind: .mouseButton), rules: [double], context: context, now: 1.1)
        XCTAssertEqual(scheduler.candidates(for: press, rules: [double], context: context, now: 1.2).count, 1)
        scheduler.reset()
        _ = scheduler.candidates(for: press, rules: [double], context: context, now: 2)
        _ = scheduler.intervalCandidates(rules: [double], context: ExecutionContext(processIdentifier: 101, bundleIdentifier: context.bundleIdentifier), now: 2.1)
        XCTAssertTrue(scheduler.candidates(for: press, rules: [double], context: context, now: 2.2).isEmpty)
    }

    func testSingleShortcutStillFiresOnEachPressAlongsideDoubleShortcut() {
        var scheduler = RuleScheduler()
        let single = rule(kind: .shortcut)
        let double = rule()
        XCTAssertEqual(scheduler.candidates(for: press, rules: [single, double], context: context, now: 1).map(\.id), [single.id])
        XCTAssertEqual(scheduler.candidates(for: press, rules: [single, double], context: context, now: 1.3).map(\.id), [single.id, double.id])
    }

    func testCooldownIsCheckedOnlyForCompletedPairsAndBlockedPairsAreConsumed() {
        var scheduler = RuleScheduler()
        let double = rule(cooldown: 1)
        _ = scheduler.candidates(for: press, rules: [double], context: context, now: 1)
        XCTAssertEqual(scheduler.candidates(for: press, rules: [double], context: context, now: 1.1).count, 1)
        XCTAssertTrue(scheduler.candidates(for: press, rules: [double], context: context, now: 1.2).isEmpty)
        XCTAssertTrue(scheduler.candidates(for: press, rules: [double], context: context, now: 1.3).isEmpty)
        XCTAssertTrue(scheduler.candidates(for: press, rules: [double], context: context, now: 2).isEmpty)
        XCTAssertEqual(scheduler.candidates(for: press, rules: [double], context: context, now: 2.2).count, 1)
    }

    func testResetDeletionDisableAndTriggerEditClearPendingState() {
        for change in 0..<4 {
            var scheduler = RuleScheduler()
            var double = rule()
            _ = scheduler.candidates(for: press, rules: [double], context: context, now: 1)
            switch change {
            case 0: scheduler.reset()
            case 1: scheduler.removeStaleRules([])
            case 2:
                double.enabled = false
                scheduler.removeStaleRules([double])
                double.enabled = true
            default:
                double.trigger.keyCode = 1
                scheduler.removeStaleRules([double])
                double.trigger.keyCode = 0
            }
            XCTAssertTrue(scheduler.candidates(for: press, rules: [double], context: context, now: 1.1).isEmpty)
        }
    }

    func testInvalidatingPendingShortcutsPreservesCooldownAndIntervalSchedule() {
        var scheduler = RuleScheduler()
        let double = rule()
        let single = rule(kind: .shortcut, cooldown: 5)
        var interval = rule(kind: .interval)
        interval.trigger.intervalSeconds = 2
        XCTAssertEqual(scheduler.candidates(for: press, rules: [single, double, interval], context: context, now: 1).map(\.id), [single.id])
        XCTAssertTrue(scheduler.intervalCandidates(rules: [single, double, interval], context: context, now: 1).isEmpty)
        scheduler.invalidatePendingShortcuts()
        XCTAssertTrue(scheduler.candidates(for: press, rules: [single, double, interval], context: context, now: 1.1).isEmpty)
        XCTAssertEqual(scheduler.intervalCandidates(rules: [single, double, interval], context: context, now: 3).map(\.id), [interval.id])
    }

    func testInvalidAndReversedTimeNeverCompleteAnOldPair() {
        for time in [Double.nan, .infinity, 0.9] {
            var scheduler = RuleScheduler()
            let double = rule()
            _ = scheduler.candidates(for: press, rules: [double], context: context, now: 1)
            _ = scheduler.candidates(for: TriggerSignal(kind: .scroll), rules: [double], context: context, now: time)
            XCTAssertTrue(scheduler.candidates(for: press, rules: [double], context: context, now: 1.1).isEmpty)
        }
    }

    func testAppConditionsPreventArmingAndSyntheticDoubleSignalCannotRunRule() {
        var scheduler = RuleScheduler()
        var double = rule()
        double.conditions.appBundleIdentifiers = ["com.example.Other"]
        XCTAssertTrue(scheduler.candidates(for: press, rules: [double], context: context, now: 1).isEmpty)
        double.conditions = RuleConditions()
        XCTAssertTrue(scheduler.candidates(for: press, rules: [double], context: context, now: 1.1).isEmpty)
        XCTAssertTrue(scheduler.candidates(for: TriggerSignal(kind: .doubleShortcut, keyCode: 0, modifiers: [.command]),
                                           rules: [double], context: context, now: 1.2).isEmpty)
        XCTAssertEqual(scheduler.candidates(for: press, rules: [double], context: context, now: 1.3).count, 1)
    }

    func testValidationRequirementsAndSingleDoubleConflictWarnings() {
        var double = rule()
        XCTAssertTrue(RuleValidator.validate(double).isEmpty)
        XCTAssertEqual(RuleRequirements.capabilities(for: double, automatic: true), [.inputMonitoring])
        XCTAssertTrue(RuleRequirements.capabilities(for: double, automatic: false).isEmpty)
        double.trigger.modifiers = [.shift]
        XCTAssertFalse(RuleValidator.validate(double).isEmpty)
        double.trigger.modifiers = [.command]
        let single = rule(kind: .shortcut)
        let otherDouble = rule()
        XCTAssertEqual(RuleValidator.conflicts(in: [single, double, otherDouble]).count, 3)
        double.conditions.excludedAppBundleIdentifiers = [context.bundleIdentifier]
        var scopedSingle = single
        scopedSingle.conditions.appBundleIdentifiers = [context.bundleIdentifier]
        XCTAssertTrue(RuleValidator.conflicts(in: [scopedSingle, double]).isEmpty)
    }

    func testOldTriggerJSONIsUnchangedAndNewKindNeedsNoNewProperties() throws {
        let oldJSON = Data("{\"kind\":\"shortcut\",\"keyCode\":0,\"modifiers\":1048576,\"mouseButton\":2,\"scrollDirection\":\"up\",\"intervalSeconds\":60,\"appBundleIdentifier\":\"\"}".utf8)
        var trigger = try JSONDecoder().decode(Trigger.self, from: oldJSON)
        XCTAssertEqual(trigger.kind, .shortcut)
        let oldObject = try XCTUnwrap(JSONSerialization.jsonObject(with: oldJSON) as? NSDictionary)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(trigger)) as? NSDictionary, oldObject)
        trigger.kind = .doubleShortcut
        let encoded = try JSONEncoder().encode(trigger)
        XCTAssertEqual(try JSONDecoder().decode(Trigger.self, from: encoded), trigger)
        let newObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(newObject.keys), Set(oldObject.allKeys.compactMap { $0 as? String }))
        XCTAssertEqual(newObject["kind"] as? String, "doubleShortcut")
        XCTAssertEqual(trigger.summary, "⌘A × 2")
        XCTAssertEqual(TriggerKind.doubleShortcut.title, "Double-press shortcut")
    }
}
