import Foundation
import XCTest
@testable import ActionFlowCore

final class ApplicationLifecycleTests: XCTestCase {
    private let foreground = ExecutionContext(processIdentifier: 100, bundleIdentifier: "com.example.Editor")
    private let eventApp = "com.example.Background"

    private func rule(_ kind: TriggerKind, cooldown: Double = 0.5) -> AutomationRule {
        AutomationRule(enabled: true, trigger: Trigger(kind: kind, appBundleIdentifier: eventApp),
                       actions: [AutomationAction(kind: .delay, delaySeconds: 0)], cooldown: cooldown)
    }

    func testLaunchAndTerminationMatchBackgroundEventIdentityNotForegroundTarget() {
        for kind in [TriggerKind.appLaunched, .appTerminated] {
            var scheduler = RuleScheduler()
            let rule = rule(kind)
            let signal = TriggerSignal(kind: kind, appBundleIdentifier: eventApp.uppercased())
            XCTAssertEqual(scheduler.candidates(for: signal, rules: [rule], context: foreground, now: 1).map(\.id), [rule.id])
            let anotherProcess = ExecutionContext(processIdentifier: 200, bundleIdentifier: foreground.bundleIdentifier)
            XCTAssertEqual(scheduler.candidates(for: signal, rules: [rule], context: anotherProcess, now: 2).map(\.id), [rule.id])
            XCTAssertTrue(scheduler.candidates(for: TriggerSignal(kind: kind, appBundleIdentifier: "com.example.Other"),
                                               rules: [rule], context: foreground, now: 3).isEmpty)
        }
    }

    func testActivationStillRequiresEventAppToBeForeground() {
        let rule = rule(.appActivated)
        let signal = TriggerSignal(kind: .appActivated, appBundleIdentifier: eventApp)
        var scheduler = RuleScheduler()
        XCTAssertTrue(scheduler.candidates(for: signal, rules: [rule], context: foreground, now: 1).isEmpty)
        let activated = ExecutionContext(processIdentifier: 200, bundleIdentifier: eventApp)
        XCTAssertEqual(scheduler.candidates(for: signal, rules: [rule], context: activated, now: 2).map(\.id), [rule.id])
        XCTAssertTrue(rule.trigger.summary.hasPrefix("App activates:"))
    }

    func testLifecycleConditionsReferToForegroundAppNotEventSource() {
        for kind in [TriggerKind.appLaunched, .appTerminated] {
            var scheduler = RuleScheduler()
            var rule = rule(kind)
            rule.conditions.appBundleIdentifiers = [foreground.bundleIdentifier]
            rule.conditions.excludedAppBundleIdentifiers = [eventApp]
            XCTAssertTrue(RuleValidator.validate(rule).isEmpty)
            let signal = TriggerSignal(kind: kind, appBundleIdentifier: eventApp)
            XCTAssertEqual(scheduler.candidates(for: signal, rules: [rule], context: foreground, now: 1).count, 1)
            let other = ExecutionContext(processIdentifier: 200, bundleIdentifier: "com.example.Other")
            XCTAssertTrue(scheduler.candidates(for: signal, rules: [rule], context: other, now: 2).isEmpty)
            rule.conditions.excludedAppBundleIdentifiers.append(foreground.bundleIdentifier)
            XCTAssertTrue(scheduler.candidates(for: signal, rules: [rule], context: foreground, now: 3).isEmpty)
        }
    }

    func testLifecycleKindsAreDistinctAndDoNotReplayFromIntervalsOrOtherSignals() {
        var scheduler = RuleScheduler()
        let launch = rule(.appLaunched)
        let terminate = rule(.appTerminated)
        let activated = rule(.appActivated)
        let all = [launch, terminate, activated]
        XCTAssertEqual(scheduler.candidates(for: TriggerSignal(kind: .appLaunched, appBundleIdentifier: eventApp),
                                           rules: all, context: foreground, now: 1).map(\.id), [launch.id])
        XCTAssertTrue(scheduler.intervalCandidates(rules: all, context: foreground, now: 100).isEmpty)
        XCTAssertTrue(scheduler.candidates(for: TriggerSignal(kind: .shortcut), rules: all, context: foreground, now: 101).isEmpty)
        XCTAssertEqual(scheduler.candidates(for: TriggerSignal(kind: .appTerminated, appBundleIdentifier: eventApp),
                                           rules: all, context: foreground, now: 102).map(\.id), [terminate.id])
    }

