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

    /// `Bundle.main`'s dictionary is read once at launch and keeps describing the bundle
    /// this PROCESS started from — it does not change when the files underneath are
    /// replaced. Reading the plist off disk is therefore the only way to notice that a new
    /// version was installed over a running app, which macOS otherwise does silently: the
    /// old executable keeps running, and every version-dependent affordance (the API
    /// Update button included) keeps comparing against what the old code was built with.
    private static func infoValueOnDisk(_ key: String) -> String? {
        let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
        guard
            let data = try? Data(contentsOf: plist),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info[key] as? String
    }

    static var bundleVersionOnDisk: String? { infoValueOnDisk("CFBundleVersion") }

    static var shortVersionOnDisk: String? { infoValueOnDisk("CFBundleShortVersionString") }

    /// True when the installed bundle is no longer the one this process is running.
    /// Any difference counts, downgrades included: either way what is on screen is not
    /// what is installed, and only a relaunch fixes that.
    static var installedBundleDiffersFromRunning: Bool {
        guard let onDisk = bundleVersionOnDisk else { return false }
        return onDisk != bundleVersion
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
