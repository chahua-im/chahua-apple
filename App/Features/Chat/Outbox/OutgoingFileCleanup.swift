import Foundation

/// Unsent media is not a cache. Only files absent from a durable queue snapshot
/// are eligible, after readers/workers have settled and the handoff grace period.
nonisolated enum OutgoingFileCleanup {
    static func reclaim(directory: URL, retaining paths: Set<String>, olderThan cutoff: Date) async throws {
        try await Task.detached(priority: .utility) {
            let accountRoot = try OutgoingImageFiles.root(directory)
            let root = accountRoot.appendingPathComponent("Outbox", isDirectory: true)
            let manager = FileManager.default
            try OutgoingImageFiles.checkOutbox(root, root: accountRoot)
            guard manager.fileExists(atPath: root.path) else { return }
            let retained = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
            for slot in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)) {
                try Task.checkCancellation()
                let values = try slot.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true, values.isDirectory == true else { continue }
                let files = try manager.contentsOfDirectory(at: slot, includingPropertiesForKeys: Array(keys))
                for file in files {
                    let fileValues = try file.resourceValues(forKeys: keys)
                    guard fileValues.isDirectory != true, fileValues.isSymbolicLink != true,
                        !retained.contains(file.standardizedFileURL.path),
                        let modified = fileValues.contentModificationDate, modified < cutoff
                    else { continue }
                    try manager.removeItem(at: file)
                }
                if try manager.contentsOfDirectory(atPath: slot.path).isEmpty,
                    let modified = values.contentModificationDate, modified < cutoff {
                    try manager.removeItem(at: slot)
                }
            }
        }.value
    }
}
