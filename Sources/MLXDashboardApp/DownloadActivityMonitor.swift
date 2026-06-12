import Foundation
import MLXPythonBridge

struct DownloadCacheSummary: Equatable {
    var totalBytes: Int64
    var incompleteBlobCount: Int
    var pendingFileNames: [String]
    var secondsSinceGrowth: Int?

    var statusText: String {
        var parts = ["Cache \(Self.formatBytes(totalBytes))"]
        if incompleteBlobCount == 1 {
            parts.append("1 incomplete blob")
        } else {
            parts.append("\(incompleteBlobCount) incomplete blobs")
        }
        if let secondsSinceGrowth, secondsSinceGrowth >= 30 {
            parts.append("no growth for \(secondsSinceGrowth)s")
        }
        return parts.joined(separator: " • ")
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let megabytes = Double(bytes) / 1024 / 1024
        if megabytes >= 1 {
            return "\(Int(megabytes.rounded())) MB"
        }
        let kilobytes = Double(bytes) / 1024
        if kilobytes >= 1 {
            return "\(Int(kilobytes.rounded())) KB"
        }
        return "\(bytes) B"
    }
}

struct DownloadCacheSampler {
    func summary(modelID: String, cacheRoot: URL, secondsSinceGrowth: Int? = nil) throws -> DownloadCacheSummary {
        let repo = cacheRoot.appending(path: repoFolderName(for: modelID), directoryHint: .isDirectory)
        var totalBytes: Int64 = 0
        var pendingNames: [String] = []

        guard let enumerator = FileManager.default.enumerator(
            at: repo,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return DownloadCacheSummary(totalBytes: 0, incompleteBlobCount: 0, pendingFileNames: [], secondsSinceGrowth: secondsSinceGrowth)
        }

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            totalBytes += Int64(values.fileSize ?? 0)
            if url.lastPathComponent.hasSuffix(".incomplete") {
                pendingNames.append(url.lastPathComponent)
            }
        }

        return DownloadCacheSummary(
            totalBytes: totalBytes,
            incompleteBlobCount: pendingNames.count,
            pendingFileNames: pendingNames.sorted(),
            secondsSinceGrowth: secondsSinceGrowth
        )
    }

    private func repoFolderName(for modelID: String) -> String {
        "models--" + modelID.replacingOccurrences(of: "/", with: "--")
    }
}

struct XetLogActivityReader {
    func activities(logRoot: URL) throws -> [HuggingFaceDownloadActivity] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: logRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let newest = try files
            .map { url -> (URL, Date) in
                let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
                return (url, values.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(2)
            .map(\.0)

        var activities: [HuggingFaceDownloadActivity] = []
        for file in newest {
            let text = try String(contentsOf: file, encoding: .utf8)
            activities.append(contentsOf: HuggingFaceDownloadActivity.parse(from: text))
        }
        var uniqueActivities: [HuggingFaceDownloadActivity] = []
        for activity in activities {
            if !uniqueActivities.contains(activity) {
                uniqueActivities.append(activity)
            }
        }
        return uniqueActivities
    }
}
