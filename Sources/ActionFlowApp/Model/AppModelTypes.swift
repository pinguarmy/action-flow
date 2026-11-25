import ActionFlowCore
import Foundation

public enum SidebarSection: String, CaseIterable, Identifiable {
    case rules, activity, permissions, settings, gestureLab
    public var id: String { rawValue }
    public var title: String { switch self { case .rules: return AppLocalization.text("Rules"); case .activity: return AppLocalization.text("Activity"); case .permissions: return AppLocalization.text("Permissions"); case .settings: return AppLocalization.text("Settings"); case .gestureLab: return AppLocalization.text("Gesture Lab") } }
    public var systemImage: String { switch self { case .rules: return "slider.horizontal.3"; case .activity: return "clock.arrow.circlepath"; case .permissions: return "hand.raised"; case .settings: return "gearshape"; case .gestureLab: return "hand.draw" } }
}
public struct PermissionState {
    public var accessibility = false
    public var inputMonitoring = false
    public var notifications = false
}
public struct ActivityEntry: Identifiable {
    public let id = UUID()
    public let date = Date()
    public var ruleName: String
    public var message: String
    public var success: Bool
    public var completedActions: Int? = nil
    public var totalActions: Int? = nil
}
