import SwiftUI
import ActionFlowCore

struct TemplateLibraryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var pendingTemplate: RuleTemplate?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 11) {
                Label(AppLocalization.text("Built-in templates"), systemImage: "square.stack")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                ForgeNote(text: "Start with a useful rule pack, then make it your own. Every rule is added disabled.", symbol: "slider.horizontal.3")
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(RuleTemplates.all) { template in
                        templateRow(template)
                        if template.id != RuleTemplates.all.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 24)
            }
            Divider()
            HStack(spacing: 14) {
                ForgeNote(text: "Adding templates does not run actions, open apps or request permissions.", symbol: "lock.shield")
                Button(AppLocalization.text("Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(minWidth: 560, idealWidth: 650, maxWidth: 820, minHeight: 480, idealHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(AppLocalization.text("Add this template's rules?"), isPresented: Binding(
            get: { pendingTemplate != nil },
            set: { if !$0 { pendingTemplate = nil } }
        ), titleVisibility: .visible) {
            Button(AppLocalization.text("Add disabled rules")) {
                guard let template = pendingTemplate else { return }
                model.addTemplate(template)
                pendingTemplate = nil
                dismiss()
            }
            Button(AppLocalization.text("Cancel"), role: .cancel) { pendingTemplate = nil }
        } message: {
            Text(AppLocalization.text("The rules are copied with new identifiers and remain disabled. Existing rules and your automation, script and login settings are unchanged. Review shortcuts and app conditions before enabling them."))
        }
    }

    private func templateRow(_ template: RuleTemplate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 15) {
                Image(systemName: template.rules.first?.trigger.kind.forgeSymbol ?? "square.stack")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(ForgeStyle.accent)
                    .frame(width: 31)
                    .padding(.top, 3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(AppLocalization.text(template.name))
                        .font(.system(size: 15, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(AppLocalization.text(template.detail))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(String(format: AppLocalization.text("%lld disabled rules"), Int64(template.rules.count)))
                        .font(.caption.weight(.medium))
                    Text(String(format: AppLocalization.text("Needs: %@"), capabilitiesDescription(for: template)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(AppLocalization.text("Add disabled rules…")) { pendingTemplate = template }
                    .controlSize(.small)
                    .accessibilityLabel(String(format: AppLocalization.text("Add disabled rules from %@"), AppLocalization.text(template.name)))
            }
            .padding(.leading, 46)
        }
        .padding(.vertical, 20)
    }

    private func capabilitiesDescription(for template: RuleTemplate) -> String {
        let required = Set(template.rules.flatMap { RuleRequirements.capabilities(for: $0, automatic: true) })
        let titles = AutomationCapability.allCases.filter { required.contains($0) }.map { AppLocalization.text($0.title) }
        return titles.isEmpty ? AppLocalization.text("No additional access") : titles.joined(separator: ", ")
    }
}
