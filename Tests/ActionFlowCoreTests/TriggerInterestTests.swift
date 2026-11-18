import Foundation
import XCTest
@testable import ActionFlowCore

final class TriggerInterestTests: XCTestCase {
    private func rule(_ kind: TriggerKind, enabled: Bool = true) -> AutomationRule {
        AutomationRule(name: kind.rawValue, enabled: enabled,
                       trigger: Trigger(kind: kind, appBundleIdentifier: "com.apple.Safari"))
    }

    func testEachTriggerKindMapsToItsInterest() {
        let expected: [(TriggerKind, TriggerInterest)] = [
            (.shortcut, .keyboard), (.doubleShortcut, .keyboard), (.mouseButton, .mouseButtons),
            (.scroll, .scroll), (.appActivated, .appActivation), (.appLaunched, .appLifecycle),
            (.appTerminated, .appLifecycle), (.interval, .interval)
        ]
        XCTAssertEqual(expected.count, TriggerKind.allCases.count)
        for (kind, interest) in expected {
            XCTAssertEqual(TriggerInterest(rules: [rule(kind)]), interest, kind.rawValue)
        }
    }

    func testOptionsAreDistinct() {
        let all: [TriggerInterest] = [.keyboard, .mouseButtons, .scroll, .appActivation, .appLifecycle, .interval]
        XCTAssertEqual(Set(all.map(\.rawValue)).count, all.count)
        for option in all { XCTAssertEqual(option.rawValue.nonzeroBitCount, 1) }
    }

    func testEmptyAndDisabledRulesContributeNothing() {
        XCTAssertEqual(TriggerInterest(rules: []), [])
        XCTAssertTrue(TriggerInterest(rules: []).isEmpty)
        let disabled = TriggerKind.allCases.map { rule($0, enabled: false) }
        let interest = TriggerInterest(rules: disabled)
        XCTAssertTrue(interest.isEmpty)
        XCTAssertFalse(interest.needsInputMonitoring)
        for kind in TriggerKind.allCases { XCTAssertFalse(interest.wants(kind), kind.rawValue) }
    }

    func testCombinesEnabledRulesOnly() {
        let interest = TriggerInterest(rules: [rule(.scroll), rule(.appLaunched), rule(.mouseButton, enabled: false)])
        XCTAssertEqual(interest, [.scroll, .appLifecycle])
        XCTAssertEqual(TriggerInterest(rules: TriggerKind.allCases.map { rule($0) }),
                       [.keyboard, .mouseButtons, .scroll, .appActivation, .appLifecycle, .interval])
    }

    func testWantsUsesTheKeyboardFamilyForShortcutSignals() {
        let doubleOnly = TriggerInterest(rules: [rule(.doubleShortcut)])
        XCTAssertTrue(doubleOnly.wants(.shortcut))
        XCTAssertTrue(doubleOnly.wants(.doubleShortcut))
        XCTAssertFalse(doubleOnly.wants(.mouseButton))
        XCTAssertFalse(doubleOnly.wants(.scroll))

        let lifecycle = TriggerInterest(rules: [rule(.appTerminated)])
        XCTAssertTrue(lifecycle.wants(.appLaunched))
        XCTAssertTrue(lifecycle.wants(.appTerminated))
        XCTAssertFalse(lifecycle.wants(.appActivated))
        XCTAssertFalse(lifecycle.wants(.interval))

        let everything = TriggerInterest(rules: TriggerKind.allCases.map { rule($0) })
        for kind in TriggerKind.allCases { XCTAssertTrue(everything.wants(kind), kind.rawValue) }
    }

    func testInputMonitoringOnlyForKeyboardMouseOrScroll() {
        XCTAssertTrue(TriggerInterest(rules: [rule(.shortcut)]).needsInputMonitoring)
        XCTAssertTrue(TriggerInterest(rules: [rule(.doubleShortcut)]).needsInputMonitoring)
        XCTAssertTrue(TriggerInterest(rules: [rule(.mouseButton)]).needsInputMonitoring)
        XCTAssertTrue(TriggerInterest(rules: [rule(.scroll)]).needsInputMonitoring)
        XCTAssertFalse(TriggerInterest(rules: [rule(.appActivated), rule(.appLaunched), rule(.appTerminated), rule(.interval)]).needsInputMonitoring)
    }
}
