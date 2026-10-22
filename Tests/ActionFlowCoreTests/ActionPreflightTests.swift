import Foundation
import XCTest
@testable import ActionFlowCore

final class ActionPreflightTests: XCTestCase {
    private func errors(_ kind: ActionKind, text: String) -> [String] {
        ActionPreflight.errors(for: [AutomationAction(kind: kind, text: text)])
    }

    func testChainCountsAndUniqueIdentifiers() {
        XCTAssertEqual(ActionPreflight.errors(for: []), ["Add at least one action."])
        let action = AutomationAction(kind: .delay, delaySeconds: 0)
        XCTAssertTrue(ActionPreflight.errors(for: [action, action]).contains("Action identifiers must be unique within a rule."))
        XCTAssertTrue(ActionPreflight.errors(for: (0..<64).map { _ in AutomationAction(kind: .delay, delaySeconds: 0) }).isEmpty)
        XCTAssertTrue(ActionPreflight.errors(for: (0..<65).map { _ in AutomationAction(kind: .delay, delaySeconds: 0) })
            .contains("A rule cannot have more than 64 actions."))
    }

    func testInsertedTextUsesUTF16UnitsAndChecksSingleCharacterSize() {
        let utf16LimitMessage = "Inserted text is limited to 16,384 UTF-16 units."
        // Byte/unit limits remain independent of the stricter execution budget.
        XCTAssertFalse(errors(.insertText, text: String(repeating: "a", count: 16_384)).contains(where: { $0.contains(utf16LimitMessage) }))
        XCTAssertTrue(errors(.insertText, text: String(repeating: "a", count: 16_385)).contains(where: { $0.contains(utf16LimitMessage) }))
        XCTAssertFalse(errors(.insertText, text: String(repeating: "😀", count: 8_192)).contains(where: { $0.contains(utf16LimitMessage) }))
        XCTAssertFalse(errors(.insertText, text: String(repeating: "😀", count: 8_193)).isEmpty)
        let oversizedGrapheme = "a" + String(repeating: "\u{0301}", count: 256)
        XCTAssertEqual(oversizedGrapheme.count, 1)
        XCTAssertTrue(errors(.insertText, text: oversizedGrapheme).contains(where: { $0.contains("256 UTF-16") }))
    }

    func testScriptAndNotificationByteLimitsIncludeMultibyteText() {
        XCTAssertTrue(errors(.shellScript, text: String(repeating: "x", count: 16_384)).isEmpty)
        XCTAssertFalse(errors(.shellScript, text: String(repeating: "x", count: 16_385)).isEmpty)
        XCTAssertTrue(errors(.notification, text: String(repeating: "x", count: 4_096)).isEmpty)
        XCTAssertFalse(errors(.notification, text: String(repeating: "x", count: 4_097)).isEmpty)
        XCTAssertFalse(errors(.notification, text: String(repeating: "中", count: 1_366)).isEmpty)
        XCTAssertFalse(errors(.shellScript, text: String(repeating: "中", count: 5_462)).isEmpty)
        for kind in [ActionKind.insertText, .notification, .shellScript] {
            XCTAssertFalse(errors(kind, text: " \n").isEmpty)
            XCTAssertTrue(errors(kind, text: "secret\0payload").contains("Action text cannot contain NUL characters."))
        }
    }

    func testURLLimitsAndExistingMailtoSemantics() {
        let prefix = "https://example.com/"
        XCTAssertTrue(errors(.openURL, text: prefix + String(repeating: "x", count: 8_192 - prefix.utf8.count)).isEmpty)
        XCTAssertFalse(errors(.openURL, text: prefix + String(repeating: "x", count: 8_193 - prefix.utf8.count)).isEmpty)
        for value in ["MAILTO:person@example.com", "MailTo:person%40example.com?subject=hello", "http://localhost:8080"] {
            XCTAssertTrue(errors(.openURL, text: value).isEmpty)
        }
        for value in ["mailto:?subject=hello", "mailto:person%0A@example.com", "file:///private/secret", "javascript:secret", "https://"] {
            XCTAssertFalse(errors(.openURL, text: value).isEmpty)
        }
    }

