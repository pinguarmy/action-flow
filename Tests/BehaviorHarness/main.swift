import Foundation
import Darwin
import CoreGraphics
import ActionFlowCore

// Portable behavior checks for machines with Command Line Tools but no XCTest.
// This executable only touches its own temporary fixture directory.
var assertions = 0

func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
    guard try value() else {
        throw NSError(domain: "ActionFlowChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: name])
    }
    assertions += 1
    print("PASS \(name)")
}

func rejects(_ name: String, _ body: () throws -> Void) throws {
    do {
        try body()
    } catch {
        assertions += 1
        print("PASS \(name): \(error.localizedDescription.prefix(120))")
        return
    }
    throw NSError(domain: "ActionFlowChecks", code: 2,
                  userInfo: [NSLocalizedDescriptionKey: "Expected rejection: \(name)"])
}

let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("ActionFlowChecks-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
// Retain fixtures on failure so the exact bytes can be inspected.
do {
    let store = ConfigurationStore(url: directory.appendingPathComponent("configuration.json"))
    let defaults = try store.load()
    try check(!defaults.automationEnabled && !defaults.allowScripts && !defaults.launchAtLogin, "safe defaults")
    try check(defaults.rules.allSatisfy { !$0.enabled && RuleValidator.validate($0).isEmpty }, "disabled valid examples")

    let original = Configuration(rules: [AutomationRule(name: "Original")])
    try store.save(original)
    let previous = try Data(contentsOf: store.url)
    var draft = AutomationRule(name: "", actions: [])
    try store.save(Configuration(rules: [draft]))
    try check(try Data(contentsOf: store.backupURL) == previous, "exact previous bytes backup")
    try check(try store.load().rules == [draft], "disabled incomplete draft persists")
    draft.enabled = true
    try rejects("enabled incomplete draft rejected") {
        try store.save(Configuration(rules: [draft]))
    }

    let source = directory.appendingPathComponent("import.json")
    let imported = Configuration(rules: [AutomationRule(name: "Imported", enabled: true)],
                                 automationEnabled: true, allowScripts: true, launchAtLogin: true)
    try JSONEncoder().encode(imported).write(to: source)
    let liveBytes = try Data(contentsOf: store.url)
    let result = try store.importConfiguration(from: source)
    try check(!result.automationEnabled && !result.allowScripts && !result.launchAtLogin,
              "import resets every execution opt-in")
    try check(result.rules == imported.rules, "import preserves rule data")
    try check(try Data(contentsOf: store.url) == liveBytes, "import leaves live file unchanged")

    let export = directory.appendingPathComponent("export.json")
    try store.exportConfiguration(original, to: export)
    try check(try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: export)) == original,
              "real JSON export roundtrip")
    try rejects("export cannot overwrite live file") {
        try store.exportConfiguration(original, to: store.url)
    }

    let futureBytes = Data("{\"schemaVersion\":999,\"rules\":\"future shape\"}".utf8)
    try futureBytes.write(to: store.url)
    try rejects("future schema load rejected") { _ = try store.load() }
    try rejects("future file cannot be downgraded by save") { try store.save(original) }
    try check(try Data(contentsOf: store.url) == futureBytes, "future original preserved")

    let corrupt = Data("broken JSON".utf8)
    try corrupt.write(to: store.url)
    try rejects("corrupt load rejected") { _ = try store.load() }
    try store.save(original)
    try check(try Data(contentsOf: store.backupURL) == corrupt, "explicit recovery preserves corrupt bytes")

    let oversized = directory.appendingPathComponent("oversized.json")
    try Data(repeating: 32, count: ConfigurationStore.maximumFileBytes + 1).write(to: oversized)
    try rejects("oversized import rejected before decode") {
        _ = try store.importConfiguration(from: oversized)
    }

    for text in ["https://example.com", "http://localhost:8080", "mailto:person@example.com"] {
        try check(RuleValidator.validate(AutomationRule(actions: [AutomationAction(kind: .openURL, text: text)])).isEmpty,
                  "allowed URL \(text)")
    }
    for text in ["javascript:alert(1)", "file:///etc/passwd", "https://", "mailto:"] {
        try check(!RuleValidator.validate(AutomationRule(actions: [AutomationAction(kind: .openURL, text: text)])).isEmpty,
                  "blocked URL \(text)")
    }

    // Opaque mailto URLs have no URL.path on some supported Foundation versions.
    for text in ["MAILTO:person@example.com", "MailTo:person%40example.com?subject=Hello",
                 "mailto:person%2Btag@example.com", "mailto:person@example.com,other%40example.com?body=Hello%20there"] {
        try check(RuleValidator.validate(AutomationRule(actions: [AutomationAction(kind: .openURL, text: text)])).isEmpty,
                  "allowed opaque mailto \(text)")
    }
    for text in ["mailto:?subject=Hello", "MAILTO:?to=person@example.com", "mailto:#person@example.com",
                 "mailto:person", "mailto:@example.com", "mailto:person@", "mailto:person%0A@example.com",
                 "mailto:person%00@example.com", "mailto:%20?to=person@example.com", "mailto:person%ZZ@example.com",
                 "mailto://person@example.com", "mailto:person@example.com,"] {
        try check(!RuleValidator.validate(AutomationRule(actions: [AutomationAction(kind: .openURL, text: text)])).isEmpty,
                  "blocked invalid opaque mailto \(text)")
    }

    let first = AutomationRule(name: "First", enabled: true)
    var second = AutomationRule(name: "Second", enabled: true)
    try check(RuleValidator.conflicts(in: [first, second]).count == 1, "same enabled trigger conflicts")
    second.conditions = RuleConditions(appBundleIdentifiers: ["com.apple.Safari"])
    var scopedFirst = first
    scopedFirst.conditions = RuleConditions(excludedAppBundleIdentifiers: ["com.apple.Safari"])
    try check(RuleValidator.conflicts(in: [scopedFirst, second]).isEmpty,
              "disjoint app conditions do not conflict")

    for seconds in [0.0, 0.9, 86_401, Double.nan] {
        try check(!RuleValidator.validate(AutomationRule(trigger: Trigger(kind: .interval, intervalSeconds: seconds))).isEmpty,
                  "invalid interval \(seconds)")
    }
    try check(RuleValidator.validate(AutomationRule(trigger: Trigger(kind: .interval, intervalSeconds: 1))).isEmpty,
              "one second interval accepted")

    let recovery = ConfigurationStore(url: directory.appendingPathComponent("recovery.json"))
    let recoverySource = Configuration(rules: [AutomationRule(name: "Recovery", enabled: true)],
                                       automationEnabled: true, allowScripts: true, launchAtLogin: true)
    let recoveryBytes = try JSONEncoder().encode(recoverySource)
    let damagedBytes = Data("damaged recovery current file".utf8)
    try recoveryBytes.write(to: recovery.backupURL)
    try damagedBytes.write(to: recovery.url)
    let recovered = try recovery.restoreBackup()
    try check(!recovered.configuration.automationEnabled && !recovered.configuration.allowScripts &&
              !recovered.configuration.launchAtLogin, "restore disables every global opt-in")
    try check(recovered.configuration.rules.allSatisfy { !$0.enabled }, "restore disables every rule")
    try check(recovered.configuration.rules.map(\.id) == recoverySource.rules.map(\.id), "restore retains rule identities")
    try check(try recovery.load() == recovered.configuration, "restored live JSON matches return value")
    try check(recovered.preservedCurrentFileURL != nil, "restore returns archive location")
    if let archive = recovered.preservedCurrentFileURL {
        try check(try Data(contentsOf: archive) == damagedBytes, "restore archive preserves exact damaged bytes")
        let permissions = try FileManager.default.attributesOfItem(atPath: archive.path)
        try check((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600, "recovery archive is private 0600")
        let secondRestore = try recovery.restoreBackup()
        try check(secondRestore.preservedCurrentFileURL != archive, "repeated restore creates distinct archive")
        try check(try Data(contentsOf: archive) == damagedBytes, "repeated restore never overwrites earlier archive")
    }
    try check(try Data(contentsOf: recovery.backupURL) == recoveryBytes, "restores never modify source backup")

    let missingCurrent = ConfigurationStore(url: directory.appendingPathComponent("missing-current.json"))
    try recoveryBytes.write(to: missingCurrent.backupURL)
    let missingResult = try missingCurrent.restoreBackup()
    try check(missingResult.preservedCurrentFileURL == nil, "missing current file needs no archive")
    try check(try missingCurrent.load() == missingResult.configuration, "missing current file is restored")

    let rejectedRestore = ConfigurationStore(url: directory.appendingPathComponent("rejected-restore.json"))
    try damagedBytes.write(to: rejectedRestore.url)
    try rejects("missing backup rejected") { _ = try rejectedRestore.restoreBackup() }
    try check(try Data(contentsOf: rejectedRestore.url) == damagedBytes, "missing backup leaves current bytes unchanged")
    for source in [Data("broken backup".utf8), Data("{\"schemaVersion\":999,\"rules\":[]}".utf8),
                   Data(repeating: 32, count: ConfigurationStore.maximumFileBytes + 1)] {
        try source.write(to: rejectedRestore.backupURL)
        try rejects("invalid backup rejected before restore") { _ = try rejectedRestore.restoreBackup() }
        try check(try Data(contentsOf: rejectedRestore.url) == damagedBytes, "invalid backup leaves current bytes unchanged")
        try check(try Data(contentsOf: rejectedRestore.backupURL) == source, "invalid backup remains exact")
    }
    let futureCurrent = Data("{\"schemaVersion\":999,\"rules\":\"future shape\"}".utf8)
    try futureCurrent.write(to: rejectedRestore.url)
    try recoveryBytes.write(to: rejectedRestore.backupURL)
    try rejects("restore cannot overwrite future current schema") { _ = try rejectedRestore.restoreBackup() }
    try check(try Data(contentsOf: rejectedRestore.url) == futureCurrent, "future current bytes preserved during recovery")
    try check(try Data(contentsOf: rejectedRestore.backupURL) == recoveryBytes, "future rejection preserves backup")
    let rejectedArchives = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        .filter { $0.hasPrefix("rejected-restore.json.before-restore-") }
    try check(rejectedArchives.isEmpty, "failed preflight never creates recovery archive")

    let privateExport = directory.appendingPathComponent("private-export.json")
    try Data("public old export".utf8).write(to: privateExport)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: privateExport.path)
    try store.exportConfiguration(original, to: privateExport)
    for file in [store.url, store.backupURL, privateExport] {
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)
        try check((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                  "secure writer publishes private file \(file.lastPathComponent)")
    }

    let failedCommit = ConfigurationStore(url: directory.appendingPathComponent("failed-commit.json"))
    try failedCommit.save(original)
    let beforeFailedCommit = try Data(contentsOf: failedCommit.url)
    try FileManager.default.createDirectory(at: failedCommit.backupURL, withIntermediateDirectories: true)
    let sentinel = failedCommit.backupURL.appendingPathComponent("keep-me")
    let sentinelBytes = Data("do not remove unrelated data".utf8)
    try sentinelBytes.write(to: sentinel)
    let lookalike = directory.appendingPathComponent(".actionflow-write-not-ours")
    try sentinelBytes.write(to: lookalike)
    try rejects("backup publication failure aborts save") { try failedCommit.save(Configuration()) }
    try check(try Data(contentsOf: failedCommit.url) == beforeFailedCommit, "failed backup commit preserves live bytes")
    try check(try Data(contentsOf: sentinel) == sentinelBytes, "failed commit preserves destination directory contents")
    try check(try Data(contentsOf: lookalike) == sentinelBytes, "staging cleanup never deletes unrelated lookalike")
    try rejects("export publication failure reported") { try store.exportConfiguration(original, to: failedCommit.backupURL) }
    let remainingStaging = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        .filter { $0.hasPrefix(".actionflow-write-") }
    try check(remainingStaging == [lookalike.lastPathComponent], "successful and failed writes clean only owned staging files")

    let invalidForSave = Configuration(rules: [AutomationRule(name: "", enabled: true, actions: [])])
    let beforeInvalidSave = try Data(contentsOf: store.url)
    let backupBeforeInvalidSave = try Data(contentsOf: store.backupURL)
    try rejects("invalid configuration rejected before private staging") { try store.save(invalidForSave) }
    try check(try Data(contentsOf: store.url) == beforeInvalidSave, "validation failure preserves live bytes")
    try check(try Data(contentsOf: store.backupURL) == backupBeforeInvalidSave, "validation failure preserves backup bytes")

    let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
    try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "private config permissions 0600")
    let context = ExecutionContext(processIdentifier: 100, bundleIdentifier: "com.example.Editor")
    try check(RuleScheduler.canAutomaticallyRun(context: context, editorBundleIdentifier: "io.github.pinguarmy.actionflow", automationEnabled: true, isRecording: false, isPreparingManualRun: false), "scheduler accepts explicit enabled external target")
    try check(!RuleScheduler.canAutomaticallyRun(context: context, editorBundleIdentifier: "io.github.pinguarmy.actionflow", automationEnabled: true, isRecording: true, isPreparingManualRun: false), "scheduler blocks recording")
    let ownContext = ExecutionContext(processIdentifier: 100, bundleIdentifier: "IO.GITHUB.PINGUARMY.ACTIONFLOW")
    try check(!RuleScheduler.canAutomaticallyRun(context: ownContext, editorBundleIdentifier: "io.github.pinguarmy.actionflow", automationEnabled: true, isRecording: false, isPreparingManualRun: false), "scheduler blocks own editor")
    var scheduler = RuleScheduler()
    let shortcut = AutomationRule(name: "Scheduled shortcut", enabled: true, trigger: Trigger(kind: .shortcut, keyCode: 0, modifiers: [.command]), actions: [AutomationAction(kind: .delay, delaySeconds: 0)], cooldown: 1)
    let signal = TriggerSignal(kind: .shortcut, keyCode: 0, modifiers: [.command])
    try check(scheduler.candidates(for: signal, rules: [shortcut], context: context, now: 1).count == 1, "shortcut matches")
    try check(scheduler.candidates(for: signal, rules: [shortcut], context: context, now: 1.1).isEmpty, "shortcut cooldown blocks burst")
    let timerRule = AutomationRule(name: "Timer", enabled: true, trigger: Trigger(kind: .interval, intervalSeconds: 2), actions: [AutomationAction(kind: .delay, delaySeconds: 0)])
    try check(scheduler.intervalCandidates(rules: [timerRule], context: context, now: 0).isEmpty, "timer does not fire on first observation")
    try check(scheduler.intervalCandidates(rules: [timerRule], context: context, now: 100).count == 1, "timer sleep gap yields only one event")
    try check(scheduler.intervalCandidates(rules: [timerRule], context: context, now: 100.1).isEmpty, "timer does not replay backlog")
    var queue = RuleExecutionQueue(capacity: 2)
    try check(queue.append(shortcut, context: context, runningRuleID: nil), "queue accepts pending rule")
    try check(!queue.append(shortcut, context: context, runningRuleID: nil), "queue rejects duplicates")
    try check(queue.next(rules: [shortcut], context: ExecutionContext(processIdentifier: 101, bundleIdentifier: context.bundleIdentifier)) == nil, "queue rejects restarted same-bundle process")
    queue.append(shortcut, context: context, runningRuleID: nil)
    queue.append(timerRule, context: context, runningRuleID: nil)
    try check(queue.next(rules: [shortcut, timerRule], context: context)?.id == shortcut.id, "queue preserves first-in order")
    try check(queue.next(rules: [shortcut, timerRule], context: context)?.id == timerRule.id, "queue gives following rule its turn")
    let screen = CGRect(x: 0, y: 20, width: 1200, height: 800)
    let originalFrame = CGRect(x: 300, y: 220, width: 600, height: 400)
    try check(WindowOperation.allCases.count == 15, "fifteen window operations exposed")
    try check(try WindowLayout.target(for: .topLeft, original: originalFrame, screens: [screen]) == CGRect(x:0,y:20,width:600,height:400), "top-left quarter geometry")
    try check(try WindowLayout.target(for: .bottomRight, original: originalFrame, screens: [screen]) == CGRect(x:600,y:420,width:600,height:400), "bottom-right quarter geometry")
    try check(try WindowLayout.target(for: .centerTwoThirds, original: originalFrame, screens: [screen]) == CGRect(x:200,y:20,width:800,height:800), "centered two-thirds geometry")
    let bigger = try WindowLayout.target(for: .larger, original: originalFrame, screens: [screen])
    try check(abs(bigger.width - 660) < 0.001 && abs(bigger.midX - originalFrame.midX) < 0.001, "larger preserves center and increases size")
    let smaller = try WindowLayout.target(for: .smaller, original: originalFrame, screens: [screen])
    try check(abs(smaller.width - 540) < 0.001, "smaller reduces window size")
    for operation in WindowOperation.allCases {
        if operation == .nextDisplay { continue }
        let frame = try WindowLayout.target(for: operation, original: originalFrame, screens: [screen], restoreFrame: originalFrame)
        try check(screen.contains(frame) && frame.width > 0 && frame.height > 0, "layout fits visible screen \(operation.rawValue)")
    }
    try rejects("layout rejects invalid dimensions") { _ = try WindowLayout.target(for: .maximize, original: CGRect(x:0,y:0,width:0,height:10), screens:[screen]) }
    try rejects("next display needs another display") { _ = try WindowLayout.target(for: .nextDisplay, original: originalFrame, screens:[screen]) }
    let recoveredFrame = try WindowLayout.target(for: .restore, original: originalFrame, screens:[screen],restoreFrame:CGRect(x:-3000,y:-2000,width:1800,height:1200))
    try check(screen.contains(recoveredFrame), "restore refits disconnected display frame")
    let requirementRule = AutomationRule(name: "Requirements", trigger: Trigger(kind:.shortcut), actions:[AutomationAction(kind:.window),AutomationAction(kind:.notification,text:"test"),AutomationAction(kind:.shellScript,text:"exit 0")])
    try check(RuleRequirements.capabilities(for: requirementRule, automatic: true) == AutomationCapability.allCases, "automatic capabilities list is complete and stable")
    try check(!RuleRequirements.capabilities(for: requirementRule, automatic: false).contains(.inputMonitoring), "manual run does not need input monitoring")
    try check(RuleRequirements.missing(for: requirementRule, automatic: true, available:[.accessibility,.scripts]) == [.inputMonitoring,.notifications], "missing capability analysis respects actual grants")
    for triggerKind in TriggerKind.allCases {
        let r = AutomationRule(trigger: Trigger(kind:triggerKind), actions:[AutomationAction(kind:.delay)])
        let requiresInput = [.shortcut,.doubleShortcut,.mouseButton,.scroll].contains(triggerKind)
        try check(RuleRequirements.capabilities(for:r,automatic:true).contains(.inputMonitoring) == requiresInput, "trigger capability \(triggerKind.rawValue)")
    }
    for actionKind in ActionKind.allCases {
        let r = AutomationRule(trigger:Trigger(kind:.interval),actions:[AutomationAction(kind:actionKind)])
        let caps = RuleRequirements.capabilities(for:r,automatic:false)
        try check(caps.contains(.accessibility) == [.window,.keyboardShortcut,.insertText,.menuCommand].contains(actionKind), "action accessibility capability \(actionKind.rawValue)")
        try check(!caps.contains(.inputMonitoring), "actions never require input monitoring \(actionKind.rawValue)")
    }
    // Pure menu path parsing. No app menus are queried anywhere in this harness.
    let menuPath = try MenuCommandPath(parsing:"[\"File\", \"New\"]")
    try check(menuPath.segments == ["File","New"], "menu path parses exact titles")
    try check(try MenuCommandPath(parsing:menuPath.canonicalJSON) == menuPath, "menu path canonical roundtrip")
    try check((try? MenuCommandPath(parsing:"  [ \"File\" ,\n \"New\" ]  "))?.canonicalJSON == "[\"File\",\"New\"]", "menu path canonical form ignores source formatting")
    let exactTitles = try MenuCommandPath(segments:[" 格式","带有  空格和,标点…"])
    try check(exactTitles.segments == [" 格式","带有  空格和,标点…"], "menu titles preserved byte-exact without trimming")
    for invalidMenuJSON in ["", "not json", "[\"File\",", "{\"File\":\"New\"}", "\"File\"", "[1, 2]", "[\"File\", 2]",
                            "[[\"File\"], \"New\"]", "[true, false]", "null", "[]", "[\"OnlyOne\"]"] {
        try check((try? MenuCommandPath(parsing:invalidMenuJSON)) == nil, "menu path rejects \(invalidMenuJSON.prefix(24))")
    }
    try check((try? MenuCommandPath(parsing:"[" + (1...9).map{"\"\($0)\""}.joined(separator:",") + "]")) == nil, "menu path rejects nine segments")
    try check((try? MenuCommandPath(parsing:"[\"File\", \"\"]")) == nil, "menu path rejects empty title")
    for whitespaceTitle in [" ", "   ", "\\t", "\\n"] {
        try check((try? MenuCommandPath(parsing:"[\"File\", \"\(whitespaceTitle)\"]")) == nil, "menu path rejects whitespace-only title")
    }
    for controlEscape in ["\\u0000", "\\u0007", "\\u001F"] {
        try check((try? MenuCommandPath(parsing:"[\"File\", \"A\(controlEscape)\"]")) == nil, "menu path rejects control character \(controlEscape)")
    }
    let maxTitle = String(repeating:"x",count:256)
    try check((try? MenuCommandPath(parsing:"[\"File\", \"\(maxTitle)\"]")) != nil, "menu path accepts 256-byte title")
    try check((try? MenuCommandPath(parsing:"[\"File\", \"\(maxTitle)x\"]")) == nil, "menu path rejects 257-byte title")
    try check((try? MenuCommandPath(parsing:"[\"文件\", \"\(String(repeating:"中",count:86))\"]")) == nil, "menu path measures multibyte titles in UTF-8 bytes")
    // Per-title (256) and segment (8) caps bound any path to exactly 2048
    // bytes, so the total-path limit is a defense-in-depth composition check.
    let eightMaxTitles = (0..<8).map { _ in String(repeating:"y",count:256) }
    try check((try? MenuCommandPath(segments:eightMaxTitles)) != nil, "menu path accepts 2048-byte total across eight titles")
    try check(eightMaxTitles.reduce(0){ $0 + $1.utf8.count } == MenuCommandPath.maximumPathUTF8Bytes, "title and segment caps compose to the path byte limit")
    let fullSegments = (0..<8).map { _ in String(repeating:"z",count:256) }
    let paddedJSON = "[" + fullSegments.map{"\"\($0)\""}.joined(separator:", ") + String(repeating:" ",count:4_096) + "]"
    try check((try? MenuCommandPath(parsing:paddedJSON)) == nil, "menu path rejects oversized JSON payload")
    let menuSecret = "SECRET_MENU_TITLE_NOT_EMITTED"
    let menuErrors = ActionPreflight.errors(for:[AutomationAction(kind:.menuCommand,text:"[\"\(menuSecret)\"]")])
    try check(menuErrors == ["Action 1: A menu path needs between 2 and 8 titles."] && !menuErrors.joined().contains(menuSecret), "menu preflight errors are fixed and redacted")
    try check(ActionPreflight.errors(for:[AutomationAction(kind:.menuCommand,text:"[\"File\", \"New\"]")]).isEmpty, "valid menu path passes preflight")
    try check(!RuleValidator.validate(AutomationRule(name:"Menu",actions:[AutomationAction(kind:.delay,delaySeconds:0),AutomationAction(kind:.menuCommand,text:menuSecret)])).isEmpty, "late invalid menu action fails whole-rule validation")
    let menuPlan = ExecutionPlan(rule:AutomationRule(name:"Menu",trigger:Trigger(kind:.interval,intervalSeconds:60),actions:[AutomationAction(kind:.menuCommand,text:"[\"\(menuSecret)\", \"\(menuSecret)2\"]")]))
    let menuPlanJSON = String(data:try JSONEncoder().encode(menuPlan),encoding:.utf8)!
    try check(!menuPlanJSON.contains(menuSecret) && menuPlan.steps[0].summary.contains("2") && menuPlan.requiredCapabilities == [.accessibility], "menu plan reports depth only, titles redacted")
    try check(ExecutionPlan(rule:AutomationRule(actions:[AutomationAction(kind:.menuCommand,text:"not json")])).steps[0].summary == "Invalid menu command path. No action will run during preview.", "invalid menu plan step is marked without payload")
    try check(ActionKind.allCases.count == 9, "nine action kinds exposed")
    var doubleScheduler = RuleScheduler()
    let doubleRule = AutomationRule(name:"Double",enabled:true,trigger:Trigger(kind:.doubleShortcut,keyCode:0,modifiers:[.command]),actions:[AutomationAction(kind:.delay,delaySeconds:0)],cooldown:0.25)
    try check(doubleScheduler.candidates(for:signal,rules:[doubleRule],context:context,now:1).isEmpty, "double shortcut first press waits")
    try check(doubleScheduler.candidates(for:signal,rules:[doubleRule],context:context,now:1.35).count == 1, "double shortcut accepts exact 350ms boundary")
    try check(doubleScheduler.candidates(for:signal,rules:[doubleRule],context:context,now:2).isEmpty, "third press starts a new pair")
    let otherContext = ExecutionContext(processIdentifier:101,bundleIdentifier:context.bundleIdentifier)
    try check(doubleScheduler.candidates(for:signal,rules:[doubleRule],context:otherContext,now:2.1).isEmpty, "process switch never completes another apps double shortcut")
    try check(doubleScheduler.candidates(for:signal,rules:[doubleRule],context:otherContext,now:2.2).count == 1, "second pair in same new process can complete")
    doubleScheduler.reset()
    try check(doubleScheduler.candidates(for:signal,rules:[doubleRule],context:context,now:3).isEmpty, "reset clears pending double shortcut")
    let wrongSignal = TriggerSignal(kind:.shortcut,keyCode:1,modifiers:[.command])
    _ = doubleScheduler.candidates(for:wrongSignal,rules:[doubleRule],context:context,now:3.1)
    try check(doubleScheduler.candidates(for:signal,rules:[doubleRule],context:context,now:3.2).isEmpty, "different key breaks pending pair")
    let privatePayload = "SECRET_PAYLOAD_DO_NOT_EMIT"
    let planRule = AutomationRule(name:privatePayload,trigger:Trigger(kind:.interval),actions:[AutomationAction(kind:.insertText,text:privatePayload),AutomationAction(kind:.shellScript,text:privatePayload),AutomationAction(kind:.delay,delaySeconds:0.5)])
    let redactedPlan = ExecutionPlan(rule:planRule)
    let planJSON = String(data:try JSONEncoder().encode(redactedPlan),encoding:.utf8)!
    try check(!planJSON.contains(privatePayload), "execution plan never includes rule name or action payload")
    try check(redactedPlan.steps.map(\.index) == [1,2,3], "execution plan preserves ordered step numbers")
    try check(redactedPlan.requiredCapabilities == [.accessibility,.scripts], "execution plan describes action requirements")
    try check(redactedPlan.totalDelaySeconds == 0.5, "execution plan totals valid delays")
    try check(!ActionPreflight.errors(for:[AutomationAction(kind:.delay,delaySeconds:0),AutomationAction(kind:.insertText,text:String(repeating:"a",count:16_385))]).isEmpty, "late oversized text fails entire chain preflight")
    try check(!ActionPreflight.errors(for:(0..<3).map { _ in AutomationAction(kind:.delay,delaySeconds:60) }).isEmpty, "total chain wait limit preflight")
    let historyStore = ConfigurationStore(url: directory.appendingPathComponent("history-fixture.json"))
    let historyOriginal = Configuration()
    try historyStore.save(historyOriginal)
    let snapshot = try historyStore.createSnapshot(configuration:historyOriginal)
    try check(try historyStore.listSnapshots().count == 1, "explicit private snapshot is listed")
    var modifiedHistory = historyOriginal
    modifiedHistory.rules[0].name = "changed history fixture"
    try historyStore.save(modifiedHistory)
    let historyBytes = try Data(contentsOf:historyStore.url)
    let historyRestored = try historyStore.restoreSnapshot(id:snapshot.id)
    try check(historyRestored.configuration.rules[0].name == historyOriginal.rules[0].name, "selected snapshot restores original rule content")
    try check(!historyRestored.configuration.automationEnabled && !historyRestored.configuration.allowScripts && historyRestored.configuration.rules.allSatisfy { !$0.enabled }, "snapshot restores every rule paused")
    try check(try Data(contentsOf:historyRestored.preservedCurrentFileURL!) == historyBytes, "snapshot recovery retains exact replaced bytes")
    try rejects("snapshot traversal rejected") { _ = try historyStore.restoreSnapshot(id:"../escape") }
    for _ in 1..<10 { _ = try historyStore.createSnapshot(configuration:historyOriginal) }
    try rejects("history capacity fails without deleting") { _ = try historyStore.createSnapshot(configuration:historyOriginal) }
    try check(try historyStore.listSnapshots().count == 10, "history full preserves every private snapshot")
    let historyDirectory = historyStore.url.appendingPathExtension("history")
    let historyLockFD = open(historyDirectory.appendingPathComponent(".lock").path,O_RDWR)
    try check(historyLockFD >= 0 && flock(historyLockFD,LOCK_EX|LOCK_NB) == 0, "private history lock fixture acquired")
    try rejects("busy history fails instead of blocking") { _ = try historyStore.listSnapshots() }
    _ = flock(historyLockFD,LOCK_UN)
    _ = close(historyLockFD)
    let historyAlias = directory.appendingPathComponent("export-parent-alias")
    try FileManager.default.createSymbolicLink(at:historyAlias,withDestinationURL:directory)
    let liveBeforeAliasExport = try Data(contentsOf:historyStore.url)
    try rejects("export through parent alias cannot overwrite live") { try historyStore.exportConfiguration(Configuration(rules:[]),to:historyAlias.appendingPathComponent(historyStore.url.lastPathComponent)) }
    try check(try Data(contentsOf:historyStore.url) == liveBeforeAliasExport, "alias export rejection preserves live bytes")
    try check(RuleTemplates.all.count >= 6, "built-in template catalog contains six safe packs")
    for template in RuleTemplates.all {
        try check(template.rules.allSatisfy { !$0.enabled && RuleValidator.validate($0).isEmpty && !$0.actions.contains { $0.kind == .shellScript } }, "template rules valid disabled script-free \(template.id)")
        try check(!template.configuration.automationEnabled && !template.configuration.allowScripts && !template.configuration.launchAtLogin, "template configuration opts out of all execution \(template.id)")
        let copies = template.makeRules()
        try check(Set(copies.map(\.id)).isDisjoint(with:template.rules.map(\.id)) && copies.allSatisfy { !$0.enabled }, "adding template creates fresh disabled copies \(template.id)")
    }
    let lifecycleRule = AutomationRule(name:"Background source",enabled:true,trigger:Trigger(kind:.appLaunched,appBundleIdentifier:"com.example.background"),actions:[AutomationAction(kind:.delay,delaySeconds:0)])
    var lifecycleScheduler = RuleScheduler()
    let lifecycleSignal = TriggerSignal(kind:.appLaunched,appBundleIdentifier:"com.example.background")
    try check(lifecycleScheduler.candidates(for:lifecycleSignal,rules:[lifecycleRule],context:context,now:1).count == 1, "launch source is independent of current foreground target")
    var scopedLifecycle = lifecycleRule
    scopedLifecycle.conditions = RuleConditions(appBundleIdentifiers:["com.example.other"])
    lifecycleScheduler.reset()
    try check(lifecycleScheduler.candidates(for:lifecycleSignal,rules:[scopedLifecycle],context:context,now:2).isEmpty, "lifecycle conditions still scope current foreground application")
    var terminatedRule = lifecycleRule
    terminatedRule.trigger.kind = .appTerminated
    try check(lifecycleScheduler.candidates(for:TriggerSignal(kind:.appTerminated,appBundleIdentifier:"com.example.background"),rules:[terminatedRule],context:context,now:3).count == 1, "termination source matches without activating exited app")
    var transitionState = SessionTransitionState()
    transitionState.apply(.willSleep)
    try check(transitionState.isSuspended, "sleep latches execution suspended")
    transitionState.apply(.sessionResigned)
    transitionState.apply(.didWake)
    try check(transitionState.isSuspended, "wake does not clear inactive-session latch")
    transitionState.apply(.sessionBecameActive)
    try check(!transitionState.isSuspended, "both independent suspension latches must clear")
    let queryRules = [AutomationRule(name:"Visible alpha",enabled:false,group:"One",actions:[AutomationAction(kind:.insertText,text:"SECRET_NOT_SEARCHED")]), AutomationRule(name:"Visible beta",enabled:true,group:"Two")]
    try check(RuleQuery(status:.enabled).apply(to:queryRules).map(\.name) == ["Visible beta"], "status query retains only enabled rules")
    try check(RuleQuery(group:"One").apply(to:queryRules).map(\.name) == ["Visible alpha"], "group query preserves exact identity")
    try check(RuleQuery(text:"SECRET_NOT_SEARCHED").apply(to:queryRules).isEmpty, "rule search never matches private action payload")
    try check(RuleQuery().apply(to:queryRules) == queryRules, "default filters preserve content and order")
    let leaseURL = directory.appendingPathComponent("leased.json")
    let writerLease = try ConfigurationLease(configurationURL:leaseURL)
    try rejects("second writer lease fails without blocking") { _ = try ConfigurationLease(configurationURL:leaseURL) }
    try check(!FileManager.default.fileExists(atPath:leaseURL.path), "writer lease never creates live configuration")
    writerLease.release()
    let nextWriterLease = try ConfigurationLease(configurationURL:leaseURL)
    nextWriterLease.release()
    try check(true, "lease can be reacquired only after owner releases")
    // Pure gesture recognizer checks. Typed synthetic samples only, no input hardware.
    try check(GestureThresholds(swipePoints: 0, pinchScaleDelta: 0.2, rotateDegrees: 10) == nil, "gesture thresholds reject non-positive values")
    try check(GestureThresholds(swipePoints: .nan, pinchScaleDelta: 0.2, rotateDegrees: 10) == nil, "gesture thresholds reject NaN")
    var gestures = GestureRecognizer(thresholds: GestureThresholds(swipePoints: 50, pinchScaleDelta: 0.2, rotateDegrees: 10)!)
    _ = gestures.process(.swipe(phase: .began, deltaX: 0, deltaY: 0), at: 1)
    _ = gestures.process(.swipe(phase: .changed, deltaX: 60, deltaY: 0), at: 1.1)
    try check(gestures.process(.swipe(phase: .ended, deltaX: 0, deltaY: 0), at: 1.2)?.kind == .swipeLeft, "phased swipe left recognized once at threshold")
    try check(gestures.process(.swipe(phase: .ended, deltaX: 100, deltaY: 0), at: 2) == nil, "ended without began produces no result")
    _ = gestures.process(.magnify(phase: .began, delta: 0), at: 2)
    _ = gestures.process(.magnify(phase: .changed, delta: 0.3), at: 2.1)
    _ = gestures.process(.magnify(phase: .cancelled, delta: 0), at: 2.2)
    try check(gestures.process(.magnify(phase: .ended, delta: 0), at: 2.3) == nil, "cancelled pinch never completes")
    _ = gestures.process(.rotate(phase: .began, degrees: 0), at: 3)
    _ = gestures.process(.rotate(phase: .changed, degrees: -12), at: 3.1)
    try check(gestures.process(.rotate(phase: .ended, degrees: 0), at: 3.2)?.kind == .rotateClockwise, "negative rotation degrees are clockwise")
    _ = gestures.process(.swipe(phase: .began, deltaX: 0, deltaY: 0), at: 4)
    _ = gestures.process(.swipe(phase: .changed, deltaX: 40, deltaY: 0), at: 4.1)
    _ = gestures.process(.magnify(phase: .changed, delta: 0.4), at: 4.2)
    try check(gestures.process(.swipe(phase: .ended, deltaX: 100, deltaY: 0), at: 4.3) == nil, "cross-kind sample resets pending without mixing deltas")
    _ = gestures.process(.magnify(phase: .began, delta: 0), at: 5)
    _ = gestures.process(.magnify(phase: .changed, delta: .nan), at: 5.1)
    try check(!gestures.isTracking && gestures.process(.magnify(phase: .ended, delta: 1), at: 5.2) == nil, "NaN delta resets pending without result")
    try check(GestureRecognizer.classifySwipe(deltaX: 1, deltaY: 0) == .swipeLeft && GestureRecognizer.classifySwipe(deltaX: 0, deltaY: -1) == .swipeDown, "discrete swipe direction follows NSEvent delta convention")
    try check(GestureRecognizer.classifySwipe(deltaX: 1, deltaY: 1) == nil, "diagonal-ambiguous swipe produces no result")
    print("Verified \(assertions) assertions.")
    print("Fixture directory: \(directory.path)")
} catch {
    fputs("FAIL after \(assertions) assertions: \(error.localizedDescription)\nFixture directory: \(directory.path)\n", stderr)
    exit(1)
}
