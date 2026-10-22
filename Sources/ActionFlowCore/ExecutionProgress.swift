import Foundation

public enum ExecutionPhase: String, Codable, Equatable, Sendable {
    case running, completed, failed, cancelled
}

/// Observed runtime checkpoints only. Contains no rule names, action payloads,
/// script output, error strings, application identifiers, or window metadata.
public struct ExecutionProgress: Codable, Equatable, Sendable {
    public let actionIndex: Int
    public let actionCount: Int
    public let kind: ActionKind
    public let phase: ExecutionPhase
    public let completedActions: Int

    public init(actionIndex: Int, actionCount: Int, kind: ActionKind,
                phase: ExecutionPhase, completedActions: Int) {
        self.actionIndex = actionIndex
        self.actionCount = actionCount
        self.kind = kind
        self.phase = phase
        self.completedActions = completedActions
    }
}
