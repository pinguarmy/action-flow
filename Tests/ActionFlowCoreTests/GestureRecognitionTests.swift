import Foundation
import XCTest
@testable import ActionFlowCore

final class GestureRecognitionTests: XCTestCase {
    private func makeRecognizer() -> GestureRecognizer {
        GestureRecognizer(thresholds: GestureThresholds(swipePoints: 50, pinchScaleDelta: 0.2, rotateDegrees: 10)!)
    }

    func testThresholdsRejectNonPositiveOrNonFiniteValues() {
        XCTAssertNil(GestureThresholds(swipePoints: 0, pinchScaleDelta: 0.2, rotateDegrees: 10))
        XCTAssertNil(GestureThresholds(swipePoints: -1, pinchScaleDelta: 0.2, rotateDegrees: 10))
        XCTAssertNil(GestureThresholds(swipePoints: .nan, pinchScaleDelta: 0.2, rotateDegrees: 10))
        XCTAssertNil(GestureThresholds(swipePoints: .infinity, pinchScaleDelta: 0.2, rotateDegrees: 10))
        XCTAssertNil(GestureThresholds(swipePoints: 50, pinchScaleDelta: 0, rotateDegrees: 10))
        XCTAssertNil(GestureThresholds(swipePoints: 50, pinchScaleDelta: 0.2, rotateDegrees: .nan))
        XCTAssertNotNil(GestureThresholds(swipePoints: 0.001, pinchScaleDelta: 0.001, rotateDegrees: 0.001))
    }

    func testSwipeAccumulatesFromBeganUntilEndedAndEmitsOnce() {
        var recognizer = makeRecognizer()
        XCTAssertNil(recognizer.process(.swipe(phase: .began, deltaX: 0, deltaY: 0), at: 1))
        XCTAssertTrue(recognizer.isTracking)
        XCTAssertNil(recognizer.process(.swipe(phase: .changed, deltaX: 30, deltaY: 0), at: 1.1))
        XCTAssertNil(recognizer.process(.swipe(phase: .changed, deltaX: 25, deltaY: 0), at: 1.2))
        let result = recognizer.process(.swipe(phase: .ended, deltaX: 5, deltaY: 0), at: 1.3)
        XCTAssertEqual(result?.kind, .swipeLeft)
        XCTAssertEqual(result?.magnitude, 60)
        XCTAssertEqual(result?.sampleCount, 4)
        XCTAssertEqual(result?.duration ?? -1, 0.3, accuracy: 0.0001)
        XCTAssertFalse(recognizer.isTracking)
    }

    func testSwipeBelowThresholdAtEndProducesNoResult() {
        var recognizer = makeRecognizer()
        XCTAssertNil(recognizer.process(.swipe(phase: .began, deltaX: 0, deltaY: 0), at: 0))
        XCTAssertNil(recognizer.process(.swipe(phase: .changed, deltaX: -20, deltaY: 0), at: 0.1))
        XCTAssertNil(recognizer.process(.swipe(phase: .ended, deltaX: -10, deltaY: 0), at: 0.2))
        XCTAssertFalse(recognizer.isTracking)
    }

    func testSwipeDominantAxisDirection() {
        for (deltaX, deltaY, kind) in [(60.0, 4.0, GestureKind.swipeLeft), (-60.0, 4.0, .swipeRight),
                                       (4.0, 60.0, .swipeUp), (4.0, -60.0, .swipeDown)] {
            var recognizer = makeRecognizer()
            _ = recognizer.process(.swipe(phase: .began, deltaX: 0, deltaY: 0), at: 0)
            _ = recognizer.process(.swipe(phase: .changed, deltaX: deltaX, deltaY: deltaY), at: 0.1)
            XCTAssertEqual(recognizer.process(.swipe(phase: .ended, deltaX: 0, deltaY: 0), at: 0.2)?.kind, kind)
        }
    }

    func testDiagonalAmbiguousSwipeProducesNoResult() {
        var recognizer = makeRecognizer()
        _ = recognizer.process(.swipe(phase: .began, deltaX: 0, deltaY: 0), at: 0)
        _ = recognizer.process(.swipe(phase: .changed, deltaX: 60, deltaY: 40), at: 0.1)
        XCTAssertNil(recognizer.process(.swipe(phase: .ended, deltaX: 0, deltaY: 0), at: 0.2))
        XCTAssertFalse(recognizer.isTracking)
    }

    func testSingleShotSwipeClassification() {
        // NSEvent convention: deltaX +1 = swipe left, -1 = right; deltaY +1 = up, -1 = down.
        XCTAssertEqual(GestureRecognizer.classifySwipe(deltaX: 1, deltaY: 0), .swipeLeft)
        XCTAssertEqual(GestureRecognizer.classifySwipe(deltaX: -1, deltaY: 0), .swipeRight)
        XCTAssertEqual(GestureRecognizer.classifySwipe(deltaX: 0, deltaY: 1), .swipeUp)
        XCTAssertEqual(GestureRecognizer.classifySwipe(deltaX: 0, deltaY: -1), .swipeDown)
        XCTAssertNil(GestureRecognizer.classifySwipe(deltaX: 0, deltaY: 0))
        XCTAssertNil(GestureRecognizer.classifySwipe(deltaX: .nan, deltaY: 1))
        XCTAssertNil(GestureRecognizer.classifySwipe(deltaX: 1, deltaY: 1))
    }

