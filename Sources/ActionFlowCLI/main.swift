import Foundation
import Darwin
import ActionFlowCore

// Offline file inspection only. This target deliberately does not import AppKit
// or the runtime, and never runs rules, requests permissions, or uses live paths.
private let helpText = """
Usage: actionflow-cli <command> [path]

Commands:
  help                      Show this help.
  validate <path>           Validate an existing configuration, without writing it.
  summarize <path>          Show counts and rule metadata, not action text.
  plan <path>               Preview redacted action plans. Never execute them.
  example <new-path>        Create a private, disabled example. Never overwrite.
  templates                 List built-in disabled template packs.
  template <id> <new-path>  Export a disabled template pack. Never overwrite.

Paths are explicit local filesystem paths. No default live configuration is used.
JSON output is pretty-printed with sorted keys. Errors are JSON on stderr.
Exit codes: 0 success, 1 invalid configuration, unknown template, or file failure,
2 usage error.
This tool never executes rules, scripts, window actions, or keyboard input.
"""

private struct CLIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct ValidationOutput: Encodable {
    let valid: Bool
    let ruleCount: Int
    let schemaVersion: Int
}

private struct TemplateMetadata: Encodable {
    let id: String
    let name: String
    let detail: String
    let ruleCount: Int
    let capabilities: [AutomationCapability]

    init(_ template: RuleTemplate) {
        id = template.id
        name = template.name
        detail = template.detail
        ruleCount = template.rules.count
        let required = Set(template.rules.flatMap { RuleRequirements.capabilities(for: $0, automatic: true) })
        capabilities = AutomationCapability.allCases.filter { required.contains($0) }
    }
}

private struct PlanOutput: Encodable {
    struct Rule: Encodable {
        let id: UUID
        let plan: ExecutionPlan
    }
    let schemaVersion: Int
    let rules: [Rule]

    init(_ configuration: Configuration) {
        schemaVersion = configuration.schemaVersion
        // Unlike summarize, plans intentionally omit names and trigger summaries.
        // ExecutionPlan contains descriptive counts, never action payloads.
        rules = configuration.rules.map { Rule(id: $0.id, plan: ExecutionPlan(rule: $0)) }
    }
}

private struct SummaryOutput: Encodable {
    struct Counts: Encodable {
        let rules: Int
        let enabledRules: Int
        let disabledRules: Int
        let actions: Int
        let actionsByKind: [String: Int]
    }
    struct Rule: Encodable {
        let id: UUID
        let name: String
        let trigger: String
        let actionCount: Int
    }
    let schemaVersion: Int
    let automationEnabled: Bool
    let allowScripts: Bool
    let launchAtLogin: Bool
    let counts: Counts
    let rules: [Rule]

    init(_ configuration: Configuration) {
        schemaVersion = configuration.schemaVersion
        automationEnabled = configuration.automationEnabled
        allowScripts = configuration.allowScripts
        launchAtLogin = configuration.launchAtLogin
        let actions = configuration.rules.flatMap(\.actions)
        let enabled = configuration.rules.filter(\.enabled).count
        counts = Counts(rules: configuration.rules.count, enabledRules: enabled,
                        disabledRules: configuration.rules.count - enabled, actions: actions.count,
                        actionsByKind: Dictionary(uniqueKeysWithValues: ActionKind.allCases.map { kind in
                            (kind.rawValue, actions.filter { $0.kind == kind }.count)
                        }))
        rules = configuration.rules.map {
            Rule(id: $0.id, name: $0.name, trigger: $0.trigger.summary, actionCount: $0.actions.count)
        }
    }
}

private func encoded<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    data.append(0x0A)
    return data
}

private func output<Value: Encodable>(_ value: Value) throws {
    try FileHandle.standardOutput.write(contentsOf: encoded(value))
}

private func loadExisting(_ path: String) throws -> Configuration {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    // ConfigurationStore.load intentionally returns defaults for missing files;
    // an inspection command must instead fail, including removal during a read.
    var before = stat()
    let result = url.withUnsafeFileSystemRepresentation { pointer in
        pointer.map { Darwin.fstatat(AT_FDCWD, $0, &before, 0) } ?? -1
    }
    guard result == 0 else { throw posixError("Cannot inspect configuration", code: errno) }
    guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
        throw CLIError(message: "The configuration must be an existing regular file.")
    }
    let configuration = try ConfigurationStore(url: url).load()
    var after = stat()
    let stillPresent = url.withUnsafeFileSystemRepresentation { pointer in
        pointer.map { Darwin.fstatat(AT_FDCWD, $0, &after, 0) } ?? -1
    }
    guard stillPresent == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
          before.st_size == after.st_size,
          before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
          before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
        throw CLIError(message: "The configuration changed while being inspected. Retry with a stable file.")
    }
    return configuration
}

private func exampleConfiguration() -> Configuration {
    // Stable fixture identities make repeated example output reproducible.
    let left = AutomationRule(id: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
                              name: "Window to left half", enabled: false, group: "Examples",
                              trigger: Trigger(keyCode: 123),
                              actions: [AutomationAction(id: UUID(uuidString: "20000000-0000-4000-8000-000000000001")!,
                                                         windowOperation: .leftHalf)])
    let right = AutomationRule(id: UUID(uuidString: "10000000-0000-4000-8000-000000000002")!,
                               name: "Window to right half", enabled: false, group: "Examples",
                               trigger: Trigger(keyCode: 124),
                               actions: [AutomationAction(id: UUID(uuidString: "20000000-0000-4000-8000-000000000002")!,
                                                          windowOperation: .rightHalf)])
    return Configuration(rules: [left, right], automationEnabled: false, allowScripts: false, launchAtLogin: false)
}

