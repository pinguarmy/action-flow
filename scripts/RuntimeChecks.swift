import AppKit
import ApplicationServices
import Foundation
import ActionFlowCore

// Synthetic menu tree fixtures. These nodes are plain objects; no AX query,
// no real menu, and no press ever reaches the desktop from these tests.
private final class FakeMenuNode {
    let role: String
    var title: String?
    var enabled: Bool
    var pid: pid_t
    var submenu: FakeMenuNode?
    var children: [FakeMenuNode]

    init(role: String, title: String? = nil, enabled: Bool = true, pid: pid_t = 101,
         submenu: FakeMenuNode? = nil, children: [FakeMenuNode] = []) {
        self.role = role
        self.title = title
        self.enabled = enabled
        self.pid = pid
        self.submenu = submenu
        self.children = children
    }
}

@MainActor
private final class FakeMenuProvider: MenuCommandProvider {
    var menuBar: [FakeMenuNode] = []
    var menuBarError: Error?
    var childrenError: Error?
    var infoError: Error?
    var pressError: Error?
    var menuBarReads = 0
    var events: [String] = []
    /// Test hook to mutate a node after its first read, modeling a last-query race.
    var onInfoRead: ((FakeMenuNode) -> Void)?
    /// Simulated internal scan steps so tests can cancel inside provider loops.
    var internalScanSteps = 0

    func menuBarNodes(processIdentifier: pid_t, checkpoint: () throws -> Void) throws -> [AnyObject] {
        menuBarReads += 1
        if let menuBarError { throw menuBarError }
        return menuBar
    }

    func submenuNode(of item: AnyObject, checkpoint: () throws -> Void) throws -> AnyObject? {
        for _ in 0..<internalScanSteps { try checkpoint() }
        return (item as? FakeMenuNode)?.submenu
    }

    func childNodes(of menu: AnyObject, checkpoint: () throws -> Void) throws -> [AnyObject] {
        if let childrenError { throw childrenError }
        let children = (menu as? FakeMenuNode)?.children ?? []
        for _ in children { try checkpoint() }
        return children
    }

    func info(of node: AnyObject) throws -> MenuNodeInfo {
        if let infoError { throw infoError }
        guard let node = node as? FakeMenuNode else { throw MenuCommandError.unavailable }
        defer { onInfoRead?(node) }
        return MenuNodeInfo(role: node.role, title: node.title, enabled: node.enabled,
                            processIdentifier: node.pid)
    }

    func press(_ node: AnyObject) throws {
        if let pressError { throw pressError }
        events.append("press")
    }
}

