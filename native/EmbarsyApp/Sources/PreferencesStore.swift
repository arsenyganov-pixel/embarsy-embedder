import Foundation

@MainActor
final class PreferencesStore: ObservableObject {
    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }

    @Published var startStackOnLaunch: Bool {
        didSet { defaults.set(startStackOnLaunch, forKey: Keys.startStackOnLaunch) }
    }

    @Published var defaultProjectPath: String {
        didSet { defaults.set(defaultProjectPath, forKey: Keys.defaultProjectPath) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        self.startStackOnLaunch = defaults.object(forKey: Keys.startStackOnLaunch) as? Bool ?? true
        self.defaultProjectPath = defaults.string(forKey: Keys.defaultProjectPath) ?? ""
    }

    private enum Keys {
        static let launchAtLogin = "launchAtLogin"
        static let startStackOnLaunch = "startStackOnLaunch"
        static let defaultProjectPath = "defaultProjectPath"
    }
}
