import AppKit
import SwiftUI
import ActionFlowCore

@main
struct ActionFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("ActionFlow", id: "main") {
            MainView()
                .environmentObject(model)
                .frame(minWidth: 1220, minHeight: 680)
                .tint(Color(red: 0.17, green: 0.49, blue: 0.36))
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.shutdown() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshPermissions() }
                .onAppear { delegate.reopenEditor = { openWindow(id: "main") } }
        }
        .defaultSize(width: 1220, height: 790)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Rule") { model.addRule() }.keyboardShortcut("n")
                Button("Import Rules…") { model.importRules() }.keyboardShortcut("o")
                Button("Export Rules…") { model.exportRules() }.keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandMenu("Automation") {
                Button(AppLocalization.text(model.configuration.automationEnabled ? "Pause Automation" : "Resume Automation")) { model.toggleAutomation() }
                Button("Stop Current Action Chain") { model.stopExecution() }.keyboardShortcut(".", modifiers: [.command])
                Divider()
                Button("Permissions") { model.section = .permissions; showMainWindow() }
            }
        }
        MenuBarExtra {
            Text("ActionFlow").font(.headline)
            Button("Open Rule Editor") { showMainWindow() }
            Divider()
            Button(AppLocalization.text(model.configuration.automationEnabled ? "Pause Automation" : "Resume Automation")) { model.toggleAutomation() }
            Button("Stop Current Actions") { model.stopExecution() }.disabled(!model.isExecuting)
            Text(String(format: AppLocalization.text("%lld enabled rules"), Int64(model.configuration.rules.filter(\.enabled).count)))
            Divider()
            Button("Quit ActionFlow") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Image(systemName: model.configuration.automationEnabled ? "hand.draw.fill" : "hand.draw")
                .accessibilityLabel(AppLocalization.text(model.configuration.automationEnabled ? "ActionFlow running" : "ActionFlow paused"))
        }
    }

    private func showMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first(where: { $0.title.contains("ActionFlow") && $0.canBecomeKey }) { window.makeKeyAndOrderFront(nil) }
        else { openWindow(id: "main") }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var reopenEditor: (() -> Void)?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let window = sender.windows.first(where: \.canBecomeKey) { window.makeKeyAndOrderFront(nil) }
            else { reopenEditor?() }
        }
        return true
    }
}
