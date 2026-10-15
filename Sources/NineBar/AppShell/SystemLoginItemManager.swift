import ServiceManagement
import NineBarCore

actor SystemLoginItemManager: LoginItemManaging, LoginItemsSettingsOpening {
    func status() async -> LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled:
            .enabled
        case .notRegistered:
            .disabled
        case .notFound:
            .unavailable
        case .requiresApproval:
            .requiresApproval
        @unknown default:
            .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) async throws {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try await SMAppService.mainApp.unregister()
            }
        } catch {
            throw LoginItemError.unavailable
        }
    }

    func openLoginItemsSettings() async -> Bool {
        SMAppService.openSystemSettingsLoginItems()
        return true
    }
}
