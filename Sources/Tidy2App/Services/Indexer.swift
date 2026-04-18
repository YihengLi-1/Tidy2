import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

final class Indexer: IndexerServiceProtocol {
    private struct PDFIndexPayload {
        let title: String?
        let snippet: String?
        let body: String
    }

    private struct PersistedIndexStats: Codable {
        let reason: String
        let scope: String
        let root: String
        let watermark: String
        let enumeratedFiles: Int
        let written: Int
        let skippedTotal: Int
        let skippedHidden: Int
        let skippedPackage: Int
        let skippedSymlink: Int
        let skippedExtensionFilter: Int
        let skippedPermission: Int
        let skippedWatermark: Int
        let skippedNonRegular: Int
        let timestamp: Double
    }

    private struct IndexScanStats {
        var enumeratedEntries = 0
        var enumeratedFiles = 0
        var written = 0
        var skippedHidden = 0
        var skippedPackage = 0
        var skippedSymlink = 0
        var skippedExtensionFilter = 0
        var skippedPermission = 0
        var skippedWatermark = 0
        var skippedNonRegular = 0

        var skippedTotal: Int {
            skippedHidden + skippedPackage + skippedSymlink + skippedExtensionFilter + skippedPermission + skippedWatermark + skippedNonRegular
        }

        mutating func merge(_ rhs: IndexScanStats) {
            enumeratedEntries += rhs.enumeratedEntries
            enumeratedFiles += rhs.enumeratedFiles
            written += rhs.written
            skippedHidden += rhs.skippedHidden
            skippedPackage += rhs.skippedPackage
            skippedSymlink += rhs.skippedSymlink
            skippedExtensionFilter += rhs.skippedExtensionFilter
            skippedPermission += rhs.skippedPermission
            skippedWatermark += rhs.skippedWatermark
            skippedNonRegular += rhs.skippedNonRegular
        }
    }

    private let store: SQLiteStore
    private let fileManager = FileManager.default
    private let watermarkKey = "downloads_last_indexed_at"
    private let lastDownloadsIndexStatsKey = "last_downloads_index_stats_json"
    private let pdfMaxPages = 5
    private let pdfMaxChars = 5000
    private let pdfBackfillLimitPerScan = 40
    private let skipPackageExtensions: Set<String> = [
        "app", "pkg", "photoslibrary", "bundle", "framework", "xcarchive"
    ]
    /// Directory names unconditionally skipped during enumeration.
    /// These are dev build/dependency dirs that should never be treated as user docs.
    private static let devDirectoryNames: Set<String> = [
        "node_modules", ".build", "DerivedData", "Pods", ".gradle",
        "vendor", "__pycache__", ".tox", "dist", "target",
        ".meteor", ".cargo", "bower_components"
    ]
    var onScanCompleted: (@Sendable () -> Void)?
    var onProgress: (@Sendable (RootScope, Int) -> Void)?

    init(store: SQLiteStore) {
        self.store = store
    }

    func scanDownloads(rootURL: URL, excludedPaths: [String] = []) throws -> [IndexedFile] {
        try runDownloadsScan(
            rootURL: rootURL,
            forceFullScan: false,
            reason: "scanDownloads",
            excludedPaths: excludedPaths
        )
    }

    func forceFullScanDownloads(rootURL: URL, excludedPaths: [String] = []) throws -> [IndexedFile] {
        try store.setDoubleSetting(key: watermarkKey, value: 0)
        return try runDownloadsScan(
            rootURL: rootURL,
            forceFullScan: true,
            reason: "forceFullScan",
            excludedPaths: excludedPaths
        )
    }

    func reindex(scope: RootScope, rootURL: URL, changedDirectories: [URL], excludedPaths: [String] = []) throws -> [IndexedFile] {
        let scanStartedAt = Date()
        let normalizedDirectories = normalizeDirectories(changedDirectories, within: rootURL)
        let normalizedExcludedPaths = normalizedPaths(excludedPaths)
        var aggregatedStats = IndexScanStats()

        guard !normalizedDirectories.isEmpty else {
            logIndexStats(
                reason: "reindex",
                scope: scope,
                rootURL: rootURL,
                watermark: nil,
                directories: 0,
                stats: aggregatedStats
            )
            return try store.listFiles(scope: scope)
        }

        var seenPaths: Set<String> = []

        for directory in normalizedDirectories {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                var stats = IndexScanStats()
                try indexDirectory(
                    directory,
                    scope: scope,
                    scanStartedAt: scanStartedAt,
                    watermark: nil,
                    excludedPaths: normalizedExcludedPaths,
                    collector: &seenPaths,
                    stats: &stats
                )
                aggregatedStats.merge(stats)
            }
        }

