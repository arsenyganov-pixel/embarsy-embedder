import AppKit
import Foundation

enum WorkspaceError: LocalizedError {
    case emptyPath
    case codeCommandFailed

    var errorDescription: String? {
        switch self {
        case .emptyPath: "Project path is empty. Choose a project folder first."
        case .codeCommandFailed: "Failed to open project in VSCode with the `code` command."
        }
    }
}

struct WorkspaceService {
    func chooseProjectFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    func openInVSCode(path: String) throws {
        guard !path.isEmpty else { throw WorkspaceError.emptyPath }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["code", path]
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw WorkspaceError.codeCommandFailed
        }
    }
}
