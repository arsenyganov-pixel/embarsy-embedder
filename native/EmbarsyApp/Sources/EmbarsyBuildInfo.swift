import Foundation

struct EmbarsyBuildInfo {
    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    static var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }

    static var bundlePath: String {
        Bundle.main.bundleURL.path
    }

    static var isRunningFromMountedVolume: Bool {
        bundlePath.hasPrefix("/Volumes/")
    }

    static var mountedVolumeWarning: String? {
        guard isRunningFromMountedVolume else { return nil }
        return "Running from a mounted DMG at \(bundlePath). Copy Embarsy.app to /Applications or rebuild/remount the DMG before testing fixes."
    }

    static var summary: String {
        var lines = [
            "Version: \(shortVersion)",
            "Build: \(bundleVersion)",
            "Bundle path: \(bundlePath)",
        ]
        if let mountedVolumeWarning {
            lines.append("Warning: \(mountedVolumeWarning)")
        }
        return lines.joined(separator: "\n")
    }
}