        for directory in normalizedDirectories {
            let knownPaths = try store.filePaths(
                scope: scope,
                underDirectory: directory.path,
                statuses: [.active, .missing]
            )

            for path in knownPaths where !seenPaths.contains(path) {
                try store.updateFileStatus(path: path, status: .missing, lastSeenAt: scanStartedAt)
            }
        }

        logIndexStats(
            reason: "reindex",
            scope: scope,
            rootURL: rootURL,
            watermark: nil,
            directories: normalizedDirectories.count,
            stats: aggregatedStats
        )
        let indexedPDFCount = try backfillPDFTextIndex(scope: scope, limit: max(10, normalizedDirectories.count * 6))
        if indexedPDFCount > 0 {
            appendRuntimeLog("[Indexer] pdf_index_backfill scope=\(scope.rawValue) indexed=\(indexedPDFCount)")
        }
        onScanCompleted?()

        return try store.listFiles(scope: scope)
    }

    private func runDownloadsScan(rootURL: URL,
                                  forceFullScan: Bool,
                                  reason: String,
                                  excludedPaths: [String]) throws -> [IndexedFile] {
        let storedWatermark = try store.doubleSetting(key: watermarkKey)
        let baseWatermark: Date?
        let normalizedExcludedPaths = normalizedPaths(excludedPaths)

        if forceFullScan {
            baseWatermark = nil
        } else if let storedWatermark, storedWatermark > 0 {
            baseWatermark = Date(timeIntervalSince1970: storedWatermark)
        } else {
            baseWatermark = nil
        }

        // Keep 1s overlap to avoid mtime boundary misses (filesystem timestamp precision differs).
        let effectiveWatermark = baseWatermark?.addingTimeInterval(-1)
        let scanStartedAt = Date()
        var collector: Set<String> = []
        var stats = IndexScanStats()

        try indexDirectory(
            rootURL,
            scope: .downloads,
            scanStartedAt: scanStartedAt,
            watermark: effectiveWatermark,
            excludedPaths: normalizedExcludedPaths,
            collector: &collector,
            stats: &stats
        )

        let nextWatermark = max(0, scanStartedAt.addingTimeInterval(-1).timeIntervalSince1970)
        try store.setDoubleSetting(key: watermarkKey, value: nextWatermark)
        let indexedPDFCount = try backfillPDFTextIndex(scope: .downloads, limit: pdfBackfillLimitPerScan)

        logIndexStats(
            reason: reason,
            scope: .downloads,
            rootURL: rootURL,
            watermark: effectiveWatermark,
            directories: 1,
            stats: stats
        )
        if indexedPDFCount > 0 {
            appendRuntimeLog("[Indexer] pdf_index_backfill scope=downloads indexed=\(indexedPDFCount)")
        }
        onScanCompleted?()

        return try store.listFiles(scope: .downloads)
    }

    private func indexDirectory(_ directory: URL,
                                scope: RootScope,
                                scanStartedAt: Date,
                                watermark: Date?,
                                excludedPaths: [String],
                                collector: inout Set<String>,
                                stats: inout IndexScanStats) throws {
        let resourceKeys: [URLResourceKey] = [
            .isDirectoryKey,
            .isPackageKey,
            .isHiddenKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .nameKey
        ]

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: []
        ) else {
            return
        }

        for case let fileURL as URL in enumerator {
            stats.enumeratedEntries += 1
            do {
                let values = try fileURL.resourceValues(forKeys: Set(resourceKeys))

                if values.isHidden == true || fileURL.lastPathComponent.hasPrefix(".") {
                    stats.skippedHidden += 1
                    if values.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                if values.isDirectory == true {
                    let normalizedPath = fileURL.standardizedFileURL.path
                    if excludedPaths.contains(where: { normalizedPath == $0 || normalizedPath.hasPrefix($0 + "/") }) {
                        enumerator.skipDescendants()
                        continue
                    }
                    // Skip git repositories — these are source-code project trees,
                    // not user documents. Indexing them causes source files to be
                    // treated as organizable content and potentially moved/renamed.
                    if fileManager.fileExists(atPath: fileURL.appendingPathComponent(".git").path) {
                        enumerator.skipDescendants()
                        continue
                    }
                    // Skip well-known development build / dependency directories.
                    let dirName = fileURL.lastPathComponent
                    if Self.devDirectoryNames.contains(dirName) {
                        enumerator.skipDescendants()
                        continue
                    }
                    let ext = fileURL.pathExtension.lowercased()
                    if values.isPackage == true || skipPackageExtensions.contains(ext) {
                        stats.skippedPackage += 1
                        enumerator.skipDescendants()
                    }
                    continue
                }

                if values.isSymbolicLink == true {
                    stats.skippedSymlink += 1
                    continue
                }

                guard values.isRegularFile == true else {
                    stats.skippedNonRegular += 1
                    continue
                }

                // Duplicate detection should cover all regular files (no extension whitelist).
                stats.enumeratedFiles += 1
                if stats.enumeratedFiles % 500 == 0 {
                    onProgress?(scope, stats.enumeratedFiles)
                }

                let modifiedAt = values.contentModificationDate ?? scanStartedAt
                if let watermark, modifiedAt < watermark {
                    stats.skippedWatermark += 1
                    continue
                }

                let fileName = values.name ?? fileURL.lastPathComponent
                let ext = fileURL.pathExtension.lowercased()
                let size = Int64(values.fileSize ?? 0)

                try store.upsertFile(
                    path: fileURL.path,
                    rootScope: scope,
                    name: fileName,
                    ext: ext,
                    sizeBytes: size,
                    modifiedAt: modifiedAt,
                    lastSeenAt: scanStartedAt
                )
                do {
                    try indexPDFContentIfNeeded(path: fileURL.path, ext: ext, modifiedAt: modifiedAt)
                } catch {
                    appendRuntimeLog("[Indexer] pdf_index_failed path=\(fileURL.path) error=\(error.localizedDescription)")
                }
                collector.insert(fileURL.path)
                stats.written += 1
            } catch {
                stats.skippedPermission += 1
                continue
            }
        }

        onProgress?(scope, stats.enumeratedFiles)
    }

    private func indexDirectory(_ directory: URL,
                                scope: RootScope,
                                scanStartedAt: Date,
                                watermark: Date?,
                                excludedPaths: [String]) throws {
        var collector: Set<String> = []
        var stats = IndexScanStats()
        try indexDirectory(
            directory,
            scope: scope,
            scanStartedAt: scanStartedAt,
            watermark: watermark,
            excludedPaths: excludedPaths,
            collector: &collector,
            stats: &stats
        )
    }

    private func normalizedPaths(_ paths: [String]) -> [String] {
        paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }

    private func indexPDFContentIfNeeded(path: String, ext: String, modifiedAt: Date) throws {
        guard ext == "pdf" else {
            try? store.removePDFContentIndex(path: path)
            return
        }

        if let indexedModifiedAt = try store.pdfContentIndexModifiedAt(path: path),
           abs(indexedModifiedAt.timeIntervalSince(modifiedAt)) < 0.001 {
            return
        }

        let url = URL(fileURLWithPath: path)
        guard let payload = extractPDFTextPayload(url: url) else {
            try? store.removePDFContentIndex(path: path)
            return
        }

        try store.upsertPDFContentIndex(
            path: path,
            modifiedAt: modifiedAt,
            title: payload.title,
            snippet: payload.snippet,
            body: payload.body
        )
    }

    func backfillPDFTextIndex(scope: RootScope, limit: Int) throws -> Int {
        guard limit > 0 else { return 0 }
        let candidates = try store.listPDFFilesMissingContentIndex(scope: scope, limit: limit)
        guard !candidates.isEmpty else { return 0 }

        var indexed = 0
        for candidate in candidates {
            do {
                try indexPDFContentIfNeeded(path: candidate.path, ext: "pdf", modifiedAt: candidate.modifiedAt)
                indexed += 1
            } catch {
                appendRuntimeLog("[Indexer] pdf_backfill_failed path=\(candidate.path) error=\(error.localizedDescription)")
            }
        }
        return indexed
    }

    private func extractPDFTextPayload(url: URL) -> PDFIndexPayload? {
#if canImport(PDFKit)
        guard let document = PDFDocument(url: url) else { return nil }
        let rawTitle = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = rawTitle?.isEmpty == false ? rawTitle : nil

        var chunks: [String] = []
        var charCount = 0
        let pageCount = min(max(0, document.pageCount), pdfMaxPages)
        for pageIndex in 0 ..< pageCount {
            guard let page = document.page(at: pageIndex),
                  let text = page.string else {
                continue
            }
            let normalized = text
                .replacingOccurrences(of: "\u{0}", with: " ")
                .replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }

            if charCount + normalized.count > pdfMaxChars {
                let remain = max(0, pdfMaxChars - charCount)
                if remain > 0 {
                    chunks.append(String(normalized.prefix(remain)))
                }
                charCount = pdfMaxChars
                break
            } else {
                chunks.append(normalized)
                charCount += normalized.count
            }
        }

        let body = chunks.joined(separator: "\n")
        let snippet: String?
        if let firstLine = body
            .split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            snippet = String(firstLine.prefix(180))
        } else if let title {
            snippet = String(title.prefix(180))
        } else {
            snippet = nil
        }

        if body.isEmpty && title == nil {
            return nil
        }

        let mergedBody: String
        if let title {
            mergedBody = "\(title)\n\(body)"
        } else {
            mergedBody = body
        }
        return PDFIndexPayload(title: title, snippet: snippet, body: mergedBody)
