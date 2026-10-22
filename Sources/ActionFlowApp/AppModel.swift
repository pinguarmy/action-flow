import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import ActionFlowCore
import ServiceManagement
import SwiftUI
import UserNotifications

public enum SidebarSection: String, CaseIterable, Identifiable {
    case rules, activity, permissions, settings, gestureLab
    public var id: String { rawValue }
    public var title: String { switch self { case .rules: return AppLocalization.text("Rules"); case .activity: return AppLocalization.text("Activity"); case .permissions: return AppLocalization.text("Permissions"); case .settings: return AppLocalization.text("Settings"); case .gestureLab: return AppLocalization.text("Gesture Lab") } }
    public var systemImage: String { switch self { case .rules: return "slider.horizontal.3"; case .activity: return "clock.arrow.circlepath"; case .permissions: return "hand.raised"; case .settings: return "gearshape"; case .gestureLab: return "hand.draw" } }
}
public struct PermissionState {
    public var accessibility = false
    public var inputMonitoring = false
    public var notifications = false
}
public struct ActivityEntry: Identifiable {
    public let id = UUID()
    public let date = Date()
    public var ruleName: String
    public var message: String
    public var success: Bool
    public var completedActions: Int? = nil
    public var totalActions: Int? = nil
}

@MainActor
final class AppModel: ObservableObject {
    @Published var configuration: Configuration
    @Published var selection: UUID?
    @Published var section: SidebarSection = .rules
    @Published var searchText = ""
    @Published var ruleStatusFilter: RuleStatusFilter = .all
    @Published var ruleGroupFilter: String?
    @Published var activity: [ActivityEntry] = []
    @Published var permissions = PermissionState()
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var isRecordingShortcut = false
    @Published var isExecuting = false
    @Published var executionProgress: ExecutionProgress?
    @Published private var lastExternalApplication: NSRunningApplication?

    private let store: ConfigurationStore
    private var configurationLease: ConfigurationLease?
    var hasConfigurationLease: Bool { configurationLease != nil }
    private let monitor = InputMonitor()
    private let executor = ActionExecutor()
    private var timer: Timer?
    private var workspaceObserver: NSObjectProtocol?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var scheduler = RuleScheduler()
    private var runningTask: Task<Void, Never>?
    private var recorderToken: Any?
    private var recordingTimeout: Task<Void, Never>?
    private var busyRuleID: UUID?
    private var persistedLaunchAtLogin = false
    private var persistenceBlocked = false
    private var pendingRules = RuleExecutionQueue()
    private var previousAutomationEnabled = false
    private var manualActivationTask: Task<Void, Never>?
    private var manualActivationID: UUID?
    private var lastSavedConfiguration: Configuration?

    init(configurationURL: URL? = nil) {
        let url = configurationURL ?? Self.defaultConfigurationURL
        store = ConfigurationStore(url: url)
        var loadError: String?
        do { configurationLease = try ConfigurationLease(configurationURL:url) }
        catch { loadError = "This configuration is unavailable for writing. Automation is disabled in this instance. \(error.localizedDescription)" }
        do { configuration = try store.load() }
        catch { configuration = Configuration(); loadError = "Your saved configuration could not be loaded. The original file was left untouched. \(error.localizedDescription)" }
        if configurationLease == nil {
            configuration.automationEnabled = false
            configuration.allowScripts = false
            for index in configuration.rules.indices { configuration.rules[index].enabled = false }
        }
        if let app = NSWorkspace.shared.frontmostApplication, Self.isRegularTarget(app) { lastExternalApplication = app }
        selection = configuration.rules.first?.id
        persistedLaunchAtLogin = SMAppService.mainApp.status == .enabled
        configuration.launchAtLogin = persistedLaunchAtLogin
        previousAutomationEnabled = configuration.automationEnabled
        errorMessage = loadError
        persistenceBlocked = loadError != nil
        if loadError == nil { lastSavedConfiguration = configuration }
        refreshPermissions()
        monitor.onEvent = { [weak self] event in self?.handle(event) }
        monitor.onStatus = { [weak self] message in self?.statusMessage = message }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let identifier = app.bundleIdentifier ?? ""
            Task { @MainActor in
                guard let self else { return }
                self.scheduler.invalidatePendingShortcuts()
                if Self.isRegularTarget(app) { self.lastExternalApplication = app }
                self.handle(InputEvent(kind: .appActivated, appBundleIdentifier: identifier))
            }
        }
        for (notification, kind) in [(NSWorkspace.didLaunchApplicationNotification, TriggerKind.appLaunched), (NSWorkspace.didTerminateApplicationNotification, TriggerKind.appTerminated)] {
            let token = NSWorkspace.shared.notificationCenter.addObserver(forName:notification,object:nil,queue:.main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let identifier = app.bundleIdentifier, !identifier.isEmpty,
                      identifier != (Bundle.main.bundleIdentifier ?? "io.github.pinguarmy.actionflow"), identifier != "com.apple.loginwindow" else { return }
                // Notification metadata only. Never launch/activate the event source.
                Task { @MainActor in self?.handle(InputEvent(kind:kind,appBundleIdentifier:identifier)) }
            }
            lifecycleObservers.append(token)
        }
        for (notification, transition) in [(NSWorkspace.willSleepNotification, SessionTransition.willSleep), (NSWorkspace.didWakeNotification, SessionTransition.didWake), (NSWorkspace.sessionDidResignActiveNotification, SessionTransition.sessionResigned), (NSWorkspace.sessionDidBecomeActiveNotification, SessionTransition.sessionBecameActive)] {
            let token = NSWorkspace.shared.notificationCenter.addObserver(forName:notification,object:nil,queue:.main) { [weak self] _ in
                Task { @MainActor in self?.handleSessionTransition(transition) }
            }
            lifecycleObservers.append(token)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if configuration.automationEnabled { configureMonitor() }
    }

