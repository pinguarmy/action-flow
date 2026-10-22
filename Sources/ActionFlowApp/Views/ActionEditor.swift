import SwiftUI
import ActionFlowCore

struct ActionEditor: View {
    @Binding var action: AutomationAction
    let number: Int
    let count: Int
    let allowScripts: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void
    let remove: () -> Void

    var body: some View {
        ForgePanel {
            HStack(spacing: 8) {
                Text(String(format: "%02d", number))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Image(systemName: action.kind.forgeSymbol)
                    .foregroundStyle(ForgeStyle.accent)
                    .accessibilityHidden(true)
                Picker("Action \(number)", selection: $action.kind) {
                    ForEach(ActionKind.allCases) { kind in
                        Text(AppLocalization.text(kind.title)).tag(kind)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("Action \(number) type")
                Spacer(minLength: 2)
                HStack(spacing: 7) {
                    Button(action: moveUp) { Image(systemName: "chevron.up") }
                        .disabled(number == 1)
                        .accessibilityLabel("Move action \(number) up")
                    Button(action: moveDown) { Image(systemName: "chevron.down") }
                        .disabled(number == count)
                        .accessibilityLabel("Move action \(number) down")
                    Button(action: remove) { Image(systemName: "trash") }
                        .accessibilityLabel("Remove action \(number)")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            Divider()
            parameters
        }
    }

    @ViewBuilder
    private var parameters: some View {
        switch action.kind {
        case .window:
            Picker("Window operation", selection: $action.windowOperation) {
                ForEach(WindowOperation.allCases) { operation in
                    Text(AppLocalization.text(operation.title)).tag(operation)
                }
            }
            ForgeNote(text: "Applies to the frontmost app's focused window. Requires Accessibility permission.", symbol: "macwindow")
        case .keyboardShortcut:
            KeyCodeEditor(keyCode: $action.keyCode)
            EditorField(title: "Modifiers") {
                ModifierEditor(modifiers: $action.modifiers)
            }
            ForgeNote(text: "Sends this shortcut to the frontmost app. Requires Accessibility permission.")
        case .insertText:
            EditorField(title: "Text to insert") {
                TextEditor(text: $action.text)
                    .font(.system(.body))
                    .frame(minHeight: 85, maxHeight: 160)
                    .padding(5)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.12)) }
                    .accessibilityLabel("Text for action \(number)")
            }
            ForgeNote(text: "Inserts into the focused text field. Do not store passwords or other secrets in rules.")
        case .openURL:
            EditorField(title: "URL") {
                TextField("https://example.com", text: $action.text)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("URL for action \(number)")
            }
            ForgeNote(text: "Supports https, http and mailto links. Opens in the default app.")
        case .launchApp:
            EditorField(title: "Application bundle identifier") {
                ApplicationIdentifierField(title: "com.apple.Safari", identifier: $action.text)
            }
            ForgeNote(text: "Opens the selected app. Use its bundle identifier, not a shell command.")
        case .menuCommand:
            EditorField(title: "Menu path (JSON array)") {
                TextEditor(text: $action.text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 120)
                    .padding(5)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.12)) }
                    .accessibilityLabel("Menu path JSON for action \(number)")
            }
            MenuPathStatus(text: action.text)
            ForgeNote(text: "Enter the exact menu titles as they appear in the app, including language, capitalization and punctuation, as a JSON array of 2 to 8 titles, for example [\"File\", \"New\"]. Unknown or misspelled titles make the action fail. Titles are never trimmed, guessed, or joined.")
            ForgeNote(text: "Only the final menu item is pressed; parent menus are never opened automatically, so apps with dynamic submenus may be unavailable. Requires Accessibility permission.", symbol: "menubar.rectangle")
        case .delay:
            HStack {
                Text("Wait")
                TextField("Seconds", value: $action.delaySeconds, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .accessibilityLabel("Delay in seconds for action \(number)")
                Text("seconds").foregroundStyle(.secondary)
                Spacer()
            }
            ForgeNote(text: "Between 0 and 60 seconds. Stop cancels the remaining chain.")
        case .notification:
            EditorField(title: "Message") {
                TextField("Action complete", text: $action.text, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Notification message for action \(number)")
            }
            ForgeNote(text: "macOS notification delivery depends on the app's notification permission.", symbol: "bell")
        case .shellScript:
            ForgeNote(
                text: allowScripts ? "Scripts are allowed. This command runs with your user account's access. Review every line before running." : "Scripts are blocked. You must explicitly allow them in Settings before this action can run.",
                symbol: "lock.shield",
                warning: true
            )
            EditorField(title: "Shell script") {
                TextEditor(text: $action.text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 110, maxHeight: 220)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.12)) }
                    .accessibilityLabel("Shell script for action \(number)")
            }
            ForgeNote(text: "Scripts are local and unsandboxed. Configuration exports include their contents.")
        }
    }
}

/// Live read-only status of the JSON menu path. Parses locally only; it never
/// queries an application's menus, so it cannot confirm the titles exist.
private struct MenuPathStatus: View {
    let text: String

    var body: some View {
        if let path = try? MenuCommandPath(parsing: text) {
            ForgeNote(
                text: String(format: AppLocalization.text("%lld menu levels. Titles are checked only when the action runs, against the app's current menus."), Int64(path.segments.count)),
                symbol: "checkmark.circle",
                localizesText: false
            )
        } else {
            ForgeNote(text: "Not a valid menu path yet. The rule cannot run until this parses.", symbol: "exclamationmark.triangle", warning: true)
        }
    }
}
