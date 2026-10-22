import SwiftUI
import AppKit
import ActionFlowCore
import UniformTypeIdentifiers

enum ForgeStyle {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? NSColor(red: 0.40, green: 0.76, blue: 0.59, alpha: 1) : NSColor(red: 0.15, green: 0.43, blue: 0.31, alpha: 1)
    })
    static let panel = Color(nsColor: .controlBackgroundColor)
}

struct ForgeEmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(AppLocalization.text(title))
                .font(.system(size: 18, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(AppLocalization.text(message))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 330)
            actions().padding(.top, 3)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ForgePanel<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .padding(17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ForgeStyle.panel, in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
            }
    }
}

struct FlowSection<Content: View>: View {
    let number: String
    let title: String
    let subtitle: String
    var isLast = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Text(number)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ForgeStyle.accent)
                    .frame(width: 27, height: 27)
                    .background(ForgeStyle.accent.opacity(0.10), in: Circle())
                    .overlay { Circle().strokeBorder(ForgeStyle.accent.opacity(0.28)) }
                if !isLast {
                    Rectangle().fill(ForgeStyle.accent.opacity(0.22))
                        .frame(width: 1)
                        .padding(.top, 5)
                }
            }
            VStack(alignment: .leading, spacing: 11) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppLocalization.text(title)).font(.system(size: 15, weight: .semibold))
                    Text(AppLocalization.text(subtitle)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 3)
                content()
            }
            .padding(.bottom, isLast ? 0 : 23)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct ForgeNote: View {
    let text: String
    var symbol = "info.circle"
    var warning = false
    var localizesText = true

    var body: some View {
        Label {
            Text(localizesText ? AppLocalization.text(text) : text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.caption)
        .foregroundStyle(warning ? Color.orange : Color.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EditorField<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppLocalization.text(title)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ModifierEditor: View {
    @Binding var modifiers: ModifierKeys

    private let choices: [(String, String, ModifierKeys)] = [
        ("⌃", "Control", .control), ("⌥", "Option", .option),
        ("⇧", "Shift", .shift), ("⌘", "Command", .command)
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(choices, id: \.1) { choice in
                Toggle(isOn: Binding(
                    get: { modifiers.contains(choice.2) },
                    set: { enabled in
                        if enabled { modifiers.insert(choice.2) }
                        else { modifiers.remove(choice.2) }
                    }
                )) {
                    Text(choice.0)
                        .font(.system(size: 15, weight: .medium))
                        .frame(minWidth: 25)
                }
                .toggleStyle(.button)
                .accessibilityLabel(String(format: AppLocalization.text("%@ modifier"), AppLocalization.text(choice.1)))
                .help(AppLocalization.text(choice.1))
            }
            Spacer(minLength: 0)
        }
    }
}

struct KeyCodeEditor: View {
    @Binding var keyCode: UInt16

    private static let keys: [(UInt16, String)] = [
        (0, "A"), (11, "B"), (8, "C"), (2, "D"), (14, "E"), (3, "F"),
        (5, "G"), (4, "H"), (34, "I"), (38, "J"), (40, "K"), (37, "L"),
        (46, "M"), (45, "N"), (31, "O"), (35, "P"), (12, "Q"), (15, "R"),
        (1, "S"), (17, "T"), (32, "U"), (9, "V"), (13, "W"), (7, "X"),
        (16, "Y"), (6, "Z"), (29, "0"), (18, "1"), (19, "2"), (20, "3"),
        (21, "4"), (23, "5"), (22, "6"), (26, "7"), (28, "8"), (25, "9"),
        (36, "Return"), (48, "Tab"), (49, "Space"), (51, "Delete"), (53, "Escape"),
        (123, "← Left"), (124, "→ Right"), (125, "↓ Down"), (126, "↑ Up"),
        (122, "F1"), (120, "F2"), (99, "F3"), (118, "F4"), (96, "F5"),
        (97, "F6"), (98, "F7"), (100, "F8"), (101, "F9"), (109, "F10"),
        (103, "F11"), (111, "F12")
    ]

    var body: some View {
        HStack(spacing: 12) {
            Picker("Key", selection: $keyCode) {
                ForEach(Self.keys, id: \.0) { key in
                    Text(AppLocalization.text(key.1)).tag(key.0)
                }
                if !Self.keys.contains(where: { $0.0 == keyCode }) {
                    Text("Key code \(keyCode)").tag(keyCode)
                }
            }
            TextField("Code", value: $keyCode, format: .number)
                .frame(width: 58)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Virtual key code")
                .help("macOS virtual key code. Key labels use the US keyboard layout.")
        }
    }
}

struct ApplicationIdentifierField: View {
    let title: String
    @Binding var identifier: String

    var body: some View {
        HStack {
            TextField(AppLocalization.text(title), text: $identifier)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(AppLocalization.text(title))
            Button("Choose…") {
                if let selected = chooseApplicationIdentifier() { identifier = selected }
            }
            .help("Choose an application to use its bundle identifier")
        }
    }
}

@MainActor
func chooseApplicationIdentifier() -> String? {
    let panel = NSOpenPanel()
    panel.title = AppLocalization.text("Choose an application")
    panel.message = AppLocalization.text("ActionFlow uses the application's bundle identifier.")
    panel.allowedContentTypes = [.application]
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return Bundle(url: url)?.bundleIdentifier
}

extension TriggerKind {
    var forgeSymbol: String {
        switch self {
        case .shortcut: return "command"
        case .doubleShortcut: return "repeat"
        case .mouseButton: return "computermouse"
        case .scroll: return "arrow.up.and.down"
        case .appActivated: return "app.badge"
        case .appLaunched: return "app.badge.checkmark"
        case .appTerminated: return "xmark.app"
        case .interval: return "timer"
        }
    }
}

extension ActionKind {
    var forgeSymbol: String {
        switch self {
        case .window: return "macwindow"
        case .keyboardShortcut: return "command"
        case .insertText: return "text.cursor"
        case .openURL: return "link"
        case .launchApp: return "app"
        case .delay: return "hourglass"
        case .notification: return "bell"
        case .shellScript: return "terminal"
        case .menuCommand: return "menubar.rectangle"
        }
    }
}
