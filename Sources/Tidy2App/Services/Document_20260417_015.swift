import Foundation

final class AccessManager: AccessManagerProtocol {
    private let store: SQLiteStore
    private let archiveRootSettingKey = "archive_root_bookmark"
    private let lock = NSLock()
    private var activeURLs: [AccessTarget: URL] = [:]

    init(store: SQLiteStore) {
        self.store = store
    }

    deinit {
        lock.lock()
        let urls = Array(activeURLs.values)
        activeURLs.removeAll()
        lock.unlock()

        for url in urls {
            url.stopAccessingSecurityScopedResource()
        }
    }

    func resolveDownloadsAccess() throws -> URL? {
        try resolveAccess(target: .downloads)
    }

    func resolveDesktopAccess() throws -> URL? {
        try resolveAccess(target: .desktop)
    }

    func resolveDocumentsAccess() throws -> URL? {
        try resolveAccess(target: .documents)
    }

    func resolveArchiveRootAccess() throws -> URL? {
        try resolveAccess(target: .archiveRoot)
    }

    func saveDownloadsBookmark(url: URL) throws {
        try saveBookmark(target: .downloads, url: url)
    }

    func saveDesktopBookmark(url: URL) throws {
        try saveBookmark(target: .desktop, url: url)
    }

    func saveDocumentsBookmark(url: URL) throws {
        try saveBookmark(target: .documents, url: url)
    }

    func saveArchiveRootBookmark(url: URL) throws {
        try saveBookmark(target: .archiveRoot, url: url)
    }

    func health(target: AccessTarget) throws -> AccessHealthItem {
        let loaded = try loadBookmark(target: target)
        guard let bookmark = loaded.bookmark else {
            return AccessHealthItem(target: target, status: .missing, path: loaded.path)
        }

        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            if stale {
                return AccessHealthItem(target: target, status: .stale, path: url.path)
            }

            if url.startAccessingSecurityScopedResource() {
                url.stopAccessingSecurityScopedResource()
                return AccessHealthItem(target: target, status: .ok, path: url.path)
            }
            return AccessHealthItem(target: target, status: .denied, path: url.path)
        } catch {
            return AccessHealthItem(target: target, status: .denied, path: loaded.path)
        }
    }

    func healthSnapshot() throws -> [AccessHealthItem] {
        try AccessTarget.allCases.map { try health(target: $0) }
    }

    func makeAccessError(target: AccessTarget, reason: String, fallbackStatus: AccessHealthStatus? = nil) -> NSError {
        let hint: AccessActionHint
        switch target {
        case .downloads:
            hint = .reauthorizeDownloads
        case .archiveRoot:
            hint = .reauthorizeArchiveRoot
        case .desktop:
            hint = .enableDesktop
        case .documents:
            hint = .enableDocuments
        }

        return NSError(
            domain: "AccessManager",
            code: 403,
            userInfo: [
                NSLocalizedDescriptionKey: reason,
                "action_hint": hint.rawValue,
                "access_target": target.rawValue,
                "access_status": (fallbackStatus ?? .denied).rawValue
            ]
        )
    }

    // MARK: - Private

    private func resolveAccess(target: AccessTarget) throws -> URL? {
        lock.lock()
        if let existing = activeURLs[target] {
            lock.unlock()
            return existing
        }
        lock.unlock()

        let loaded = try loadBookmark(target: target)
        guard let bookmark = loaded.bookmark else {
            return nil
        }

        var stale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )

        if stale {
            try saveBookmark(target: target, url: url)
        }

        guard url.startAccessingSecurityScopedResource() else {
            throw makeAccessError(
                target: target,
                reason: "Access denied for \(target.rawValue). Please re-authorize.",
                fallbackStatus: .denied
            )
        }

        lock.lock()
        activeURLs[target] = url
        lock.unlock()

        return url
    }

    private func saveBookmark(target: AccessTarget, url: URL) throws {
        let bookmark = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        switch target {
        case .downloads:
            try store.saveAuthorizedRoot(scope: .downloads, path: url.path, bookmark: bookmark)
        case .desktop:
            try store.saveAuthorizedRoot(scope: .desktop, path: url.path, bookmark: bookmark)
        case .documents:
            try store.saveAuthorizedRoot(scope: .documents, path: url.path, bookmark: bookmark)
        case .archiveRoot:
            try store.setBlobSetting(key: archiveRootSettingKey, value: bookmark)
        }
    }

    private func loadBookmark(target: AccessTarget) throws -> (bookmark: Data?, path: String?) {
        switch target {
        case .downloads:
            guard let record = try store.loadAuthorizedRoot(scope: .downloads) else {
                return (nil, nil)
            }
            return (record.bookmark, record.path)
        case .desktop:
            guard let record = try store.loadAuthorizedRoot(scope: .desktop) else {
                return (nil, nil)
            }
            return (record.bookmark, record.path)
        case .documents:
            guard let record = try store.loadAuthorizedRoot(scope: .documents) else {
                return (nil, nil)
            }
            return (record.bookmark, record.path)
        case .archiveRoot:
            let data = try store.blobSetting(key: archiveRootSettingKey)
            if let data {
                var stale = false
                let url = try? URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
                return (data, url?.path)
            }
            return (nil, nil)
        }
    }
}
