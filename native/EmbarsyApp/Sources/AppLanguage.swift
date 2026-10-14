import AppKit
import Foundation

/// The interface language, chosen in Settings. English unless the person picks Russian —
/// the Mac's own language doesn't switch it. macOS picks a bundle's language once, at launch,
/// so a change applies after Embarsy restarts.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case russian = "ru"

    var id: String { rawValue }

    /// Each language named in itself, so it's findable whatever the current one is.
    var nativeName: String {
        switch self {
        case .english: return "English"
        case .russian: return "Русский"
        }
    }

    private static let key = "embarsyLanguage"

    static var chosen: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .english
    }

    /// What the running process actually shows (it changes only on restart).
    static let running: AppLanguage = {
        Bundle.main.preferredLocalizations.first == "ru" ? .russian : .english
    }()

    /// Called first thing at launch, before any text is looked up: pins this app's
    /// language list to the chosen one, so the bundle loads it.
    static func applyAtLaunch() {
        UserDefaults.standard.set([chosen.rawValue], forKey: "AppleLanguages")
    }

    static func choose(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: key)
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
    }

    /// Starts a fresh copy of the app and quits this one. The stack keeps running; the new
    /// copy finds it as it does after any restart.
    static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// The language the local model writes its explanations in — the one on screen.
    static var modelInstruction: String {
        running == .russian ? "Russian" : "English"
    }
}

/// A phrase for the interface, translated. Use it wherever a sentence is built as a `String`
/// (a hover, a notice, a finding) rather than written straight into `Text("…")` — the
/// compiler collects its English text as a key for Localizable.strings either way.
func L(_ text: String.LocalizationValue) -> String {
    String(localized: text)
}
