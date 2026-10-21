import BigBangCore
import Foundation
import ServiceManagement

@MainActor enum LoginItemService {
    static func controller() -> LoginItemController {
        LoginItemController(manager: SystemLoginItemManager())
    }

    static func disabledMockController() -> LoginItemController {
        LoginItemController.preview()
    }
}

@MainActor private final class SystemLoginItemManager: LoginItemManaging {
    private var hasApplicationBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    var status: LoginItemStatus {
        guard hasApplicationBundle else { return .unavailable }
        let systemStatus: LoginItemSystemStatus
        switch SMAppService.mainApp.status {
        case .enabled: systemStatus = .enabled
        case .notRegistered: systemStatus = .notRegistered
        case .requiresApproval: systemStatus = .requiresApproval
        case .notFound: systemStatus = .notFound
        @unknown default: systemStatus = .unknown
        }
        return systemStatus.status(hasApplicationBundle: true)
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
