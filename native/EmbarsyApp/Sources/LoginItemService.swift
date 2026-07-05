import Foundation
import ServiceManagement

@MainActor
final class LoginItemService: ObservableObject {
    @Published private(set) var statusText = "Unknown"
    @Published private(set) var isEnabled = false

    func refresh() {
        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            isEnabled = status == .enabled
            statusText = String(describing: status)
        } else {
            isEnabled = false
            statusText = "Unsupported macOS"
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if #available(macOS 13.0, *) {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh()
        }
    }
}
