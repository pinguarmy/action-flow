import Foundation
import XCTest
@testable import ActionFlowCore

final class MenuCommandTests: XCTestCase {
    private func path(_ json: String) throws -> MenuCommandPath {
        try MenuCommandPath(parsing: json)
    }

    func testValidPathsParseAndPreserveExactTitles() throws {
        let simple = try path("[\"File\", \"New\"]")
        XCTAssertEqual(simple.segments, ["File", "New"])
        let deep = try path("[\"1\",\"2\",\"3\",\"4\",\"5\",\"6\",\"7\",\"8\"]")
        XCTAssertEqual(deep.segments.count, 8)
        // Exact titles keep punctuation, case, and meaningful inner spacing.
        let exact = try path("[\" 格式\", \"带有  空格和,标点…\"]")
        XCTAssertEqual(exact.segments, [" 格式", "带有  空格和,标点…"])
        // Leading/trailing whitespace inside a title is data, not trimmed away.
        let padded = try path("[\"File\", \" New \"]")
        XCTAssertEqual(padded.segments, ["File", " New "])
    }

    func testCanonicalJSONRoundTrip() throws {
        let titles = ["File", "Quote \"and\" backslash \\", "表情 🚀"]
        let original = try MenuCommandPath(segments: titles)
        let reparsed = try MenuCommandPath(parsing: original.canonicalJSON)
        XCTAssertEqual(reparsed, original)
        XCTAssertEqual(reparsed.canonicalJSON, original.canonicalJSON)
        // Canonical form does not depend on source formatting.
        let messy = try path("  [ \"File\" ,\n \"New\" ]  ")
        XCTAssertEqual(messy.canonicalJSON, "[\"File\",\"New\"]")
    }

    func testRejectsMalformedJSONAndNonStringArrays() {
        for json in ["", "not json", "[\"File\",", "{\"File\":\"New\"}", "\"File\"",
                     "[1, 2]", "[\"File\", 2]", "[[\"File\"], \"New\"]", "[true, false]",
                     "null", "[]"] {
            XCTAssertThrowsError(try path(json), json) { error in
                XCTAssertNotNil(error as? MenuCommandPathError)
            }
        }
    }

    func testSegmentCountBounds() {
        XCTAssertThrowsError(try path("[\"OnlyOne\"]")) { XCTAssertEqual($0 as? MenuCommandPathError, .segmentCount) }
        let nine = "[" + (1...9).map { "\"\($0)\"" }.joined(separator: ",") + "]"
        XCTAssertThrowsError(try path(nine)) { XCTAssertEqual($0 as? MenuCommandPathError, .segmentCount) }
    }

    func testRejectsEmptyWhitespaceAndControlTitles() {
        XCTAssertThrowsError(try path("[\"File\", \"\"]")) { XCTAssertEqual($0 as? MenuCommandPathError, .emptyTitle) }
        for whitespace in [" ", "   ", "\\t", "\\n", " \u{00A0} "] {
            XCTAssertThrowsError(try path("[\"File\", \"\(whitespace)\"]"), whitespace) {
                XCTAssertEqual($0 as? MenuCommandPathError, .whitespaceOnlyTitle)
            }
        }
        // JSON-escaped control characters decode into real control scalars.
        for control in ["\\u0000", "\\u0007", "\\u001F"] {
            XCTAssertThrowsError(try path("[\"File\", \"A\(control)\"]"), control) {
                XCTAssertEqual($0 as? MenuCommandPathError, .controlCharacters)
            }
        }
    }

    func testUTF8ByteLimits() throws {
        let longTitle = String(repeating: "x", count: 256)
        XCTAssertNoThrow(try path("[\"File\", \"\(longTitle)\"]"))
        let tooLongTitle = String(repeating: "x", count: 257)
        XCTAssertThrowsError(try path("[\"File\", \"\(tooLongTitle)\"]")) {
            XCTAssertEqual($0 as? MenuCommandPathError, .titleTooLong)
        }
        // Multibyte titles are measured in UTF-8 bytes, not characters.
        let multibyte = String(repeating: "中", count: 85) // 255 bytes
        XCTAssertNoThrow(try path("[\"文件\", \"\(multibyte)\"]"))
        let multibyteTooLong = String(repeating: "中", count: 86) // 258 bytes
        XCTAssertThrowsError(try path("[\"文件\", \"\(multibyteTooLong)\"]")) {
            XCTAssertEqual($0 as? MenuCommandPathError, .titleTooLong)
        }
        // Per-title (256) and segment (8) caps compose to exactly the 2048-byte
        // path limit, which stays as defense in depth.
        let maxTitles = (0..<8).map { _ in String(repeating: "y", count: 256) }
        XCTAssertEqual(maxTitles.reduce(0) { $0 + $1.utf8.count }, MenuCommandPath.maximumPathUTF8Bytes)
        XCTAssertNoThrow(try MenuCommandPath(segments: maxTitles))
        // JSON payload cap: 8x256-byte titles fit the path budget, but padding
        // pushes the raw JSON beyond 4096 bytes.
        let segments = (0..<8).map { _ in String(repeating: "z", count: 256) }
        XCTAssertEqual(segments.reduce(0) { $0 + $1.utf8.count }, 2_048)
        let padded = "[" + segments.map { "\"\($0)\"" }.joined(separator: ", ") + String(repeating: " ", count: 4_096) + "]"
        XCTAssertGreaterThan(padded.utf8.count, 4_096)
        XCTAssertThrowsError(try path(padded)) { XCTAssertEqual($0 as? MenuCommandPathError, .jsonTooLarge) }
    }

