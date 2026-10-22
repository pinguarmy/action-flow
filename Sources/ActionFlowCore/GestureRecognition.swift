import Foundation

/// Gesture kinds recognized by the local Gesture Lab. Recognition is derived
/// only from typed samples fed into `GestureRecognizer`; the library never
/// observes devices, global input or raw touches, and makes no finger-count claims.
public enum GestureKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case swipeLeft, swipeRight, swipeUp, swipeDown
    case pinchIn, pinchOut
    case rotateClockwise, rotateCounterclockwise
    public var id: String { rawValue }
}

public enum GestureSamplePhase: String, Codable, CaseIterable, Sendable {
    case began, changed, ended, cancelled
}

/// One typed input sample with its phase and per-event relative delta.
public enum GestureSample: Equatable, Sendable {
    case swipe(phase: GestureSamplePhase, deltaX: Double, deltaY: Double)
    case magnify(phase: GestureSamplePhase, delta: Double)
    case rotate(phase: GestureSamplePhase, degrees: Double)
}

/// Positive, finite recognition thresholds. Invalid values are rejected at init.
public struct GestureThresholds: Equatable, Sendable {
    public let swipePoints: Double
    public let pinchScaleDelta: Double
    public let rotateDegrees: Double
    public init?(swipePoints: Double, pinchScaleDelta: Double, rotateDegrees: Double) {
        guard Self.isValid(swipePoints), Self.isValid(pinchScaleDelta), Self.isValid(rotateDegrees) else { return nil }
        self.swipePoints = swipePoints
        self.pinchScaleDelta = pinchScaleDelta
        self.rotateDegrees = rotateDegrees
    }
    public static func isValid(_ value: Double) -> Bool { value.isFinite && value > 0 }
    public static let `default` = GestureThresholds(swipePoints: 60, pinchScaleDelta: 0.15, rotateDegrees: 15)!
}

/// One completed recognition. `magnitude` is the absolute accumulated delta in the
/// kind's unit: points for swipes, scale fraction for pinches, degrees for rotation.
public struct RecognizedGesture: Equatable, Identifiable, Sendable {
    public let id = UUID()
    public let kind: GestureKind
    public let magnitude: Double
    public let sampleCount: Int
    public let duration: TimeInterval
    public init(kind: GestureKind, magnitude: Double, sampleCount: Int, duration: TimeInterval) {
        self.kind = kind
        self.magnitude = magnitude
        self.sampleCount = sampleCount
        self.duration = duration
    }
}

/// Pure, testable gesture recognizer. Deltas accumulate from `.began` until `.ended`;
/// a result is produced at most once per gesture, exactly when the accumulated
/// delta reaches the configured threshold at `.ended`. `.cancelled` clears any
/// pending accumulation without a result. Non-finite input resets pending state.
public struct GestureRecognizer: Equatable, Sendable {
    public private(set) var thresholds: GestureThresholds
    /// Safety bounds so a stuck sequence cannot accumulate forever. Generous enough
    /// that normal trackpad gestures never reach them.
    public static let maximumSampleCount = 512
    public static let maximumDuration: TimeInterval = 8
    /// A swipe whose secondary axis reaches this fraction of the dominant axis is
    /// diagonal-ambiguous and produces no result. Documented policy: dominant axis wins.
    public static let diagonalAmbiguityRatio = 0.5

    private enum PendingKind: Equatable, Sendable { case swipe, magnify, rotate }
    private var pending: PendingKind?
    private var accumulatedX = 0.0
    private var accumulatedY = 0.0
    private var beganAt = 0.0
    private var lastAt = 0.0
    private var samples = 0

    public init(thresholds: GestureThresholds = .default) {
        self.thresholds = thresholds
    }

    /// True while a `.began` sequence is accumulating and has not ended or been cancelled.
    public var isTracking: Bool { pending != nil }

    /// Clears any pending accumulation without producing a result. Used by callers on
    /// interrupt (view teardown, window detach) and by threshold changes.
    public mutating func reset() {
        pending = nil
        accumulatedX = 0
        accumulatedY = 0
        samples = 0
    }

    /// Changing thresholds interrupts any pending gesture; it never produces a result.
    public mutating func setThresholds(_ newThresholds: GestureThresholds) {
        reset()
        thresholds = newThresholds
    }

    /// Processes one sample. Returns a completed recognition at `.ended` when the
    /// accumulated delta reaches the threshold; otherwise nil.
    public mutating func process(_ sample: GestureSample, at timestamp: TimeInterval) -> RecognizedGesture? {
        guard timestamp.isFinite else { reset(); return nil }
        switch sample {
        case let .swipe(phase, deltaX, deltaY):
            guard deltaX.isFinite, deltaY.isFinite else { reset(); return nil }
            if pending != nil && pending != .swipe { reset() }
            switch phase {
            case .began:
                begin(.swipe, at: timestamp)
                return accumulateSwipe(deltaX: deltaX, deltaY: deltaY, at: timestamp, finishing: false)
            case .changed:
                guard pending == .swipe else { return nil }
                return accumulateSwipe(deltaX: deltaX, deltaY: deltaY, at: timestamp, finishing: false)
            case .ended:
                guard pending == .swipe else { return nil }
                return accumulateSwipe(deltaX: deltaX, deltaY: deltaY, at: timestamp, finishing: true)
            case .cancelled:
                reset()
                return nil
            }
        case let .magnify(phase, delta):
            guard delta.isFinite else { reset(); return nil }
            if pending != nil && pending != .magnify { reset() }
            switch phase {
            case .began:
                begin(.magnify, at: timestamp)
                return accumulatePinch(delta: delta, at: timestamp, finishing: false)
            case .changed:
                guard pending == .magnify else { return nil }
                return accumulatePinch(delta: delta, at: timestamp, finishing: false)
            case .ended:
                guard pending == .magnify else { return nil }
                return accumulatePinch(delta: delta, at: timestamp, finishing: true)
            case .cancelled:
                reset()
                return nil
            }
        case let .rotate(phase, degrees):
            guard degrees.isFinite else { reset(); return nil }
            if pending != nil && pending != .rotate { reset() }
            switch phase {
            case .began:
                begin(.rotate, at: timestamp)
                return accumulateRotate(degrees: degrees, at: timestamp, finishing: false)
            case .changed:
                guard pending == .rotate else { return nil }
                return accumulateRotate(degrees: degrees, at: timestamp, finishing: false)
            case .ended:
                guard pending == .rotate else { return nil }
                return accumulateRotate(degrees: degrees, at: timestamp, finishing: true)
            case .cancelled:
                reset()
                return nil
            }
        }
    }

