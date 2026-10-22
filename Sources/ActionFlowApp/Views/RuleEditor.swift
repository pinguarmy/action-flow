import SwiftUI
import ActionFlowCore

struct RuleEditor: View {
    @EnvironmentObject private var model: AppModel
    @Binding var rule: AutomationRule
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    @State private var showAdvanced = false
    @State private var confirmRun = false
    @State private var showPreview = false
    @State private var previewPlan: ExecutionPlan?

    private var errors: [String] { RuleValidator.validate(rule) }
    private var usesScript: Bool { rule.actions.contains(where: { $0.kind == .shellScript }) }
    private var requiredCapabilities: [AutomationCapability] { model.requiredCapabilities(for: rule) }
    private var missingAutomaticCapabilities: [AutomationCapability] { model.missingCapabilities(for: rule, automatic: true) }
    private var missingManualCapabilities: [AutomationCapability] { model.missingCapabilities(for: rule, automatic: false) }
    private var missingManualSummary: String { missingManualCapabilities.map { AppLocalization.text($0.title) }.joined(separator: ", ") }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !rule.enabled || !model.configuration.automationEnabled {
                        ForgeNote(
                            text: !rule.enabled ? "This rule is disabled. Enable it when you are ready." : "Automation is paused. This rule will run when automation is enabled.",
                            symbol: "pause.circle"
                        )
                        .padding(.bottom, 22)
                    }
                    prerequisitesPanel
                        .padding(.bottom, 22)
                    FlowSection(number: "01", title: "When this happens", subtitle: "Choose the input that starts this rule.") {
                        triggerEditor
                    }
                    FlowSection(number: "02", title: "Only in these apps", subtitle: "Optional conditions for the frontmost application.") {
                        conditionsEditor
                    }
                    FlowSection(number: "03", title: "Do this", subtitle: "Actions run in order, from top to bottom.", isLast: true) {
                        actionsEditor
                    }
                    if !errors.isEmpty {
                        messagePanel(title: "Review before running", messages: errors, warning: true)
                            .padding(.top, 22)
                    }
                    if !model.conflictMessages.isEmpty {
                        DisclosureGroup {
                            ForEach(Array(model.conflictMessages.enumerated()), id: \.offset) { _, message in
                                ForgeNote(text: message, symbol: "exclamationmark.triangle", warning: true, localizesText: false)
                                    .padding(.vertical, 3)
                            }
                        } label: {
                            Label("Potential rule conflicts", systemImage: "exclamationmark.triangle")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.orange)
                        }
                        .padding(.top, 20)
                    }
                    DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                        ForgePanel {
                            EditorField(title: "Group") {
                                TextField("My rules", text: $rule.group)
                                    .textFieldStyle(.roundedBorder)
                            }
                            EditorField(title: "Minimum time between runs") {
                                HStack {
                                    TextField("Seconds", value: $rule.cooldown, format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 90)
                                        .accessibilityLabel("Cooldown in seconds")
                                    Text("seconds").foregroundStyle(.secondary)
                                    Spacer()
                                }
                            }
                            ForgeNote(text: "A cooldown prevents repeated input from starting the same rule too often.")
                        }
                        .padding(.top, 10)
                    }
                    .font(.callout)
                    .padding(.top, 24)
                }
                .padding(24)
                .frame(maxWidth: 780)
                .frame(maxWidth: .infinity)
            }
            .onSubmit { model.save() }
            Divider()
            footer
        }
        .confirmationDialog("Run this action chain now?", isPresented: $confirmRun, titleVisibility: .visible) {
            Button(AppLocalization.text(usesScript ? "Run actions including script" : "Run actions")) {
                model.save()
                model.runRule(rule)
            }
            .disabled(!model.hasConfigurationLease || !errors.isEmpty || !missingManualCapabilities.isEmpty)
        } message: {
            Text("Target: \(model.manualTargetDescription)\n\nThis is a real run, even if the rule or automation is disabled. Actions may change the target app, open apps or URLs, or run allowed scripts. App conditions still apply.")
        }
        .sheet(isPresented: $showPreview) {
            if let previewPlan {
                ExecutionPlanPreview(plan: previewPlan)
            }
        }
        .onChange(of: rule.enabled) { _, _ in model.save() }
        .onDisappear {
            model.stopRecordingShortcut()
            model.save()
        }
    }

    private var prerequisitesPanel: some View {
        ForgePanel {
            HStack(alignment: .firstTextBaseline) {
                Label("Required for this rule", systemImage: "checklist")
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 8)
                Text(missingAutomaticCapabilities.isEmpty ? AppLocalization.text("Access ready") : String(format: AppLocalization.text("%lld missing"), Int64(missingAutomaticCapabilities.count)))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(missingAutomaticCapabilities.isEmpty ? ForgeStyle.accent : Color.orange)
            }
            if requiredCapabilities.isEmpty {
                ForgeNote(text: "This trigger and its actions need no additional permission or script opt-in.", symbol: "checkmark.circle")
            } else {
                ForEach(requiredCapabilities) { capability in
                    capabilityRow(capability)
                }
            }
            if !missingAutomaticCapabilities.isEmpty {
                ForgeNote(text: "You can enable this rule now, but automatic runs need the missing access shown above. Manual runs check action requirements only.", symbol: "info.circle")
            }
            if !missingAutomaticCapabilities.isEmpty || requiredCapabilities.contains(.scripts) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        reviewPermissionsButton
                        if requiredCapabilities.contains(.scripts) { reviewScriptsButton }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        reviewPermissionsButton
                        if requiredCapabilities.contains(.scripts) { reviewScriptsButton }
                    }
                }
            }
        }
    }

    private func capabilityRow(_ capability: AutomationCapability) -> some View {
        let available = model.availableCapabilities.contains(capability)
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: available ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(available ? ForgeStyle.accent : Color.orange)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(AppLocalization.text(capability.title)).font(.caption.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(AppLocalization.text(available ? "Available" : "Missing"))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(available ? ForgeStyle.accent : Color.orange)
                }
                Text(AppLocalization.text(capability.detail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(AppLocalization.text(capability.title)), \(AppLocalization.text(available ? "Available" : "Missing")). \(AppLocalization.text(capability.detail))"))
    }

    private var reviewPermissionsButton: some View {
        Button("Review permissions") { model.section = .permissions }
            .controlSize(.small)
    }

    private var reviewScriptsButton: some View {
        Button("Review script settings") { model.section = .settings }
            .controlSize(.small)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                Label("RULE EDITOR", systemImage: "slider.horizontal.3")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Enabled", isOn: $rule.enabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel("Enable this rule")
                    .disabled(!model.hasConfigurationLease || (!rule.enabled && !errors.isEmpty))
                    .help(AppLocalization.text(errors.isEmpty ? "Allow this rule to run when automation is enabled" : "Resolve the validation messages before enabling this rule"))
                Menu {
                    Button("Duplicate rule", action: onDuplicate)
                        .disabled(!model.hasConfigurationLease)
                    Divider()
                    Button("Delete rule…", role: .destructive, action: onDelete)
                        .disabled(!model.hasConfigurationLease)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Rule options")
            }
            TextField("Rule name", text: $rule.name)
                .font(.system(size: 23, weight: .semibold))
                .textFieldStyle(.plain)
                .accessibilityLabel("Rule name")
                .onSubmit { model.save() }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 19)
    }

    private var triggerEditor: some View {
        ForgePanel {
            Picker("Trigger", selection: $rule.trigger.kind) {
                ForEach(TriggerKind.allCases) { kind in
                    Label(AppLocalization.text(kind.title), systemImage: kind.forgeSymbol).tag(kind)
                }
            }
            .onChange(of: rule.trigger.kind) { _, _ in model.stopRecordingShortcut() }
            Divider()
            switch rule.trigger.kind {
            case .shortcut, .doubleShortcut:
                if rule.trigger.kind == .doubleShortcut {
                    ForgeNote(text: "Press the same key and modifiers twice within 350 ms. This is not a sequence of different shortcuts.", symbol: "repeat")
                    ForgeNote(text: "Both key presses still reach the active app. A single-press rule using the same shortcut may also run.")
                }
                HStack(spacing: 12) {
                    Text(model.isRecordingShortcut ? AppLocalization.text("Press a shortcut…") : rule.trigger.summary)
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(ForgeStyle.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityLabel("Recorded shortcut: \(rule.trigger.summary)")
                    Button(AppLocalization.text(model.isRecordingShortcut ? "Cancel" : "Record")) {
                        if model.isRecordingShortcut { model.stopRecordingShortcut() }
                        else { model.startRecordingShortcut() }
                    }
                }
                ForgeNote(text: model.isRecordingShortcut ? "Press your shortcut in this window within 15 seconds. Escape cancels." : "Recording is local to this window. Use a modifier to avoid ordinary typing.")
                if rule.trigger.kind == .doubleShortcut {
                    ForgeNote(text: "Record the shortcut once to set its keys. Double-press mode stays selected.")
                }
                DisclosureGroup("Set keys manually") {
                    VStack(alignment: .leading, spacing: 12) {
                        KeyCodeEditor(keyCode: $rule.trigger.keyCode)
                        ModifierEditor(modifiers: $rule.trigger.modifiers)
                    }
                    .padding(.top, 10)
                }
                .font(.caption)
            case .mouseButton:
                Picker("Mouse button", selection: $rule.trigger.mouseButton) {
                    Text("Left button").tag(0)
                    Text("Right button").tag(1)
                    Text("Middle button").tag(2)
                    Text("Button 4").tag(3)
                    Text("Button 5").tag(4)
                    if !(0...4).contains(rule.trigger.mouseButton) {
                        Text("Button \(rule.trigger.mouseButton + 1)").tag(rule.trigger.mouseButton)
                    }
                }
                EditorField(title: "Required modifiers") {
                    ModifierEditor(modifiers: $rule.trigger.modifiers)
                }
                ForgeNote(text: "Mouse input is observed, not blocked. The original click still reaches the app.")
            case .scroll:
                Picker("Direction", selection: $rule.trigger.scrollDirection) {
                    ForEach(ScrollDirection.allCases) { direction in
                        Text(AppLocalization.text(direction.title)).tag(direction)
                    }
                }
                EditorField(title: "Required modifiers") {
                    ModifierEditor(modifiers: $rule.trigger.modifiers)
                }
                ForgeNote(text: "Scrolling still reaches the app. Add a modifier and cooldown to avoid repeated runs.")
            case .appActivated, .appLaunched, .appTerminated:
                EditorField(title: "Application bundle identifier") {
                    ApplicationIdentifierField(title: "com.apple.Safari", identifier: $rule.trigger.appBundleIdentifier)
                }
                if rule.trigger.kind == .appActivated {
                    ForgeNote(text: "Choose an app to match when it becomes frontmost. This is app activation, not app launch.")
                } else {
                    if rule.trigger.kind == .appLaunched {
                        ForgeNote(text: "Matches when the selected application's process starts, even if it launches in the background.")
                    } else {
                        ForgeNote(text: "Matches when the selected application's process ends. The app may already be closed when actions run.")
                    }
                    ForgeNote(text: "Window, keyboard and text actions target the current frontmost app, not the app that launched or terminated. App conditions also check the frontmost app.", symbol: "exclamationmark.triangle", warning: true)
                    ForgeNote(text: "Prefer notifications or other actions that do not change the focused app. The trigger does not activate the event app or replay missed events.")
                }
            case .interval:
                HStack {
                    Text("Every")
                    TextField("Seconds", value: $rule.trigger.intervalSeconds, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 95)
                        .accessibilityLabel("Interval in seconds")
                    Text("seconds").foregroundStyle(.secondary)
                    Spacer()
                }
                ForgeNote(text: "Runs while ActionFlow is open and automation is enabled. App conditions are checked each time.")
            }
        }
    }

    private var conditionsEditor: some View {
        ForgePanel {
            ApplicationScopeEditor(
                title: "Include apps",
                emptyMessage: "Any frontmost app",
                identifiers: $rule.conditions.appBundleIdentifiers
            )
            DisclosureGroup("Exclude apps") {
                ApplicationScopeEditor(
                    title: "Exclude apps",
                    emptyMessage: "No exclusions",
                    identifiers: $rule.conditions.excludedAppBundleIdentifiers
                )
                .padding(.top, 10)
            }
            .font(.caption)
        }
    }

    private var actionsEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(rule.actions.enumerated()), id: \.element.id) { index, action in
                ActionEditor(
                    action: actionBinding(action),
                    number: index + 1,
                    count: rule.actions.count,
                    allowScripts: model.configuration.allowScripts,
                    moveUp: { moveAction(at: index, by: -1) },
                    moveDown: { moveAction(at: index, by: 1) },
                    remove: { rule.actions.removeAll { $0.id == action.id } }
                )
            }
            if rule.actions.isEmpty {
                ForgePanel {
                    ForgeNote(text: "No actions yet. Add the first step below.", symbol: "plus.circle")
                }
            }
            Menu {
                ForEach(ActionKind.allCases) { kind in
                    Button {
                        var action = AutomationAction()
                        action.kind = kind
                        rule.actions.append(action)
                    } label: {
                        Label(AppLocalization.text(kind.title), systemImage: kind.forgeSymbol)
                    }
                }
            } label: {
                Label("Add action", systemImage: "plus")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
            .menuStyle(.borderedButton)
            .accessibilityLabel("Add an action to the chain")
            if usesScript && !model.configuration.allowScripts {
                Button { model.section = .settings } label: {
                    Label("Scripts are blocked. Review script settings.", systemImage: "lock.shield")
                        .font(.caption)
                }
                .buttonStyle(.link)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.hasConfigurationLease {
                ForgeNote(text: "Saving and running are unavailable without configuration ownership. Preview and export are still available.", symbol: "lock.fill", warning: true)
            }
            if model.isExecuting, let progress = model.executionProgress {
                executionProgressView(progress)
            }
            if !model.isExecuting {
                Label {
                    Text("Run target: \(model.manualTargetDescription)")
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "scope")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Manual run target: \(model.manualTargetDescription)")
                if !missingManualCapabilities.isEmpty {
                    ForgeNote(
                        text: String(format: AppLocalization.text("Run now is unavailable. Missing: %@. Target: %@."), missingManualSummary, model.manualTargetDescription),
                        symbol: "exclamationmark.circle",
                        warning: true,
                        localizesText: false
                    )
                }
            }
            HStack(spacing: 10) {
                if model.isExecuting {
                    if model.executionProgress == nil {
                        ProgressView().controlSize(.small)
                        Text("Running actions…").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Stop", action: model.stopExecution)
                        .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button { confirmRun = true } label: {
                        Label("Run now…", systemImage: "play")
                    }
                    .disabled(!model.hasConfigurationLease || !errors.isEmpty || !missingManualCapabilities.isEmpty)
                    .help(missingManualCapabilities.isEmpty ? "Run real actions on \(model.manualTargetDescription). A confirmation is shown first." : "Missing: \(missingManualSummary). Target: \(model.manualTargetDescription).")
                }
                Spacer()
                Button {
                    previewPlan = ExecutionPlan(rule: rule)
                    showPreview = true
                } label: {
                    Label(AppLocalization.text("Preview…"), systemImage: "doc.text.magnifyingglass")
                }
                .help(AppLocalization.text("Inspect a redacted plan without running any actions"))
                Button("Save", action: model.save)
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.hasConfigurationLease)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 13)
    }

    private func executionProgressView(_ progress: ExecutionProgress) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(String(format: AppLocalization.text("Step %lld of %lld: %@"), Int64(progress.actionIndex), Int64(progress.actionCount), AppLocalization.text(progress.kind.title)))
                    .font(.caption.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(AppLocalization.text(progressPhaseTitle(progress.phase)))
                    .font(.caption)
                    .foregroundStyle(progress.phase == .failed || progress.phase == .cancelled ? Color.orange : ForgeStyle.accent)
            }
            if progress.actionCount > 0 {
                ProgressView(value: Double(progress.completedActions), total: Double(progress.actionCount))
                    .progressViewStyle(.linear)
                    .accessibilityLabel(AppLocalization.text("Action chain progress"))
                    .accessibilityValue(String(format: AppLocalization.text("Completed %lld of %lld actions"), Int64(progress.completedActions), Int64(progress.actionCount)))
            }
            Text(String(format: AppLocalization.text("Completed %lld of %lld actions"), Int64(progress.completedActions), Int64(progress.actionCount)))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func progressPhaseTitle(_ phase: ExecutionPhase) -> String {
        switch phase {
        case .running: return "Running"
        case .completed: return "Step complete"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    private func messagePanel(title: String, messages: [String], warning: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(AppLocalization.text(title)).font(.callout.weight(.semibold))
            ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                ForgeNote(text: message, symbol: "exclamationmark.triangle", warning: warning, localizesText: false)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    private func actionBinding(_ fallback: AutomationAction) -> Binding<AutomationAction> {
        Binding(
            get: { rule.actions.first(where: { $0.id == fallback.id }) ?? fallback },
            set: { value in
                if let index = rule.actions.firstIndex(where: { $0.id == fallback.id }) {
                    rule.actions[index] = value
                }
            }
        )
    }

    private func moveAction(at index: Int, by offset: Int) {
        let destination = index + offset
        guard rule.actions.indices.contains(index), rule.actions.indices.contains(destination) else { return }
        rule.actions.swapAt(index, destination)
    }
}

struct ExecutionPlanPreview: View {
    @Environment(\.dismiss) private var dismiss
    let plan: ExecutionPlan

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Label(AppLocalization.text("Action preview"), systemImage: "doc.text.magnifyingglass")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                ForgeNote(text: "Read-only preview. No actions run, no app is activated and no permission is requested.", symbol: "eye")
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForgeNote(text: "Text, URLs, app identifiers and scripts are hidden. Only action types, counts and safe parameters appear below.", symbol: "lock.shield")
                    VStack(alignment: .leading, spacing: 11) {
                        Text(AppLocalization.text("Planned actions"))
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        if plan.steps.isEmpty {
                            ForgeNote(text: "No actions to preview.")
                        }
                        ForEach(Array(plan.steps.enumerated()), id: \.offset) { offset, step in
                            ForgePanel {
                                HStack(alignment: .top, spacing: 11) {
                                    Text(String(format: "%02d", offset + 1))
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 2)
                                    Image(systemName: step.kind.forgeSymbol)
                                        .foregroundStyle(ForgeStyle.accent)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(AppLocalization.text(step.title))
                                            .font(.callout.weight(.semibold))
                                        Text(AppLocalization.text(step.summary))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                        Text(String(format: AppLocalization.text("Total planned delay: %@ seconds"), plan.totalDelaySeconds.formatted()))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForgePanel {
                        Text(AppLocalization.text("Requirements for automatic runs"))
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        if plan.requiredCapabilities.isEmpty {
                            ForgeNote(text: "No additional permission or script opt-in is required.")
                        }
                        ForEach(plan.requiredCapabilities) { capability in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(AppLocalization.text(capability.title))
                                    .font(.caption.weight(.semibold))
                                Text(AppLocalization.text(capability.detail))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    ForgePanel {
                        Label(
                            AppLocalization.text(plan.validationErrors.isEmpty ? "No validation issues found" : "Review before running"),
                            systemImage: plan.validationErrors.isEmpty ? "checkmark.circle" : "exclamationmark.triangle"
                        )
                        .font(.headline)
                        .foregroundStyle(plan.validationErrors.isEmpty ? ForgeStyle.accent : Color.orange)
                        ForEach(Array(plan.validationErrors.enumerated()), id: \.offset) { _, error in
                            ForgeNote(text: error, symbol: "exclamationmark.circle", warning: true, localizesText: false)
                        }
                        ForgeNote(text: "Validation does not check live permissions, app availability or the current target. This preview is not a test run.")
                    }
                    ForgeNote(text: "Detailed step summaries and validation messages may appear in English.")
                }
                .padding(24)
            }
            Divider()
            HStack {
                Text(AppLocalization.text("Nothing has been executed."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(AppLocalization.text("Close")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 15)
        }
        .frame(minWidth: 520, idealWidth: 580, maxWidth: 760, minHeight: 460, idealHeight: 650)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ApplicationScopeEditor: View {
    let title: String
    let emptyMessage: String
    @Binding var identifiers: [String]
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(AppLocalization.text(title)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            if identifiers.isEmpty {
                Text(AppLocalization.text(emptyMessage)).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(identifiers.enumerated()), id: \.offset) { index, identifier in
                HStack(spacing: 8) {
                    Image(systemName: "app").foregroundStyle(.secondary)
                    Text(identifier).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        guard identifiers.indices.contains(index) else { return }
                        identifiers.remove(at: index)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(identifier)")
                }
            }
            HStack {
                TextField("com.apple.Safari", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("\(title) bundle identifier")
                    .onSubmit(addDraft)
                Button("Add", action: addDraft)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Choose…") {
                    if let identifier = chooseApplicationIdentifier() { add(identifier) }
                }
                .accessibilityLabel("Choose application for \(title.lowercased())")
            }
        }
    }

    private func addDraft() {
        add(draft)
        draft = ""
    }

    private func add(_ value: String) {
        let identifier = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, !identifiers.contains(identifier) else { return }
        identifiers.append(identifier)
    }
}
