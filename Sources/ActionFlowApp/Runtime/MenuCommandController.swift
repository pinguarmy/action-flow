import AppKit
import ApplicationServices
import ActionFlowCore

/// Snapshot of one menu element. Titles are compared exactly and are never
/// logged, persisted, or included in errors.
struct MenuNodeInfo: Equatable, Sendable {
    var role: String
    var title: String?
    var enabled: Bool
    var processIdentifier: pid_t
}

/// Reads exactly the menu levels needed for one path. A fake implementation
/// drives offline tests; only the AX implementation touches a real desktop.
/// Callers must hold Accessibility permission and an expected foreground PID.
@MainActor
protocol MenuCommandProvider: AnyObject {
    /// Children of the application's menu bar. `checkpoint` must be called
    /// before internal batch reads so cancellation and deadlines still apply.
    func menuBarNodes(processIdentifier: pid_t, checkpoint: () throws -> Void) throws -> [AnyObject]
    /// The single submenu exposed by a menu item, or nil when it has none.
    /// Items with several submenus fail closed rather than guessing.
    func submenuNode(of item: AnyObject, checkpoint: () throws -> Void) throws -> AnyObject?
    /// Children of one menu node. Dynamic submenus may not exist until opened;
    /// nothing here opens them.
    func childNodes(of menu: AnyObject, checkpoint: () throws -> Void) throws -> [AnyObject]
    /// Role, exact title, enabled state, and owning process of one node.
    func info(of node: AnyObject) throws -> MenuNodeInfo
    /// Performs exactly one press on the resolved final menu item.
    func press(_ node: AnyObject) throws
}

/// Fixed, redacted failures. No menu titles, roles dumps, or app contents.
enum MenuCommandError: LocalizedError, Equatable {
    case unavailable
    case unexpectedProcess
    case titleNotFound
    case duplicateTitle
    case submenuUnavailable
    case tooManyChildren
    case disabled
    case changed
    case pressRejected
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The application does not expose this menu level through Accessibility. Nothing was pressed."
        case .unexpectedProcess:
            return "A menu element belongs to an unexpected process. Nothing was pressed."
        case .titleNotFound:
            return "No menu item matches the requested exact title at this level. Nothing was pressed."
        case .duplicateTitle:
            return "More than one menu item at the same level has the requested exact title. Nothing was pressed."
        case .submenuUnavailable:
            return "A menu item on this path does not expose a static submenu. Parent menus are never opened automatically. Nothing was pressed."
        case .tooManyChildren:
            return "A menu level exposes more items than the 128-item safety bound. Nothing was pressed."
        case .disabled:
            return "The requested menu item is disabled. Nothing was pressed."
        case .changed:
            return "The menu item changed before it could be pressed. Nothing was pressed."
        case .pressRejected:
            return "The application rejected the menu item press."
        case .timedOut:
            return "Reading the menu took longer than the 10-second traversal limit. Nothing was pressed."
        }
    }
}

/// Resolves an exact menu path against the foreground app's menu bar and
/// performs one press on the final item only. Parent menus are never opened,
/// so apps that build submenus on demand may fail as unavailable. Reads are
/// bounded (128 children per level, path depth at most 8 by MenuCommandPath)
/// and titles are queried only along the requested path, never enumerated
/// for logging or browsing.
@MainActor
final class MenuCommandController {
    static let maximumChildrenPerLevel = 128
    /// Bounds the whole traversal even when every single AX query stays inside
    /// its 0.25-second messaging timeout. Cancellation and focus changes are
    /// observed between node reads, not during one in-flight AX call.
    static let maximumTraversalSeconds: TimeInterval = 10
    private let provider: any MenuCommandProvider

    init(provider: (any MenuCommandProvider)? = nil) {
        self.provider = provider ?? AXMenuCommandProvider()
    }

    /// `checkpoint` revalidates expected focus, session state, cancellation and
    /// the chain deadline. It runs before every node read and again immediately
    /// before the single press. A change during one in-flight read is an
    /// accepted race bounded by the per-call messaging timeout.
    func perform(path: MenuCommandPath, expectedProcessIdentifier: pid_t,
                 checkpoint: () throws -> Void) throws {
        let traversalDeadline = ProcessInfo.processInfo.systemUptime + Self.maximumTraversalSeconds
        func stepCheckpoint() throws {
            try checkpoint()
            guard ProcessInfo.processInfo.systemUptime < traversalDeadline else {
                throw MenuCommandError.timedOut
            }
        }
        try stepCheckpoint()
        guard expectedProcessIdentifier > 0 else { throw MenuCommandError.unavailable }
        var levelNodes = try bounded(try provider.menuBarNodes(processIdentifier: expectedProcessIdentifier,
                                                               checkpoint: stepCheckpoint))
        var resolved: (node: AnyObject, info: MenuNodeInfo)?
        for (level, segment) in path.segments.enumerated() {
            let expectedRole = level == 0 ? "AXMenuBarItem" : "AXMenuItem"
            var matches: [(node: AnyObject, info: MenuNodeInfo)] = []
            for node in levelNodes {
                try stepCheckpoint()
                let info = try provider.info(of: node)
                guard info.processIdentifier == expectedProcessIdentifier else {
                    throw MenuCommandError.unexpectedProcess
                }
                guard info.role == expectedRole, info.title == segment else { continue }
                matches.append((node, info))
            }
            if matches.count > 1 { throw MenuCommandError.duplicateTitle }
            guard let match = matches.first else { throw MenuCommandError.titleNotFound }
            // A disabled item fails closed at any level, not only the last one.
            guard match.info.enabled else { throw MenuCommandError.disabled }
            if level == path.segments.count - 1 {
                resolved = match
            } else {
                try stepCheckpoint()
                guard let submenu = try provider.submenuNode(of: match.node, checkpoint: stepCheckpoint) else {
                    throw MenuCommandError.submenuUnavailable
                }
                levelNodes = try bounded(try provider.childNodes(of: submenu, checkpoint: stepCheckpoint))
            }
        }
        guard let final = resolved else { throw MenuCommandError.titleNotFound }
        // Immediately before the single press, re-read the resolved item:
        // exact title, enabled state, and owning process must still hold.
        try stepCheckpoint()
        let current = try provider.info(of: final.node)
        guard current.processIdentifier == expectedProcessIdentifier else {
            throw MenuCommandError.unexpectedProcess
        }
        guard current.role == "AXMenuItem", current.title == path.segments.last else {
            throw MenuCommandError.changed
        }
        guard current.enabled else { throw MenuCommandError.disabled }
        try stepCheckpoint()
        try provider.press(final.node)
    }

