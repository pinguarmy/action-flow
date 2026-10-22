import Foundation
import XCTest
@testable import ActionFlowCore

final class RuleQueryTests: XCTestCase {
    private func rule(name: String, group: String = "My rules", enabled: Bool = false) -> AutomationRule {
        AutomationRule(name: name, enabled: enabled, group: group,
                       actions: [AutomationAction(kind: .delay, delaySeconds: 0)])
    }

    func testDefaultQueryRetainsInputOrderAndValues() {
        let rules = [rule(name: "Third"), rule(name: "First", enabled: true), rule(name: "Second")]
        let originals = rules
        XCTAssertEqual(RuleQuery().apply(to: rules), rules)
        XCTAssertEqual(rules, originals)
        XCTAssertEqual(RuleQuery(), RuleQuery(text: "", status: .all, group: nil))
        XCTAssertTrue(RuleQuery().apply(to: []).isEmpty)
    }

    func testStatusFiltersIncludeDisabledIncompleteDraftsNeedingAttention() {
        let validEnabled = rule(name: "Enabled", enabled: true)
        let validDisabled = rule(name: "Disabled")
        let invalidDisabled = AutomationRule(name: "", enabled: false, actions: [])
        let invalidEnabled = AutomationRule(name: "Broken", enabled: true, actions: [])
        let rules = [validDisabled, invalidDisabled, validEnabled, invalidEnabled]
        XCTAssertEqual(RuleQuery(status: .enabled).apply(to: rules), [validEnabled, invalidEnabled])
        XCTAssertEqual(RuleQuery(status: .disabled).apply(to: rules), [validDisabled, invalidDisabled])
        XCTAssertEqual(RuleQuery(status: .invalid).apply(to: rules), [invalidDisabled, invalidEnabled])
    }

    func testTextSearchesRuleNameGroupAndTriggerSummaryCaseInsensitively() {
        let named = rule(name: "Meeting Notes", group: "Work")
        let grouped = rule(name: "Window", group: "Meeting tools")
        let timed = AutomationRule(name: "Reminder", group: "Breaks", trigger: Trigger(kind: .interval, intervalSeconds: 1_800),
                                   actions: [AutomationAction(kind: .delay, delaySeconds: 0)])
        XCTAssertEqual(RuleQuery(text: "MEETING").apply(to: [named, grouped, timed]), [named, grouped])
        XCTAssertEqual(RuleQuery(text: "Every").apply(to: [named, grouped, timed]), [timed])
        XCTAssertTrue(RuleQuery(text: "not present").apply(to: [named, grouped, timed]).isEmpty)
    }

    func testSearchDoesNotInspectAnyActionPayload() {
        let privateText = "SENTINEL_PRIVATE_PAYLOAD"
        let rule = AutomationRule(name: "Public rule", group: "Public group", actions: [
            AutomationAction(kind: .insertText, text: privateText),
            AutomationAction(kind: .notification, text: privateText),
            AutomationAction(kind: .shellScript, text: "echo \(privateText)"),
            AutomationAction(kind: .openURL, text: "https://example.com/\(privateText)"),
            AutomationAction(kind: .launchApp, text: "com.example.\(privateText)")
        ])
        XCTAssertFalse(RuleQuery(text: privateText).matches(rule))
        XCTAssertFalse(RuleQuery(text: "example.com").matches(rule))
        XCTAssertFalse(RuleQuery(text: "echo").matches(rule))
        XCTAssertTrue(RuleQuery(text: "Public").matches(rule))
    }

    func testGroupFilterUsesExactRawValuesIncludingWhitespaceAndEmpty() {
        let empty = rule(name: "Empty", group: "")
        let plain = rule(name: "Plain", group: "Work")
        let spaced = rule(name: "Spaced", group: " Work ")
        let lowercase = rule(name: "Lowercase", group: "work")
        let rules = [empty, plain, spaced, lowercase]
        XCTAssertEqual(RuleQuery(group: "").apply(to: rules), [empty])
        XCTAssertEqual(RuleQuery(group: "Work").apply(to: rules), [plain])
        XCTAssertEqual(RuleQuery(group: " Work ").apply(to: rules), [spaced])
        XCTAssertEqual(RuleQuery(group: "work").apply(to: rules), [lowercase])
        XCTAssertEqual(RuleQuery(group: nil).apply(to: rules), rules)
        XCTAssertTrue(RuleQuery(group: "missing").apply(to: rules).isEmpty)
    }

    func testGroupOptionsAreUniqueRawNamesWithStableLexicalOrder() {
        let names = ["工作", "Work", "", " Work ", "work", "Work", ""]
        let rules = names.map { rule(name: "Item", group: $0) }
        XCTAssertEqual(RuleQuery.groups(in: rules), Set(names).sorted())
        XCTAssertEqual(RuleQuery.groups(in: rules), RuleQuery.groups(in: rules.reversed()))
        XCTAssertTrue(RuleQuery.groups(in: []).isEmpty)
    }

    func testCombinedFiltersUseIntersectionAndRetainOriginalOrder() {
        let first = rule(name: "Meeting one", group: "Work", enabled: true)
        let otherGroup = rule(name: "Meeting two", group: "Home", enabled: true)
        let disabled = rule(name: "Meeting three", group: "Work")
        let last = rule(name: "Meeting four", group: "Work", enabled: true)
        let rules = [first, otherGroup, disabled, last]
        let query = RuleQuery(text: "meeting", status: .enabled, group: "Work")
        XCTAssertEqual(query.apply(to: rules), [first, last])
        XCTAssertEqual(rules.map(\.name), ["Meeting one", "Meeting two", "Meeting three", "Meeting four"])
    }

    func testUnicodeNamesAndGroupsAreSearchableWithoutMutation() {
        let chinese = rule(name: "会议记录", group: "工作")
        let accented = rule(name: "CAFÉ notes", group: "Personal")
        XCTAssertTrue(RuleQuery(text: "会议").matches(chinese))
        XCTAssertTrue(RuleQuery(text: "工作").matches(chinese))
        XCTAssertTrue(RuleQuery(text: "café").matches(accented))
        XCTAssertEqual(chinese.name, "会议记录")
        XCTAssertEqual(chinese.group, "工作")
    }

    func testFilterMetadataAndMutableQueryFields() {
        XCTAssertEqual(RuleStatusFilter.allCases.map(\.title), ["All states", "Enabled", "Disabled", "Needs attention"])
        for status in RuleStatusFilter.allCases { XCTAssertEqual(status.id, status.rawValue) }
        var query = RuleQuery()
        query.text = "Window"
        query.status = .disabled
        query.group = "Work"
        XCTAssertEqual(query, RuleQuery(text: "Window", status: .disabled, group: "Work"))
    }
}
