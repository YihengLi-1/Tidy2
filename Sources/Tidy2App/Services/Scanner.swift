import Foundation

final class Scanner: ScannerServiceProtocol {
    private let store: SQLiteStore
    private let fileManager = FileManager.default
    private let testModeSettingKey = "test_mode_enabled"

    private let skipPackageExtensions: Set<String> = [
        "app", "pkg", "photoslibrary", "bundle", "framework", "xcarchive"
    ]

    init(store: SQLiteStore) {
        self.store = store
    }

    func detectDuplicateGroups(scope: RootScope) throws -> DuplicateScanReport {
        let indexedFiles = try scopedIndexedFiles(scope: scope)
        let candidates = indexedFiles.filter(isEligibleForDuplicateScan)

        let buckets = Dictionary(grouping: candidates, by: { $0.sizeBytes })
            .values
            .filter { $0.count > 1 }

        var hashMap: [String: [IndexedFile]] = [:]
        var sizeOnlyDuplicateCandidates = 0
        var hashedFilesCount = 0

        for bucket in buckets {
            guard let size = bucket.first?.sizeBytes else { continue }

            if size > 512 * 1024 * 1024 {
                // Large files are grouped only by size for hinting; never auto-isolated in MVP.
                sizeOnlyDuplicateCandidates += bucket.count
                continue
            }

            for file in bucket {
                let url = URL(fileURLWithPath: file.path)
                do {
                    let sha = try FileHash.sha256(for: url)
                    try store.updateFileHash(path: file.path, sha256: sha)
                    hashedFilesCount += 1

                    let refreshed = IndexedFile(
                        id: file.id,
                        path: file.path,
                        rootScope: file.rootScope,
                        name: file.name,
                        ext: file.ext,
                        sizeBytes: file.sizeBytes,
                        modifiedAt: file.modifiedAt,
                        lastSeenAt: file.lastSeenAt,
                        sha256: sha
                    )
                    hashMap[sha, default: []].append(refreshed)
                } catch {
                    continue
                }
            }
        }

        var groups: [DuplicateScanGroup] = []
        for (sha, files) in hashMap where files.count > 1 {
            let sorted = files.sorted {
                if $0.modifiedAt == $1.modifiedAt {
                    return $0.path < $1.path
                }
                return $0.modifiedAt > $1.modifiedAt
            }
            guard let canonical = sorted.first else { continue }
            let duplicates = Array(sorted.dropFirst())
            groups.append(
                DuplicateScanGroup(
                    sha256: sha,
                    canonical: canonical,
                    duplicatesToQuarantine: duplicates
                )
            )
        }

        logDuplicateScanStats(
            scope: scope,
            dbCandidateCount: indexedFiles.count,
            eligibleCandidateCount: candidates.count,
            bucketCount: buckets.count,
            hashedFilesCount: hashedFilesCount,
            verifiedGroupCount: groups.count,
            sizeOnlyDuplicateCandidates: sizeOnlyDuplicateCandidates
        )

        return DuplicateScanReport(
            verifiedGroups: groups.sorted { $0.canonical.modifiedAt > $1.canonical.modifiedAt },
            sizeOnlyDuplicateCandidates: sizeOnlyDuplicateCandidates
        )
    }

    private func scopedIndexedFiles(scope: RootScope) throws -> [IndexedFile] {
        let files = try store.listFiles(scope: scope)
        guard scope == .downloads else { return files }
        let raw = try store.stringSetting(key: testModeSettingKey) ?? "0"
        guard raw == "1" || raw.lowercased() == "true" else { return files }

        guard let downloads = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            return files
        }
        let testRootPath = downloads.appendingPathComponent("TidyTest", isDirectory: true).standardizedFileURL.path
        return files.filter { file in
            let path = URL(fileURLWithPath: file.path).standardizedFileURL.path
            return path == testRootPath || path.hasPrefix(testRootPath + "/")
        }
    }

    private func isEligibleForDuplicateScan(_ file: IndexedFile) -> Bool {
        let url = URL(fileURLWithPath: file.path)

        // Symlink policy: skip symlinks to avoid duplicate counting across alias paths.
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return false
        }

        for component in url.pathComponents {
            if component.hasPrefix(".") && component != "." && component != ".." {
                return false
            }

            let ext = URL(fileURLWithPath: component).pathExtension.lowercased()
            if skipPackageExtensions.contains(ext) {
                return false
            }
        }

        if let fileType = try? fileManager.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType,
           fileType == .typeSymbolicLink {
            return false
        }

        if let fileType = try? fileManager.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType,
           fileType != .typeRegular {
            return false
        }

        // No extension whitelist: include all regular files for duplicate detection.
        return true
    }

    private func logDuplicateScanStats(scope: RootScope,
                                       dbCandidateCount: Int,
                                       eligibleCandidateCount: Int,
                                       bucketCount: Int,
                                       hashedFilesCount: Int,
                                       verifiedGroupCount: Int,
                                       sizeOnlyDuplicateCandidates: Int) {
        let line = """
        [Scanner] detectDuplicateGroups scope=\(scope.rawValue) db_candidates=\(dbCandidateCount) eligible_candidates=\(eligibleCandidateCount) size_buckets=\(bucketCount) hashed_files=\(hashedFilesCount) verified_groups=\(verifiedGroupCount) size_only_candidates=\(sizeOnlyDuplicateCandidates)
        """
        appendRuntimeLog(line)
    }

    private func appendRuntimeLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        print(line.trimmingCharacters(in: .newlines))

        do {
            let appSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Tidy2", isDirectory: true)

            let logFolder = appSupport.appendingPathComponent("Logs", isDirectory: true)
            if !fileManager.fileExists(atPath: logFolder.path) {
                try fileManager.createDirectory(at: logFolder, withIntermediateDirectories: true)
            }

            let logURL = logFolder.appendingPathComponent("runtime.log", isDirectory: false)
            if fileManager.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                if let data = line.data(using: .utf8) {
                    handle.write(data)
                }
            } else {
                try line.write(to: logURL, atomically: true, encoding: .utf8)
            }
        } catch {
            print("[Scanner] runtime.log write failed: \(error.localizedDescription)")
        }
    }
}
