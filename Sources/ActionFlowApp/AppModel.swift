import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import ActionFlowCore
import ServiceManagement
import SwiftUI
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published var configuration: Configuration {
        didSet {
            // Runs on every in-place edit, so it must stay cheap and must never save.
            // The rules comparison is the only O(n) work; configureMonitor() never mutates configuration.
            let rulesChanged = oldValue.rules != configuration.rules
            guard rulesChanged || oldValue.automationEnabled != configuration.automationEnabled else { return }
            // Also rebuilds the interception index when the rules changed.
            let interestChanged = rulesChanged && router.refreshInterest(rules: configuration.rules)
            if interestChanged { configureMonitor() } else { pushInterceptionSnapshot() }
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
    private let router = TriggerRouter()
    private let coordinator = RuleExecutionCoordinator()
    private let recorder = ShortcutRecorder()
    private let systemEvents = SystemEventObserver()
    private var persistedLaunchAtLogin = false
    private var persistenceBlocked = false
    private var previousAutomationEnabled = false
    /// Every assignment records a configuration that was just loaded or written, which by
    /// construction passed the store's content validation, so no save-blocking issue remains.
    private var lastSavedConfiguration: Configuration? {
        didSet { if unsavedIssueCount != 0 { unsavedIssueCount = 0 } }
    }
    private var autosaveTask: Task<Void, Never>?
    private var conflictCache: (rules: [AutomationRule], pairs: [RuleConflict], ruleIDs: Set<UUID>)?
    private var backupRotation = BackupRotationPolicy()

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
        router.refreshInterest(rules: configuration.rules)
        if let app = NSWorkspace.shared.frontmostApplication, Self.isRegularTarget(app) { lastExternalApplication = app }
        selection = configuration.rules.first?.id
        persistedLaunchAtLogin = SMAppService.mainApp.status == .enabled
        configuration.launchAtLogin = persistedLaunchAtLogin
        previousAutomationEnabled = configuration.automationEnabled
        errorMessage = loadError
        persistenceBlocked = loadError != nil
        if loadError == nil { lastSavedConfiguration = configuration }
        refreshPermissions()
        router.onEvent = { [weak self] event in self?.handle(event) ?? false }
        router.onStatus = { [weak self] message in self?.statusMessage = message }
        coordinator.rules = { [weak self] in self?.configuration.rules ?? [] }
        coordinator.hasConfigurationLease = { [weak self] in self?.hasConfigurationLease ?? false }
        coordinator.allowsScripts = { [weak self] in self?.configuration.allowScripts ?? false }
        coordinator.missingCapabilities = { [weak self] rule in self?.missingCapabilities(for: rule, automatic: false) ?? [] }
        coordinator.isEligibleForAutomaticExecution = { [weak self] context in self?.eligibleForAutomaticExecution(context) ?? false }
        coordinator.currentProgress = { [weak self] in self?.executionProgress }
        coordinator.publishExecuting = { [weak self] value in self?.isExecuting = value }
        coordinator.publishProgress = { [weak self] value in self?.executionProgress = value }
        coordinator.onPreparationChanged = { [weak self] in self?.pushInterceptionSnapshot() }
        coordinator.recordActivity = { [weak self] name, message, success, progress in
            self?.appendActivity(name, message, success, progress: progress)
        }
        systemEvents.onApplicationActivated = { [weak self] app, identifier in
            guard let self else { return }
            self.router.invalidatePendingShortcuts()
            if Self.isRegularTarget(app) { self.lastExternalApplication = app }
            // The frontmost app changed: the keyboard interceptor decides against the new one from now on.
            self.pushInterceptionSnapshot(frontmost: app)
            self.handle(InputEvent(kind: .appActivated, appBundleIdentifier: identifier))
        }
        systemEvents.onApplicationLifecycle = { [weak self] kind, identifier in
            self?.handle(InputEvent(kind: kind, appBundleIdentifier: identifier))
        }
        systemEvents.onSessionTransition = { [weak self] transition in self?.handleSessionTransition(transition) }
        systemEvents.onTick = { [weak self] in self?.tick() }
        systemEvents.onWillTerminate = { [weak self] in self?.shutdown() }
        systemEvents.start()
        pushInterceptionSnapshot()
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
    /// Views read the conflicts on every render. Recompute only when the rules change.
    private var conflictPairs: [RuleConflict] {
        refreshConflictCache().pairs
    }
    private func refreshConflictCache() -> (pairs: [RuleConflict], ruleIDs: Set<UUID>) {
        if let cache = conflictCache, cache.rules == configuration.rules { return (cache.pairs, cache.ruleIDs) }
        let pairs = RuleValidator.conflictPairs(in: configuration.rules)
        var ids = Set<UUID>()
        for pair in pairs { ids.insert(pair.first.id); ids.insert(pair.second.id) }
        conflictCache = (rules: configuration.rules, pairs: pairs, ruleIDs: ids)
        return (pairs, ids)
    }
    var conflictMessages: [String] {
        // Locale is fixed at launch, so the pair cache is enough.
        conflictPairs.map { conflict in
            AppLocalization.format("\"%@\" and \"%@\" share %@ in overlapping apps.",
                                   conflict.first.name, conflict.second.name, conflict.first.trigger.localizedSummary)
        }
    }
    /// Conflicts among enabled rules that involve the given rule, in validator order.
    func conflicts(involving ruleID: UUID) -> [RuleConflict] {
        conflictPairs.filter { $0.first.id == ruleID || $0.second.id == ruleID }
    }
    /// Read once per rule row on every render, so it is cached with the pairs.
    var conflictingRuleIDs: Set<UUID> {
        refreshConflictCache().ruleIDs
    }
    /// True when edits exist that are not on disk yet. False when nothing was ever loaded or saved
    /// (that state has its own banner and alert handling).
    var hasUnsavedChanges: Bool {
        guard let lastSavedConfiguration else { return false }
        return lastSavedConfiguration != configuration
    }
    /// Diagnostics/tests: the input kinds the enabled rules currently need.
    var observedInputInterest: TriggerInterest { router.interest }
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
    /// Shared by the rule list switch and its context menu. The caller applies the same gating.
    func setRule(_ id: UUID, enabled: Bool) {
        guard let index = configuration.rules.firstIndex(where: { $0.id == id }) else { return }
        guard configuration.rules[index].enabled != enabled else { return }
        configuration.rules[index].enabled = enabled
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
            router.stopMonitor()
            stopExecution()
            return
        }
        guard !persistenceBlocked else {
            configuration.automationEnabled = false
            configuration.allowScripts = false
            errorMessage = AppLocalization.text("Saving is disabled because the existing configuration could not be read. Export new work to a different file, then recover the original configuration before restarting.")
            router.stopMonitor()
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
            if !configuration.allowScripts { coordinator.allowScripts = false }
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
        do { try writeConfiguration(configuration); lastSavedConfiguration = configuration }
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
            router.stopMonitor()
            stopExecution()
            return
        }
        coordinator.allowScripts = configuration.allowScripts
        configureMonitor()
    }
    /// The backup rotation rules (first write of the session, then at most every 10 minutes, always for
    /// imports and templates) live in `BackupRotationPolicy`.
    private func writeConfiguration(_ configuration: Configuration, forceBackupRotation: Bool = false) throws {
        let now = ProcessInfo.processInfo.systemUptime
        let rotate = backupRotation.shouldRotate(now: now, forced: forceBackupRotation)
        try store.save(configuration, rotatingBackup: rotate)
        if rotate { backupRotation.recordRotation(at: now) }
    }
    /// Shared by the written and not-written save paths.
    private func synchronizeRuntimeWithConfiguration() {
        // Changes in a live chain never take effect halfway through execution.
        if previousAutomationEnabled && !configuration.automationEnabled { stopExecution() }
        if previousAutomationEnabled != configuration.automationEnabled { router.reset() }
        router.removeStaleRules(configuration.rules)
        previousAutomationEnabled = configuration.automationEnabled
    }
    func configureMonitor() {
        // The snapshot must be current before an active keyboard tap can start deciding with it.
        pushInterceptionSnapshot()
        router.reconfigure(canRun: hasConfigurationLease && configuration.automationEnabled && permissions.inputMonitoring && SessionSafety.allowsExecution)
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
        guard !isExecuting, !coordinator.isPreparingManualRun else { appendActivity(rule.name, AppLocalization.text("Not run: another action chain is running or preparing."), false); return }
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
        coordinator.beginManualRun(rule, target: target)
    }
    func addTemplate(_ template: RuleTemplate) {
        guard !persistenceBlocked else { errorMessage = AppLocalization.text("Recover the saved configuration before adding a template."); return }
        // Adding a pack is a persistence operation only, never an execution request.
        let rules = template.makeRules()
        var candidate = configuration
        candidate.rules.append(contentsOf: rules)
        do {
            try writeConfiguration(candidate, forceBackupRotation: true)
            configuration = candidate
            lastSavedConfiguration = candidate
            clearRuleFilters()
            selection = rules.first?.id
            router.removeStaleRules(configuration.rules)
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
            coordinator.allowScripts = false
            selection = configuration.rules.first?.id
            router.reset()
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
        coordinator.allowScripts = false
        previousAutomationEnabled = false
        stopExecution()
        router.stopMonitor()
        router.reset()
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
            coordinator.allowScripts = false
            selection = configuration.rules.first?.id
            router.reset()
            errorMessage = nil
            statusMessage = AppLocalization.text("Previous backup restored with every rule disabled.") + (restored.preservedCurrentFileURL.map { " " + AppLocalization.format("Previous file preserved at %@.", $0.lastPathComponent) } ?? "")
        } catch { errorMessage = AppLocalization.format("Backup restore failed. Review the saved files before retrying: %@", AppLocalization.describe(error)) }
    }
    func revealConfigurationFolder() {
        let directory = store.url.deletingLastPathComponent()
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); NSWorkspace.shared.open(directory) }
        catch { errorMessage = AppLocalization.format("Could not open the configuration folder: %@", AppLocalization.describe(error)) }
    }
    func stopExecution() { coordinator.stop() }
    private var currentExecutionContext: ExecutionContext { RuleExecutionCoordinator.currentContext }
    private func eligibleForAutomaticExecution(_ context: ExecutionContext) -> Bool {
        // The same function the keyboard interceptor's snapshot uses, so both can never disagree.
        InterceptionSnapshot.isEligible(context: context, editorBundleIdentifier: Self.editorBundleIdentifier,
                                        automaticExecutionAllowed: automaticExecutionAllowed)
    }
    private static var editorBundleIdentifier: String { Bundle.main.bundleIdentifier ?? "io.github.pinguarmy.actionflow" }
    /// Lease, session safety, automation switch, no recording and no manual-run preparation.
    private var automaticExecutionAllowed: Bool {
        hasConfigurationLease && SessionSafety.allowsExecution && configuration.automationEnabled
            && !isRecordingShortcut && !coordinator.isPreparingManualRun
    }
    /// Diagnostics/tests: the snapshot most recently handed to the keyboard interceptor.
    private(set) var currentInterceptionSnapshot = InterceptionSnapshot.blocked
    /// Builds and pushes everything the background keyboard interceptor needs to decide whether a key press
    /// is kept. Cheap and never saves; called whenever an input changes and once per tick. A snapshot
    /// that lags a state change by one main-thread turn can only delay a consume decision, never invent one.
    private func pushInterceptionSnapshot(frontmost: NSRunningApplication? = nil) {
        let app = frontmost ?? NSWorkspace.shared.frontmostApplication
        let snapshot = InterceptionSnapshot(index: router.interceptionIndex, automaticExecutionAllowed: automaticExecutionAllowed,
                                            editorBundleIdentifier: Self.editorBundleIdentifier,
                                            frontmostProcessIdentifier: app?.processIdentifier, frontmostBundleIdentifier: app?.bundleIdentifier ?? "")
        currentInterceptionSnapshot = snapshot
        router.updateInterception(snapshot)
    }
    func toggleAutomation() { configuration.automationEnabled.toggle(); save() }
    func clearActivity() { activity.removeAll() }
    private func appendActivity(_ name: String, _ message: String, _ success: Bool, progress: ExecutionProgress? = nil) {
        ActivityLog.prepend(ActivityEntry(ruleName: name, message: message, success: success, completedActions: progress?.completedActions, totalActions: progress?.actionCount), to: &activity)
    }
    /// Returns true when the observed key press belongs to an enabled single-press shortcut rule that keeps
    /// it from the active app. Never true unless the input is eligible for automatic execution, so pausing
    /// automation, focusing ActionFlow, recording a shortcut or a locked session always lets keys through.
    @discardableResult
    private func handle(_ event: InputEvent) -> Bool {
        let routed = router.route(event, rules: configuration.rules, currentContext: { self.currentExecutionContext },
                                  isEligible: { self.eligibleForAutomaticExecution($0) })
        for rule in routed.candidates {
            coordinator.enqueue(rule, context: routed.context)
        }
        return routed.consumes
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
        router.stopMonitor()
        router.reset()
        pushInterceptionSnapshot()
        statusMessage = AppLocalization.text("Automation was paused for a sleep or session change. Review your target and resume explicitly when ready.")
        if wasEnabled && !persistenceBlocked {
            do { try writeConfiguration(configuration); lastSavedConfiguration = configuration }
            catch { errorMessage = AppLocalization.format("Automation remains paused in memory, but the paused state could not be saved: %@", AppLocalization.describe(error)) }
        }
    }
    private func tick() {
        // Safety net: repairs any input change that did not push a snapshot itself (for example a screen lock).
        pushInterceptionSnapshot()
        guard SessionSafety.allowsExecution else {
            router.stopMonitor()
            router.reset()
            if coordinator.hasActiveWork { stopExecution() }
            return
        }
        if configuration.automationEnabled && permissions.inputMonitoring && router.interest.needsInputMonitoring && !router.running { configureMonitor() }
        // Follow Accessibility grants and revocations: an active keyboard tap needs Accessibility, and a
        // revoked grant must fall back to listen-only promptly. A no-op inside start(interest:) when the
        // requested mode is unchanged (for example after macOS refused the active tap).
        if router.running && router.interest.contains(.shortcutInterception) && router.interceptsShortcuts != AXIsProcessTrusted() { configureMonitor() }
        let context = currentExecutionContext
        guard eligibleForAutomaticExecution(context) else { return }
        for rule in router.intervalCandidates(rules: configuration.rules, context: context) {
            coordinator.enqueue(rule, context: context)
        }
    }
    func startRecordingShortcut() {
        guard !isRecordingShortcut, selection != nil else { return }
        stopExecution()
        isRecordingShortcut = true
        pushInterceptionSnapshot()
        recorder.start(onRecorded: { [weak self] keyCode, modifiers in
            guard let self else { return }
            if let index = self.configuration.rules.firstIndex(where: { $0.id == self.selection }) {
                if self.configuration.rules[index].trigger.kind != .doubleShortcut { self.configuration.rules[index].trigger.kind = .shortcut }
                self.configuration.rules[index].trigger.keyCode = keyCode
                self.configuration.rules[index].trigger.modifiers = modifiers
            }
            self.stopRecordingShortcut()
            self.save()
        }, onEnd: { [weak self] in
            self?.stopRecordingShortcut()
        })
    }
    func stopRecordingShortcut() {
        recorder.stop()
        isRecordingShortcut = false
        pushInterceptionSnapshot()
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
            try writeConfiguration(candidate, forceBackupRotation: true)
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
        systemEvents.stopObservingTermination()
        stopRecordingShortcut()
        stopExecution()
        // Nothing may be kept from any app once the lease is gone, even before the monitor has stopped.
        currentInterceptionSnapshot = .blocked
        router.updateInterception(.blocked)
        router.stopMonitor()
        systemEvents.invalidate()
        configurationLease?.release()
        configurationLease = nil
    }
}
