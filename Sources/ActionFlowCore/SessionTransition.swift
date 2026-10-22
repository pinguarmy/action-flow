/// Workspace lifecycle signals. These describe observed events, not proof that a session is safe.
public enum SessionTransition: String, Codable, CaseIterable, Sendable {
    case willSleep, didWake, sessionResigned, sessionBecameActive
}

/// Independent suspension reasons prevent a wake event from clearing an inactive-session latch.
/// Becoming unsuspended only permits fresh session checks; it never resumes automation itself.
public struct SessionTransitionState: Equatable, Sendable {
    private var sleeping = false
    private var inactive = false

    public init() {}

    public var isSuspended: Bool { sleeping || inactive }

    public mutating func apply(_ event: SessionTransition) {
        switch event {
        case .willSleep: sleeping = true
        case .didWake: sleeping = false
        case .sessionResigned: inactive = true
        case .sessionBecameActive: inactive = false
        }
    }
}