    func testPinchInAndOutAccumulateAcrossChangedSamples() {
        var recognizer = makeRecognizer()
        _ = recognizer.process(.magnify(phase: .began, delta: 0), at: 0)
        _ = recognizer.process(.magnify(phase: .changed, delta: 0.12), at: 0.1)
        _ = recognizer.process(.magnify(phase: .changed, delta: 0.1), at: 0.2)
        let out = recognizer.process(.magnify(phase: .ended, delta: 0), at: 0.3)
        XCTAssertEqual(out?.kind, .pinchOut)
        XCTAssertEqual(out?.magnitude ?? -1, 0.22, accuracy: 0.0001)

        var second = makeRecognizer()
        _ = second.process(.magnify(phase: .began, delta: 0), at: 0)
        _ = second.process(.magnify(phase: .changed, delta: -0.25), at: 0.1)
        let inResult = second.process(.magnify(phase: .ended, delta: 0), at: 0.2)
        XCTAssertEqual(inResult?.kind, .pinchIn)
        XCTAssertEqual(inResult?.magnitude ?? -1, 0.25, accuracy: 0.0001)
    }

    func testRotationDirectionAndThreshold() {
        var recognizer = makeRecognizer()
        _ = recognizer.process(.rotate(phase: .began, degrees: 0), at: 0)
        _ = recognizer.process(.rotate(phase: .changed, degrees: -12), at: 0.1)
        XCTAssertEqual(recognizer.process(.rotate(phase: .ended, degrees: 0), at: 0.2)?.kind, .rotateClockwise)

        var counter = makeRecognizer()
        _ = counter.process(.rotate(phase: .began, degrees: 0), at: 0)
        _ = counter.process(.rotate(phase: .changed, degrees: 12), at: 0.1)
        XCTAssertEqual(counter.process(.rotate(phase: .ended, degrees: 0), at: 0.2)?.kind, .rotateCounterclockwise)

        var below = makeRecognizer()
        _ = below.process(.rotate(phase: .began, degrees: 0), at: 0)
        _ = below.process(.rotate(phase: .changed, degrees: 9), at: 0.1)
        XCTAssertNil(below.process(.rotate(phase: .ended, degrees: 0), at: 0.2))
    }

    func testCancelledProducesNoResultAndClearsPending() {
        var recognizer = makeRecognizer()
        _ = recognizer.process(.swipe(phase: .began, deltaX: 0, deltaY: 0), at: 0)
        _ = recognizer.process(.swipe(phase: .changed, deltaX: 100, deltaY: 0), at: 0.1)
        XCTAssertNil(recognizer.process(.swipe(phase: .cancelled, deltaX: 0, deltaY: 0), at: 0.2))
        XCTAssertFalse(recognizer.isTracking)
        // A later stray .ended must not resurrect the cancelled gesture.
        XCTAssertNil(recognizer.process(.swipe(phase: .ended, deltaX: 0, deltaY: 0), at: 0.3))
    }

    func testEndedWithoutBeganProducesNoResult() {
        var recognizer = makeRecognizer()
        XCTAssertNil(recognizer.process(.swipe(phase: .ended, deltaX: 100, deltaY: 0), at: 0))
        XCTAssertNil(recognizer.process(.magnify(phase: .ended, delta: 0.5), at: 0))
        XCTAssertNil(recognizer.process(.rotate(phase: .ended, degrees: 90), at: 0))
        XCTAssertFalse(recognizer.isTracking)
    }

    func testDuplicateEndProducesNoResult() {
        var recognizer = makeRecognizer()
        _ = recognizer.process(.magnify(phase: .began, delta: 0), at: 0)
        _ = recognizer.process(.magnify(phase: .changed, delta: 0.3), at: 0.1)
        XCTAssertEqual(recognizer.process(.magnify(phase: .ended, delta: 0), at: 0.2)?.kind, .pinchOut)
        XCTAssertNil(recognizer.process(.magnify(phase: .ended, delta: 0), at: 0.3))
        XCTAssertFalse(recognizer.isTracking)
    }

    func testNonFiniteInputResetsPendingState() {
        var recognizer = makeRecognizer()
        _ = recognizer.process(.rotate(phase: .began, degrees: 0), at: 0)
        _ = recognizer.process(.rotate(phase: .changed, degrees: 20), at: 0.1)
        XCTAssertNil(recognizer.process(.rotate(phase: .changed, degrees: .nan), at: 0.2))
        XCTAssertFalse(recognizer.isTracking)
        XCTAssertNil(recognizer.process(.rotate(phase: .ended, degrees: 0), at: 0.3))
        XCTAssertNil(recognizer.process(.rotate(phase: .began, degrees: .infinity), at: 1))
        XCTAssertFalse(recognizer.isTracking)
        XCTAssertNil(recognizer.process(.swipe(phase: .began, deltaX: 1, deltaY: 0), at: .nan))
        XCTAssertFalse(recognizer.isTracking)
    }

