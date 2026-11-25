import SwiftUI
import ActionFlowCore

/// First-run checklist shown above the rules list. It only reads permission state; the actions
/// open the Permissions page or select a rule, and never request a permission or enable anything.
struct GettingStartedCard: View {
    static let dismissedKey = "ActionFlow.gettingStartedDismissed"

    @EnvironmentObject private var model: AppModel
    @AppStorage(GettingStartedCard.dismissedKey) private var dismissed = false

    /// Shared with `MainView`, which hides its permission banner while the card is visible.
    static func isVisible(model: AppModel, dismissed: Bool) -> Bool {
        model.hasConfigurationLease && !dismissed && !allDone(model: model)
    }

    static func allDone(model: AppModel) -> Bool {
        model.permissions.inputMonitoring
            && model.permissions.accessibility
            && model.configuration.rules.contains(where: \.enabled)
            && model.configuration.automationEnabled
    }

    private var hasEnabledRule: Bool { model.configuration.rules.contains(where: \.enabled) }
    private var firstReviewableRule: AutomationRule? {
        model.configuration.rules.first { !$0.enabled && RuleValidator.validate($0).isEmpty }
    }
    private var earlierStepsDone: Bool {
        model.permissions.inputMonitoring && model.permissions.accessibility && hasEnabledRule
    }
    private var doneCount: Int {
        [model.permissions.inputMonitoring, model.permissions.accessibility,
         hasEnabledRule, model.configuration.automationEnabled].filter { $0 }.count
    }

    var body: some View {
        if GettingStartedCard.isVisible(model: model, dismissed: dismissed) {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            permissionSteps
            enableRuleStep
            resumeStep
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ForgeStyle.panel, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Get started").font(.headline)
            Text(String(format: AppLocalization.text("%lld of 4 done"), Int64(doneCount)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button { dismissed = true } label: {
                Image(systemName: "xmark").font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .help(AppLocalization.text("Dismiss getting started"))
            .accessibilityLabel(AppLocalization.text("Dismiss getting started"))
        }
    }

    private var permissionSteps: some View {
        Group {
            step(title: "Allow Input Monitoring",
                 caption: "Lets ActionFlow see the shortcuts, mouse buttons and scrolling your rules use.",
                 done: model.permissions.inputMonitoring,
                 buttonTitle: "Open Permissions",
                 enabled: true,
                 help: "") { model.section = .permissions }
            step(title: "Allow Accessibility",
                 caption: "Needed for window and keyboard actions.",
                 done: model.permissions.accessibility,
                 buttonTitle: "Open Permissions",
                 enabled: true,
                 help: "") { model.section = .permissions }
        }
    }

    private var enableRuleStep: some View {
        step(title: "Enable a rule",
             caption: "Review an example rule, then turn on its switch.",
             done: hasEnabledRule,
             buttonTitle: "Review a rule",
             enabled: firstReviewableRule != nil,
             help: "") { reviewFirstRule() }
    }

    private var resumeStep: some View {
        step(title: "Resume automation",
             caption: "Rules only run while automation is on.",
             done: model.configuration.automationEnabled,
             buttonTitle: "Resume",
             enabled: earlierStepsDone,
             help: earlierStepsDone ? "" : "Finish the steps above first") { model.toggleAutomation() }
    }

    private func reviewFirstRule() {
        guard let rule = firstReviewableRule else { return }
        if !model.filteredRules.contains(where: { $0.id == rule.id }) { model.clearRuleFilters() }
        model.section = .rules
        model.selection = rule.id
    }

    private func step(title: String, caption: String, done: Bool, buttonTitle: String,
                      enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? ForgeStyle.accent : Color.secondary)
                .frame(width: 16)
                .accessibilityLabel(AppLocalization.text(done ? "Step done" : "Step not done"))
            VStack(alignment: .leading, spacing: 3) {
                Text(AppLocalization.text(title)).font(.system(size: 12, weight: .semibold))
                Text(AppLocalization.text(caption))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !done {
                    Button(AppLocalization.text(buttonTitle), action: action)
                        .controlSize(.small)
                        .disabled(!enabled)
                        .help(help.isEmpty ? "" : AppLocalization.text(help))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }
}
