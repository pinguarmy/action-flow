import SwiftUI
import ActionFlowCore

struct PermissionsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeading(
                    eyebrow: "MACOS PRIVACY",
                    title: "Permission, not guesswork.",
                    subtitle: "Grant only what your rules need. ActionFlow does not request access until you choose to allow it."
                )
                PermissionRow(
                    symbol: "accessibility",
                    title: "Accessibility",
                    explanation: "Move and resize windows, send keyboard shortcuts and insert text into other apps.",
                    granted: model.permissions.accessibility,
                    action: model.requestAccessibility
                )
                PermissionRow(
                    symbol: "keyboard",
                    title: "Input Monitoring",
                    explanation: "Observe global keyboard, mouse button and scroll triggers. Events continue to reach the original app.",
                    granted: model.permissions.inputMonitoring,
                    action: model.requestInputMonitoring
                )
                PermissionRow(
                    symbol: "bell",
                    title: "Notifications",
                    explanation: "Show notification action messages through macOS. This permission is optional and is requested only when you choose to allow it.",
                    granted: model.permissions.notifications,
                    requestTitle: "Allow notifications…",
                    action: model.requestNotifications
                )
                ForgePanel {
                    Label("You stay in control", systemImage: "lock.shield")
                        .font(.headline)
                    Text("Rules and scripts live on this Mac. Global input is matched against your enabled rules, not saved as a keystroke log. Automation and scripts start off.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForgeNote(text: "If macOS does not show a permission change immediately, refresh the status. A relaunch may be required after granting Input Monitoring.")
                }
                HStack {
                    Button(action: model.refreshPermissions) {
                        Label("Refresh status", systemImage: "arrow.clockwise")
                    }
                    Spacer()
                    Button("Back to rules") { model.section = .rules }
                }
            }
            .padding(30)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .onAppear { model.refreshPermissions() }
    }
}

private struct PermissionRow: View {
    let symbol: String
    let title: String
    let explanation: String
    let granted: Bool
    var requestTitle: String? = nil
    let action: () -> Void

    var body: some View {
        ForgePanel {
            HStack(alignment: .top, spacing: 15) {
                Image(systemName: symbol)
                    .font(.system(size: 25, weight: .regular))
                    .foregroundStyle(ForgeStyle.accent)
                    .frame(width: 37)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text(AppLocalization.text(title)).font(.headline)
                        Spacer()
                        Label(AppLocalization.text(granted ? "Granted" : "Not granted"), systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(granted ? ForgeStyle.accent : .orange)
                    }
                    Text(AppLocalization.text(explanation)).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !granted {
                        Button(requestTitle.map { AppLocalization.text($0) } ?? String(format: AppLocalization.text("Open %@ settings…"), AppLocalization.text(title)), action: action)
                            .padding(.top, 3)
                    }
                }
            }
        }
    }
}

struct ActivityView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                PageHeading(
                    eyebrow: "EXECUTION HISTORY",
                    title: "See what happened.",
                    subtitle: "Recent results from this session. No background key logging."
                )
                Spacer()
                if model.isExecuting {
                    Button("Stop actions", action: model.stopExecution)
                }
                Button("Clear…") { confirmClear = true }
                    .disabled(model.activity.isEmpty)
            }
            .padding(28)
            Divider()
            if model.activity.isEmpty {
                ForgeEmptyState(
                    symbol: "clock.arrow.circlepath",
                    title: "No activity yet",
                    message: "When a rule runs, its result appears here. You can run a rule explicitly from its editor."
                ) {
                    Button("View rules") { model.section = .rules }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.activity) { entry in
                            activityRow(entry)
                            Divider().padding(.leading, 63)
                        }
                    }
                    .padding(.horizontal, 25)
                    .padding(.vertical, 10)
                }
            }
            HStack {
                Text("Up to 200 results, kept for this session only.")
                Spacer()
                Text("\(model.activity.count) results").monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(16)
        }
        .confirmationDialog("Clear this session's activity?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear activity", role: .destructive, action: model.clearActivity)
        } message: {
            Text("Your rules and saved configuration will not change.")
        }
    }

    private func activityRow(_ entry: ActivityEntry) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: entry.success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(entry.success ? ForgeStyle.accent : .orange)
                .frame(width: 24)
                .padding(.top, 2)
                .accessibilityLabel(AppLocalization.text(entry.success ? "Success" : "Not completed"))
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.ruleName).font(.callout.weight(.semibold))
                    Spacer()
                    Text(entry.date, format: .dateTime.hour().minute().second())
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if let completed = entry.completedActions, let total = entry.totalActions {
                    Text(String(format: AppLocalization.text("Completed %lld of %lld actions"), Int64(completed), Int64(total)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(entry.message)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 16)
        .accessibilityElement(children: .combine)
    }
}

