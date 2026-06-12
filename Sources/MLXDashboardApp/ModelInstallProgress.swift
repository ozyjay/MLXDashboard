import Foundation

enum ModelInstallPhase: String, Equatable {
    case preparing
    case checkingPackages
    case checkingLogin
    case downloading
    case finalizing
    case installed
    case blocked
    case failed

    var title: String {
        switch self {
        case .preparing:
            return "Preparing"
        case .checkingPackages:
            return "Checking packages"
        case .checkingLogin:
            return "Checking login"
        case .downloading:
            return "Downloading"
        case .finalizing:
            return "Finalizing"
        case .installed:
            return "Installed"
        case .blocked:
            return "Needs setup"
        case .failed:
            return "Failed"
        }
    }

    var stepText: String {
        switch self {
        case .preparing:
            return "Step 1 of 5"
        case .checkingPackages:
            return "Step 2 of 5"
        case .checkingLogin:
            return "Step 3 of 5"
        case .downloading:
            return "Step 4 of 5"
        case .finalizing, .installed:
            return "Step 5 of 5"
        case .blocked:
            return "Paused"
        case .failed:
            return "Stopped"
        }
    }

    var fractionCompleted: Double {
        switch self {
        case .preparing:
            return 0.08
        case .checkingPackages:
            return 0.20
        case .checkingLogin:
            return 0.35
        case .downloading:
            return 0.68
        case .finalizing:
            return 0.90
        case .installed, .blocked, .failed:
            return 1.0
        }
    }
}

struct ModelInstallProgress: Equatable {
    var modelID: String
    var phase: ModelInstallPhase
    var detail: String

    var title: String {
        phase.title
    }

    var stepText: String {
        phase.stepText
    }

    var fractionCompleted: Double {
        phase.fractionCompleted
    }
}
