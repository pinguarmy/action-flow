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
    @Published var configuration: Configuration {
        didSet {
            // Runs on every in-place edit, so it must stay cheap and must never save.
            // The rules comparison is the only O(n) work; configureMonitor() never mutates configuration.
            guard oldValue.rules != configuration.rules else { return }
            let interest = TriggerInterest(rules: configuration.rules)
            guard interest != triggerInterest else { return }
            triggerInterest = interest
            configureMonitor()
        }
    }
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
    /// Content problems that currently prevent the in-memory configuration from being written.
    @Published private(set) var unsavedIssueCount = 0
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
    /// Every assignment records a configuration that was just loaded or written, which by
    /// construction passed the store's content validation, so no save-blocking issue remains.
    private var lastSavedConfiguration: Configuration? {
        didSet { if unsavedIssueCount != 0 { unsavedIssueCount = 0 } }
    }
    private var autosaveTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?
    private var triggerInterest: TriggerInterest = []
    private var conflictCache: (rules: [AutomationRule], messages: [String])?

    init(configurationURL: URL? = nil) {
        let url = configurationURL ?? Self.defaultConfigurationURL
        store = ConfigurationStore(url: url)
        var loadError: String?
        do { configurationLease = try ConfigurationLease(configurationURL:url) }
        catch { loadError = AppLocalization.format("This configuration is unavailable for writing. Automation is disabled in this instance. %@", AppLocalization.describe(error)) }
        do { configuration = try store.load() }
        catch { configuration = Configuration(); loadError = AppLocalization.format("Your saved configuration could not be loaded. The original file was left untouched. %@", AppLocalization.describe(error)) }
        if configurationLease == nil {
            configuration.automationEnabled = false
            configuration.allowScripts = false
            for index in configuration.rules.indices { configuration.rules[index].enabled = false }
        }
        // `didSet` does not run for assignments inside init; seed the interest before any configureMonitor().
        triggerInterest = TriggerInterest(rules: configuration.rules)
        if let app = NSWorkspace.shared.frontmostApplication, Self.isRegularTarget(app) { lastExternalApplication = app }
        selection = configuration.rules.first?.id
        persistedLaunchAtLogin = SMAppService.mainApp.status == .enabled
        configuration.launchAtLogin = persistedLaunchAtLogin
        previousAutomationEnabled = configuration.automationEnabled
        errorMessage = loadError
        persistenceBlocked = loadError != nil
        if loadError == nil { lastSavedConfiguration = configuration }
        refreshPermissions()
        monitor.onEvent = { [weak self] event in self?.handle(event) ?? false }
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
        timer?.tolerance = 0.2
        // Termination must flush pending edits even when no window (and no SwiftUI observer) is alive.
        // A Task would never run during termination, so run synchronously on the main queue.
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.shutdown()
            }
        }
        if configuration.automationEnabled { configureMonitor() }
    }

    static var defaultConfigurationURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ActionFlow", isDirectory: true).appendingPathComponent("configuration.json")
    }
    var selectedRule: AutomationRule? { configuration.rules.first { $0.id == selection } }
    var filteredRules: [AutomationRule] {
        RuleQuery(text:searchText,status:ruleStatusFilter,group:ruleGroupFilter).apply(to:configuration.rules,
                                                                                         displayText: AppModel.searchableDisplayText)
    }
    /// Text the rule list shows: the localized trigger summary plus localized trigger and action kind titles.
    /// Never includes action content (text, URLs, scripts, bundle identifiers).
    nonisolated private static func searchableDisplayText(_ rule: AutomationRule) -> String {
        var parts = [rule.trigger.localizedSummary, AppLocalization.text(rule.trigger.kind.title)]
        parts.append(contentsOf: rule.actions.map { AppLocalization.text($0.kind.title) })
        return parts.joined(separator: "\n")
    }
    /// Reorders rules in the unfiltered list. Offsets are positions in `configuration.rules`.
    func moveRules(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard hasConfigurationLease else { return }
        configuration.rules.move(fromOffsets: source, toOffset: destination)
        save()
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
    var conflictMessages: [String] {
        // Views read this on every render. Recompute only when the rules change (locale is fixed at launch).
        if let cache = conflictCache, cache.rules == configuration.rules { return cache.messages }
        let messages = RuleValidator.conflictPairs(in: configuration.rules).map { conflict in
            AppLocalization.format("\"%@\" and \"%@\" share %@ in overlapping apps.",
                                   conflict.first.name, conflict.second.name, conflict.first.trigger.localizedSummary)
        }
        conflictCache = (rules: configuration.rules, messages: messages)
        return messages
    }
    /// True when edits exist that are not on disk yet. False when nothing was ever loaded or saved
    /// (that state has its own banner and alert handling).
    var hasUnsavedChanges: Bool {
        guard let lastSavedConfiguration else { return false }
        return lastSavedConfiguration != configuration
    }
    /// Diagnostics/tests: the input kinds the enabled rules currently need.
    var observedInputInterest: TriggerInterest { triggerInterest }
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
        let rule = AutomationRule(name: AppLocalization.text("Untitled rule"))
        configuration.rules.append(rule)
        selection = rule.id
        section = .rules
        save()
    }
    func duplicateRule(_ rule: AutomationRule) {
        clearRuleFilters()
        var copy = rule
        copy.id = UUID()
        copy.name = AppLocalization.format("%@ copy", copy.name)
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
    /// Editor views call this after any edit. Never shows an alert for content issues.
    func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard hasConfigurationLease && !persistenceBlocked else { return }
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self else { return }
            self.autosaveTask = nil
            guard self.hasConfigurationLease && !self.persistenceBlocked else { return }
            self.save()
        }
    }
    /// Save button and Command-S: report why a draft cannot be written yet.
    func saveExplicitly() {
        autosaveTask?.cancel()
        autosaveTask = nil
        save(announcingIssues: true)
    }
    func save(announcingIssues: Bool = false) {
        guard hasConfigurationLease else {
            configuration.automationEnabled = false
            configuration.allowScripts = false
            errorMessage = AppLocalization.text("Saving is disabled in this instance. Close the other instance using this configuration and restart ActionFlow.")
            monitor.stop()
            stopExecution()
            return
        }
        guard !persistenceBlocked else {
            configuration.automationEnabled = false
            configuration.allowScripts = false
            errorMessage = AppLocalization.text("Saving is disabled because the existing configuration could not be read. Export new work to a different file, then recover the original configuration before restarting.")
            monitor.stop()
            stopExecution()
            return
        }
        if configuration == lastSavedConfiguration {
            if unsavedIssueCount != 0 { unsavedIssueCount = 0 }
            return
        }
        let issues = ConfigurationStore.validationErrors(for: configuration)
        if !issues.isEmpty {
            // Nothing is written and nothing is paused: an in-progress draft is not a failure.
            // Login-item changes stay pending until the next successful save. The runtime still
            // follows the in-memory switches, and execute(_:) refuses any invalid rule.
            synchronizeRuntimeWithConfiguration()
            // Only ever lower the flag here (fail closed). execute(_:) reassigns it from the in-memory
            // configuration before each run, so this mainly matters for anything reading it between runs.
            if !configuration.allowScripts { executor.allowScripts = false }
            configureMonitor()
            unsavedIssueCount = issues.count
            if announcingIssues {
                var lines = [AppLocalization.text("Not saved yet. Fix these issues, then save again:")]
                lines.append(contentsOf: issues.prefix(5).map { AppLocalization.validationMessage($0) })
                if issues.count > 5 { lines.append(AppLocalization.format("…and %lld more.", Int64(issues.count - 5))) }
                errorMessage = lines.joined(separator: "\n")
            }
            return
        }
        // Assigned unconditionally: the publish also refreshes views that derive hasUnsavedChanges from
        // the unpublished lastSavedConfiguration once the synchronous write below completes.
        unsavedIssueCount = 0
        synchronizeRuntimeWithConfiguration()
        let previousLoginState = persistedLaunchAtLogin
        if configuration.launchAtLogin != persistedLaunchAtLogin {
            do {
                if configuration.launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
                persistedLaunchAtLogin = configuration.launchAtLogin
            } catch {
                configuration.launchAtLogin = persistedLaunchAtLogin
                errorMessage = AppLocalization.format("Login item could not be changed: %@", AppLocalization.describe(error))
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
                } catch { rollbackMessage = " " + AppLocalization.text("Login item rollback also failed; review Login Items in System Settings.") }
                configuration.launchAtLogin = SMAppService.mainApp.status == .enabled
            }
            configuration.automationEnabled = false
            previousAutomationEnabled = false
            errorMessage = AppLocalization.format("Could not save configuration. Automation was paused: %@", AppLocalization.describe(error)) + rollbackMessage
            monitor.stop()
            stopExecution()
            return
        }
        executor.allowScripts = configuration.allowScripts
        configureMonitor()
    }
    /// Shared by the written and not-written save paths.
    private func synchronizeRuntimeWithConfiguration() {
        // Changes in a live chain never take effect halfway through execution.
        if previousAutomationEnabled && !configuration.automationEnabled { stopExecution() }
        if previousAutomationEnabled != configuration.automationEnabled { scheduler.reset() }
        scheduler.removeStaleRules(configuration.rules)
        previousAutomationEnabled = configuration.automationEnabled
    }
    func configureMonitor() {
        if hasConfigurationLease && configuration.automationEnabled && permissions.inputMonitoring && SessionSafety.allowsExecution
            && triggerInterest.needsInputMonitoring {
            // No-op when already running with the same input interest; recreates the tap otherwise.
            monitor.start(interest: triggerInterest)
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
        // Do not clobber more specific recent status text each time the app becomes active.
        if !permissions.accessibility && statusMessage == nil { statusMessage = AppLocalization.text("Window and keyboard actions require Accessibility permission.") }
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
                statusMessage = AppLocalization.text(granted ? "Notifications are authorized." : "Notifications were not authorized. You can change this in System Settings.")
            } catch { errorMessage = AppLocalization.format("Notification permission could not be requested: %@", AppLocalization.describe(error)) }
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
        return String(format: AppLocalization.text("%@ will be activated for this manual run."), app.localizedName ?? app.bundleIdentifier ?? AppLocalization.text("Previous application"))
    }
    func runRule(_ rule: AutomationRule) {
        guard hasConfigurationLease else { appendActivity(rule.name, AppLocalization.text("Not run: this instance does not own the configuration writer lease."), false); return }
        guard SessionSafety.allowsExecution else { appendActivity(rule.name, AppLocalization.text("Not run: the desktop session is locked or unavailable."), false); return }
        guard !isExecuting, manualActivationTask == nil else { appendActivity(rule.name, AppLocalization.text("Not run: another action chain is running or preparing."), false); return }
        guard RuleValidator.validate(rule).isEmpty else { appendActivity(rule.name, AppLocalization.text("Not run: fix rule validation errors first."), false); return }
        let missing = missingCapabilities(for: rule, automatic: false)
        guard missing.isEmpty else { appendActivity(rule.name, AppLocalization.format("Not run: missing %@. Review Permissions and Settings.", missing.map { AppLocalization.text($0.title) }.joined(separator: ", ")), false); return }
        let current = NSWorkspace.shared.frontmostApplication
        let target = current?.bundleIdentifier == Bundle.main.bundleIdentifier ? lastExternalApplication : current
        guard let target, Self.isRegularTarget(target) else {
            appendActivity(rule.name, AppLocalization.text("Not run: switch to the intended target application, then return to ActionFlow."), false); return
        }
        guard rule.conditions.matches(bundleIdentifier: target.bundleIdentifier ?? "") else { appendActivity(rule.name, AppLocalization.text("Not run: application conditions do not match the target."), false); return }
        stopRecordingShortcut()
        // Activation is disclosed in the manual-run confirmation. Global rules never refocus a target.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            guard target.activate(options: []) else { appendActivity(rule.name, AppLocalization.text("The target application could not be activated."), false); return }
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
            self.appendActivity(rule.name, AppLocalization.text("The target did not become active within two seconds. No actions were run."), false)
        }
    }
    func addTemplate(_ template: RuleTemplate) {
        guard !persistenceBlocked else { errorMessage = AppLocalization.text("Recover the saved configuration before adding a template."); return }
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
            statusMessage = AppLocalization.format("Added %lld disabled template rules. Automation and script settings were not changed.", Int64(rules.count))
            errorMessage = nil
        } catch { errorMessage = AppLocalization.format("Template was not added: %@", AppLocalization.describe(error)) }
    }
    @Published var snapshots: [ConfigurationSnapshot] = []
    func refreshSnapshots() {
        do { snapshots = try store.listSnapshots() }
        catch { errorMessage = AppLocalization.format("Could not read snapshot history: %@", AppLocalization.describe(error)) }
    }
    func createSnapshot() {
        guard !persistenceBlocked else { errorMessage = AppLocalization.text("Recover the saved configuration before creating a snapshot."); return }
        do {
            _ = try store.createSnapshot(configuration: configuration)
            snapshots = try store.listSnapshots()
            statusMessage = AppLocalization.text("Private configuration snapshot created. No rules were run.")
        } catch { errorMessage = AppLocalization.format("Snapshot failed: %@", AppLocalization.describe(error)) }
    }
    func restoreSnapshot(_ snapshot: ConfigurationSnapshot) {
        guard hasConfigurationLease else { errorMessage = AppLocalization.text("Snapshot restore is disabled in this instance because another writer owns the configuration."); return }
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
            statusMessage = AppLocalization.text("Snapshot restored with every rule disabled.") + (restored.preservedCurrentFileURL.map { " " + AppLocalization.format("Previous file preserved at %@.", $0.lastPathComponent) } ?? "")
            snapshots = try store.listSnapshots()
        } catch { errorMessage = AppLocalization.format("Snapshot restore failed: %@", AppLocalization.describe(error)) }
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
        guard hasConfigurationLease else { errorMessage = AppLocalization.text("Backup restore is disabled in this instance because another writer owns the configuration."); return }
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
            statusMessage = AppLocalization.text("Previous backup restored with every rule disabled.") + (restored.preservedCurrentFileURL.map { " " + AppLocalization.format("Previous file preserved at %@.", $0.lastPathComponent) } ?? "")
        } catch { errorMessage = AppLocalization.format("Backup restore failed. Review the saved files before retrying: %@", AppLocalization.describe(error)) }
    }
    func revealConfigurationFolder() {
        let directory = store.url.deletingLastPathComponent()
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); NSWorkspace.shared.open(directory) }
        catch { errorMessage = AppLocalization.format("Could not open the configuration folder: %@", AppLocalization.describe(error)) }
    }
    private func execute(_ rule: AutomationRule) {
        guard hasConfigurationLease else { return }
        let errors = RuleValidator.validate(rule)
        guard errors.isEmpty else { appendActivity(rule.name, errors.map { AppLocalization.validationMessage($0) }.joined(separator: " "), false); return }
        let missing = missingCapabilities(for: rule, automatic: false)
        guard missing.isEmpty else { appendActivity(rule.name, AppLocalization.format("Skipped: missing %@. No actions were run.", missing.map { AppLocalization.text($0.title) }.joined(separator: ", ")), false); return }
        guard runningTask == nil else { appendActivity(rule.name, AppLocalization.text("Skipped: another action chain is running."), false); return }
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
                self.appendActivity(rule.name, AppLocalization.describe(error), false, progress: self.executionProgress)
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
    /// Returns true when the observed key press belongs to an enabled single-press shortcut rule that keeps
    /// it from the active app. Never true unless the input is eligible for automatic execution, so pausing
    /// automation, focusing ActionFlow, recording a shortcut or a locked session always lets keys through.
    @discardableResult
    private func handle(_ event: InputEvent) -> Bool {
        // Skip the scheduler pass for input no enabled rule can match. Mouse and scroll never affect a
        // pending double-shortcut pair, and app activation invalidates pairs in the workspace observer.
        guard triggerInterest.wants(event.kind) else { return false }
        let context = currentExecutionContext
        guard eligibleForAutomaticExecution(context) else { return false }
        let isLifecycle = event.kind == .appLaunched || event.kind == .appTerminated
        if !isLifecycle && !event.appBundleIdentifier.isEmpty && event.appBundleIdentifier.lowercased() != context.bundleIdentifier { return false }
        // Independent of cooldown and running state, so holding an owned chord never leaks repeats.
        let consumes = event.kind == .shortcut && ShortcutInterception.consumes(keyCode: event.keyCode, modifiers: event.modifiers,
            rules: configuration.rules, bundleIdentifier: context.bundleIdentifier)
        // Auto-repeat never triggers a rule or affects a pending double press.
        if event.isRepeat { return consumes }
        let signal = TriggerSignal(kind: event.kind, keyCode: event.keyCode, modifiers: event.modifiers,
            mouseButton: event.mouseButton, scrollDirection: event.scrollDirection, appBundleIdentifier: event.appBundleIdentifier)
        for rule in scheduler.candidates(for: signal, rules: configuration.rules, context: context, now: ProcessInfo.processInfo.systemUptime) {
            enqueue(rule, context: context)
        }
        return consumes
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
            catch { errorMessage = AppLocalization.format("Automation remains paused in memory, but the paused state could not be saved: %@", AppLocalization.describe(error)) }
        }
    }
    private func tick() {
        guard SessionSafety.allowsExecution else {
            monitor.stop()
            scheduler.reset()
            if runningTask != nil || manualActivationTask != nil || pendingRules.count > 0 { stopExecution() }
            return
        }
        if configuration.automationEnabled && permissions.inputMonitoring && triggerInterest.needsInputMonitoring && !monitor.running { configureMonitor() }
        // Follow Accessibility grants and revocations: an active keyboard tap needs Accessibility, and a
        // revoked grant must fall back to listen-only promptly. A no-op inside start(interest:) when the
        // requested mode is unchanged (for example after macOS refused the active tap).
        if monitor.running && triggerInterest.contains(.shortcutInterception) && monitor.interceptsShortcuts != AXIsProcessTrusted() { configureMonitor() }
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
            statusMessage = AppLocalization.format("Imported %lld rules, all disabled. Review before enabling.", Int64(incoming.rules.count))
        } catch { errorMessage = AppLocalization.format("Import failed. Existing rules were kept. %@", AppLocalization.describe(error)) }
    }
    func exportRules() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ActionFlow-rules.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.exportConfiguration(configuration, to: url); statusMessage = AppLocalization.format("Exported %lld rules. Scripts may contain personal data; review before sharing.", Int64(configuration.rules.count)) }
        catch { errorMessage = AppLocalization.format("Export failed: %@", AppLocalization.describe(error)) }
    }
    func shutdown() {
        // Flush pending edits first. Safe to call twice: the lease is released below, so a second call never saves.
        autosaveTask?.cancel()
        autosaveTask = nil
        if hasConfigurationLease && !persistenceBlocked && hasUnsavedChanges { save() }
        if let token = terminationObserver { NotificationCenter.default.removeObserver(token) }
        terminationObserver = nil
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
