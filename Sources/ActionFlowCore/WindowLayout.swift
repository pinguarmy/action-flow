import Foundation
import CoreGraphics

/// Window geometry in Accessibility coordinates, with the origin at the top
/// left. Screens must be visible frames, excluding menu bars and the Dock.
/// This engine does not query screens, permissions, or application state.
public enum WindowLayout {
    public static func target(for operation: WindowOperation, original: CGRect,
                              screens: [CGRect], restoreFrame: CGRect? = nil) throws -> CGRect {
        guard valid(original) else { throw WindowLayoutError.invalidOriginal }
        guard !screens.isEmpty else { throw WindowLayoutError.noScreens }
        guard screens.allSatisfy(valid) else { throw WindowLayoutError.invalidScreen }
        if let restoreFrame, !valid(restoreFrame) { throw WindowLayoutError.invalidRestoreFrame }

        let index = screenIndex(for: original, screens: screens)
        let screen = screens[index]
        let proposed: CGRect
        switch operation {
        case .leftHalf:
            proposed = CGRect(x: screen.minX, y: screen.minY, width: screen.width / 2, height: screen.height)
        case .rightHalf:
            proposed = CGRect(x: screen.midX, y: screen.minY, width: screen.width / 2, height: screen.height)
        case .topHalf:
            proposed = CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: screen.height / 2)
        case .bottomHalf:
            proposed = CGRect(x: screen.minX, y: screen.midY, width: screen.width, height: screen.height / 2)
        case .topLeft:
            proposed = CGRect(x: screen.minX, y: screen.minY, width: screen.width / 2, height: screen.height / 2)
        case .topRight:
            proposed = CGRect(x: screen.midX, y: screen.minY, width: screen.width / 2, height: screen.height / 2)
        case .bottomLeft:
            proposed = CGRect(x: screen.minX, y: screen.midY, width: screen.width / 2, height: screen.height / 2)
        case .bottomRight:
            proposed = CGRect(x: screen.midX, y: screen.midY, width: screen.width / 2, height: screen.height / 2)
        case .maximize:
            proposed = screen
        case .center:
            proposed = centered(size: original.size, at: CGPoint(x: screen.midX, y: screen.midY), in: screen)
        case .centerTwoThirds:
            proposed = centered(size: CGSize(width: screen.width * (2.0 / 3.0), height: screen.height),
                                 at: CGPoint(x: screen.midX, y: screen.midY), in: screen)
        case .larger, .smaller:
            let scale: CGFloat = operation == .larger ? 1.1 : 0.9
            // Clamp before multiplication, avoiding overflow for finite but
            // extreme inputs. Keep a one-point floor on ordinary displays.
            let width = min(screen.width, max(min(1, screen.width), min(original.width, screen.width / scale) * scale))
            let height = min(screen.height, max(min(1, screen.height), min(original.height, screen.height / scale) * scale))
            proposed = centered(size: CGSize(width: width, height: height),
                                 at: CGPoint(x: original.midX, y: original.midY), in: screen)
        case .nextDisplay:
            guard screens.count > 1 else { throw WindowLayoutError.requiresAnotherScreen }
            let next = screens[(index + 1) % screens.count]
            let width = min(original.width, next.width)
            let height = min(original.height, next.height)
            let fractionX = relativePosition(original.minX, in: screen.minX, span: screen.width - original.width)
            let fractionY = relativePosition(original.minY, in: screen.minY, span: screen.height - original.height)
            return try validated(fit(CGRect(x: next.minX + fractionX * (next.width - width),
                                           y: next.minY + fractionY * (next.height - height),
                                           width: width, height: height), in: next))
        case .restore:
            guard let restoreFrame else { throw WindowLayoutError.missingRestoreFrame }
            let restoreScreen = screens[screenIndex(for: restoreFrame, screens: screens)]
            return try validated(fit(restoreFrame, in: restoreScreen))
        }
        return try validated(fit(proposed, in: screen))
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.origin.x.isFinite && rect.origin.y.isFinite &&
        rect.size.width.isFinite && rect.size.height.isFinite && rect.size.width > 0 && rect.size.height > 0 &&
        rect.maxX.isFinite && rect.maxY.isFinite
    }

    private static func validated(_ rect: CGRect) throws -> CGRect {
        guard valid(rect) else { throw WindowLayoutError.invalidResult }
        return rect
    }

    private static func screenIndex(for frame: CGRect, screens: [CGRect]) -> Int {
        // Normalizing both axes keeps comparison finite for large coordinates.
        let extent = screens.reduce(max(1, abs(frame.minX), abs(frame.maxX), abs(frame.minY), abs(frame.maxY))) {
            max($0, abs($1.minX), abs($1.maxX), abs($1.minY), abs($1.maxY))
        }
        func score(_ screen: CGRect) -> (area: CGFloat, distance: CGFloat) {
            let intersection = frame.intersection(screen)
            let area = intersection.isNull ? 0 : (intersection.width / extent) * (intersection.height / extent)
            let dx = frame.midX / extent - screen.midX / extent
            let dy = frame.midY / extent - screen.midY / extent
            return (area, dx * dx + dy * dy)
        }
        var best = 0
        var bestScore = score(screens[0])
        for index in screens.indices.dropFirst() {
            let candidate = score(screens[index])
            if candidate.area > bestScore.area ||
                (candidate.area == bestScore.area && candidate.distance < bestScore.distance) {
                best = index
                bestScore = candidate
            }
        }
        return best
    }

    private static func relativePosition(_ value: CGFloat, in origin: CGFloat, span: CGFloat) -> CGFloat {
        guard span > 0 else { return 0.5 }
        // Subtraction may overflow for opposing extreme finite coordinates.
        let difference = value - origin
        if !difference.isFinite { return value > origin ? 1 : 0 }
        return max(0, min(1, difference / span))
    }

    private static func centered(size: CGSize, at center: CGPoint, in screen: CGRect) -> CGRect {
        let width = min(size.width, screen.width)
        let height = min(size.height, screen.height)
        return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }

    private static func fit(_ rect: CGRect, in screen: CGRect) -> CGRect {
        let width = min(rect.width, screen.width)
        let height = min(rect.height, screen.height)
        return CGRect(x: max(screen.minX, min(rect.minX, screen.maxX - width)),
                      y: max(screen.minY, min(rect.minY, screen.maxY - height)), width: width, height: height)
    }
}

public enum WindowLayoutError: LocalizedError, Equatable, Sendable {
    case invalidOriginal, noScreens, invalidScreen, invalidRestoreFrame
    case requiresAnotherScreen, missingRestoreFrame, invalidResult

    public var errorDescription: String? {
        switch self {
        case .invalidOriginal: return "The original window frame must have finite coordinates and positive dimensions."
        case .noScreens: return "No visible display frame is available."
        case .invalidScreen: return "Every display frame must have finite coordinates and positive dimensions."
        case .invalidRestoreFrame: return "The saved window frame is invalid."
        case .requiresAnotherScreen: return "Moving to the next display requires at least two displays."
        case .missingRestoreFrame: return "This window has no saved frame from this session."
        case .invalidResult: return "The requested layout could not produce valid window geometry."
        }
    }
}