    static var defaultConfigurationURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ActionFlow", isDirectory: true).appendingPathComponent("configuration.json")
    }
    var selectedRule: AutomationRule? { configuration.rules.first { $0.id == selection } }
    var filteredRules: [AutomationRule] {
        RuleQuery(text:searchText,status:ruleStatusFilter,group:ruleGroupFilter).apply(to:configuration.rules)
    }
    var availableRuleGroups: [String] { RuleQuery.groups(in:configuration.rules) }
    func reconcileRuleSelection() {
        if let selection, !filteredRules.contains(where: { $0.id == selection }) {
            self.selection = nil
            stopRecordingShortcut()
        }
    }
    func clearRuleFilters() {
        searchText = ""
        ruleStatusFilter = .all
        ruleGroupFilter = nil
        reconcileRuleSelection()
    }
    var conflictMessages: [String] { RuleValidator.conflicts(in: configuration.rules) }
    var availableCapabilities: Set<AutomationCapability> {
        var available: Set<AutomationCapability> = []
        if permissions.accessibility { available.insert(.accessibility) }
        if permissions.inputMonitoring { available.insert(.inputMonitoring) }
        if permissions.notifications { available.insert(.notifications) }
        if configuration.allowScripts { available.insert(.scripts) }
        return available
    }
    func requiredCapabilities(for rule: AutomationRule) -> [AutomationCapability] { RuleRequirements.capabilities(for: rule, automatic: true) }
    func missingCapabilities(for rule: AutomationRule, automatic: Bool) -> [AutomationCapability] {
        RuleRequirements.missing(for: rule, automatic: automatic, available: availableCapabilities)
    }

    func addRule() {
        clearRuleFilters()
        let rule = AutomationRule(name: "Untitled rule")
        configuration.rules.append(rule)
        selection = rule.id
        section = .rules
        save()
    }
    func duplicateRule(_ rule: AutomationRule) {
        clearRuleFilters()
        var copy = rule
        copy.id = UUID()
        copy.name += " copy"
        copy.enabled = false
        for i in copy.actions.indices { copy.actions[i].id = UUID() }
        configuration.rules.append(copy)
        selection = copy.id
        save()
    }
    func deleteRule(_ id: UUID) {
        configuration.rules.removeAll { $0.id == id }
        if selection == id { selection = configuration.rules.first?.id }
        save()
    }
    func save() {
        guard hasConfigurationLease else {
            configuration.automationEnabled = false
            configuration.allowScripts = false
            errorMessage = "Saving is disabled in this instance. Close the other instance using this configuration and restart ActionFlow."
            monitor.stop()
            stopExecution()
            return
        }
        guard !persistenceBlocked else {
            configuration.automationEnabled = false
            configuration.allowScripts = false
            errorMessage = "Saving is disabled because the existing configuration could not be read. Export new work to a different file, then recover the original configuration before restarting."
            monitor.stop()
            stopExecution()
            return
        }
        if configuration == lastSavedConfiguration { return }
        // Changes in a live chain never take effect halfway through execution.
        if previousAutomationEnabled && !configuration.automationEnabled { stopExecution() }
        if previousAutomationEnabled != configuration.automationEnabled { scheduler.reset() }
        scheduler.removeStaleRules(configuration.rules)
        previousAutomationEnabled = configuration.automationEnabled
        let previousLoginState = persistedLaunchAtLogin
        if configuration.launchAtLogin != persistedLaunchAtLogin {
            do {
                if configuration.launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
                persistedLaunchAtLogin = configuration.launchAtLogin
            } catch {
                configuration.launchAtLogin = persistedLaunchAtLogin
                errorMessage = "Login item could not be changed: \(error.localizedDescription)"
            }
        }
        do { try store.save(configuration); lastSavedConfiguration = configuration }
        catch {
            var rollbackMessage = ""
            if persistedLaunchAtLogin != previousLoginState {
                do {
                    if previousLoginState { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                    persistedLaunchAtLogin = previousLoginState
                } catch { rollbackMessage = " Login item rollback also failed; review Login Items in System Settings." }
                configuration.launchAtLogin = SMAppService.mainApp.status == .enabled
            }
            configuration.automationEnabled = false
            previousAutomationEnabled = false
            errorMessage = "Could not save configuration. Automation was paused: \(error.localizedDescription)\(rollbackMessage)"
            monitor.stop()
            stopExecution()
            return
        }
        executor.allowScripts = configuration.allowScripts
        configureMonitor()
    }
    func configureMonitor() {
        if hasConfigurationLease && configuration.automationEnabled && permissions.inputMonitoring && SessionSafety.allowsExecution {
            if !monitor.running { monitor.start() }
        } else { monitor.stop() }
    }
    func refreshPermissions() {
        permissions.accessibility = AXIsProcessTrusted()
        permissions.inputMonitoring = CGPreflightListenEventAccess()
        // A command-line harness is not a notification-capable application bundle.
        if Bundle.main.bundleIdentifier != nil {
            Task { [weak self] in
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                self?.permissions.notifications = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            }
        }
        if !permissions.accessibility { statusMessage = "Window and keyboard actions require Accessibility permission." }
        configureMonitorIfReady()
    }
    private func configureMonitorIfReady() { configureMonitor() }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openPrivacyPane("Privacy_Accessibility")
    }
    func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
        openPrivacyPane("Privacy_ListenEvent")
    }
    func requestNotifications() {
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                permissions.notifications = granted
                statusMessage = granted ? "Notifications are authorized." : "Notifications were not authorized. You can change this in System Settings."
            } catch { errorMessage = "Notification permission could not be requested: \(error.localizedDescription)" }
        }
    }
    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
    }
    private static func isRegularTarget(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular && !app.isTerminated && app.bundleIdentifier != Bundle.main.bundleIdentifier && app.bundleIdentifier != "com.apple.loginwindow"
    }
    var manualTargetDescription: String {
        guard let app = lastExternalApplication, Self.isRegularTarget(app) else { return AppLocalization.text("No previous application is available. Switch to the intended target, then return to ActionFlow.") }
        return String(format: AppLocalization.text("%@ will be activated for this manual run."), app.localizedName ?? app.bundleIdentifier ?? "Previous application")
    }
    func runRule(_ rule: AutomationRule) {
        guard hasConfigurationLease else { appendActivity(rule.name,"Not run: this instance does not own the configuration writer lease.",false); return }
        guard SessionSafety.allowsExecution else { appendActivity(rule.name, "Not run: the desktop session is locked or unavailable.", false); return }
        guard !isExecuting, manualActivationTask == nil else { appendActivity(rule.name, "Not run: another action chain is running or preparing.", false); return }
        guard RuleValidator.validate(rule).isEmpty else { appendActivity(rule.name, "Not run: fix rule validation errors first.", false); return }
        let missing = missingCapabilities(for: rule, automatic: false)
        guard missing.isEmpty else { appendActivity(rule.name, "Not run: missing " + missing.map(\.title).joined(separator: ", ") + ". Review Permissions and Settings.", false); return }
        let current = NSWorkspace.shared.frontmostApplication
        let target = current?.bundleIdentifier == Bundle.main.bundleIdentifier ? lastExternalApplication : current
        guard let target, Self.isRegularTarget(target) else {
            appendActivity(rule.name, "Not run: switch to the intended target application, then return to ActionFlow.", false); return
        }
        guard rule.conditions.matches(bundleIdentifier: target.bundleIdentifier ?? "") else { appendActivity(rule.name, "Not run: application conditions do not match the target.", false); return }
        stopRecordingShortcut()
        // Activation is disclosed in the manual-run confirmation. Global rules never refocus a target.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            guard target.activate(options: []) else { appendActivity(rule.name, "The target application could not be activated.", false); return }
        }
        let activationID = UUID()
        manualActivationID = activationID
        isExecuting = true
        manualActivationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.manualActivationID == activationID {
                    self.manualActivationTask = nil; self.manualActivationID = nil
                    if self.runningTask == nil { self.isExecuting = false }
                }
            }
            for _ in 0..<40 {
                guard !Task.isCancelled, self.manualActivationID == activationID else { return }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier { self.execute(rule); return }
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
            }
            self.appendActivity(rule.name, "The target did not become active within two seconds. No actions were run.", false)
        }
    }
    func addTemplate(_ template: RuleTemplate) {
        guard !persistenceBlocked else { errorMessage = "Recover the saved configuration before adding a template."; return }
        // Adding a pack is a persistence operation only, never an execution request.
        let rules = template.makeRules()
        var candidate = configuration
        candidate.rules.append(contentsOf: rules)
        do {
            try store.save(candidate)
            configuration = candidate
            lastSavedConfiguration = candidate
            clearRuleFilters()
            selection = rules.first?.id
            scheduler.removeStaleRules(configuration.rules)
            statusMessage = "Added \(rules.count) disabled template rules. Automation and script settings were not changed."
            errorMessage = nil
        } catch { errorMessage = "Template was not added: \(error.localizedDescription)" }
    }
    @Published var snapshots: [ConfigurationSnapshot] = []
    func refreshSnapshots() {
        do { snapshots = try store.listSnapshots() }
        catch { errorMessage = "Could not read snapshot history: \(error.localizedDescription)" }
    }
    func createSnapshot() {
        guard !persistenceBlocked else { errorMessage = "Recover the saved configuration before creating a snapshot."; return }
        do {
            _ = try store.createSnapshot(configuration: configuration)
            snapshots = try store.listSnapshots()
            statusMessage = "Private configuration snapshot created. No rules were run."
        } catch { errorMessage = "Snapshot failed: \(error.localizedDescription)" }
    }
    func restoreSnapshot(_ snapshot: ConfigurationSnapshot) {
        guard hasConfigurationLease else { errorMessage = "Snapshot restore is disabled in this instance because another writer owns the configuration."; return }
        prepareForRecovery()
        do {
            let restored = try store.restoreSnapshot(id: snapshot.id)
            configuration = restored.configuration
            // OS login registration is external state. Do not silently unregister it.
            configuration.launchAtLogin = SMAppService.mainApp.status == .enabled
            persistedLaunchAtLogin = configuration.launchAtLogin
            previousAutomationEnabled = false
            persistenceBlocked = false
            lastSavedConfiguration = configuration
            executor.allowScripts = false
            selection = configuration.rules.first?.id
            scheduler.reset()
            errorMessage = nil
            statusMessage = "Snapshot restored with every rule disabled." + (restored.preservedCurrentFileURL.map { " Previous file preserved at \($0.lastPathComponent)." } ?? "")
            snapshots = try store.listSnapshots()
        } catch { errorMessage = "Snapshot restore failed: \(error.localizedDescription)" }
    }
    var canRestoreBackup: Bool { FileManager.default.fileExists(atPath: store.backupURL.path) }
    private func prepareForRecovery() {
        // A failed restore must not silently resume the previous live automation.
        configuration.automationEnabled = false
        configuration.allowScripts = false
        executor.allowScripts = false
        previousAutomationEnabled = false
        stopExecution()
        monitor.stop()
        scheduler.reset()
    }
    func restorePreviousBackup() {
        guard hasConfigurationLease else { errorMessage = "Backup restore is disabled in this instance because another writer owns the configuration."; return }
        prepareForRecovery()
        do {
            let restored = try store.restoreBackup()
            configuration = restored.configuration
            configuration.launchAtLogin = SMAppService.mainApp.status == .enabled
            persistedLaunchAtLogin = configuration.launchAtLogin
            previousAutomationEnabled = false
            persistenceBlocked = false
            lastSavedConfiguration = configuration
            executor.allowScripts = false
            selection = configuration.rules.first?.id
            scheduler.reset()
            errorMessage = nil
            statusMessage = "Previous backup restored with every rule disabled." + (restored.preservedCurrentFileURL.map { " Previous file preserved at \($0.lastPathComponent)." } ?? "")
        } catch { errorMessage = "Backup restore failed. Review the saved files before retrying: \(error.localizedDescription)" }
    }
    func revealConfigurationFolder() {
        let directory = store.url.deletingLastPathComponent()
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); NSWorkspace.shared.open(directory) }
        catch { errorMessage = "Could not open the configuration folder: \(error.localizedDescription)" }
    }
    private func execute(_ rule: AutomationRule) {
        guard hasConfigurationLease else { return }
        let errors = RuleValidator.validate(rule)
        guard errors.isEmpty else { appendActivity(rule.name, errors.joined(separator: " "), false); return }
        let missing = missingCapabilities(for: rule, automatic: false)
        guard missing.isEmpty else { appendActivity(rule.name, "Skipped: missing " + missing.map(\.title).joined(separator: ", ") + ". No actions were run.", false); return }
        guard runningTask == nil else { appendActivity(rule.name, "Skipped: another action chain is running.", false); return }
        executor.allowScripts = configuration.allowScripts
        executionProgress = nil
        executor.onProgress = { [weak self] progress in self?.executionProgress = progress }
        busyRuleID = rule.id
        isExecuting = true
        runningTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.runningTask = nil; self.isExecuting = false; self.busyRuleID = nil
                self.executor.onProgress = nil
                self.executionProgress = nil
                self.runNextPending()
            }
            do {
                let result = try await self.executor.execute(rule.actions)
                self.appendActivity(rule.name, result, true, progress: self.executionProgress)
            } catch {
                self.appendActivity(rule.name, error.localizedDescription, false, progress: self.executionProgress)
            }
        }
    }
    func stopExecution() {
        manualActivationTask?.cancel()
        manualActivationTask = nil
        manualActivationID = nil
        if runningTask == nil { isExecuting = false }
        pendingRules.clear()
        executor.cancel()
        runningTask?.cancel()
    }
    private var currentExecutionContext: ExecutionContext {
        let app = NSWorkspace.shared.frontmostApplication
        return ExecutionContext(processIdentifier: app?.processIdentifier, bundleIdentifier: app?.bundleIdentifier ?? "")
    }
    private func eligibleForAutomaticExecution(_ context: ExecutionContext) -> Bool {
        hasConfigurationLease && SessionSafety.allowsExecution && RuleScheduler.canAutomaticallyRun(context: context, editorBundleIdentifier: Bundle.main.bundleIdentifier ?? "io.github.pinguarmy.actionflow",
            automationEnabled: configuration.automationEnabled, isRecording: isRecordingShortcut, isPreparingManualRun: manualActivationTask != nil)
    }
    private func enqueue(_ rule: AutomationRule, context: ExecutionContext) {
        guard eligibleForAutomaticExecution(context), busyRuleID != rule.id else { return }
        if runningTask == nil { execute(rule) }
        else { pendingRules.append(rule, context: context, runningRuleID: busyRuleID) }
    }
    private func runNextPending() {
        let context = currentExecutionContext
        guard eligibleForAutomaticExecution(context) else { pendingRules.clear(); return }
        if let next = pendingRules.next(rules: configuration.rules, context: context) { execute(next) }
    }
    func toggleAutomation() { configuration.automationEnabled.toggle(); save() }
    func clearActivity() { activity.removeAll() }
    private func appendActivity(_ name: String, _ message: String, _ success: Bool, progress: ExecutionProgress? = nil) {
        activity.insert(ActivityEntry(ruleName: name, message: message, success: success, completedActions: progress?.completedActions, totalActions: progress?.actionCount), at: 0)
        if activity.count > 200 { activity.removeLast(activity.count - 200) }
    }
    private func handle(_ event: InputEvent) {
        let context = currentExecutionContext
        guard eligibleForAutomaticExecution(context) else { return }
        let isLifecycle = event.kind == .appLaunched || event.kind == .appTerminated
        if !isLifecycle && !event.appBundleIdentifier.isEmpty && event.appBundleIdentifier.lowercased() != context.bundleIdentifier { return }
        let signal = TriggerSignal(kind: event.kind, keyCode: event.keyCode, modifiers: event.modifiers,
            mouseButton: event.mouseButton, scrollDirection: event.scrollDirection, appBundleIdentifier: event.appBundleIdentifier)
        for rule in scheduler.candidates(for: signal, rules: configuration.rules, context: context, now: ProcessInfo.processInfo.systemUptime) {
            enqueue(rule, context: context)
        }
    }
    func handleSessionTransition(_ transition: SessionTransition) {
        SessionSafety.noteTransition(transition)
        // Wake/activation clears only the corresponding suspension latch. It never
        // rearms rules, timers or input; an explicit user toggle is required.
        let wasEnabled = configuration.automationEnabled
        configuration.automationEnabled = false
        previousAutomationEnabled = false
        stopRecordingShortcut()
        stopExecution()
        monitor.stop()
        scheduler.reset()
        statusMessage = AppLocalization.text("Automation was paused for a sleep or session change. Review your target and resume explicitly when ready.")
        if wasEnabled && !persistenceBlocked {
            do { try store.save(configuration); lastSavedConfiguration = configuration }
            catch { errorMessage = "Automation remains paused in memory, but the paused state could not be saved: \(error.localizedDescription)" }
        }
    }
    private func tick() {
        guard SessionSafety.allowsExecution else {
            monitor.stop()
            scheduler.reset()
            if runningTask != nil || manualActivationTask != nil || pendingRules.count > 0 { stopExecution() }
            return
        }
        if configuration.automationEnabled && permissions.inputMonitoring && !monitor.running { configureMonitor() }
        let context = currentExecutionContext
        guard eligibleForAutomaticExecution(context) else { return }
        for rule in scheduler.intervalCandidates(rules: configuration.rules, context: context, now: ProcessInfo.processInfo.systemUptime) {
            enqueue(rule, context: context)
        }
    }
    func startRecordingShortcut() {
        guard !isRecordingShortcut, selection != nil else { return }
        stopExecution()
        isRecordingShortcut = true
        recorderToken = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            var consume = false
            MainActor.assumeIsolated {
                guard let self else { return }
                consume = true
                guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != actionFlowEventMarker else { return }
                if event.keyCode == 53 { self.stopRecordingShortcut(); return }
                var modifiers: ModifierKeys = []
                if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
                if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
                if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
                if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
                if let index = self.configuration.rules.firstIndex(where: { $0.id == self.selection }) {
                    if self.configuration.rules[index].trigger.kind != .doubleShortcut { self.configuration.rules[index].trigger.kind = .shortcut }
                    self.configuration.rules[index].trigger.keyCode = event.keyCode
                    self.configuration.rules[index].trigger.modifiers = modifiers
                }
                self.stopRecordingShortcut()
                self.save()
            }
            return consume ? nil : event
        }
        recordingTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if !Task.isCancelled { self?.stopRecordingShortcut() }
        }
    }
    func stopRecordingShortcut() {
        if let token = recorderToken { NSEvent.removeMonitor(token) }
        recorderToken = nil
        recordingTimeout?.cancel()
        recordingTimeout = nil
        isRecordingShortcut = false
    }
    func importRules() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var incoming = try store.importConfiguration(from: url)
            // Imports never grant script execution, start automation or enroll a login item.
            incoming.allowScripts = false
            incoming.automationEnabled = false
            incoming.launchAtLogin = configuration.launchAtLogin
            for i in incoming.rules.indices { incoming.rules[i].enabled = false }
            guard !persistenceBlocked else { throw ConfigurationStoreError.invalidConfiguration(["Recover the unreadable saved configuration before importing."]) }
            var candidate = configuration
            var existing = Set(candidate.rules.map(\.id))
            for var rule in incoming.rules {
                if existing.contains(rule.id) { rule.id = UUID() }
                existing.insert(rule.id)
                candidate.rules.append(rule)
            }
            try store.save(candidate)
            configuration = candidate
            lastSavedConfiguration = candidate
            statusMessage = "Imported \(incoming.rules.count) rules, all disabled. Review before enabling."
        } catch { errorMessage = "Import failed. Existing rules were kept. \(error.localizedDescription)" }
    }
    func exportRules() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ActionFlow-rules.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.exportConfiguration(configuration, to: url); statusMessage = "Exported \(configuration.rules.count) rules. Scripts may contain personal data; review before sharing." }
        catch { errorMessage = "Export failed: \(error.localizedDescription)" }
    }
    func shutdown() {
        stopRecordingShortcut()
        stopExecution()
        monitor.stop()
        timer?.invalidate()
        if let token = workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceObserver = nil
        for token in lifecycleObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        lifecycleObservers.removeAll()
        configurationLease?.release()
        configurationLease = nil
    }
}
