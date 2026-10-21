import Combine
import Foundation

public enum LoginItemStatus: Equatable {
    case enabled
    case disabled
    case requiresApproval
    case unavailable
}

/// Framework-independent registration states for the system adapter and isolated tests.
public enum LoginItemSystemStatus: Equatable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound
    case unknown

    public func status(hasApplicationBundle: Bool) -> LoginItemStatus {
        guard hasApplicationBundle else { return .unavailable }
        switch self {
        case .enabled: return .enabled
        case .notRegistered, .notFound:
            // ServiceManagement may return notFound until it first sees the service.
            // A valid main application must still allow the user's first register attempt.
            return .disabled
        case .requiresApproval: return .requiresApproval
        case .unknown: return .unavailable
        }
    }
}

/// System registration and authorization are the source of truth for login items.
@MainActor public protocol LoginItemManaging {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor public final class LoginItemController: ObservableObject {
    @Published public private(set) var status: LoginItemStatus
    @Published public private(set) var error: String?
    private let manager: any LoginItemManaging
    private var operationFailed = false

    public init(manager: any LoginItemManaging) {
        self.manager = manager
        status = manager.status
        refresh()
    }

    public var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    public var canToggle: Bool { status != .unavailable }

    public func refresh() {
        status = manager.status
        if status == .unavailable {
            error = L10n.string("登录时启动不可用。请将大爆炸放入应用程序文件夹，并检查系统登录项。")
        } else if operationFailed {
            error = L10n.string("无法更改登录时启动设置。请在系统设置中检查登录项后重试。")
        } else {
            error = nil
        }
    }

    public func setEnabled(_ enabled: Bool) {
        // A user may have changed the setting outside the app since the last read.
        refresh()
        guard canToggle else { return }
        guard enabled != isEnabled else { return }
        do {
            if enabled { try manager.register() } else { try manager.unregister() }
            operationFailed = false
        } catch {
            operationFailed = true
        }
        // Never infer authorization from a successful call, or rollback from an error.
        refresh()
    }

    public func openSystemSettings() { manager.openSystemSettings() }

    /// A reversible fixture controller that never accesses system login items.
    public static func preview() -> LoginItemController {
        LoginItemController(manager: PreviewLoginItemManager())
    }
}

@MainActor private final class PreviewLoginItemManager: LoginItemManaging {
    var status: LoginItemStatus = .disabled
    func register() throws { status = .enabled }
    func unregister() throws { status = .disabled }
    func openSystemSettings() {}
}
