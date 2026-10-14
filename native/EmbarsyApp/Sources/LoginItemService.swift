import Foundation
import ServiceManagement

@MainActor
final class LoginItemService: ObservableObject {
    @Published private(set) var statusText = L("Unknown")
    @Published private(set) var isEnabled = false

    func refresh() {
        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            isEnabled = status == .enabled
            switch status {
            case .enabled: statusText = L("On")
            case .notRegistered: statusText = L("Off")
            case .requiresApproval: statusText = L("Waiting for approval in System Settings → General → Login Items")
            case .notFound: statusText = L("Not found — move Embarsy to Applications")
            @unknown default: statusText = L("Unknown")
            }
        } else {
            isEnabled = false
            statusText = L("Unsupported macOS")
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
