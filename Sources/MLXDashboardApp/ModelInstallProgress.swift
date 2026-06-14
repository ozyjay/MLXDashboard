import Foundation
import MLXPythonBridge

enum ModelInstallPhase: String, Equatable {
    case preparing
    case checkingPackages
    case checkingLogin
    case downloading
    case finalizing
    case installed
    case paused
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
        case .paused:
            return "Paused"
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
        case .paused:
            return "Paused"
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
        case .installed, .paused, .blocked, .failed:
            return 1.0
        }
    }

    var canContinueDownloading: Bool {
        switch self {
        case .paused, .failed:
            return true
        case .preparing, .checkingPackages, .checkingLogin, .downloading, .finalizing, .installed, .blocked:
            return false
        }
    }
}

enum ModelInstallProgressDisplayMode: Equatable {
    case determinate(value: Double)
    case indeterminateDownload
    case phaseFallback(value: Double)
}

struct ModelInstallProgress: Equatable {
    struct ActivityRow: Equatable, Identifiable {
        var id: Int
        var message: String
    }

    private let activityHistoryLimit = 50
    private let compactActivityLimit = 5

    var modelID: String
    var phase: ModelInstallPhase
    var detail: String
    var downloadProgress: HuggingFaceDownloadProgress? = nil
    var cacheSummary: DownloadCacheSummary? = nil
    var activities: [HuggingFaceDownloadActivity] = []

    var title: String {
        phase.title
    }

    var stepText: String {
        phase.stepText
    }

    var fractionCompleted: Double {
        if phase == .downloading, let downloadProgress {
            return downloadProgress.fractionCompleted
        }
        return phase.fractionCompleted
    }

    var progressDisplayMode: ModelInstallProgressDisplayMode {
        if phase == .downloading {
            if let downloadProgress {
                return .determinate(value: downloadProgress.fractionCompleted)
            }
            return .indeterminateDownload
        }
        return .phaseFallback(value: phase.fractionCompleted)
    }

    var isWaitingForDownloadData: Bool {
        phase == .downloading && downloadProgress == nil
    }

    var downloadStatusText: String? {
        guard phase == .downloading else { return nil }
        guard let downloadProgress else { return "Waiting for download data" }
        var parts = [downloadProgress.percentText]
        if let etaText = downloadProgress.etaText {
            parts.append("ETA \(etaText)")
        } else {
            parts.append("Calculating ETA")
        }
        if let rateText = downloadProgress.rateText {
            parts.append(rateText)
        }
        return parts.joined(separator: " • ")
    }

    var cacheStatusText: String? {
        guard phase == .downloading else { return nil }
        return cacheSummary?.statusText
    }

    var xetFallbackHint: String? {
        guard phase == .downloading,
              cacheSummary?.secondsSinceGrowth ?? 0 >= 60,
              activities.contains(where: { $0.source == .xetLog && $0.tone == .warning })
        else { return nil }

        return "Xet download is stalled. Pause, then retry without Xet."
    }

    var activityMessages: [String] {
        activityRows.map(\.message)
    }

    var activityRows: [ActivityRow] {
        compactActivityRows(from: activities)
    }

    var fullActivityRows: [ActivityRow] {
        return activities.enumerated().map { offset, activity in
            ActivityRow(id: offset, message: activity.message)
        }
    }

    private func compactActivityRows(from activities: [HuggingFaceDownloadActivity]) -> [ActivityRow] {
        let startID = max(activities.count - compactActivityLimit, 0)
        return activities
            .suffix(compactActivityLimit)
            .enumerated()
            .map { offset, activity in
                ActivityRow(id: startID + offset, message: activity.message)
            }
    }

    func appendingActivity(_ activity: HuggingFaceDownloadActivity) -> ModelInstallProgress {
        guard activities.last != activity else { return self }

        var copy = self
        copy.activities.append(activity)
        if copy.activities.count > activityHistoryLimit {
            copy.activities = Array(copy.activities.suffix(activityHistoryLimit))
        }
        return copy
    }
}