    func testBundleIdentifierLimitAndShortcutValidation() {
        let prefix = "com."
        XCTAssertTrue(errors(.launchApp, text: prefix + String(repeating: "x", count: 255 - prefix.count)).isEmpty)
        XCTAssertFalse(errors(.launchApp, text: prefix + String(repeating: "x", count: 256 - prefix.count)).isEmpty)
        for value in ["", "com..app", "com.app/secret", " com.app"] { XCTAssertFalse(errors(.launchApp, text: value).isEmpty) }
        let unsafe = AutomationAction(kind: .keyboardShortcut, keyCode: 128, modifiers: [.shift])
        let unsafeErrors = ActionPreflight.errors(for: [unsafe])
        XCTAssertTrue(unsafeErrors.contains("Action 1: Key code must be between 0 and 127."))
        XCTAssertTrue(unsafeErrors.contains(where: { $0.contains("Command, Option, or Control") }))
        XCTAssertFalse(ActionPreflight.errors(for: [AutomationAction(kind: .keyboardShortcut,
                                                                    modifiers: [.command, ModifierKeys(rawValue: 1)])]).isEmpty)
    }

    func testDelayLimitsTotalAndNonFiniteValues() {
        for value in [0.0, 60] {
            XCTAssertTrue(ActionPreflight.errors(for: [AutomationAction(kind: .delay, delaySeconds: value)]).isEmpty)
        }
        for value in [-1.0, 61, Double.nan, .infinity] {
            XCTAssertTrue(ActionPreflight.errors(for: [AutomationAction(kind: .delay, delaySeconds: value)])
                .contains("Action 1: Wait time must be between 0 and 60 seconds."))
        }
        let two = (0..<2).map { _ in AutomationAction(kind: .delay, delaySeconds: 60) }
        XCTAssertEqual(ActionPreflight.errors(for: two), ["Planned waits and text insertion exceed the 119-second execution budget."])
        XCTAssertTrue(ActionPreflight.errors(for: two + [AutomationAction(kind: .delay, delaySeconds: 0.1)])
            .contains("Total wait time cannot exceed 120 seconds."))
    }

    func testSharedTimingConstantsAndDelayBudgetBoundary() {
        XCTAssertEqual(ActionPreflight.chainDeadlineSeconds, 120)
        XCTAssertEqual(ActionPreflight.executionBudgetSeconds, 119)
        XCTAssertEqual(ActionPreflight.textCharacterPauseSeconds, 0.012)
        let boundary = [AutomationAction(kind: .delay, delaySeconds: 60),
                        AutomationAction(kind: .delay, delaySeconds: 59)]
        XCTAssertTrue(ActionPreflight.errors(for: boundary).isEmpty)
        let exceeded = [AutomationAction(kind: .delay, delaySeconds: 60),
                        AutomationAction(kind: .delay, delaySeconds: 59.001)]
        XCTAssertEqual(ActionPreflight.errors(for: exceeded), ["Planned waits and text insertion exceed the 119-second execution budget."])
    }

    func testTextBudgetCountsCharactersRatherThanUTF16OrUTF8() {
        let budgetMessage = "Planned waits and text insertion exceed the 119-second execution budget."
        XCTAssertTrue(errors(.insertText, text: String(repeating: "a", count: 4_958)).isEmpty)
        XCTAssertEqual(errors(.insertText, text: String(repeating: "a", count: 4_959)), [budgetMessage])
        // Four extended graphemes with different UTF-16 and UTF-8 lengths.
        let mixed = "a😀👩‍💻e\u{0301}"
        XCTAssertEqual(mixed.count, 4)
        let accepted = String(repeating: mixed, count: 1_000)
        XCTAssertLessThan(accepted.utf16.count, ActionPreflight.maximumInsertedTextUTF16Units)
        XCTAssertTrue(errors(.insertText, text: accepted).isEmpty)
        let rejected = String(repeating: mixed, count: 1_240)
        XCTAssertLessThan(rejected.utf16.count, ActionPreflight.maximumInsertedTextUTF16Units)
        XCTAssertEqual(errors(.insertText, text: rejected), [budgetMessage])
    }

