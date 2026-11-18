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
            EditorField(title: "Menu path") {
                MenuPathEditor(text: $action.text, number: number)
            }
            ForgeNote(text: "Type each title exactly as the app shows it, including language, capitalization and punctuation; for example, an ellipsis \"…\" is not three dots. Use 2 to 8 levels. Unknown titles make the action fail. Titles are never trimmed or guessed.")
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

/// Row-per-title editor for a menu command path. `text` (the action's JSON
/// payload) stays the single source of truth: rows are re-derived from it on
/// every read and every edit writes it back as compact JSON. Titles are never
/// trimmed or otherwise altered.
private struct MenuPathEditor: View {
    @Binding var text: String
    let number: Int
    @State private var showsJSON = false

    /// Titles to show as rows, or nil when a non-empty payload is not a JSON
    /// array of strings. A blank payload or an empty array shows two empty
    /// rows without writing anything until the user types.
    private var draftSegments: [String]? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return ["", ""] }
        guard let segments = MenuCommandPath.draftSegments(from: text) else { return nil }
        return segments.isEmpty ? ["", ""] : segments
    }

    private var isMalformed: Bool { draftSegments == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let segments = draftSegments {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { index, _ in
                        row(index: index, count: segments.count)
                    }
                }
                Button {
                    addLevel()
                } label: {
                    Label(AppLocalization.text("Add level"), systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(segments.count >= MenuCommandPath.maximumSegments)
                .accessibilityLabel(AppLocalization.text("Add level"))
            } else {
                ForgeNote(text: "This menu path is not a list of titles. Edit the JSON below or start over.", symbol: "exclamationmark.triangle", warning: true)
                Button(AppLocalization.text("Start over")) {
                    text = MenuCommandPath.draftJSON(for: ["", ""])
                }
            }
            MenuPathStatus(text: text)
            DisclosureGroup(isExpanded: jsonExpanded) {
                TextEditor(text: $text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 120)
                    .padding(5)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.12)) }
                    .accessibilityLabel("Menu path JSON for action \(number)")
                    .padding(.top, 4)
            } label: {
                Text(AppLocalization.text("Edit as JSON"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // Latch the JSON editor open once the payload is malformed, so fixing it
        // there does not collapse the editor (and drop focus) mid-typing.
        .onChange(of: isMalformed, initial: true) { _, malformed in
            if malformed { showsJSON = true }
        }
    }

    private var jsonExpanded: Binding<Bool> {
        Binding(
            get: { showsJSON || isMalformed },
            set: { showsJSON = $0 }
        )
    }

    private func row(index: Int, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: String(index + 1))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)
                .accessibilityHidden(true)
            TextField(AppLocalization.text(index == 0 ? "Menu bar title" : "Menu item title"), text: titleBinding(at: index))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(AppLocalization.format("Menu title, level %lld of action %lld", Int64(index + 1), Int64(number)))
            Button {
                removeLevel(at: index)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .disabled(count <= MenuCommandPath.minimumSegments)
            .accessibilityLabel(AppLocalization.format("Remove menu level %lld", Int64(index + 1)))
            .help(AppLocalization.format("Remove menu level %lld", Int64(index + 1)))
        }
    }

    /// Reads and writes one title by position. Both sides re-derive the current
    /// titles from `text` instead of capturing an array that may be stale.
    private func titleBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                guard let segments = draftSegments, segments.indices.contains(index) else { return "" }
                return segments[index]
            },
            set: { newValue in
                guard var segments = draftSegments, segments.indices.contains(index),
                      segments[index] != newValue else { return }
                segments[index] = newValue
                write(segments)
            }
        )
    }

    private func addLevel() {
        guard var segments = draftSegments, segments.count < MenuCommandPath.maximumSegments else { return }
        segments.append("")
        write(segments)
    }

    private func removeLevel(at index: Int) {
        guard var segments = draftSegments, segments.count > MenuCommandPath.minimumSegments,
              segments.indices.contains(index) else { return }
        segments.remove(at: index)
        write(segments)
    }

    /// Drops an edit whose JSON would exceed the payload limit: such text would
    /// no longer decode as rows, and the row being typed in would disappear.
    private func write(_ segments: [String]) {
        let json = MenuCommandPath.draftJSON(for: segments)
        guard json.utf8.count <= MenuCommandPath.maximumJSONBytes else { return }
        text = json
    }
}

/// Live read-only status of the menu path. Parses locally only; it never
/// queries an application's menus, so it cannot confirm the titles exist.
private struct MenuPathStatus: View {
    let text: String

    private enum Outcome {
        case untouched
        case valid(Int)
        case invalid(String)
    }

    private var outcome: Outcome {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .untouched }
        // A fresh path of empty rows (for example after "Start over") is not yet an error.
        if let segments = MenuCommandPath.draftSegments(from: text), segments.allSatisfy({ $0.isEmpty }) {
            return .untouched
        }
        do {
            let path = try MenuCommandPath(parsing: text)
            return .valid(path.segments.count)
        } catch let error as MenuCommandPathError {
            return .invalid(error.message)
        } catch {
            return .invalid(MenuCommandPathError.invalidJSON.message)
        }
    }

    var body: some View {
        switch outcome {
        case .untouched:
            ForgeNote(text: "Enter the menu bar title, then each submenu or item title.")
        case .valid(let count):
            ForgeNote(
                text: AppLocalization.format("%lld menu levels. Titles are checked only when the action runs, against the app's current menus.", Int64(count)),
                symbol: "checkmark.circle",
                localizesText: false
            )
        case .invalid(let message):
            ForgeNote(text: AppLocalization.text(message), symbol: "exclamationmark.triangle", warning: true, localizesText: false)
        }
    }
}
