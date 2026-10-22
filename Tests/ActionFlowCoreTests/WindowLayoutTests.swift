import Foundation
import CoreGraphics
import XCTest
@testable import ActionFlowCore

final class WindowLayoutTests: XCTestCase {
    private let screen = CGRect(x: 100, y: 40, width: 1200, height: 900)
    private let original = CGRect(x: 400, y: 300, width: 400, height: 300)

    func testHalvesAndQuartersUseAccessibilityTopLeftCoordinates() throws {
        let expected: [(WindowOperation, CGRect)] = [
            (.leftHalf, CGRect(x: 100, y: 40, width: 600, height: 900)),
            (.rightHalf, CGRect(x: 700, y: 40, width: 600, height: 900)),
            (.topHalf, CGRect(x: 100, y: 40, width: 1200, height: 450)),
            (.bottomHalf, CGRect(x: 100, y: 490, width: 1200, height: 450)),
            (.topLeft, CGRect(x: 100, y: 40, width: 600, height: 450)),
            (.topRight, CGRect(x: 700, y: 40, width: 600, height: 450)),
            (.bottomLeft, CGRect(x: 100, y: 490, width: 600, height: 450)),
            (.bottomRight, CGRect(x: 700, y: 490, width: 600, height: 450)),
            (.maximize, screen),
            (.center, CGRect(x: 500, y: 340, width: 400, height: 300)),
            (.centerTwoThirds, CGRect(x: 300, y: 40, width: 800, height: 900))
        ]
        for (operation, frame) in expected {
            assertRect(try WindowLayout.target(for: operation, original: original, screens: [screen]), frame)
        }
    }

    func testLargerAndSmallerKeepCenterAndScaleTenPercent() throws {
        assertRect(try WindowLayout.target(for: .larger, original: original, screens: [screen]),
                   CGRect(x: 380, y: 285, width: 440, height: 330))
        assertRect(try WindowLayout.target(for: .smaller, original: original, screens: [screen]),
                   CGRect(x: 420, y: 315, width: 360, height: 270))
        assertRect(try WindowLayout.target(for: .larger, original: screen, screens: [screen]), screen)
    }

    func testCenterFitsOversizedWindowAndResizeClampsAtEdges() throws {
        assertRect(try WindowLayout.target(for: .center,
                                          original: CGRect(x: -1000, y: -2000, width: 5000, height: 6000), screens: [screen]), screen)
        let edge = CGRect(x: 100, y: 40, width: 400, height: 300)
        assertRect(try WindowLayout.target(for: .larger, original: edge, screens: [screen]),
                   CGRect(x: 100, y: 40, width: 440, height: 330))
    }

    func testLargestIntersectionSelectsDisplayNotWindowOrigin() throws {
        let displays = [CGRect(x: -1000, y: 0, width: 1000, height: 800),
                        CGRect(x: 0, y: 0, width: 1400, height: 900)]
        let straddling = CGRect(x: -100, y: 200, width: 600, height: 400)
        assertRect(try WindowLayout.target(for: .maximize, original: straddling, screens: displays), displays[1])
    }

    func testOffscreenWindowChoosesNearestCenterDeterministically() throws {
        let displays = [CGRect(x: -1000, y: 0, width: 1000, height: 800),
                        CGRect(x: 1000, y: 0, width: 1000, height: 800)]
        assertRect(try WindowLayout.target(for: .maximize,
                                          original: CGRect(x: 2100, y: 100, width: 100, height: 100), screens: displays), displays[1])
        let tied = CGRect(x: 450, y: 350, width: 100, height: 100)
        assertRect(try WindowLayout.target(for: .maximize, original: tied, screens: displays), displays[0])
        assertRect(try WindowLayout.target(for: .maximize, original: tied, screens: Array(displays.reversed())), displays[1])
    }

