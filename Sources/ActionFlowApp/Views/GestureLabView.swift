import AppKit
import ActionFlowCore
import SwiftUI

/// Local gesture lab: recognizes trackpad gestures only inside its own pad view.
/// No global monitors, no actions, no persistence. Results are metadata-only,
/// in-memory, and disappear when the app quits.
struct GestureLabView: View {
    @StateObject private var lab = GestureLabModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(AppLocalization.text("Gesture Lab")).font(.title2.weight(.semibold))
                    Spacer()
                    Text(AppLocalization.text("Prototype lab. Not a global trigger."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForgeNote(text: "Only inside this pad. No actions are run.", symbol: "hand.draw")
                ForgeNote(text: "macOS decides which public gesture events reach this pad; system-reserved gestures may never arrive. These events do not report finger count, so the lab makes no three- or four-finger claims. Discrete system swipes have a fixed direction-only delta and are not gated by the swipe threshold.")

                GesturePadRepresentable(model: lab)
                    .frame(maxWidth: .infinity)
                    .frame(height: 300)

                ForgePanel {
                    Text(AppLocalization.text("Recognition thresholds")).font(.system(size: 13, weight: .semibold))
                    thresholdSlider(title: AppLocalization.text("Swipe distance (points, phased gestures)"),
                                    value: $lab.swipePoints, range: 20...300,
                                    format: AppLocalization.text("%lld pt"))
                    thresholdSlider(title: AppLocalization.text("Pinch scale change"),
                                    value: $lab.pinchPercent, range: 5...60,
                                    format: AppLocalization.text("%lld%%"))
                    thresholdSlider(title: AppLocalization.text("Rotation angle"),
                                    value: $lab.rotationDegrees, range: 5...90,
                                    format: AppLocalization.text("%lld°"))
                }

                ForgePanel {
                    HStack {
                        Text(AppLocalization.text("Last recognition")).font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button(AppLocalization.text("Clear"), action: lab.clear)
                            .controlSize(.small)
                            .accessibilityLabel(AppLocalization.text("Clear recognition results and cancel any pending gesture"))
                    }
                    if let last = lab.results.first {
                        Text(lab.describe(last))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(ForgeStyle.accent)
                            .accessibilityLabel(String(format: AppLocalization.text("Last recognized gesture: %@"), lab.describe(last)))
                    } else {
                        Text(AppLocalization.text("No gestures recognized yet."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if !lab.results.isEmpty {
                        Divider()
                        Text(AppLocalization.text("Recent results")).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        ForEach(lab.results) { result in
                            Text(lab.describe(result))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityLabel(lab.describe(result))
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private func thresholdSlider(title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.callout)
                .frame(width: 220, alignment: .leading)
            Slider(value: value, in: range, step: 1)
                .accessibilityLabel(title)
            Text(String(format: format, Int64(value.wrappedValue)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }
}

/// In-memory lab state. Nothing is persisted or logged. All use is main-thread
/// via SwiftUI and AppKit view callbacks.
final class GestureLabModel: ObservableObject {
    @Published private(set) var results: [RecognizedGesture] = []
    /// Raw slider values; applied to the recognizer through `thresholds`.
    @Published var swipePoints: Double = GestureThresholds.default.swipePoints
    @Published var pinchPercent: Double = GestureThresholds.default.pinchScaleDelta * 100
    @Published var rotationDegrees: Double = GestureThresholds.default.rotateDegrees

    var recognizer = GestureRecognizer()

    /// Current thresholds, or nil when a slider is mid-edit at an invalid value.
    var thresholds: GestureThresholds? {
        GestureThresholds(swipePoints: swipePoints, pinchScaleDelta: pinchPercent / 100, rotateDegrees: rotationDegrees)
    }

    /// Applies slider thresholds. Only an actual value change interrupts pending tracking.
    func applyThresholds() {
        guard let thresholds, thresholds != recognizer.thresholds else { return }
        recognizer.setThresholds(thresholds)
        // A threshold change is an interrupt: adapter session flags reset too,
        // so later phaseless samples cannot silently restart the same gesture.
        interruptHook?()
    }

    /// Records a completed recognition, keeping only the last eight results.
    func record(_ result: RecognizedGesture) {
        results.insert(result, at: 0)
        if results.count > 8 { results.removeLast(results.count - 8) }
    }

    /// True while a phased gesture is accumulating.
    var isTracking: Bool { recognizer.isTracking }

    /// Clears results and cancels any pending gesture without producing a result.
    func clear() {
        recognizer.reset()
        interruptHook?()
        results.removeAll()
    }

    /// Interrupt hook for view teardown and window detach: cancels pending tracking,
    /// keeps already-recorded results, and never produces a completed result.
    func interruptPending() {
        recognizer.reset()
        interruptHook?()
    }

    /// Set by the pad coordinator so Clear and interrupts also reset adapter
    /// begin/end session flags; otherwise later phaseless samples could mix.
    var interruptHook: (() -> Void)?

    private static let kindTitles: [GestureKind: String] = [
        .swipeLeft: "Swipe left", .swipeRight: "Swipe right",
        .swipeUp: "Swipe up", .swipeDown: "Swipe down",
        .pinchIn: "Pinch in", .pinchOut: "Pinch out",
        .rotateClockwise: "Rotate clockwise", .rotateCounterclockwise: "Rotate counterclockwise"
    ]

    /// Metadata-only description: kind, magnitude in the kind's unit, samples, duration.
    func describe(_ result: RecognizedGesture) -> String {
        let title = AppLocalization.text(Self.kindTitles[result.kind] ?? result.kind.rawValue)
        let magnitude: String
        switch result.kind {
        case .swipeLeft, .swipeRight, .swipeUp, .swipeDown:
            magnitude = result.magnitude > 0
                ? String(format: AppLocalization.text("%.0f pt"), result.magnitude)
                : AppLocalization.text("discrete system swipe")
        case .pinchIn, .pinchOut:
            magnitude = String(format: AppLocalization.text("%.0f%%"), result.magnitude * 100)
        case .rotateClockwise, .rotateCounterclockwise:
            magnitude = String(format: AppLocalization.text("%.0f°"), result.magnitude)
        }
        return String(format: AppLocalization.text("%1$@ · %2$@ · %3$lld samples · %4$.1fs"),
                      title, magnitude, Int64(result.sampleCount), result.duration)
    }
}

/// Owns the AppKit pad. Only this view receives gesture events; nothing installs
/// global or local event monitors, and no key events are captured.
struct GesturePadRepresentable: NSViewRepresentable {
    let model: GestureLabModel

    func makeCoordinator() -> GesturePadCoordinator { GesturePadCoordinator(model: model) }

    func makeNSView(context: Context) -> GesturePadView {
        let view = GesturePadView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: GesturePadView, context: Context) {
        view.coordinator = context.coordinator
        model.applyThresholds()
        view.needsDisplay = true
    }

    static func dismantleNSView(_ view: GesturePadView, coordinator: GesturePadCoordinator) {
        // Leaving the lab cancels pending tracking without producing a result.
        coordinator.model.interruptPending()
        view.coordinator = nil
    }
}

/// Bridges public NSEvent gesture callbacks into typed core samples.
/// Phased events pass their phase through. Phaseless magnify/rotate sequences are
/// wrapped by the public beginGesture/endGesture callbacks: the first phaseless
/// sample after beginGesture starts accumulation, and endGesture ends it — no
/// .ended is ever fabricated without a real end signal. Phaseless swipe events are
/// discrete system swipes classified direction-only. Called only from AppKit view
/// callbacks on the main thread.
final class GesturePadCoordinator {
    let model: GestureLabModel
    private var gestureSessionActive = false
    private var phaselessMagnifyActive = false
    private var phaselessRotateActive = false

    init(model: GestureLabModel) {
        self.model = model
        model.interruptHook = { [weak self] in self?.resetSessionFlags() }
    }

    private func resetSessionFlags() {
        gestureSessionActive = false
        phaselessMagnifyActive = false
        phaselessRotateActive = false
    }

    private var timestamp: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func beginGesture() {
        gestureSessionActive = true
    }

    func endGesture(phase: NSEvent.Phase) {
        defer { resetSessionFlags() }
        // A cancelled session ends pending tracking without ever producing a result.
        let ending: GestureSamplePhase = phase == .cancelled ? .cancelled : .ended
        if phaselessMagnifyActive {
            if let result = model.recognizer.process(.magnify(phase: ending, delta: 0), at: timestamp) { model.record(result) }
        }
        if phaselessRotateActive {
            if let result = model.recognizer.process(.rotate(phase: ending, degrees: 0), at: timestamp) { model.record(result) }
        }
    }

    func swipe(deltaX: Double, deltaY: Double, phase: NSEvent.Phase) {
        switch phase {
        case .began:
            _ = model.recognizer.process(.swipe(phase: .began, deltaX: deltaX, deltaY: deltaY), at: timestamp)
        case .changed:
            _ = model.recognizer.process(.swipe(phase: .changed, deltaX: deltaX, deltaY: deltaY), at: timestamp)
        case .ended:
            if let result = model.recognizer.process(.swipe(phase: .ended, deltaX: deltaX, deltaY: deltaY), at: timestamp) { model.record(result) }
        case .cancelled:
            _ = model.recognizer.process(.swipe(phase: .cancelled, deltaX: deltaX, deltaY: deltaY), at: timestamp)
        case .mayBegin, .stationary:
            break
        default:
            // NSEvent swipes commonly carry no phase: a complete, discrete system swipe.
            if let kind = GestureRecognizer.classifySwipe(deltaX: deltaX, deltaY: deltaY) {
                // Discrete system swipes carry a fixed direction-only delta, so no
                // point magnitude is reported; zero marks a single-shot result.
                model.record(RecognizedGesture(kind: kind, magnitude: 0, sampleCount: 1, duration: 0))
            }
        }
    }

    func magnify(delta: Double, phase: NSEvent.Phase) {
        switch phase {
        case .began:
            _ = model.recognizer.process(.magnify(phase: .began, delta: delta), at: timestamp)
        case .changed:
            _ = model.recognizer.process(.magnify(phase: .changed, delta: delta), at: timestamp)
        case .ended:
            if let result = model.recognizer.process(.magnify(phase: .ended, delta: delta), at: timestamp) { model.record(result) }
        case .cancelled:
            _ = model.recognizer.process(.magnify(phase: .cancelled, delta: delta), at: timestamp)
        case .mayBegin, .stationary:
            break
        default:
            // Phaseless magnify: only meaningful inside a beginGesture/endGesture session.
            guard gestureSessionActive else { return }
            if !phaselessMagnifyActive {
                phaselessMagnifyActive = true
                _ = model.recognizer.process(.magnify(phase: .began, delta: delta), at: timestamp)
            } else {
                _ = model.recognizer.process(.magnify(phase: .changed, delta: delta), at: timestamp)
            }
        }
    }

    func rotate(degrees: Double, phase: NSEvent.Phase) {
        switch phase {
        case .began:
            _ = model.recognizer.process(.rotate(phase: .began, degrees: degrees), at: timestamp)
        case .changed:
            _ = model.recognizer.process(.rotate(phase: .changed, degrees: degrees), at: timestamp)
        case .ended:
            if let result = model.recognizer.process(.rotate(phase: .ended, degrees: degrees), at: timestamp) { model.record(result) }
        case .cancelled:
            _ = model.recognizer.process(.rotate(phase: .cancelled, degrees: degrees), at: timestamp)
        case .mayBegin, .stationary:
            break
        default:
            guard gestureSessionActive else { return }
            if !phaselessRotateActive {
                phaselessRotateActive = true
                _ = model.recognizer.process(.rotate(phase: .began, degrees: degrees), at: timestamp)
            } else {
                _ = model.recognizer.process(.rotate(phase: .changed, degrees: degrees), at: timestamp)
            }
        }
    }
}

/// The pad itself. Receives only events the system delivers directly to this view.
/// Becomes first responder only when clicked; it never captures key events.
public final class GesturePadView: NSView {
    fileprivate weak var coordinator: GesturePadCoordinator?

    public override var acceptsFirstResponder: Bool { true }
    public override var isFlipped: Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.group)
        setAccessibilityLabel(AppLocalization.text("Gesture recognition pad. Gestures are recognized only inside this area. No actions are run."))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("GesturePadView is created programmatically") }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Detaching from the window cancels pending tracking without a result.
        if window == nil { coordinator?.model.interruptPending() }
    }

    public override func swipe(with event: NSEvent) {
        coordinator?.swipe(deltaX: event.deltaX, deltaY: event.deltaY, phase: event.phase)
        needsDisplay = true
    }

    public override func magnify(with event: NSEvent) {
        coordinator?.magnify(delta: event.magnification, phase: event.phase)
        needsDisplay = true
    }

    public override func rotate(with event: NSEvent) {
        coordinator?.rotate(degrees: Double(event.rotation), phase: event.phase)
        needsDisplay = true
    }

    public override func beginGesture(with event: NSEvent) {
        coordinator?.beginGesture()
    }

    public override func endGesture(with event: NSEvent) {
        coordinator?.endGesture(phase: event.phase)
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        let bounds = bounds.insetBy(dx: 1.5, dy: 1.5)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let accent = dark ? NSColor(red: 0.40, green: 0.76, blue: 0.59, alpha: 1) : NSColor(red: 0.15, green: 0.43, blue: 0.31, alpha: 1)
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        let tracking = coordinator?.model.isTracking == true
        let border = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        border.lineWidth = tracking ? 2 : 1.25
        (tracking ? accent : accent.withAlphaComponent(0.55)).setStroke()
        border.stroke()
        let inner = NSBezierPath(roundedRect: bounds.insetBy(dx: 7, dy: 7), xRadius: 7, yRadius: 7)
        let dashes: [CGFloat] = [5, 4]
        inner.setLineDash(dashes, count: dashes.count, phase: 0)
        accent.withAlphaComponent(0.30).setStroke()
        inner.lineWidth = 1
        inner.stroke()
        if let image = NSImage(systemSymbolName: "hand.draw", accessibilityDescription: nil) {
            let size: CGFloat = 44
            let tinted = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                image.draw(in: rect)
                accent.withAlphaComponent(tracking ? 0.9 : 0.55).set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2, width: size, height: size))
        }
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.withAlphaComponent(0.35).setStroke()
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: -1.5, dy: -1.5), xRadius: 12, yRadius: 12)
            focus.lineWidth = 2.5
            focus.stroke()
        }
    }

    public override var focusRingMaskBounds: NSRect { bounds }
}
