import Foundation
import XCTest
@testable import ActionFlowCore

final class SessionTransitionTests: XCTestCase {
    func testInitialStatePermitsFreshSessionChecks() {
        XCTAssertFalse(SessionTransitionState().isSuspended)
    }

    func testSleepOnlyClearsOnWake() {
        var state = SessionTransitionState()
        state.apply(.willSleep)
        XCTAssertTrue(state.isSuspended)
        state.apply(.sessionBecameActive)
        XCTAssertTrue(state.isSuspended)
        state.apply(.didWake)
        XCTAssertFalse(state.isSuspended)
    }

    func testInactiveSessionOnlyClearsOnBecameActive() {
        var state = SessionTransitionState()
        state.apply(.sessionResigned)
        XCTAssertTrue(state.isSuspended)
        state.apply(.didWake)
        XCTAssertTrue(state.isSuspended)
        state.apply(.sessionBecameActive)
        XCTAssertFalse(state.isSuspended)
    }

    func testCrossedNotificationsRetainBothIndependentReasons() {
        for first in [SessionTransition.willSleep, .sessionResigned] {
            for firstClear in [SessionTransition.didWake, .sessionBecameActive] {
                var state = SessionTransitionState()
                state.apply(first)
                state.apply(first == .willSleep ? .sessionResigned : .willSleep)
                XCTAssertTrue(state.isSuspended)
                state.apply(firstClear)
                XCTAssertTrue(state.isSuspended)
                state.apply(firstClear == .didWake ? .sessionBecameActive : .didWake)
                XCTAssertFalse(state.isSuspended)
            }
        }
    }

    func testDuplicateSignalsAreIdempotentNotReferenceCounts() {
        for (suspend, resume) in [(SessionTransition.willSleep, SessionTransition.didWake),
                                  (.sessionResigned, .sessionBecameActive)] {
            var state = SessionTransitionState()
            state.apply(suspend)
            state.apply(suspend)
            XCTAssertTrue(state.isSuspended)
            state.apply(resume)
            XCTAssertFalse(state.isSuspended)
            state.apply(resume)
            XCTAssertFalse(state.isSuspended)
        }
    }

    func testClearSignalsDoNotAuthorizeOrCreateSuspensionByThemselves() {
        var state = SessionTransitionState()
        state.apply(.didWake)
        state.apply(.sessionBecameActive)
        XCTAssertEqual(state, SessionTransitionState())
    }

    func testAllShortEventSequencesFollowIndependentBooleanState() {
        let events = SessionTransition.allCases
        for first in events {
            for second in events {
                for third in events {
                    for fourth in events {
                        var state = SessionTransitionState()
                        var sleeping = false
                        var inactive = false
                        for event in [first, second, third, fourth] {
                            state.apply(event)
                            switch event {
                            case .willSleep: sleeping = true
                            case .didWake: sleeping = false
                            case .sessionResigned: inactive = true
                            case .sessionBecameActive: inactive = false
                            }
                            XCTAssertEqual(state.isSuspended, sleeping || inactive)
                        }
                    }
                }
            }
        }
    }

    func testEventRawValuesAndCodableAreStable() throws {
        XCTAssertEqual(SessionTransition.allCases.map(\.rawValue),
                       ["willSleep", "didWake", "sessionResigned", "sessionBecameActive"])
        for event in SessionTransition.allCases {
            let encoded = try JSONEncoder().encode(event)
            XCTAssertEqual(try JSONDecoder().decode(SessionTransition.self, from: encoded), event)
        }
    }
}