private func posixError(_ operation: String, code: Int32) -> CLIError {
    CLIError(message: "\(operation): \(String(cString: strerror(code))).")
}

/// Write a complete private staging file, then atomically publish with linkat.
/// Unlike a preflight fileExists check followed by export, linkat cannot clobber
/// a racing writer, existing symlink, directory, or existing destination file.
private func createConfiguration(_ configuration: Configuration, at path: String) throws {
    let destination = URL(fileURLWithPath: path).standardizedFileURL
    let data = try encoded(configuration)
    guard data.count <= ConfigurationStore.maximumFileBytes else {
        throw CLIError(message: "The exported configuration exceeds the configuration file limit.")
    }
    let directory = destination.deletingLastPathComponent()
    let directoryFD = directory.withUnsafeFileSystemRepresentation { pointer in
        pointer.map { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) } ?? -1
    }
    guard directoryFD >= 0 else { throw posixError("Cannot open destination directory", code: errno) }
    defer { Darwin.close(directoryFD) }
    let temporaryName = ".actionflow-cli-\(UUID().uuidString)"
    var descriptor = temporaryName.withCString {
        Darwin.openat(directoryFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    }
    guard descriptor >= 0 else { throw posixError("Cannot create private example staging file", code: errno) }
    var identity = stat()
    let identified = Darwin.fstat(descriptor, &identity) == 0
    defer {
        if descriptor >= 0 { Darwin.close(descriptor) }
        // Only remove the entry matching the staging inode we created.
        if identified {
            var current = stat()
            let same = temporaryName.withCString {
                Darwin.fstatat(directoryFD, $0, &current, AT_SYMLINK_NOFOLLOW) == 0 &&
                    identity.st_dev == current.st_dev && identity.st_ino == current.st_ino
            }
            if same { _ = temporaryName.withCString { Darwin.unlinkat(directoryFD, $0, 0) } }
        }
    }
    guard identified, Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
        throw posixError("Cannot secure the example staging file", code: errno)
    }
    try data.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { return }
        var offset = 0
        while offset < buffer.count {
            let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw posixError("Cannot write the example", code: count == 0 ? EIO : errno) }
            offset += count
        }
    }
    guard Darwin.fsync(descriptor) == 0 else { throw posixError("Cannot sync the example", code: errno) }
    let closeResult = Darwin.close(descriptor)
    descriptor = -1
    guard closeResult == 0 else { throw posixError("Cannot close the example", code: errno) }
    let published = temporaryName.withCString { source in
        destination.lastPathComponent.withCString { target in
            Darwin.linkat(directoryFD, source, directoryFD, target, 0)
        }
    }
    guard published == 0 else {
        if errno == EEXIST { throw CLIError(message: "The destination already exists. No configuration was written or overwritten.") }
        throw posixError("Cannot publish the example without overwriting", code: errno)
    }
    try output(["created": true, "rulesDisabled": true, "automationEnabled": false, "allowScripts": false, "launchAtLogin": false])
}

private func run(_ arguments: [String]) throws -> Int32 {
    guard let command = arguments.first else { throw UsageError() }
    if ["help", "--help", "-h"].contains(command), arguments.count == 1 {
        try FileHandle.standardOutput.write(contentsOf: Data((helpText + "\n").utf8))
        return 0
    }
    if command == "templates" {
        guard arguments.count == 1 else { throw UsageError() }
        try output(RuleTemplates.all.map { TemplateMetadata($0) })
        return 0
    }
    if command == "template" {
        guard arguments.count == 3, !arguments[1].isEmpty, !arguments[2].isEmpty,
              !arguments[1].contains("\0"), !arguments[2].contains("\0") else { throw UsageError() }
        guard let template = RuleTemplates.find(id: arguments[1]) else {
            throw CLIError(message: "Unknown template identifier. Run actionflow-cli templates to list available packs.")
        }
        try createConfiguration(template.configuration, at: arguments[2])
        return 0
    }
    guard arguments.count == 2, ["validate", "summarize", "plan", "example"].contains(command),
          !arguments[1].isEmpty, !arguments[1].contains("\0") else { throw UsageError() }
    switch command {
    case "validate":
        let configuration = try loadExisting(arguments[1])
        try output(ValidationOutput(valid: true, ruleCount: configuration.rules.count, schemaVersion: configuration.schemaVersion))
    case "summarize":
        try output(SummaryOutput(loadExisting(arguments[1])))
    case "plan":
        try output(PlanOutput(loadExisting(arguments[1])))
    case "example":
        try createConfiguration(exampleConfiguration(), at: arguments[1])
    default:
        throw UsageError()
    }
    return 0
}

private struct UsageError: Error {}

let exitCode: Int32
do {
    exitCode = try run(Array(CommandLine.arguments.dropFirst()))
} catch is UsageError {
    let message = ["error": "Invalid usage. Run actionflow-cli help.\n" + helpText]
    if let data = try? encoded(message) { try? FileHandle.standardError.write(contentsOf: data) }
    exitCode = 2
} catch {
    if let data = try? encoded(["error": error.localizedDescription]) {
        try? FileHandle.standardError.write(contentsOf: data)
    }
    exitCode = 1
}
Darwin.exit(exitCode)
