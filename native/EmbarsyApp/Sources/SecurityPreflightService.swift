import Darwin
import Foundation
import Security

struct SecurityPreflight {
    let bundlePath: String
    let bundleID: String
    let installedInApplications: Bool
    let hasQuarantine: Bool
    let codeSignatureValid: Bool

    static let unknown = SecurityPreflight(
        bundlePath: "Unknown",
        bundleID: "Unknown",
        installedInApplications: false,
        hasQuarantine: false,
        codeSignatureValid: false
    )

    var hasWarnings: Bool {
        !installedInApplications || hasQuarantine || !codeSignatureValid
    }

    var summary: String {
        let applicationsStatus = installedInApplications ? "yes" : "no"
        let quarantineStatus = hasQuarantine ? "detected" : "not detected"
        let signatureStatus = codeSignatureValid ? "valid" : "not valid"

        return [
            "Bundle: \(bundlePath)",
            "Bundle ID: \(bundleID)",
            "Installed in /Applications: \(applicationsStatus)",
            "Quarantine: \(quarantineStatus)",
            "Code signature: \(signatureStatus)",
        ].joined(separator: "\n")
    }
}

struct SecurityPreflightService {
    func check(bundle: Bundle = .main) -> SecurityPreflight {
        let bundleURL = bundle.bundleURL
        return SecurityPreflight(
            bundlePath: bundleURL.path,
            bundleID: bundle.bundleIdentifier ?? "Unknown",
            installedInApplications: bundleURL.path.hasPrefix("/Applications/"),
            hasQuarantine: hasExtendedAttribute("com.apple.quarantine", at: bundleURL.path),
            codeSignatureValid: isCurrentCodeSignatureValid()
        )
    }

    private func hasExtendedAttribute(_ name: String, at path: String) -> Bool {
        getxattr(path, name, nil, 0, 0, 0) >= 0
    }

    private func isCurrentCodeSignatureValid() -> Bool {
        var code: SecCode?
        let copyStatus = SecCodeCopySelf(SecCSFlags(), &code)
        guard copyStatus == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, SecCSFlags(), nil) == errSecSuccess
    }
}
