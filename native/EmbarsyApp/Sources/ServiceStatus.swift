import Foundation
import SwiftUI

enum ServiceStatus: String, CaseIterable, Identifiable {
    case unknown
    case starting
    case running
    case stopped
    case failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unknown: "Unknown"
        case .starting: "Starting"
        case .running: "Running"
        case .stopped: "Stopped"
        case .failed: "Failed"
        }
    }

    var systemImage: String {
        switch self {
        case .running: "circle.fill"
        case .starting: "clock.fill"
        case .failed: "xmark.circle.fill"
        case .stopped: "stop.circle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    /// Status hue from the shared Embarsy palette. `.stopped` and `.unknown`
    /// both resolve to systemGray (was `.gray` / `.secondary`).
    var indicatorColor: Color { Theme.status(self) }
}

enum ManagedService: String, CaseIterable, Identifiable {
    case qdrant
    case ollama
    case api

    var id: String { rawValue }

    var title: String {
        switch self {
        case .qdrant: "Qdrant"
        case .ollama: "Ollama"
        case .api: "Embarsy API"
        }
    }
}

enum InstallStep: String, CaseIterable, Identifiable {
    case idle
    case prepareDirectories
    case secrets
    case validateBinaries
    case startQdrant
    case startOllama
    case prepareModel
    case startAPI
    case verifyHealth
    case completed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .idle: "Ready"
        case .prepareDirectories: "Prepare App Support layout"
        case .secrets: "Prepare local secrets"
        case .validateBinaries: "Validate bundled binaries"
        case .startQdrant: "Start Qdrant"
        case .startOllama: "Start Ollama"
        case .prepareModel: "Download and prepare embedding model"
        case .startAPI: "Start Embarsy API"
        case .verifyHealth: "Verify health"
        case .completed: "Completed"
        }
    }

    var progress: Double {
        switch self {
        case .idle: 0.0
        case .prepareDirectories: 0.12
        case .secrets: 0.24
        case .validateBinaries: 0.36
        case .startQdrant: 0.48
        case .startOllama: 0.60
        case .prepareModel: 0.76
        case .startAPI: 0.88
        case .verifyHealth: 0.96
        case .completed: 1.0
        }
    }
}

struct BinaryCheck: Identifiable, Hashable {
    let service: ManagedService
    let path: String
    let isExecutable: Bool

    var id: String { service.rawValue }
}