    func testNextDisplayPreservesRelativePositionAndWraps() throws {
        let displays = [CGRect(x: 0, y: 0, width: 1000, height: 800),
                        CGRect(x: -1600, y: -900, width: 1600, height: 900)]
        let frame = CGRect(x: 400, y: 300, width: 200, height: 200)
        let moved = try WindowLayout.target(for: .nextDisplay, original: frame, screens: displays)
        assertRect(moved, CGRect(x: -900, y: -550, width: 200, height: 200))
        assertRect(try WindowLayout.target(for: .nextDisplay, original: moved, screens: displays), frame)
    }

    func testNextDisplayShrinksAndCentersOversizedWindow() throws {
        let displays = [CGRect(x: 0, y: 0, width: 1000, height: 800),
                        CGRect(x: 1000, y: 0, width: 600, height: 400)]
        assertRect(try WindowLayout.target(for: .nextDisplay,
                                          original: CGRect(x: -100, y: -100, width: 1200, height: 1000), screens: displays), displays[1])
    }

    func testRestoreChoosesSavedFrameDisplayAndFitsDisconnectedDisplay() throws {
        let other = CGRect(x: -1000, y: -800, width: 1000, height: 800)
        let saved = CGRect(x: -900, y: -700, width: 400, height: 300)
        assertRect(try WindowLayout.target(for: .restore, original: original, screens: [screen, other], restoreFrame: saved), saved)
        assertRect(try WindowLayout.target(for: .restore, original: original, screens: [screen], restoreFrame: saved),
                   CGRect(x: 100, y: 40, width: 400, height: 300))
    }

    func testRejectsMissingDisplaysRestoreAndSecondDisplay() {
        XCTAssertThrowsError(try WindowLayout.target(for: .maximize, original: original, screens: [])) {
            XCTAssertEqual($0 as? WindowLayoutError, .noScreens)
        }
        XCTAssertThrowsError(try WindowLayout.target(for: .restore, original: original, screens: [screen])) {
            XCTAssertEqual($0 as? WindowLayoutError, .missingRestoreFrame)
        }
        XCTAssertThrowsError(try WindowLayout.target(for: .nextDisplay, original: original, screens: [screen])) {
            XCTAssertEqual($0 as? WindowLayoutError, .requiresAnotherScreen)
        }
    }

    func testRejectsInvalidFramesInEveryInputPosition() {
        let invalid: [CGRect] = [
            .zero, .null, .infinite,
            CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
            CGRect(x: 0, y: CGFloat.infinity, width: 100, height: 100),
            CGRect(x: 0, y: 0, width: -100, height: 100),
            CGRect(x: 0, y: 0, width: 100, height: -100),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100),
            CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 100)
        ]
        for frame in invalid {
            XCTAssertThrowsError(try WindowLayout.target(for: .maximize, original: frame, screens: [screen]))
            XCTAssertThrowsError(try WindowLayout.target(for: .maximize, original: original, screens: [screen, frame]))
            // All inputs are checked, even when a restore frame is not consumed.
            XCTAssertThrowsError(try WindowLayout.target(for: .maximize, original: original, screens: [screen], restoreFrame: frame))
        }
    }

    func testEveryOperationProducesFiniteContainedGeometry() throws {
        let displays = [screen, CGRect(x: -1200, y: -1000, width: 1100, height: 800)]
        for operation in WindowOperation.allCases {
            let frame = try WindowLayout.target(for: operation, original: original, screens: displays, restoreFrame: original)
            XCTAssertTrue(frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite)
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
            XCTAssertTrue(displays.contains { $0.contains(frame) }, "\(operation) must fit a visible display")
        }
    }

    func testWindowOperationSerializationRemainsStableAndIncludesNewLayouts() throws {
        XCTAssertEqual(WindowOperation.allCases.count, 15)
        for operation in WindowOperation.allCases {
            XCTAssertEqual(try JSONDecoder().decode(WindowOperation.self, from: JSONEncoder().encode(operation)), operation)
            XCTAssertFalse(operation.title.isEmpty)
        }
        XCTAssertEqual(try JSONDecoder().decode(WindowOperation.self, from: Data("\"leftHalf\"".utf8)), .leftHalf)
    }

    private func assertRect(_ actual: CGRect, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.origin.x, expected.origin.x, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(actual.origin.y, expected.origin.y, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.000001, file: file, line: line)
    }
}