@main
struct RuntimeChecks {
    @MainActor static func main() async {
        var assertions = 0
        func check(_ value: Bool, _ name: String) {
            guard value else { fputs("FAIL \(name)\n", stderr); exit(1) }
            assertions += 1; print("PASS \(name)")
        }
        // These CGEvents exist only in memory. Never post them or start a tap.
        func syntheticEvent() -> CGEvent {
            guard let event = CGEvent(source: nil) else {
                check(false, "synthetic CGEvent allocation")
                fatalError("CGEvent allocation failed")
            }
            event.flags = []
            return event
        }
        func decode(_ type: CGEventType, _ event: CGEvent) -> InputEvent? {
            InputDecoder.decode(type: type, event: event, appBundleIdentifier: "test.offline.fixture")
        }
        let key = syntheticEvent()
        key.type = .keyDown
        key.setIntegerValueField(.keyboardEventKeycode, value: 42)
        key.flags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskAlphaShift, .maskSecondaryFn]
        let decodedKey = decode(.keyDown, key)
        check(decodedKey?.kind == .shortcut && decodedKey?.keyCode == 42, "decoder preserves physical shortcut signal")
        check(decodedKey?.modifiers == [.command, .option, .control, .shift], "decoder keeps supported modifiers only")
        check(decodedKey?.appBundleIdentifier == "test.offline.fixture", "decoder uses supplied app identity")
        key.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        check(decode(.keyDown, key) == nil, "decoder drops key autorepeat")
        key.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        key.setIntegerValueField(.eventSourceUserData, value: actionFlowEventMarker)
        check(decode(.keyDown, key) == nil, "decoder drops self-generated keys")
        for type: CGEventType in [.keyUp, .flagsChanged, .mouseMoved, .leftMouseUp, .tapDisabledByTimeout] {
            check(decode(type, syntheticEvent()) == nil, "decoder ignores irrelevant event \(type.rawValue)")
        }
        for (type, number): (CGEventType, Int64) in [(.leftMouseDown, 0), (.rightMouseDown, 1), (.otherMouseDown, 4)] {
            let event = syntheticEvent()
            event.type = type
            event.setIntegerValueField(.mouseEventButtonNumber, value: number)
            event.flags = [.maskControl]
            let decoded = decode(type, event)
            check(decoded?.kind == .mouseButton && decoded?.mouseButton == Int(number) && decoded?.modifiers == .control,
                  "decoder preserves mouse button \(number)")
            event.setIntegerValueField(.eventSourceUserData, value: actionFlowEventMarker)
            check(decode(type, event) == nil, "decoder drops self-generated mouse button \(number)")
        }
        func scroll(vertical: Double = 0, horizontal: Double = 0,
                    fields: (CGEventField, CGEventField) = (.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2)) -> CGEvent {
            let event = syntheticEvent()
            event.type = .scrollWheel
            // Explicitly clear every representation so fallback tests are not
            // affected by a CGEvent source's default fields.
            for field: CGEventField in [.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2,
                                        .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2,
                                        .scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2] {
                event.setDoubleValueField(field, value: 0)
            }
            event.setDoubleValueField(fields.0, value: vertical)
            event.setDoubleValueField(fields.1, value: horizontal)
            return event
        }
        for (vertical, horizontal, direction): (Double, Double, ScrollDirection) in [
            (0.25, 0, .up), (-0.25, 0, .down), (0, 0.25, .left), (0, -0.25, .right),
            (0.125, -0.5, .right), (-0.5, 0.125, .down), (0.25, -0.25, .up)
        ] {
            let decoded = decode(.scrollWheel, scroll(vertical: vertical, horizontal: horizontal))
            check(decoded?.kind == .scroll && decoded?.scrollDirection == direction,
                  "decoder preserves fractional scroll \(vertical),\(horizontal) as \(direction.rawValue)")
        }
        let fixed = scroll(vertical: -0.125, fields: (.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2))
        check(decode(.scrollWheel, fixed)?.scrollDirection == .down, "decoder falls back to fractional fixed-point scroll")
        let wheel = scroll(horizontal: -2, fields: (.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2))
        check(decode(.scrollWheel, wheel)?.scrollDirection == .right, "decoder falls back to wheel ticks")
        let preferred = scroll(vertical: 1, fields: (.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2))
        preferred.setDoubleValueField(.scrollWheelEventDeltaAxis2, value: -10)
        // CGEvent's wheel setter also updates point/fixed-point representations.
        // Override the complete point pair last to construct a deliberate conflict.
        preferred.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 1)
        preferred.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: 0)
        check(decode(.scrollWheel, preferred)?.scrollDirection == .up, "decoder prefers point deltas without mixing wheel units")
        check(decode(.scrollWheel, scroll()) == nil, "decoder ignores zero scroll")
        let generatedScroll = scroll(vertical: 0.25)
        generatedScroll.setIntegerValueField(.eventSourceUserData, value: actionFlowEventMarker)
        check(decode(.scrollWheel, generatedScroll) == nil, "decoder drops self-generated scroll")
        // These AX application references are local identity tokens only. We
        // never query their attributes, inspect user apps, or ask for AX access.
        let identityA = AXUIElementCreateApplication(123_451)
        let identityACopy = AXUIElementCreateApplication(123_451)
        let identityB = AXUIElementCreateApplication(123_452)
        var currentElement = identityA
        do {
            let stable = try FocusedElementGuard(current: { currentElement })
            try stable.validate()
            check(true, "AX identity guard accepts captured element")
            currentElement = identityACopy
            try stable.validate()
            check(true, "AX identity guard uses CFEqual rather than pointer identity")
            currentElement = identityB
            do { try stable.validate(); check(false, "AX identity guard rejects same-action change") }
            catch { check(error as? FocusedElementError == .changed, "AX identity guard rejects same-action change") }
            // A subsequent action deliberately captures the new target instead
            // of retaining a whole-chain field/window pin.
            let nextAction = try FocusedElementGuard(current: { currentElement })
            try nextAction.validate()
            check(true, "AX identity guard recaptures target for the next action")
            var available = true
            let disappearing = try FocusedElementGuard(current: {
                guard available else { throw FocusedElementError.unavailable }
                return identityA
            })
            available = false
            do { try disappearing.validate(); check(false, "AX identity guard fails closed when target unavailable") }
            catch { check(error as? FocusedElementError == .unavailable, "AX identity guard fails closed when target unavailable") }
            do {
                _ = try FocusedElementGuard(current: { throw FocusedElementError.changed })
                check(false, "AX identity guard rejects unavailable capture")
            } catch { check(error as? FocusedElementError == .unavailable, "AX identity guard rejects unavailable capture") }
            let originalGuard = FocusedElementGuard(captured: identityA, current: { identityB })
            do { try originalGuard.validate(); check(false, "AX window guard validates explicit original identity") }
            catch { check(error as? FocusedElementError == .changed, "AX window guard validates explicit original identity") }
            let description = FocusedElementError.changed.localizedDescription
            check(description.contains("stopped") && !description.contains("123451"), "AX focus errors contain fixed redacted text")
        } catch { check(false, "AX identity guard offline checks") }
        // Synthetic identities exercise the guard without querying permissions,
        // posting input, launching apps, or changing the user's foreground app.
        var context = FocusContext(initialProcessIdentifier: 101)
        do {
            check(try context.validate(currentProcessIdentifier: 101) == 101, "unchanged foreground accepted")
        } catch { check(false, "unchanged foreground accepted") }
        do { try context.validate(currentProcessIdentifier: 202); check(false, "changed foreground rejected") }
        catch { check(error as? FocusContextError == .changed, "changed foreground rejected") }
        do { try context.validate(currentProcessIdentifier: nil); check(false, "missing current foreground rejected") }
        catch { check(error as? FocusContextError == .unavailable, "missing current foreground rejected") }
        do { try FocusContext(initialProcessIdentifier: nil).validate(currentProcessIdentifier: 101); check(false, "missing initial foreground rejected") }
        catch { check(error as? FocusContextError == .unavailable, "missing initial foreground rejected") }
        do { try FocusContext(initialProcessIdentifier: 0).validate(currentProcessIdentifier: 0); check(false, "invalid process identity rejected") }
        catch { check(error as? FocusContextError == .unavailable, "invalid process identity rejected") }
        do { try context.acceptSuccessfulLaunch(processIdentifier: 202, currentProcessIdentifier: 303); check(false, "unconfirmed launch cannot retarget") }
        catch { check(error as? FocusContextError == .launchNotFrontmost && context.expectedProcessIdentifier == 101, "unconfirmed launch cannot retarget") }
        do {
            try context.acceptSuccessfulLaunch(processIdentifier: 202, currentProcessIdentifier: 202)
            check(try context.validate(currentProcessIdentifier: 202) == 202, "confirmed explicit launch retargets")
        } catch { check(false, "confirmed explicit launch retargets") }
        // Model repeated insertion checkpoints with no CGEvents. Once the
        // foreground differs, no later character is accepted by this context.
        var acceptedCharacters = 0
        for identity: pid_t in [202, 202, 303, 303] {
            do { try context.validate(currentProcessIdentifier: identity); acceptedCharacters += 1 }
            catch { break }
        }
        check(acceptedCharacters == 2, "insertion checkpoints stop on foreground change")
        let executor = ActionExecutor(foregroundProcessIdentifier: { 101 }, sessionAllowsExecution: { true })
        do {
            for kind: ActionKind in [.keyboardShortcut, .insertText, .window] {
                var identityReads = 0
                let guarded = ActionExecutor(foregroundProcessIdentifier: {
                    identityReads += 1
                    return identityReads == 1 ? 101 : 202
                }, sessionAllowsExecution: { true })
                do {
                    _ = try await guarded.execute([AutomationAction(kind: .delay, delaySeconds: 0.001),
                                                   AutomationAction(kind: kind, text: "must not be typed", keyCode: 0, modifiers: .command)])
                    check(false, "\(kind.rawValue) rejects changed focus before permissions or effects")
                } catch {
                    check(error as? FocusContextError == .changed,
                          "\(kind.rawValue) rejects changed focus before permissions or effects")
                }
            }
            let noForeground = ActionExecutor(foregroundProcessIdentifier: { nil }, sessionAllowsExecution: { true })
            do { _ = try await noForeground.execute([AutomationAction(kind: .insertText, text: "must not be typed")]); check(false, "missing focus blocks invasive action") }
            catch { check(error as? FocusContextError == .unavailable, "missing focus blocks invasive action") }
            let noFocusDelay = try await noForeground.execute([AutomationAction(kind: .delay, delaySeconds: 0)])
            check(noFocusDelay.contains("Completed"), "noninvasive delay does not require foreground identity")
            do { _ = try await executor.execute([]); check(false, "empty chain rejected") }
            catch { check(true, "empty chain rejected") }
            do { _ = try await executor.execute(Array(repeating: AutomationAction(kind: .delay, delaySeconds: 0), count: 65)); check(false, "oversized chain rejected") }
            catch { check(true, "oversized chain rejected") }
            let result = try await executor.execute([AutomationAction(kind: .delay, delaySeconds: 0.01)])
            check(result.contains("Completed 1 action"), "delay executes and reports completion")
            do { _ = try await executor.execute([AutomationAction(kind: .delay, delaySeconds: 61)]); check(false, "unbounded delay rejected") }
            catch { check(true, "unbounded delay rejected") }
            do { _ = try await executor.execute([AutomationAction(kind: .openURL, text: "file:///etc/passwd")]); check(false, "file URLs rejected before open") }
            catch { check(true, "file URLs rejected before open") }
            do { _ = try await executor.execute([AutomationAction(kind: .shellScript, text: "exit 0")]); check(false, "scripts disabled by default") }
            catch { check(true, "scripts disabled by default") }
            var sessionReads = 0
            let preflightProbe = ActionExecutor(foregroundProcessIdentifier: { 101 }, sessionAllowsExecution: { sessionReads += 1; return true })
            do {
                _ = try await preflightProbe.execute([AutomationAction(kind:.delay,delaySeconds:0), AutomationAction(kind:.insertText,text:String(repeating:"x",count:16_385))])
                check(false,"invalid later action rejected before chain starts")
            } catch { check(sessionReads == 0, "invalid later action rejected before chain starts") }
            do {
                _ = try await preflightProbe.execute([AutomationAction(kind:.delay,delaySeconds:0), AutomationAction(kind:.shellScript,text:"exit 0")])
                check(false,"disabled script later in chain rejected upfront")
            } catch { check(sessionReads == 0 && error.localizedDescription.contains("No steps were run"), "disabled script later in chain rejected upfront") }
            do {
                _ = try await preflightProbe.execute([AutomationAction(kind:.insertText,text:String(repeating:"a",count:5_000))])
                check(false,"predictable long text timeout rejected before input")
            } catch { check(sessionReads == 0 && error.localizedDescription.contains("119-second"), "predictable long text timeout rejected before input") }
            let progressExecutor = ActionExecutor(foregroundProcessIdentifier: { 101 }, sessionAllowsExecution: { true })
            var progressEvents: [ExecutionProgress] = []
            progressExecutor.onProgress = { progressEvents.append($0) }
            _ = try await progressExecutor.execute((0..<3).map { _ in AutomationAction(kind: .delay, delaySeconds: 0) })
            let expectedProgress = (0..<3).flatMap { index in
                [ExecutionProgress(actionIndex: index + 1, actionCount: 3, kind: .delay, phase: .running, completedActions: index),
                 ExecutionProgress(actionIndex: index + 1, actionCount: 3, kind: .delay, phase: .completed, completedActions: index + 1)]
            }
            check(progressEvents == expectedProgress, "progress reports actual ordered running and completed steps")
            progressEvents.removeAll()
            do {
                _ = try await progressExecutor.execute([AutomationAction(kind: .delay, delaySeconds: 0),
                                                        AutomationAction(kind: .delay, delaySeconds: 61)])
                check(false, "preflight rejection emits no progress")
            } catch { check(progressEvents.isEmpty, "preflight rejection emits no progress") }
            var cancelProgress: [ExecutionProgress] = []
            var cancellationSessionChecks = 0
            let callbackCancel = ActionExecutor(foregroundProcessIdentifier: { 101 }, sessionAllowsExecution: {
                cancellationSessionChecks += 1
                return true
            })
            callbackCancel.onProgress = { event in
                cancelProgress.append(event)
                if event.phase == .running { callbackCancel.cancel() }
            }
            do {
                _ = try await callbackCancel.execute([AutomationAction(kind: .delay, delaySeconds: 30)])
                check(false, "running callback cancellation stops before step effects")
            } catch {
                check(error is CancellationError && cancellationSessionChecks == 1,
                      "running callback cancellation stops before step effects")
            }
            check(cancelProgress == [ExecutionProgress(actionIndex: 1, actionCount: 1, kind: .delay, phase: .running, completedActions: 0),
                                     ExecutionProgress(actionIndex: 1, actionCount: 1, kind: .delay, phase: .cancelled, completedActions: 0)],
                  "callback cancellation emits cancelled without completed step")
            callbackCancel.onProgress = nil
            progressEvents.removeAll()
            progressExecutor.allowScripts = true
            do {
                _ = try await progressExecutor.execute([AutomationAction(kind: .delay, delaySeconds: 0),
                                                        AutomationAction(kind: .shellScript, text: "exit 7"),
                                                        AutomationAction(kind: .delay, delaySeconds: 0)])
                check(false, "failed script progress preserves prior completion count")
            } catch {
                check(progressEvents == [ExecutionProgress(actionIndex: 1, actionCount: 3, kind: .delay, phase: .running, completedActions: 0),
                                         ExecutionProgress(actionIndex: 1, actionCount: 3, kind: .delay, phase: .completed, completedActions: 1),
                                         ExecutionProgress(actionIndex: 2, actionCount: 3, kind: .shellScript, phase: .running, completedActions: 1),
                                         ExecutionProgress(actionIndex: 2, actionCount: 3, kind: .shellScript, phase: .failed, completedActions: 1)],
                      "failed script progress preserves prior completion count")
            }
            let progressData = try JSONEncoder().encode(progressEvents)
            check(try JSONDecoder().decode([ExecutionProgress].self, from: progressData) == progressEvents,
                  "progress events preserve Codable round trip")
            let progressJSON = try JSONSerialization.jsonObject(with: progressData) as? [[String: Any]]
            check(progressJSON?.allSatisfy { Set($0.keys) == ["actionIndex", "actionCount", "kind", "phase", "completedActions"] } == true,
                  "progress contains only redacted counters and enum metadata")
            let progressText = String(data: progressData, encoding: .utf8) ?? ""
            check(!progressText.contains("exit 7"), "progress never includes script payload")
            progressExecutor.onProgress = nil
            var taskCancelEvents: [ExecutionProgress] = []
            let taskCancelExecutor = ActionExecutor(foregroundProcessIdentifier: { 101 }, sessionAllowsExecution: { true })
            taskCancelExecutor.onProgress = { taskCancelEvents.append($0) }
            let cancelledTask = Task { @MainActor in try await taskCancelExecutor.execute([AutomationAction(kind: .delay, delaySeconds: 20)]) }
            for _ in 0..<100 where taskCancelEvents.isEmpty {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            check(!taskCancelEvents.isEmpty, "Task cancellation fixture reached running checkpoint")
            cancelledTask.cancel()
            do { _ = try await cancelledTask.value; check(false, "Task cancellation produces cancelled progress") }
            catch { check(error is CancellationError && taskCancelEvents.last?.phase == .cancelled && taskCancelEvents.last?.completedActions == 0,
                          "Task cancellation produces cancelled progress") }
            taskCancelExecutor.onProgress = nil
            let pending = Task { @MainActor in try await executor.execute([AutomationAction(kind: .delay, delaySeconds: 20)]) }
            try await Task.sleep(nanoseconds: 60_000_000)
            executor.cancel()
            do { _ = try await pending.value; check(false, "cancel stops delay chain") }
            catch { check(true, "cancel stops delay chain") }
            executor.allowScripts = true
            let success = try await executor.execute([AutomationAction(kind: .shellScript, text: "test -z \"${ACTIONFLOW_TEST_SECRET:-}\" && exit 0")])
            check(success.contains("Completed"), "opted-in isolated script executes with minimal environment")
            do { _ = try await executor.execute([AutomationAction(kind: .shellScript, text: "exit 7")]); check(false, "script nonzero exit reported") }
            catch { check(true, "script nonzero exit reported") }
            let longScript = Task { @MainActor in try await executor.execute([AutomationAction(kind: .shellScript, text: "/bin/sleep 30")]) }
            try await Task.sleep(nanoseconds: 100_000_000)
            executor.cancel()
            do { _ = try await longScript.value; check(false, "cancel terminates owned script group") }
            catch { check(true, "cancel terminates owned script group") }
            let locked = ActionExecutor(foregroundProcessIdentifier: { 101 }, sessionAllowsExecution: { false })
            locked.allowScripts = true
            do {
                _ = try await locked.execute([AutomationAction(kind: .shellScript, text: "exit 0")])
                check(false, "locked session blocks even opted-in scripts")
            } catch { check(error.localizedDescription.contains("desktop session"), "locked session blocks even opted-in scripts") }
            var allowed = true
            let sessionChanges = ActionExecutor(foregroundProcessIdentifier: { 101 }, sessionAllowsExecution: { allowed })
            let lockDuringDelay = Task { @MainActor in try await sessionChanges.execute([AutomationAction(kind: .delay, delaySeconds: 10)]) }
            try await Task.sleep(nanoseconds: 50_000_000)
            allowed = false
            do { _ = try await lockDuringDelay.value; check(false, "locking interrupts a running delay") }
            catch { check(error.localizedDescription.contains("desktop session"), "locking interrupts a running delay") }
            // Synthetic menu command checks. The controller drives the exact
            // same protocol path as the AX provider, but only fake node objects
            // are read and presses are recorded, never performed.
            func fakeMenuTree() -> (provider: FakeMenuProvider, newItem: FakeMenuNode) {
                let newItem = FakeMenuNode(role: "AXMenuItem", title: "New")
                let fileMenu = FakeMenuNode(role: "AXMenu", children: [
                    FakeMenuNode(role: "AXMenuItem", title: "Close", enabled: false),
                    newItem,
                ])
                let fileItem = FakeMenuNode(role: "AXMenuBarItem", title: "File", submenu: fileMenu)
                let provider = FakeMenuProvider()
                provider.menuBar = [FakeMenuNode(role: "AXMenuBarItem", title: "Edit",
                                                 submenu: FakeMenuNode(role: "AXMenu")), fileItem]
                return (provider, newItem)
            }
            let fileNewPath = try MenuCommandPath(parsing: "[\"File\", \"New\"]")
            do {
                let (provider, _) = fakeMenuTree()
                let controller = MenuCommandController(provider: provider)
                try controller.perform(path: fileNewPath, expectedProcessIdentifier: 101) {
                    provider.events.append("checkpoint")
                }
                check(provider.events.last == "press" && provider.events.filter { $0 == "press" }.count == 1
                      && provider.events.filter { $0 == "checkpoint" }.count >= 2 && provider.menuBarReads == 1,
                      "menu success presses exactly once with checkpoints before reads and press")
            }
            do {
                // Three-level path traverses one submenu per intermediate item.
                let target = FakeMenuNode(role: "AXMenuItem", title: "Plain Text")
                let formatMenu = FakeMenuNode(role: "AXMenu", children: [target])
                let formatItem = FakeMenuNode(role: "AXMenuItem", title: "Format", submenu: formatMenu)
                let fileMenu = FakeMenuNode(role: "AXMenu", children: [formatItem])
                let provider = FakeMenuProvider()
                provider.menuBar = [FakeMenuNode(role: "AXMenuBarItem", title: "File",
                                                 submenu: fileMenu)]
                try MenuCommandController(provider: provider).perform(
                    path: MenuCommandPath(parsing: "[\"File\", \"Format\", \"Plain Text\"]"),
                    expectedProcessIdentifier: 101) {}
                check(provider.events == ["press"], "menu three-level exact traversal succeeds")
            }
            do {
                let (provider, _) = fakeMenuTree()
                do {
                    try MenuCommandController(provider: provider).perform(
                        path: MenuCommandPath(parsing: "[\"File\", \"Nope\"]"),
                        expectedProcessIdentifier: 101) {}
                    check(false, "missing exact menu title rejected")
                } catch { check(error as? MenuCommandError == .titleNotFound && provider.events.isEmpty, "missing exact menu title rejected") }
            }
            do {
                let (provider, _) = fakeMenuTree()
                provider.menuBar.append(FakeMenuNode(role: "AXMenuBarItem", title: "File",
                                                     submenu: FakeMenuNode(role: "AXMenu")))
                do {
                    try MenuCommandController(provider: provider).perform(path: fileNewPath, expectedProcessIdentifier: 101) {}
                    check(false, "duplicate exact title at one level rejected")
                } catch { check(error as? MenuCommandError == .duplicateTitle && provider.events.isEmpty, "duplicate exact title at one level rejected") }
            }
            do {
                let (provider, newItem) = fakeMenuTree()
                newItem.enabled = false
                do {
                    try MenuCommandController(provider: provider).perform(path: fileNewPath, expectedProcessIdentifier: 101) {}
                    check(false, "disabled final menu item rejected")
                } catch { check(error as? MenuCommandError == .disabled && provider.events.isEmpty, "disabled final menu item rejected") }
            }
            do {
                let (provider, _) = fakeMenuTree()
                provider.menuBar[1].enabled = false
                do {
                    try MenuCommandController(provider: provider).perform(path: fileNewPath, expectedProcessIdentifier: 101) {}
                    check(false, "disabled parent menu item rejected")
                } catch { check(error as? MenuCommandError == .disabled && provider.events.isEmpty, "disabled parent menu item rejected") }
            }
            do {
                let (provider, newItem) = fakeMenuTree()
                newItem.title = nil
                do {
                    try MenuCommandController(provider: provider).perform(path: fileNewPath, expectedProcessIdentifier: 101) {}
                    check(false, "untitled node never matches")
                } catch { check(error as? MenuCommandError == .titleNotFound, "untitled node never matches") }
            }
            do {
                let (provider, _) = fakeMenuTree()
                provider.menuBar[1] = FakeMenuNode(role: "AXMenuItem", title: "File",
                                                   submenu: FakeMenuNode(role: "AXMenu"))
                do {
                    try MenuCommandController(provider: provider).perform(path: fileNewPath, expectedProcessIdentifier: 101) {}
                    check(false, "wrong role at menu bar level rejected")
                } catch { check(error as? MenuCommandError == .titleNotFound && provider.events.isEmpty, "wrong role at menu bar level rejected") }
            }
            do {
                let (provider, _) = fakeMenuTree()
                provider.menuBar[1].submenu = nil
                do {
                    try MenuCommandController(provider: provider).perform(path: fileNewPath, expectedProcessIdentifier: 101) {}
                    check(false, "item without static submenu fails without opening it")
                } catch { check(error as? MenuCommandError == .submenuUnavailable && provider.events.isEmpty, "item without static submenu fails without opening it") }
            }
            do {
                let (provider, _) = fakeMenuTree()
                provider.menuBar = (0..<129).map { FakeMenuNode(role: "AXMenuBarItem", title: "Item \($0)") }
                do {
                    try MenuCommandController(provider: provider).perform(path: fileNewPath, expectedProcessIdentifier: 101) {}
                    check(false, "menu level beyond 128-item bound rejected")
                } catch { check(error as? MenuCommandError == .tooManyChildren && provider.events.isEmpty, "menu level beyond 128-item bound rejected") }
            }
            do {
                let (provider, _) = fakeMenuTree()
                provider.childrenError = MenuCommandError.unavailable
                do {
                    try MenuCommandController(provider: provider).perform(path: fileNewPath, expectedProcessIdentifier: 101) {}
                    check(false, "provider read error fails closed")
                } catch { check(error as? MenuCommandError == .unavailable && provider.events.isEmpty, "provider read error fails closed") }
            }
            do {
                let (provider, _) = fakeMenuTree()
                provider.menuBar[1].pid = 202
                do {
                    try MenuCommandController(provider: provider).perform(path: fileNewPath, expectedProcessIdentifier: 101) {}
                    check(false, "menu element from unexpected process rejected")
                } catch { check(error as? MenuCommandError == .unexpectedProcess && provider.events.isEmpty, "menu element from unexpected process rejected") }
            }
            do {
                let (provider, _) = fakeMenuTree()
                var calls = 0
                do {
                    try MenuCommandController(provider: provider).perform(path: fileNewPath, expectedProcessIdentifier: 101) {
                        calls += 1
                        if calls == 2 { throw CancellationError() }
                    }
                    check(false, "cancellation between reads stops traversal without press")
                } catch { check(error is CancellationError && provider.events.isEmpty, "cancellation between reads stops traversal without press") }
            }
            do {
                let (provider, _) = fakeMenuTree()
                do {
                    try MenuCommandController(provider: provider).perform(path: fileNewPath, expectedProcessIdentifier: 101) {
                        throw CancellationError()
                    }
                    check(false, "cancellation before first read performs no queries")
                } catch { check(error is CancellationError && provider.menuBarReads == 0, "cancellation before first read performs no queries") }
            }
            do {
                // Cancellation reaches provider-internal loops through the
                // shared checkpoint contract, not only the controller's loop.
                let (provider, _) = fakeMenuTree()
                provider.internalScanSteps = 5
                var scanChecks = 0
                do {
                    try MenuCommandController(provider: provider).perform(path: fileNewPath, expectedProcessIdentifier: 101) {
                        scanChecks += 1
                        // Calls 1-4 are controller checkpoints (start, two menu
                        // bar nodes, pre-submenu); call 6 lands inside the
                        // provider's simulated internal scan loop.
                        if scanChecks == 6 { throw CancellationError() }
                    }
                    check(false, "cancellation inside provider scan stops traversal")
                } catch { check(error is CancellationError && scanChecks == 6 && provider.events.isEmpty, "cancellation inside provider scan stops traversal") }
            }
            do {
                // The final pre-press re-read catches a mutation racing the traversal.
                let (provider, newItem) = fakeMenuTree()
                var reads = 0
                provider.onInfoRead = { node in
                    if node === newItem {
                        reads += 1
                        if reads == 1 { newItem.enabled = false }
                    }
                }
                do {
                    try MenuCommandController(provider: provider).perform(path: fileNewPath, expectedProcessIdentifier: 101) {}
                    check(false, "item disabled before final press re-read rejected")
                } catch { check(error as? MenuCommandError == .disabled && provider.events.isEmpty, "item disabled before final press re-read rejected") }
            }
            do {
                let (provider, newItem) = fakeMenuTree()
                provider.onInfoRead = { node in
                    if node === newItem { newItem.title = "Changed" }
                }
                do {
                    try MenuCommandController(provider: provider).perform(path: fileNewPath, expectedProcessIdentifier: 101) {}
                    check(false, "item retitled before final press re-read rejected")
                } catch { check(error as? MenuCommandError == .changed && provider.events.isEmpty, "item retitled before final press re-read rejected") }
            }
            do {
                // Executor-level: invalid menu path late in a chain is rejected
                // by preflight before any session probe, permission check or read.
                var menuSessionReads = 0
                let menuProbe = ActionExecutor(foregroundProcessIdentifier: { 101 }, sessionAllowsExecution: {
                    menuSessionReads += 1
                    return true
                })
                do {
                    _ = try await menuProbe.execute([AutomationAction(kind: .delay, delaySeconds: 0),
                                                     AutomationAction(kind: .menuCommand, text: "[\"OnlyOne\"]")])
                    check(false, "invalid late menu action rejected before chain starts")
                } catch { check(menuSessionReads == 0, "invalid late menu action rejected before chain starts") }
                // A changed foreground is rejected before accessibility or menu reads.
                var menuIdentityReads = 0
                let (provider, _) = fakeMenuTree()
                let guardedMenu = ActionExecutor(foregroundProcessIdentifier: {
                    menuIdentityReads += 1
                    return menuIdentityReads == 1 ? 101 : 202
                }, sessionAllowsExecution: { true }, menuCommandController: MenuCommandController(provider: provider))
                do {
                    _ = try await guardedMenu.execute([AutomationAction(kind: .delay, delaySeconds: 0.001),
                                                       AutomationAction(kind: .menuCommand, text: "[\"File\", \"New\"]")])
                    check(false, "menuCommand rejects changed focus before permissions or effects")
                } catch {
                    check(error as? FocusContextError == .changed && provider.menuBarReads == 0 && provider.events.isEmpty,
                          "menuCommand rejects changed focus before permissions or effects")
                }
            }
            print("Verified \(assertions) runtime assertions. No desktop input, window operations, app launching or permission prompts were performed.")
        } catch { fputs("Unexpected runtime check failure: \(error)\n", stderr); exit(1) }
    }
}