struct AppSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmScripts = false
    @State private var confirmRestore = false
    @State private var pendingSnapshot: ConfigurationSnapshot?

    private var scriptBinding: Binding<Bool> {
        Binding(
            get: { model.configuration.allowScripts },
            set: { enabled in
                if enabled { confirmScripts = true }
                else { model.configuration.allowScripts = false; model.save() }
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeading(
                    eyebrow: "PREFERENCES",
                    title: "Local by default.",
                    subtitle: "Control when ActionFlow runs and what your rules are allowed to do."
                )
                ForgePanel {
                    Text("General").font(.headline)
                    Toggle("Launch ActionFlow at login", isOn: $model.configuration.launchAtLogin)
                        .onChange(of: model.configuration.launchAtLogin) { _, _ in model.save() }
                    ForgeNote(text: "macOS manages login items. Registration requires a properly installed application bundle.")
                    Divider()
                    Toggle("Enable automation", isOn: $model.configuration.automationEnabled)
                    ForgeNote(text: "When paused, rules do not run automatically. Run now remains available as an explicit, confirmed action.")
                }
                ForgePanel {
                    HStack {
                        Label("Script execution", systemImage: "terminal").font(.headline)
                        Spacer()
                        Text(AppLocalization.text(model.configuration.allowScripts ? "ALLOWED" : "BLOCKED"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(model.configuration.allowScripts ? .orange : .secondary)
                    }
                    Toggle("Allow shell script actions", isOn: scriptBinding)
                    ForgeNote(text: "Scripts run as your macOS user and can change or delete files. Enable this only for commands you have reviewed and trust.", symbol: "exclamationmark.shield", warning: true)
                    Text("Importing rules never grants script permission. Script contents are included when you export configuration.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForgePanel {
                    Label("Configuration", systemImage: "externaldrive").font(.headline)
                    Text("Rules are saved as versioned JSON in Application Support. A backup is preserved when the configuration is replaced.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Import rules…", action: model.importRules)
                        Button("Export configuration…", action: model.exportRules)
                    }
                    ForgeNote(text: "Imported rules are added disabled. Existing rules are kept. Review exported text and scripts before sharing.")
                }
                ForgePanel {
                    Label("Backup and recovery", systemImage: "clock.arrow.circlepath").font(.headline)
                    HStack(spacing: 7) {
                        Image(systemName: model.canRestoreBackup ? "checkmark.circle" : "info.circle")
                            .foregroundStyle(model.canRestoreBackup ? ForgeStyle.accent : Color.secondary)
                        Text(AppLocalization.text(model.canRestoreBackup ? "A previous configuration backup is available." : "No previous configuration backup is available."))
                            .font(.callout)
                    }
                    Text("Restoring replaces your current configuration. ActionFlow keeps a separate copy of the current configuration before restoring and leaves the original backup unchanged.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            restoreButton
                            configurationFolderButton
                        }
                        VStack(alignment: .leading, spacing: 9) {
                            restoreButton
                            configurationFolderButton
                        }
                    }
                    ForgeNote(text: "Restored rules stay disabled. Automation is paused and shell scripts are blocked until you explicitly enable them.", symbol: "lock.shield")
                }
                snapshotHistoryPanel
                HStack(spacing: 7) {
                    Image(systemName: "cursorarrow.motionlines").foregroundStyle(ForgeStyle.accent)
                    Text("ActionFlow").fontWeight(.semibold)
                    Text("Independent macOS automation").foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(.top, 2)
            }
            .padding(30)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .onAppear { model.refreshSnapshots() }
        .alert("Restore this snapshot?", isPresented: Binding(
            get: { pendingSnapshot != nil },
            set: { if !$0 { pendingSnapshot = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingSnapshot = nil }
            Button(AppLocalization.text("Restore snapshot"), role: .destructive) {
                if let snapshot = pendingSnapshot { model.restoreSnapshot(snapshot) }
                pendingSnapshot = nil
            }
        } message: {
            Text(AppLocalization.text("This replaces your current configuration. Its exact current bytes are preserved in a separate recovery copy. All restored rules will be disabled, automation will be paused and scripts will be blocked. Restoring does not enable launch at login; any existing macOS login registration is kept. The snapshot is unchanged."))
        }
        .alert("Allow shell scripts?", isPresented: $confirmScripts) {
            Button("Keep blocked", role: .cancel) {}
            Button("Allow scripts", role: .destructive) {
                model.configuration.allowScripts = true
                model.save()
            }
        } message: {
            Text("Scripts have your account's access to files and apps. Only enable scripts you understand. This setting applies to every script action in your rules.")
        }
        .alert("Restore the previous backup?", isPresented: $confirmRestore) {
            Button("Cancel", role: .cancel) {}
            Button("Restore backup", role: .destructive, action: model.restorePreviousBackup)
        } message: {
            Text("This replaces all current rules and configuration with the previous backup. Your current configuration is preserved in a separate pre-restore copy. All restored rules will be disabled, automation will be paused and scripts will be blocked. The original backup will not be overwritten.")
        }
    }

    private var snapshotHistoryPanel: some View {
        ForgePanel {
            HStack {
                Label(AppLocalization.text("Private snapshots"), systemImage: "square.stack.3d.up")
                    .font(.headline)
                Spacer(minLength: 8)
                Text(String(format: AppLocalization.text("%lld of 10 saved"), Int64(model.snapshots.count)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ForgeNote(text: "Save a private copy before making changes. Snapshots contain your full configuration, including text and scripts; no content is shown here.", symbol: "lock.shield")
            HStack {
                Button(action: model.createSnapshot) {
                    Label(AppLocalization.text("Snapshot current configuration"), systemImage: "plus")
                }
                .disabled(model.snapshots.count >= 10)
                Spacer(minLength: 8)
                Button(action: model.refreshSnapshots) {
                    Label(AppLocalization.text("Refresh snapshots"), systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .help(AppLocalization.text("Refresh snapshots"))
                .accessibilityLabel(AppLocalization.text("Refresh snapshots"))
            }
            if model.snapshots.isEmpty {
                Text(AppLocalization.text("No snapshots yet. Create one to keep this configuration for later."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.snapshots) { snapshot in
                        if snapshot.id != model.snapshots.first?.id { Divider() }
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(snapshot.createdAt, format: .dateTime.year().month(.abbreviated).day().hour().minute().second())
                                    .font(.callout)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(snapshot.byteCount), countStyle: .file))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button(AppLocalization.text("Restore…")) { pendingSnapshot = snapshot }
                                .controlSize(.small)
                                .accessibilityLabel(String(format: AppLocalization.text("Restore snapshot from %@"), snapshot.createdAt.formatted()))
                        }
                        .padding(.vertical, 10)
                    }
                }
            }
            ForgeNote(
                text: model.snapshots.count >= 10 ? "Snapshot limit reached. No snapshots are deleted automatically. Manage copies in the configuration folder before creating another." : "Up to 10 snapshots are kept. Existing snapshots are never deleted automatically.",
                symbol: model.snapshots.count >= 10 ? "exclamationmark.circle" : "info.circle",
                warning: model.snapshots.count >= 10
            )
        }
    }

    private var restoreButton: some View {
        Button("Restore previous backup…") { confirmRestore = true }
            .disabled(!model.canRestoreBackup)
            .help("Replace the current configuration with the previous backup after confirmation")
    }

    private var configurationFolderButton: some View {
        Button(action: model.revealConfigurationFolder) {
            Label("Show configuration folder", systemImage: "folder")
        }
        .help("Reveal configuration and backup files in Finder")
    }
}

private struct PageHeading: View {
    let eyebrow: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(AppLocalization.text(eyebrow))
                .font(.system(size: 10, weight: .semibold))
                .tracking(1)
                .foregroundStyle(ForgeStyle.accent)
            Text(AppLocalization.text(title)).font(.system(size: 27, weight: .semibold))
            Text(AppLocalization.text(subtitle)).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
