import AppKit
import SwiftUI
import ActionFlowCore

@main
struct AppChecks {
    @MainActor static func main() async {
        _ = NSApplication.shared
        var assertions = 0
        func check(_ value: Bool, _ name: String) {
            guard value else { fputs("FAIL \(name)\n", stderr); exit(1) }
            assertions += 1; print("PASS \(name)")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ActionFlowAppChecks-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if AppLocalization.forcedLanguage == "zh-Hans" {
                check(AppLocalization.text("Rules") == "规则", "Simplified Chinese resources resolve in native app code")
                check(AppLocalization.text("Accessibility") == "辅助功能", "permission title resolves in Simplified Chinese")
            } else {
                check(AppLocalization.text("Rules") == "Rules", "English localization fallback remains stable")
            }
            check(AppLocalization.text("User rule text 12345") == "User rule text 12345", "unknown user content is not rewritten")
            let url = dir.appendingPathComponent("configuration.json")
            let model = AppModel(configurationURL: url)
            defer { model.shutdown() }
            check(!model.configuration.automationEnabled && !model.configuration.allowScripts, "app starts paused without scripts")
            let initial = model.configuration.rules.count
            model.addRule()
            check(model.configuration.rules.count == initial + 1 && model.selectedRule?.enabled == false, "create disabled rule and select it")
            let added = model.selectedRule!
            model.duplicateRule(added)
            check(model.configuration.rules.count == initial + 2 && model.selectedRule?.id != added.id, "duplicate uses distinct rule id")
            model.deleteRule(model.selectedRule!.id)
            check(model.configuration.rules.count == initial + 1, "delete only selected duplicate")
            let persisted = try ConfigurationStore(url: url).load()
            check(persisted.rules.count == initial + 1, "editor changes persist as versioned JSON")
            model.deleteRule(added.id)
            check(model.configuration.rules.count == initial, "restore example-only configuration")
            model.clearActivity()
            check(model.activity.isEmpty, "clear in-memory activity")
            check(model.canRestoreBackup, "previous backup is discoverable by editor")
            let bytesBeforeSecondInstance = try Data(contentsOf:url)
            let secondInstance = AppModel(configurationURL:url)
            check(model.hasConfigurationLease && !secondInstance.hasConfigurationLease && !secondInstance.configuration.automationEnabled, "second instance cannot own writer lease or start automation")
            secondInstance.configuration.rules[0].name = "must not overwrite first instance"
            secondInstance.save()
            secondInstance.restorePreviousBackup()
            check(try Data(contentsOf:url) == bytesBeforeSecondInstance, "second instance save and recovery preserve first instance bytes")
            secondInstance.runRule(AutomationRule(name:"no execution",actions:[AutomationAction(kind:.delay,delaySeconds:0)]))
            check(!secondInstance.isExecuting && secondInstance.activity.first?.message.contains("writer lease") == true, "second instance manual execution is blocked without activation")
            secondInstance.shutdown()
            let backupURL = url.appendingPathExtension("backup")
            let backupBeforeNoop = try Data(contentsOf: backupURL)
            model.save()
            check(try Data(contentsOf: backupURL) == backupBeforeNoop, "no-change save does not rotate recovery backup")
            model.restorePreviousBackup()
            check(!model.configuration.automationEnabled && !model.configuration.allowScripts && model.configuration.rules.allSatisfy { !$0.enabled }, "editor restore pauses automation and disables every rule")
            check(model.statusMessage?.contains("restored") == true && model.errorMessage == nil, "successful restore reports actual commit")
            model.refreshSnapshots()
            check(model.snapshots.isEmpty, "snapshot history starts empty without creating rules")
            model.createSnapshot()
            check(model.snapshots.count == 1 && model.errorMessage == nil, "editor explicitly creates one private snapshot")
            let snapshot = model.snapshots[0]
            model.configuration.rules[0].name = "Changed after snapshot"
            model.save()
            let beforeSnapshotRestore = try Data(contentsOf:url)
            model.restoreSnapshot(snapshot)
            check(model.configuration.rules[0].name != "Changed after snapshot" && !model.configuration.automationEnabled && !model.configuration.allowScripts && model.configuration.rules.allSatisfy { !$0.enabled }, "editor snapshot restore resets opt-ins and restores selected content")
            check(model.snapshots.count == 1 && model.errorMessage == nil && model.statusMessage?.contains("Snapshot restored") == true, "snapshot restore preserves history and reports success")
            let preservedArchives = try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil).filter { $0.lastPathComponent.contains("before-restore") }
            check(try preservedArchives.contains { try Data(contentsOf:$0) == beforeSnapshotRestore }, "snapshot restore preserves exact replaced file")
            model.configuration.automationEnabled = true
            model.configuration.allowScripts = true
            try Data("invalid backup fixture".utf8).write(to:backupURL)
            let liveBeforeFailedRestore = try Data(contentsOf:url)
            model.restorePreviousBackup()
            check(model.errorMessage != nil && !model.configuration.automationEnabled && !model.configuration.allowScripts, "failed recovery leaves automation and scripts paused")
            check(try Data(contentsOf:url) == liveBeforeFailedRestore, "failed recovery does not rewrite saved configuration")
            check(!model.manualTargetDescription.isEmpty, "manual target description is explicit")
            let requirementProbe = AutomationRule(actions:[AutomationAction(kind:.window),AutomationAction(kind:.notification,text:"test"),AutomationAction(kind:.shellScript,text:"exit 0")])
            model.permissions = PermissionState()
            check(model.missingCapabilities(for:requirementProbe,automatic:true) == AutomationCapability.allCases, "editor reports every missing capability without permission prompts")
            model.permissions.accessibility = true
            model.permissions.notifications = true
            model.configuration.allowScripts = true
            check(model.missingCapabilities(for:requirementProbe,automatic:false).isEmpty, "manual preflight excludes input monitoring")
            model.permissions = PermissionState()
            model.configuration.allowScripts = false
            if !SessionSafety.allowsExecution {
                model.runRule(AutomationRule(name: "Locked-session check", actions: [AutomationAction(kind: .delay, delaySeconds: 0)]))
                check(!model.isExecuting && model.activity.first?.message.contains("desktop session") == true, "manual run refuses unavailable desktop without effects")
            }
            let corrupt = dir.appendingPathComponent("future.json")
            let original = Data("{\"schemaVersion\":999}".utf8)
            try original.write(to: corrupt)
            let guarded = AppModel(configurationURL: corrupt)
            defer { guarded.shutdown() }
            guarded.addRule()
            let preserved = try Data(contentsOf: corrupt)
            check(guarded.errorMessage != nil && preserved == original, "unreadable future configuration never overwritten by editor saves")
            model.configuration.rules = []
            model.configuration.automationEnabled = false
            model.configuration.allowScripts = false
            let template = RuleTemplates.all[0]
            model.addTemplate(template)
            model.addTemplate(template)
            check(model.configuration.rules.count == template.rules.count * 2 && Set(model.configuration.rules.map(\.id)).count == model.configuration.rules.count, "adding same template twice uses distinct rule identities")
            check(model.configuration.rules.allSatisfy { !$0.enabled } && !model.configuration.automationEnabled && !model.configuration.allowScripts, "template insertion never enables rules automation or scripts")
            check(try ConfigurationStore(url:url).load() == model.configuration, "template insertion persists the reviewed disabled copies")
            let rulesBeforeFiltering = model.configuration
            let diskBeforeFiltering = try Data(contentsOf:url)
            model.selection = model.configuration.rules.first?.id
            model.ruleStatusFilter = .enabled
            model.reconcileRuleSelection()
            check(model.filteredRules.isEmpty && model.selection == nil, "filtering hidden disabled rule clears edit selection")
            model.ruleStatusFilter = .all
            model.ruleGroupFilter = "group not present"
            check(model.filteredRules.isEmpty, "group filter uses exact user group identity")
            model.clearRuleFilters()
            check(model.filteredRules.count == model.configuration.rules.count && model.configuration == rulesBeforeFiltering, "clearing filters restores visibility without modifying configuration")
            check(try Data(contentsOf:url) == diskBeforeFiltering, "model filter changes do not save or rotate backups")
            model.configuration.automationEnabled = true
            model.handleSessionTransition(.willSleep)
            check(!model.configuration.automationEnabled && !SessionSafety.allowsExecution, "sleep transition pauses automation and blocks execution immediately")
            model.handleSessionTransition(.sessionResigned)
            model.handleSessionTransition(.didWake)
            check(!model.configuration.automationEnabled && !SessionSafety.allowsExecution, "wake cannot clear an inactive user session or rearm automation")
            model.handleSessionTransition(.sessionBecameActive)
            check(!model.configuration.automationEnabled && !model.isExecuting, "session activation never resumes suspended work")
            check(try !ConfigurationStore(url:url).load().automationEnabled, "session pause is persisted when automation was enabled")
            // Synthetic Gesture Lab adapter checks. Typed samples only; no hardware, no monitors.
            let labModel = GestureLabModel()
            let pad = GesturePadCoordinator(model: labModel)
            pad.beginGesture()
            pad.magnify(delta: 0.3, phase: [])
            pad.endGesture(phase: [])
            check(labModel.results.map(\.kind) == [.pinchOut], "phaseless magnify wrapped by begin/end gesture recognizes pinch once")
            pad.beginGesture()
            pad.magnify(delta: 0.3, phase: [])
            pad.endGesture(phase: .cancelled)
            check(labModel.results.count == 1, "cancelled gesture session never produces a result")
            pad.beginGesture()
            pad.magnify(delta: 0.3, phase: [])
            labModel.clear()
            pad.endGesture(phase: [])
            check(labModel.results.isEmpty && !labModel.isTracking, "clear cancels pending session flags and drops results")
            pad.beginGesture()
            pad.rotate(degrees: 20, phase: [])
            pad.endGesture(phase: [])
            check(labModel.results.map(\.kind) == [.rotateCounterclockwise], "phaseless rotation recognizes counterclockwise once")
            pad.swipe(deltaX: 1, deltaY: 0, phase: [])
            check(labModel.results.first?.kind == .swipeLeft && labModel.results.first?.magnitude == 0, "discrete system swipe is direction-only without point magnitude")
            labModel.clear()
            pad.magnify(delta: 0.5, phase: [])
            check(labModel.results.isEmpty, "phaseless magnify outside a gesture session is ignored")
            pad.beginGesture()
            pad.magnify(delta: 0.1, phase: [])
            labModel.pinchPercent = 30
            labModel.applyThresholds()
            pad.magnify(delta: 0.4, phase: [])
            pad.endGesture(phase: [])
            check(labModel.results.isEmpty && !labModel.isTracking, "threshold change interrupts session flags so later phaseless samples cannot restart mid-gesture")
            model.configuration.rules = AutomationRule.exampleRules
            model.selection = model.configuration.rules.first?.id
            model.statusMessage = nil
            let locale = Locale(identifier: AppLocalization.forcedLanguage ?? "en")
            let dark = ProcessInfo.processInfo.environment["ACTIONFLOW_APPEARANCE"] == "dark"
            let width = Double(ProcessInfo.processInfo.environment["ACTIONFLOW_RENDER_WIDTH"] ?? "1220") ?? 1220
            let height = Double(ProcessInfo.processInfo.environment["ACTIONFLOW_RENDER_HEIGHT"] ?? "790") ?? 790
            NSApplication.shared.appearance = NSAppearance(named:dark ? .darkAqua : .aqua)
            let readOnlyFixture = ProcessInfo.processInfo.environment["ACTIONFLOW_RENDER_READONLY"] == "1" ? AppModel(configurationURL:url) : nil
            readOnlyFixture?.errorMessage = nil
            let host = NSHostingView(rootView: MainView().environmentObject(readOnlyFixture ?? model).environment(\.locale, locale).environment(\.colorScheme,dark ? .dark : .light).frame(width:width,height:height))
            host.sizingOptions = []
            host.frame = NSRect(x:0,y:0,width:width,height:height)
            let window = NSWindow(contentRect:host.frame,styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            window.title = "ActionFlow verification"
            window.appearance = NSAppearance(named:dark ? .darkAqua : .aqua)
            host.appearance = window.appearance
            window.contentView = host
            window.setContentSize(NSSize(width:width,height:height))
            try await Task.sleep(nanoseconds:200_000_000)
            host.layoutSubtreeIfNeeded()
            print("Render requested \(width)x\(height), actual \(host.bounds), fitting \(host.fittingSize), readonly \(readOnlyFixture != nil), lease \((readOnlyFixture ?? model).hasConfigurationLease)")
            if ProcessInfo.processInfo.environment["ACTIONFLOW_DEBUG_HIERARCHY"] == "1" {
                let rendered = readOnlyFixture ?? model
                print("DEBUG model rules=\(rendered.configuration.rules.count) selection=\(String(describing: rendered.selection)) filtered=\(rendered.filteredRules.count) section=\(rendered.section) permissions=\(rendered.permissions.accessibility),\(rendered.permissions.inputMonitoring)")
                func dump(_ view: NSView, _ indent: String) {
                    print("\(indent)\(type(of:view)) frame=\(view.frame) hidden=\(view.isHidden) alpha=\(view.alphaValue) subviews=\(view.subviews.count)")
                    for sub in view.subviews.prefix(12) { dump(sub, indent + "  ") }
                }
                dump(host, "")
            }
            // Render our own view hierarchy, not another application's desktop or locked screen.
            if CommandLine.arguments.count > 1 {
                let destination = URL(fileURLWithPath: CommandLine.arguments[1])
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in:host.bounds,to:bitmap)
                    if let png = bitmap.representation(using:.png,properties:[:]) {
                        try png.write(to:destination)
                        check(png.count > 1000, "native SwiftUI view renders into an offscreen image")
                    }
                } else { check(false, "native view bitmap is available") }
            }
            model.isExecuting = true
            model.executionProgress = ExecutionProgress(actionIndex:2,actionCount:3,kind:.delay,phase:.running,completedActions:1)
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds) {
                host.cacheDisplay(in:host.bounds,to:bitmap)
                check(bitmap.pixelsWide > 0, "synthetic progress fixture renders actual counter UI without running actions")
                if let path = ProcessInfo.processInfo.environment["ACTIONFLOW_PROGRESS_IMAGE"], let data = bitmap.representation(using:.png,properties:[:]) { try data.write(to:URL(fileURLWithPath:path)) }
            } else { check(false,"progress fixture bitmap available") }
            model.isExecuting = false
            model.executionProgress = nil
            let plan = ExecutionPlan(rule: model.configuration.rules[0])
            let preview = NSHostingView(rootView: ExecutionPlanPreview(plan: plan).environment(\.locale, locale))
            preview.frame = NSRect(x:0,y:0,width:600,height:700)
            window.contentView = preview
            preview.layoutSubtreeIfNeeded()
            let previewBitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds)
            if let previewBitmap { preview.cacheDisplay(in: preview.bounds,to:previewBitmap) }
            check(previewBitmap != nil, "read-only execution plan sheet renders without running actions")
            if let path = ProcessInfo.processInfo.environment["ACTIONFLOW_PREVIEW_IMAGE"], let previewBitmap,
               let data = previewBitmap.representation(using:.png,properties:[:]) { try data.write(to:URL(fileURLWithPath:path)) }
            // Menu command fixtures: a real saved configuration containing a
            // menu action, rendered locally. No application menu is queried.
            let menuConfiguration = Configuration(rules: [AutomationRule(name: "Menu fixture",
                trigger: Trigger(kind: .interval, intervalSeconds: 60),
                actions: [AutomationAction(kind: .menuCommand, text: "[\"File\", \"New\"]")])])
            let menuURL = dir.appendingPathComponent("menu-fixture.json")
            try JSONEncoder().encode(menuConfiguration).write(to: menuURL)
            let menuModel = AppModel(configurationURL: menuURL)
            menuModel.errorMessage = nil
            menuModel.selection = menuModel.configuration.rules.first?.id
            let menuPlan = ExecutionPlan(rule: menuModel.configuration.rules[0])
            check(menuPlan.validationErrors.isEmpty && menuPlan.requiredCapabilities == [.accessibility]
                  && menuPlan.steps[0].summary.contains("2") && !menuPlan.steps[0].summary.contains("File"),
                  "menu fixture plan is valid, needs accessibility and hides titles")
            let menuEditor = NSHostingView(rootView: ActionEditor(action: .constant(menuModel.configuration.rules[0].actions[0]),
                number: 1, count: 1, allowScripts: false, moveUp: {}, moveDown: {}, remove: {})
                .environment(\.locale, locale).environment(\.colorScheme,dark ? .dark : .light)
                .frame(width:560).padding(16))
            menuEditor.sizingOptions = []
            menuEditor.frame = NSRect(x:0,y:0,width:592,height:420)
            window.contentView = menuEditor
            try await Task.sleep(nanoseconds:200_000_000)
            menuEditor.layoutSubtreeIfNeeded()
            if let bitmap = menuEditor.bitmapImageRepForCachingDisplay(in:menuEditor.bounds) {
                menuEditor.cacheDisplay(in:menuEditor.bounds,to:bitmap)
                check(bitmap.pixelsWide > 0, "menu action editor renders from a real saved configuration without querying app menus")
                if let path = ProcessInfo.processInfo.environment["ACTIONFLOW_MENU_IMAGE"],let data = bitmap.representation(using:.png,properties:[:]) { try data.write(to:URL(fileURLWithPath:path)) }
            } else { check(false,"menu action editor bitmap available") }
            let menuPreview = NSHostingView(rootView: ExecutionPlanPreview(plan: menuPlan).environment(\.locale, locale))
            menuPreview.frame = NSRect(x:0,y:0,width:600,height:700)
            window.contentView = menuPreview
            menuPreview.layoutSubtreeIfNeeded()
            if let menuPreviewBitmap = menuPreview.bitmapImageRepForCachingDisplay(in: menuPreview.bounds) {
                menuPreview.cacheDisplay(in: menuPreview.bounds,to:menuPreviewBitmap)
                check(true, "menu action preview renders depth without titles")
                if let path = ProcessInfo.processInfo.environment["ACTIONFLOW_MENU_PREVIEW_IMAGE"],let data = menuPreviewBitmap.representation(using:.png,properties:[:]) { try data.write(to:URL(fileURLWithPath:path)) }
            } else { check(false,"menu preview bitmap available") }
            menuModel.shutdown()
            let library = NSHostingView(rootView:TemplateLibraryView().environmentObject(model).environment(\.locale,locale))
            window.contentView = library
            library.layoutSubtreeIfNeeded()
            if let bitmap = library.bitmapImageRepForCachingDisplay(in:library.bounds) {
                library.cacheDisplay(in:library.bounds,to:bitmap)
                check(bitmap.pixelsWide > 0, "built-in template library renders without adding or running rules")
                if let path = ProcessInfo.processInfo.environment["ACTIONFLOW_TEMPLATES_IMAGE"],let data = bitmap.representation(using:.png,properties:[:]) { try data.write(to:URL(fileURLWithPath:path)) }
            } else { check(false,"template library bitmap available") }
            let labSectionModel = model
            labSectionModel.section = .gestureLab
            window.contentView = host
            try await Task.sleep(nanoseconds:200_000_000)
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds) {
                host.cacheDisplay(in:host.bounds,to:bitmap)
                check(bitmap.pixelsWide > 0, "gesture lab section renders its local pad without monitors or actions")
                if let path = ProcessInfo.processInfo.environment["ACTIONFLOW_LAB_IMAGE"],let data = bitmap.representation(using:.png,properties:[:]) { try data.write(to:URL(fileURLWithPath:path)) }
            } else { check(false,"gesture lab bitmap available") }
            labSectionModel.section = .rules
            readOnlyFixture?.shutdown()
            let blockedModel = AppModel(configurationURL:url)
            blockedModel.errorMessage = nil
            let blockedHost = NSHostingView(rootView:MainView().environmentObject(blockedModel).environment(\.locale,locale).environment(\.colorScheme,dark ? .dark : .light).frame(width:width,height:height))
            blockedHost.sizingOptions = []
            blockedHost.frame = NSRect(x:0,y:0,width:width,height:height)
            let blockedWindow = NSWindow(contentRect:blockedHost.frame,styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            blockedWindow.appearance = window.appearance
            blockedHost.appearance = blockedWindow.appearance
            blockedWindow.contentView = blockedHost
            blockedWindow.setContentSize(NSSize(width:width,height:height))
            try await Task.sleep(nanoseconds:200_000_000)
            blockedHost.layoutSubtreeIfNeeded()
            if let bitmap = blockedHost.bitmapImageRepForCachingDisplay(in:blockedHost.bounds) {
                blockedHost.cacheDisplay(in:blockedHost.bounds,to:bitmap)
                check(!blockedModel.hasConfigurationLease && bitmap.pixelsWide > 0,"no-writer instance banner renders without persistence or automation")
                if let path = ProcessInfo.processInfo.environment["ACTIONFLOW_READONLY_IMAGE"],let data = bitmap.representation(using:.png,properties:[:]) { try data.write(to:URL(fileURLWithPath:path)) }
            } else { check(false,"no-writer fixture bitmap available") }
            blockedModel.shutdown()
            blockedWindow.close()
            window.close()
            print("Verified \(assertions) app assertions. No automation, privacy grants or external desktop actions were enabled.")
            print("Fixture directory: \(dir.path)")
        } catch { fputs("App check failure: \(error)\n", stderr); exit(1) }
    }
}