    /// Single-shot swipe classification for events that carry no phase information
    /// (NSEvent swipe deltas are discrete values such as ±1). Only the direction is
    /// decided here; diagonal-ambiguous deltas return nil. Thresholds do not apply
    /// because a phaseless swipe is already a complete, discrete system event.
    public static func classifySwipe(deltaX: Double, deltaY: Double) -> GestureKind? {
        guard deltaX.isFinite, deltaY.isFinite, deltaX != 0 || deltaY != 0 else { return nil }
        let x = abs(deltaX), y = abs(deltaY)
        guard min(x, y) < max(x, y) * diagonalAmbiguityRatio else { return nil }
        // NSEvent convention: deltaX +1 = swipe left, -1 = swipe right; deltaY +1 = up, -1 = down.
        if x >= y { return deltaX > 0 ? .swipeLeft : .swipeRight }
        return deltaY > 0 ? .swipeUp : .swipeDown
    }

    /// Direction-only single-shot classifiers for phaseless magnify/rotate events.
    /// The caller applies the threshold before using these.
    public static func classifyPinch(scaleDelta: Double) -> GestureKind? {
        guard scaleDelta.isFinite, scaleDelta != 0 else { return nil }
        return scaleDelta > 0 ? .pinchOut : .pinchIn
    }
    /// NSEvent rotation is in degrees; positive values are counterclockwise.
    public static func classifyRotation(degrees: Double) -> GestureKind? {
        guard degrees.isFinite, degrees != 0 else { return nil }
        return degrees > 0 ? .rotateCounterclockwise : .rotateClockwise
    }

    private mutating func begin(_ kind: PendingKind, at timestamp: TimeInterval) {
        reset()
        pending = kind
        beganAt = timestamp
        lastAt = timestamp
    }

    /// Returns false when bounds were exceeded and pending state was reset.
    private mutating func track(at timestamp: TimeInterval) -> Bool {
        guard timestamp >= lastAt, timestamp - beganAt <= Self.maximumDuration else { reset(); return false }
        samples += 1
        guard samples <= Self.maximumSampleCount else { reset(); return false }
        lastAt = timestamp
        return true
    }

    private mutating func accumulateSwipe(deltaX: Double, deltaY: Double, at timestamp: TimeInterval, finishing: Bool) -> RecognizedGesture? {
        guard track(at: timestamp) else { return nil }
        accumulatedX += deltaX
        accumulatedY += deltaY
        // Finite deltas can still overflow the accumulation; reset instead of comparing NaN.
        guard accumulatedX.isFinite, accumulatedY.isFinite else { reset(); return nil }
        guard finishing else { return nil }
        let x = abs(accumulatedX), y = abs(accumulatedY)
        let dominant = max(x, y)
        let result: RecognizedGesture?
        if dominant >= thresholds.swipePoints,
           let kind = Self.classifySwipe(deltaX: accumulatedX, deltaY: accumulatedY) {
            result = finish(kind: kind, magnitude: dominant, at: timestamp)
        } else {
            result = nil
        }
        reset()
        return result
    }

    private mutating func accumulatePinch(delta: Double, at timestamp: TimeInterval, finishing: Bool) -> RecognizedGesture? {
        guard track(at: timestamp) else { return nil }
        accumulatedX += delta
        guard accumulatedX.isFinite else { reset(); return nil }
        guard finishing else { return nil }
        let magnitude = abs(accumulatedX)
        let result: RecognizedGesture?
        if magnitude >= thresholds.pinchScaleDelta,
           let kind = Self.classifyPinch(scaleDelta: accumulatedX) {
            result = finish(kind: kind, magnitude: magnitude, at: timestamp)
        } else {
            result = nil
        }
        reset()
        return result
    }

    private mutating func accumulateRotate(degrees: Double, at timestamp: TimeInterval, finishing: Bool) -> RecognizedGesture? {
        guard track(at: timestamp) else { return nil }
        accumulatedX += degrees
        guard accumulatedX.isFinite else { reset(); return nil }
        guard finishing else { return nil }
        let magnitude = abs(accumulatedX)
        let result: RecognizedGesture?
        if magnitude >= thresholds.rotateDegrees,
           let kind = Self.classifyRotation(degrees: accumulatedX) {
            result = finish(kind: kind, magnitude: magnitude, at: timestamp)
        } else {
            result = nil
        }
        reset()
        return result
    }

    private func finish(kind: GestureKind, magnitude: Double, at timestamp: TimeInterval) -> RecognizedGesture {
        RecognizedGesture(kind: kind, magnitude: magnitude, sampleCount: samples,
                          duration: max(0, timestamp - beganAt))
    }
}