    private func bounded(_ nodes: [AnyObject]) throws -> [AnyObject] {
        guard nodes.count <= Self.maximumChildrenPerLevel else { throw MenuCommandError.tooManyChildren }
        return nodes
    }
}

/// Accessibility implementation. Queries only attributes along the requested
/// path, uses a 0.25-second messaging timeout, verifies CF types and owning
/// PIDs, and performs exactly one AXPress on the final item.
@MainActor
final class AXMenuCommandProvider: MenuCommandProvider {
    func menuBarNodes(processIdentifier pid: pid_t, checkpoint: () throws -> Void) throws -> [AnyObject] {
        guard pid > 0 else { throw MenuCommandError.unavailable }
        let application = AXUIElementCreateApplication(pid)
        guard AXUIElementSetMessagingTimeout(application, 0.25) == .success else {
            throw MenuCommandError.unavailable
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXMenuBarAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw MenuCommandError.unavailable
        }
        let menuBar = unsafeBitCast(value, to: AXUIElement.self)
        // The bar element is a fresh AX reference; bound its queries as well.
        guard AXUIElementSetMessagingTimeout(menuBar, 0.25) == .success else {
            throw MenuCommandError.unavailable
        }
        return try children(of: menuBar, expectedProcessIdentifier: pid, checkpoint: checkpoint)
    }

    func submenuNode(of item: AnyObject, checkpoint: () throws -> Void) throws -> AnyObject? {
        let element = try axElement(item)
        let children = try self.children(of: element, expectedProcessIdentifier: ownerPID(of: element),
                                         checkpoint: checkpoint)
        var submenus: [AnyObject] = []
        for child in children {
            try checkpoint()
            if try info(of: child).role == "AXMenu" { submenus.append(child) }
        }
        // Several submenus at one item are ambiguous; fail closed.
        guard submenus.count <= 1 else { throw MenuCommandError.submenuUnavailable }
        return submenus.first
    }

    func childNodes(of menu: AnyObject, checkpoint: () throws -> Void) throws -> [AnyObject] {
        let element = try axElement(menu)
        return try children(of: element, expectedProcessIdentifier: ownerPID(of: element), checkpoint: checkpoint)
    }

    func info(of node: AnyObject) throws -> MenuNodeInfo {
        let element = try axElement(node)
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
              let role = roleValue as? String else { throw MenuCommandError.unavailable }
        var titleValue: CFTypeRef?
        let title = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue) == .success
            ? titleValue as? String : nil
        var enabledValue: CFTypeRef?
        let enabled = AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabledValue) == .success
            && (enabledValue as? Bool ?? false)
        return MenuNodeInfo(role: role, title: title, enabled: enabled,
                            processIdentifier: try ownerPID(of: element))
    }

    func press(_ node: AnyObject) throws {
        let element = try axElement(node)
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
            throw MenuCommandError.pressRejected
        }
    }

    private func axElement(_ node: AnyObject) throws -> AXUIElement {
        guard CFGetTypeID(node) == AXUIElementGetTypeID() else { throw MenuCommandError.unavailable }
        return unsafeBitCast(node, to: AXUIElement.self)
    }

    private func ownerPID(of element: AXUIElement) throws -> pid_t {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else {
            throw MenuCommandError.unavailable
        }
        return pid
    }

    private func children(of element: AXUIElement, expectedProcessIdentifier pid: pid_t,
                          checkpoint: () throws -> Void) throws -> [AnyObject] {
        // Count before copying so an unbounded array is never materialized.
        var count = 0
        let countResult = AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count)
        if countResult == .noValue || countResult == .attributeUnsupported { return [] }
        guard countResult == .success else { throw MenuCommandError.unavailable }
        guard count <= MenuCommandController.maximumChildrenPerLevel else {
            throw MenuCommandError.tooManyChildren
        }
        guard count > 0 else { return [] }
        var value: CFArray?
        let result = AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, count, &value)
        if result == .noValue || result == .attributeUnsupported { return [] }
        guard result == .success, let value else { throw MenuCommandError.unavailable }
        var children: [AnyObject] = []
        for index in 0..<CFArrayGetCount(value) {
            try checkpoint()
            guard let raw = CFArrayGetValueAtIndex(value, index) else { throw MenuCommandError.unavailable }
            let child = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
            guard CFGetTypeID(child) == AXUIElementGetTypeID() else { throw MenuCommandError.unavailable }
            let element = unsafeBitCast(child, to: AXUIElement.self)
            guard AXUIElementSetMessagingTimeout(element, 0.25) == .success,
                  (try? ownerPID(of: element)) == pid else { throw MenuCommandError.unexpectedProcess }
            children.append(element)
        }
        return children
    }
}