    func testCrossKindSampleResetsPendingWithoutMixingDeltas() {
        var recognizer = makeRecognizer()
        _ = recognizer.process(.swipe(phase: .began, deltaX: 0, deltaY: 0), at: 0)
        _ = recognizer.process(.swipe(phase: .changed, deltaX: 40, deltaY: 0), at: 0.1)
        // A magnify sample interrupts the pending swipe; its delta never mixes in.
        XCTAssertNil(recognizer.process(.magnify(phase: .changed, delta: 0.4), at: 0.2))
        XCTAssertFalse(recognizer.isTracking)
        XCTAssertNil(recognizer.process(.swipe(phase: .ended, deltaX: 100, deltaY: 0), at: 0.3))
        // A new began starts a clean accumulation.
        _ = recognizer.process(.magnify(phase: .began, delta: 0), at: 1)
        _ = recognizer.process(.magnify(phase: .changed, delta: 0.21), at: 1.1)
        XCTAssertEqual(recognizer.process(.magnify(phase: .ended, delta: 0), at: 1.2)?.kind, .pinchOut)
    }

    func testThresholdChangeInterruptsPendingWithoutResult() {
        var recognizer = makeRecognizer()
        _ = recognizer.process(.swipe(phase: .began, deltaX: 0, deltaY: 0), at: 0)
        _ = recognizer.process(.swipe(phase: .changed, deltaX: 80, deltaY: 0), at: 0.1)
        recognizer.setThresholds(GestureThresholds(swipePoints: 10, pinchScaleDelta: 0.2, rotateDegrees: 10)!)
        XCTAssertFalse(recognizer.isTracking)
        XCTAssertNil(recognizer.process(.swipe(phase: .ended, deltaX: 0, deltaY: 0), at: 0.2))
    }

    func testDurationAndSampleBoundsResetWithoutResult() {
        var recognizer = makeRecognizer()
        _ = recognizer.process(.magnify(phase: .began, delta: 0), at: 0)
        _ = recognizer.process(.magnify(phase: .changed, delta: 0.1), at: 0.1)
        XCTAssertNil(recognizer.process(.magnify(phase: .changed, delta: 0.1), at: GestureRecognizer.maximumDuration + 1))
        XCTAssertFalse(recognizer.isTracking)

        var samples = makeRecognizer()
        _ = samples.process(.magnify(phase: .began, delta: 0), at: 0)
        for index in 1...GestureRecognizer.maximumSampleCount {
            _ = samples.process(.magnify(phase: .changed, delta: 0.0001), at: TimeInterval(index) * 0.001)
        }
        XCTAssertFalse(samples.isTracking)
        XCTAssertNil(samples.process(.magnify(phase: .ended, delta: 1), at: 1))
    }

    func testBackwardTimestampResetsPending() {
        var recognizer = makeRecognizer()
        _ = recognizer.process(.rotate(phase: .began, degrees: 0), at: 5)
        _ = recognizer.process(.rotate(phase: .changed, degrees: 20), at: 5.1)
        XCTAssertNil(recognizer.process(.rotate(phase: .changed, degrees: 5), at: 4))
        XCTAssertFalse(recognizer.isTracking)
    }

    func testAccumulatedOverflowResetsWithoutResult() {
        var recognizer = makeRecognizer()
        _ = recognizer.process(.swipe(phase: .began, deltaX: 0, deltaY: 0), at: 0)
        _ = recognizer.process(.swipe(phase: .changed, deltaX: .greatestFiniteMagnitude, deltaY: 0), at: 0.1)
        XCTAssertNil(recognizer.process(.swipe(phase: .changed, deltaX: .greatestFiniteMagnitude, deltaY: 0), at: 0.2))
        XCTAssertFalse(recognizer.isTracking)
        XCTAssertNil(recognizer.process(.swipe(phase: .ended, deltaX: 0, deltaY: 0), at: 0.3))
    }

    func testResultCarriesMetadataAndResetIsIdempotent() {
        var recognizer = makeRecognizer()
        _ = recognizer.process(.magnify(phase: .began, delta: 0), at: 2)
        _ = recognizer.process(.magnify(phase: .changed, delta: 0.3), at: 2.5)
        let result = recognizer.process(.magnify(phase: .ended, delta: 0), at: 3)
        XCTAssertEqual(result?.duration ?? -1, 1, accuracy: 0.0001)
        XCTAssertEqual(result?.sampleCount, 3)
        recognizer.reset()
        recognizer.reset()
        XCTAssertFalse(recognizer.isTracking)
    }
}