    func testCooldownDisabledRulesAndExcludedEventAreNeverQueuedForLater() {
        for kind in [TriggerKind.appLaunched, .appTerminated] {
            var scheduler = RuleScheduler()
            var rule = rule(kind, cooldown: 1)
            let signal = TriggerSignal(kind: kind, appBundleIdentifier: eventApp)
            XCTAssertEqual(scheduler.candidates(for: signal, rules: [rule], context: foreground, now: 1).count, 1)
            XCTAssertTrue(scheduler.candidates(for: signal, rules: [rule], context: foreground, now: 1.5).isEmpty)
            XCTAssertTrue(scheduler.intervalCandidates(rules: [rule], context: foreground, now: 20).isEmpty)
            XCTAssertEqual(scheduler.candidates(for: signal, rules: [rule], context: foreground, now: 21).count, 1)
            rule.enabled = false
            XCTAssertTrue(scheduler.candidates(for: signal, rules: [rule], context: foreground, now: 30).isEmpty)
        }
    }

    func testLifecycleRequiresValidIdentifierButNoInputMonitoring() {
        for kind in [TriggerKind.appActivated, .appLaunched, .appTerminated] {
            var rule = rule(kind)
            XCTAssertTrue(RuleValidator.validate(rule).isEmpty)
            XCTAssertTrue(RuleRequirements.capabilities(for: rule, automatic: true).isEmpty)
            XCTAssertTrue(RuleRequirements.capabilities(for: rule, automatic: false).isEmpty)
            for identifier in ["", "Safari", "com..app", "com.example/app"] {
                rule.trigger.appBundleIdentifier = identifier
                XCTAssertFalse(RuleValidator.validate(rule).isEmpty)
            }
        }
    }

    func testLifecycleConflictsConsiderSameEventAndOverlappingForegroundScopes() {
        for kind in [TriggerKind.appLaunched, .appTerminated] {
            var first = rule(kind)
            var second = rule(kind)
            first.conditions.appBundleIdentifiers = [foreground.bundleIdentifier]
            second.conditions.appBundleIdentifiers = [foreground.bundleIdentifier]
            XCTAssertEqual(RuleValidator.conflicts(in: [first, second]).count, 1)
            second.conditions.appBundleIdentifiers = ["com.example.Other"]
            XCTAssertTrue(RuleValidator.conflicts(in: [first, second]).isEmpty)
            second.conditions = first.conditions
            second.trigger.appBundleIdentifier = "com.example.Other"
            XCTAssertTrue(RuleValidator.conflicts(in: [first, second]).isEmpty)
        }
        XCTAssertTrue(RuleValidator.conflicts(in: [rule(.appLaunched), rule(.appTerminated)]).isEmpty)
    }

    func testExistingAutomaticEligibilityStillBlocksEditorAndMissingContext() {
        let editor = "io.github.pinguarmy.actionflow"
        XCTAssertFalse(RuleScheduler.canAutomaticallyRun(context: ExecutionContext(processIdentifier: 10, bundleIdentifier: editor),
                                                         editorBundleIdentifier: editor, automationEnabled: true,
                                                         isRecording: false, isPreparingManualRun: false))
        XCTAssertFalse(RuleScheduler.canAutomaticallyRun(context: ExecutionContext(processIdentifier: nil, bundleIdentifier: eventApp),
                                                         editorBundleIdentifier: editor, automationEnabled: true,
                                                         isRecording: false, isPreparingManualRun: false))
    }

    func testNewAndExistingAppTriggerJSONRoundTripWithoutNewFields() throws {
        let encoder = JSONEncoder()
        var existingKeys: Set<String>?
        for kind in [TriggerKind.appActivated, .appLaunched, .appTerminated] {
            let rule = rule(kind)
            let data = try encoder.encode(rule.trigger)
            XCTAssertEqual(try JSONDecoder().decode(Trigger.self, from: data), rule.trigger)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let keys = Set(object.keys)
            if let existingKeys { XCTAssertEqual(keys, existingKeys) } else { existingKeys = keys }
            XCTAssertEqual(object["kind"] as? String, kind.rawValue)
            let configuration = Configuration(rules: [rule])
            XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: encoder.encode(configuration)), configuration)
        }
        XCTAssertEqual(TriggerKind.appLaunched.title, "Application launched")
        XCTAssertEqual(TriggerKind.appTerminated.title, "Application terminated")
    }
}