#else
        return nil
#endif
    }

    private func normalizeDirectories(_ directories: [URL], within rootURL: URL) -> [URL] {
        let rootPath = rootURL.standardizedFileURL.path
        var resolved: [String: URL] = [:]

        for directory in directories {
            let standardized = directory.standardizedFileURL
            let path = standardized.path
            guard path == rootPath || path.hasPrefix(rootPath + "/") else { continue }
            resolved[path] = standardized
        }

        // Keep parent-most dirs only to avoid redundant traversal.
        let sorted = resolved.values.sorted { $0.path.count < $1.path.count }
        var filtered: [URL] = []
        for dir in sorted {
            if filtered.contains(where: { dir.path == $0.path || dir.path.hasPrefix($0.path + "/") }) {
                continue
            }
            filtered.append(dir)
        }
        return filtered
    }

    private func logIndexStats(reason: String,
                               scope: RootScope,
                               rootURL: URL,
                               watermark: Date?,
                               directories: Int,
                               stats: IndexScanStats) {
        let watermarkText: String
        if let watermark {
            watermarkText = ISO8601DateFormatter().string(from: watermark)
        } else {
            watermarkText = "nil"
        }

        let line = """
        [Indexer] \(reason) scope=\(scope.rawValue) root=\(rootURL.path) dirs=\(directories) watermark=\(watermarkText) enumerated_files=\(stats.enumeratedFiles) written=\(stats.written) skipped_total=\(stats.skippedTotal) skipped_hidden=\(stats.skippedHidden) skipped_package=\(stats.skippedPackage) skipped_symlink=\(stats.skippedSymlink) skipped_extension_filter=\(stats.skippedExtensionFilter) skipped_permission=\(stats.skippedPermission) skipped_watermark=\(stats.skippedWatermark)
        """
        appendRuntimeLog(line)
        persistLastDownloadsIndexStatsIfNeeded(
            reason: reason,
            scope: scope,
            rootURL: rootURL,
            watermarkText: watermarkText,
            stats: stats
        )
    }

    private func persistLastDownloadsIndexStatsIfNeeded(reason: String,
                                                        scope: RootScope,
                                                        rootURL: URL,
                                                        watermarkText: String,
                                                        stats: IndexScanStats) {
        guard scope == .downloads else { return }
        let payload = PersistedIndexStats(
            reason: reason,
            scope: scope.rawValue,
            root: rootURL.path,
            watermark: watermarkText,
            enumeratedFiles: stats.enumeratedFiles,
            written: stats.written,
            skippedTotal: stats.skippedTotal,
            skippedHidden: stats.skippedHidden,
            skippedPackage: stats.skippedPackage,
            skippedSymlink: stats.skippedSymlink,
            skippedExtensionFilter: stats.skippedExtensionFilter,
            skippedPermission: stats.skippedPermission,
            skippedWatermark: stats.skippedWatermark,
            skippedNonRegular: stats.skippedNonRegular,
            timestamp: Date().timeIntervalSince1970
        )

        do {
            let data = try JSONEncoder().encode(payload)
            let json = String(data: data, encoding: .utf8) ?? "{}"
            try store.setStringSetting(key: lastDownloadsIndexStatsKey, value: json)
        } catch {
            appendRuntimeLog("[Indexer] failed to persist scan stats: \(error.localizedDescription)")
        }
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
            print("[Indexer] runtime.log write failed: \(error.localizedDescription)")
        }
    }
}