    func testMixedWaitsAndTextShareOneBudgetAndErrorsRemainRedacted() throws {
        let payload = "SENTINEL_PRIVATE_INSERTION"
        let text = String(repeating: payload, count: 20)
        let textDuration = Double(text.count) * 2 * ActionPreflight.textCharacterPauseSeconds
        let allowed = [AutomationAction(kind: .delay, delaySeconds: 60),
                       AutomationAction(kind: .insertText, text: text),
                       AutomationAction(kind: .delay, delaySeconds: 58 - textDuration)]
        XCTAssertTrue(ActionPreflight.errors(for: allowed).isEmpty)
        let rejected = allowed + [AutomationAction(kind: .delay, delaySeconds: 1.1)]
        let errors = ActionPreflight.errors(for: rejected)
        XCTAssertEqual(errors, ["Planned waits and text insertion exceed the 119-second execution budget."])
        let plan = ExecutionPlan(rule: AutomationRule(actions: rejected))
        XCTAssertTrue(plan.validationErrors.contains(errors[0]))
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(plan), encoding: .utf8))
        XCTAssertFalse(encoded.contains(payload))
    }

    func testLaterInvalidActionsAreReportedBeforeExecutionAndValidatorUsesSameChecks() {
        let actions = [AutomationAction(kind: .window), AutomationAction(kind: .insertText, text: String(repeating: "x", count: 16_385)),
                       AutomationAction(kind: .delay, delaySeconds: 61)]
        let result = ActionPreflight.errors(for: actions)
        XCTAssertTrue(result.contains(where: { $0.hasPrefix("Action 2:") }))
        XCTAssertTrue(result.contains(where: { $0.hasPrefix("Action 3:") }))
        let rule = AutomationRule(actions: actions)
        XCTAssertTrue(Set(result).isSubset(of: Set(RuleValidator.validate(rule))))
    }

    func testDisabledDraftStorageRemainsStructuralOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GFPreflight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(url: directory.appendingPathComponent("configuration.json"))
        var rule = AutomationRule(actions: [AutomationAction(kind: .insertText, text: String(repeating: "x", count: 20_000)),
                                           AutomationAction(kind: .delay, delaySeconds: 61)])
        XCTAssertFalse(RuleValidator.validate(rule).isEmpty)
        try store.save(Configuration(rules: [rule]))
        XCTAssertEqual(try store.load().rules, [rule])
        rule.enabled = true
        XCTAssertThrowsError(try store.save(Configuration(rules: [rule])))
    }

    func testExecutionPlanHasOneBasedOrderAndNeverIncludesSensitivePayloads() throws {
        let secret = "SENTINEL_PRIVATE_PAYLOAD"
        let actions = [AutomationAction(kind: .shellScript, text: "echo \(secret)"),
                       AutomationAction(kind: .insertText, text: secret),
                       AutomationAction(kind: .openURL, text: "https://example.com/\(secret)"),
                       AutomationAction(kind: .launchApp, text: "com.example.\(secret)"),
                       AutomationAction(kind: .notification, text: secret),
                       AutomationAction(kind: .delay, delaySeconds: 0.25)]
        let rule = AutomationRule(name: secret, group: secret, actions: actions)
        let plan = ExecutionPlan(rule: rule)
        XCTAssertEqual(plan.steps.map(\.index), Array(1...actions.count))
        XCTAssertEqual(plan.steps.map(\.kind), actions.map(\.kind))
        XCTAssertEqual(plan.requiredCapabilities, AutomationCapability.allCases)
        XCTAssertEqual(plan.totalDelaySeconds, 0.25)
        XCTAssertTrue(plan.validationErrors.isEmpty)
        let data = try JSONEncoder().encode(plan)
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(encoded.contains(secret))
        XCTAssertFalse(encoded.contains("https://example.com"))
        XCTAssertFalse(encoded.contains("com.example"))
        XCTAssertEqual(try JSONDecoder().decode(ExecutionPlan.self, from: data), plan)
    }

    func testInvalidExecutionPlanIsRedactedAndJSONEncodable() throws {
        let secret = "SENTINEL_PRIVATE_PAYLOAD"
        let rule = AutomationRule(name: "", actions: [AutomationAction(kind: .openURL, text: "file:///\(secret)"),
                                                     AutomationAction(kind: .delay, delaySeconds: .nan),
                                                     AutomationAction(kind: .delay, delaySeconds: 61),
                                                     AutomationAction(kind: .delay, delaySeconds: 0.5)])
        let plan = ExecutionPlan(rule: rule)
        XCTAssertFalse(plan.validationErrors.isEmpty)
        XCTAssertEqual(plan.totalDelaySeconds, 0.5)
        XCTAssertTrue(plan.totalDelaySeconds.isFinite)
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(plan), encoding: .utf8))
        XCTAssertFalse(encoded.contains(secret))
        XCTAssertFalse(encoded.contains("file:///"))
    }
}
