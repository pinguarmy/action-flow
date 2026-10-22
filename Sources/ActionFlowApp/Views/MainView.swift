import SwiftUI
import ActionFlowCore

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var pendingDeletion: AutomationRule?
    @State private var showTemplateLibrary = false

    private var hasActiveRuleFilters: Bool {
        !model.searchText.isEmpty || model.ruleStatusFilter != .all || model.ruleGroupFilter != nil
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 240)
        } detail: {
            VStack(spacing: 0) {
                if !model.hasConfigurationLease {
                    configurationOwnershipBanner
                }
                if !model.permissions.accessibility || !model.permissions.inputMonitoring {
                    permissionBanner
                }
                switch model.section {
                case .rules:
                    ruleWorkspace
                case .activity:
                    ActivityView()
                case .permissions:
                    PermissionsView()
                case .settings:
                    AppSettingsView()
                case .gestureLab:
                    GestureLabView()
                }
                statusBar
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(ForgeStyle.accent)
        .frame(minWidth: 1220, minHeight: 680)
        .navigationTitle("ActionFlow")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isExecuting {
                    Button(action: model.stopExecution) {
                        Label("Stop actions", systemImage: "stop.circle")
                    }
                    .help("Cancel the current action chain")
                }
                if model.section == .rules {
                    Button(action: model.addRule) {
                        Label("New rule", systemImage: "plus")
                    }
                    .keyboardShortcut("n", modifiers: .command)
                    .help("Create a disabled rule")
                    .disabled(!model.hasConfigurationLease)
                    Button { showTemplateLibrary = true } label: {
                        Label(AppLocalization.text("Templates…"), systemImage: "square.stack")
                    }
                    .help(AppLocalization.text("Browse built-in rule templates"))
                    .disabled(!model.hasConfigurationLease)
                    Menu {
                        Button("Import configuration…", action: model.importRules)
                            .disabled(!model.hasConfigurationLease)
                        Button("Export configuration…", action: model.exportRules)
                    } label: {
                        Label("Configuration", systemImage: "ellipsis.circle")
                    }
                    .help("Import or export configuration")
                }
            }
        }
        .sheet(isPresented: $showTemplateLibrary) {
            TemplateLibraryView()
                .environmentObject(model)
        }
        .alert("Delete rule?", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Delete", role: .destructive) {
                if let rule = pendingDeletion { model.deleteRule(rule.id) }
                pendingDeletion = nil
            }
            .disabled(!model.hasConfigurationLease)
        } message: {
            Text("\(pendingDeletion?.name ?? AppLocalization.text("This rule")) will be removed from your configuration.")
        }
        .alert("ActionFlow", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onChange(of: model.searchText) { _, _ in model.reconcileRuleSelection() }
        .onChange(of: model.ruleStatusFilter) { _, _ in model.reconcileRuleSelection() }
        .onChange(of: model.ruleGroupFilter) { _, _ in model.reconcileRuleSelection() }
        .onChange(of: model.configuration.automationEnabled) { _, _ in model.save() }
        .onChange(of: model.selection) { _, _ in
            model.stopRecordingShortcut()
            model.save()
        }
        .onDisappear { model.save() }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "cursorarrow.motionlines")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(ForgeStyle.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ActionFlow").font(.headline)
                        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.85) : Color.primary)
                    Text("Your Mac, your rules").font(.caption)
                        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.65) : Color.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 23)

            List(selection: Binding<SidebarSection?>(
                get: { model.section },
                set: { if let section = $0 { model.section = section } }
            )) {
                Section("Workspace") {
                    ForEach(SidebarSection.allCases) { section in
                        HStack {
                            Label {
                                Text(AppLocalization.text(section.title))
                                    .foregroundStyle(model.section == section ? Color.white : (colorScheme == .dark ? Color.white.opacity(0.85) : Color.primary))
                            } icon: {
                                Image(systemName: section.systemImage)
                                    .foregroundStyle(model.section == section ? Color.white : (colorScheme == .dark ? Color.white.opacity(0.65) : Color.secondary))
                            }
                            Spacer()
                            if section == .rules {
                                Text("\(model.configuration.rules.count)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(model.section == section ? Color.white.opacity(0.8) : (colorScheme == .dark ? Color.white.opacity(0.65) : Color.secondary))
                            }
                        }
                        .padding(.vertical, 3)
                        .listRowBackground(model.section == section ? Color(red: 0.15, green: 0.43, blue: 0.31) : Color.clear)
                        .tag(section)
                    }
                }
            }
            .listStyle(.sidebar)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $model.configuration.automationEnabled) {
                    Text("Automation").font(.system(size: 12, weight: .semibold))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel("Enable automation")
                .disabled(!model.hasConfigurationLease)
                HStack(spacing: 5) {
                    Circle()
                        .fill(model.configuration.automationEnabled ? ForgeStyle.accent : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(AppLocalization.text(model.configuration.automationEnabled ? "Enabled rules can run" : "Paused. Rules will not run automatically."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            .padding(12)
        }
    }

    private var configurationOwnershipBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.orange)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(AppLocalization.text("Configuration is locked for this instance"))
                    .font(.callout.weight(.semibold))
                Text(AppLocalization.text("Another instance may own the configuration, or its writer lock could not be safely acquired. This instance cannot save changes or run rules. Close the other instance, then restart ActionFlow. Locks are never forcibly taken over."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(AppLocalization.text("You can still inspect, preview and export. Edits made here will not be saved."))
                    .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.09))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }

    private var permissionBanner: some View {
        HStack(spacing: 9) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            Text("Some actions and global inputs need macOS permission.")
                .font(.callout)
            Spacer(minLength: 8)
            Button("Review permissions") { model.section = .permissions }
                .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var ruleWorkspace: some View {
        HSplitView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Rules").font(.title2.weight(.semibold))
                        Spacer()
                        Text("\(model.configuration.rules.filter(\.enabled).count) enabled")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("Search rules", text: $model.searchText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Search rules")
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Text(AppLocalization.text("State"))
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .leading)
                            Picker(AppLocalization.text("Filter rules by state"), selection: $model.ruleStatusFilter) {
                                ForEach(RuleStatusFilter.allCases) { status in
                                    Text(AppLocalization.text(status.title)).tag(status)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel(AppLocalization.text("Filter rules by state"))
                        }
                        HStack(spacing: 8) {
                            Text(AppLocalization.text("Group"))
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .leading)
                            Picker(AppLocalization.text("Filter rules by group"), selection: $model.ruleGroupFilter) {
                                Text(AppLocalization.text("All groups")).tag(Optional<String>.none)
                                ForEach(model.availableRuleGroups, id: \.self) { group in
                                    Text(group.isEmpty ? AppLocalization.text("Ungrouped") : group)
                                        .tag(Optional(group))
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel(AppLocalization.text("Filter rules by group"))
                        }
                    }
                    .controlSize(.small)
                    HStack(alignment: .firstTextBaseline) {
                        Text(String(format: AppLocalization.text("%lld of %lld rules"), Int64(model.filteredRules.count), Int64(model.configuration.rules.count)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        if hasActiveRuleFilters {
                            Button(AppLocalization.text("Clear filters"), action: model.clearRuleFilters)
                                .font(.caption)
                                .buttonStyle(.borderless)
                        }
                    }
                }
                .padding(16)
                Divider()
                if model.filteredRules.isEmpty {
                    ForgeEmptyState(
                        symbol: hasActiveRuleFilters ? "line.3.horizontal.decrease.circle" : "cursorarrow.and.square.on.square.dashed",
                        title: hasActiveRuleFilters ? "No matching rules" : "Start with one rule",
                        message: hasActiveRuleFilters ? "Try another search, state or group, or clear all filters." : "Choose an input, then decide what your Mac should do."
                    ) {
                        if hasActiveRuleFilters {
                            Button(AppLocalization.text("Clear filters"), action: model.clearRuleFilters)
                        } else {
                            Button("New rule", action: model.addRule)
                                .buttonStyle(.borderedProminent)
                                .disabled(!model.hasConfigurationLease)
                        }
                    }
                } else {
                    List(selection: $model.selection) {
                        ForEach(model.filteredRules) { rule in
                            RuleListRow(rule: rule)
                                .tag(rule.id)
                                .contextMenu {
                                    Button("Duplicate") { model.duplicateRule(rule) }
                                        .disabled(!model.hasConfigurationLease)
                                    Button(AppLocalization.text(rule.enabled ? "Disable rule" : "Enable rule")) {
                                        if let index = model.configuration.rules.firstIndex(where: { $0.id == rule.id }) {
                                            model.configuration.rules[index].enabled.toggle()
                                            model.save()
                                        }
                                    }
                                    .disabled(!model.hasConfigurationLease || (!rule.enabled && !RuleValidator.validate(rule).isEmpty))
                                    Divider()
                                    Button("Delete…", role: .destructive) { pendingDeletion = rule }
                                        .disabled(!model.hasConfigurationLease)
                                }
                        }
                    }
                    .listStyle(.inset)
                }
                Divider()
                HStack {
                    Button(action: model.addRule) { Label("New rule", systemImage: "plus") }
                        .buttonStyle(.borderless)
                        .disabled(!model.hasConfigurationLease)
                    Spacer()
                    Text("Local only").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(13)
            }
            .frame(minWidth: 250, idealWidth: 285, maxWidth: 350)
            .background(Color(nsColor: .controlBackgroundColor))

            if let rule = model.selectedRule {
                RuleEditor(
                    rule: ruleBinding(rule),
                    onDuplicate: { model.duplicateRule(rule) },
                    onDelete: { pendingDeletion = rule }
                )
                .id(rule.id)
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ForgeEmptyState(
                    symbol: "slider.horizontal.3",
                    title: "A small shortcut. A useful change.",
                    message: "Select a rule to edit its trigger, app conditions and actions. New rules stay disabled until you enable them."
                ) {
                    Button("Create a rule", action: model.addRule)
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.hasConfigurationLease)
                }
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 7) {
            Image(systemName: model.configuration.automationEnabled ? "bolt.circle" : "pause.circle")
                .foregroundStyle(model.configuration.automationEnabled ? ForgeStyle.accent : .secondary)
            Text(model.statusMessage ?? AppLocalization.text("Configuration is stored on this Mac."))
                .lineLimit(1)
            Spacer()
            Text("\(model.configuration.rules.count) rules")
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func ruleBinding(_ fallback: AutomationRule) -> Binding<AutomationRule> {
        Binding(
            get: { model.configuration.rules.first(where: { $0.id == fallback.id }) ?? fallback },
            set: { value in
                if let index = model.configuration.rules.firstIndex(where: { $0.id == fallback.id }) {
                    model.configuration.rules[index] = value
                }
            }
        )
    }
}

private struct RuleListRow: View {
    let rule: AutomationRule

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: rule.trigger.kind.forgeSymbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(rule.enabled ? ForgeStyle.accent : .secondary)
                .frame(width: 28, height: 30)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(rule.name.isEmpty ? AppLocalization.text("Untitled rule") : rule.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if !rule.enabled {
                        Text("OFF").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(rule.trigger.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(rule.group.isEmpty ? AppLocalization.text("My rules") : rule.group)
                    Text("·")
                    Text(String(format: AppLocalization.text(rule.actions.count == 1 ? "%lld action" : "%lld actions"), Int64(rule.actions.count)))
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(rule.name), \(rule.enabled ? "enabled" : "disabled"), \(rule.trigger.summary), \(rule.actions.count) actions")
    }
}