    func testPreflightReportsRedactedErrorsAndAcceptsValid() {
        let valid = AutomationAction(kind: .menuCommand, text: "[\"File\", \"New\"]")
        XCTAssertTrue(ActionPreflight.errors(for: [valid]).isEmpty)
        let secret = "SUPER_SECRET_MENU_TITLE"
        let invalid = AutomationAction(kind: .menuCommand, text: "[\"\(secret)\"]")
        let errors = ActionPreflight.errors(for: [invalid])
        XCTAssertEqual(errors, ["Action 1: A menu path needs between 2 and 8 titles."])
        XCTAssertFalse(errors.joined().contains(secret))
        let notJSON = AutomationAction(kind: .menuCommand, text: secret)
        let notJSONErrors = ActionPreflight.errors(for: [notJSON])
        XCTAssertFalse(notJSONErrors.isEmpty)
        XCTAssertFalse(notJSONErrors.joined().contains(secret))
        // Rule-level validation rejects the same action so a chain with a late
        // invalid menu action fails before any session probe.
        XCTAssertFalse(RuleValidator.validate(AutomationRule(name: "Rule", actions: [AutomationAction(kind: .delay, delaySeconds: 0), invalid])).isEmpty)
    }

    func testMenuCommandRequiresAccessibilityNotInputMonitoring() {
        let rule = AutomationRule(trigger: Trigger(kind: .interval, intervalSeconds: 60),
                                  actions: [AutomationAction(kind: .menuCommand, text: "[\"File\", \"New\"]")])
        let automatic = RuleRequirements.capabilities(for: rule, automatic: true)
        XCTAssertEqual(automatic, [.accessibility])
        XCTAssertFalse(automatic.contains(.inputMonitoring))
        let manual = RuleRequirements.capabilities(for: rule, automatic: false)
        XCTAssertEqual(manual, [.accessibility])
    }

    func testExecutionPlanReportsDepthWithoutTitles() throws {
        let secretTitles = ["SecretMenuAlpha", "SecretItemBeta"]
        let action = AutomationAction(kind: .menuCommand,
                                      text: try MenuCommandPath(segments: secretTitles).canonicalJSON)
        let plan = ExecutionPlan(rule: AutomationRule(name: "Plan", trigger: Trigger(kind: .interval, intervalSeconds: 60),
                                                      actions: [action]))
        let json = String(data: try JSONEncoder().encode(plan), encoding: .utf8) ?? ""
        for title in secretTitles { XCTAssertFalse(json.contains(title)) }
        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertTrue(plan.steps[0].summary.contains("2"))
        XCTAssertTrue(plan.steps[0].summary.contains("hidden"))
        XCTAssertEqual(plan.requiredCapabilities, [.accessibility])
        XCTAssertTrue(plan.validationErrors.isEmpty)
        let invalid = ExecutionPlan(rule: AutomationRule(name: "Plan", actions: [AutomationAction(kind: .menuCommand, text: "not json")]))
        XCTAssertEqual(invalid.steps[0].summary, "Invalid menu command path. No action will run during preview.")
        XCTAssertFalse(invalid.validationErrors.isEmpty)
    }

    func testUnknownKindStillRejectedByOldDecoders() throws {
        // Older builds reject unknown kinds; this build accepts its own kind.
        let json = Data("[{\"id\":\"00000000-0000-0000-0000-000000000000\",\"kind\":\"menuCommand\",\"text\":\"[]\",\"keyCode\":0,\"modifiers\":1048576,\"windowOperation\":\"leftHalf\",\"delaySeconds\":1}]".utf8)
        XCTAssertEqual(try JSONDecoder().decode([AutomationAction].self, from: json).first?.kind, .menuCommand)
        let unknown = Data("[{\"id\":\"00000000-0000-0000-0000-000000000000\",\"kind\":\"futureKind\",\"text\":\"\",\"keyCode\":0,\"modifiers\":0,\"windowOperation\":\"leftHalf\",\"delaySeconds\":1}]".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode([AutomationAction].self, from: unknown))
        XCTAssertEqual(ActionKind.allCases.count, 9)
    }
}
