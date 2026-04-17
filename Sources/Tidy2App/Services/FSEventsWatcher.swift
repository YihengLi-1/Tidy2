import CoreServices
import Foundation

final class FSEventsWatcher {
    struct WatchRoot: Hashable {
        let scope: RootScope
        let url: URL
    }

    struct ScopedDirectoryDelta: Hashable {
        let scope: RootScope
        let directories: [URL]
    }

    typealias ChangeHandler = ([ScopedDirectoryDelta]) -> Void

    private let watchRoots: [WatchRoot]
    private let debounceInterval: TimeInterval
    private let onChange: ChangeHandler

    private let callbackQueue = DispatchQueue(label: "tidy2.fsevents.callback")
    private let debounceQueue = DispatchQueue(label: "tidy2.fsevents.debounce")

    private var stream: FSEventStreamRef?
    private var pendingByScope: [RootScope: Set<String>] = [:]
    private var debounceWorkItem: DispatchWorkItem?

    init(watchRoots: [WatchRoot], debounceInterval: TimeInterval = 4.0, onChange: @escaping ChangeHandler) {
        self.watchRoots = watchRoots.sorted { $0.url.path.count > $1.url.path.count }
        self.debounceInterval = debounceInterval
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() throws {
        guard stream == nil else { return }
        guard !watchRoots.isEmpty else { return }

        let paths = watchRoots.map { $0.url.path } as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            nil,
            Self.callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            flags
        ) else {
            throw NSError(domain: "FSEventsWatcher", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create FSEvents stream"])
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, callbackQueue)

        if !FSEventStreamStart(stream) {
            stop()
            throw NSError(domain: "FSEventsWatcher", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to start FSEvents stream"])
        }
    }

    func stop() {
        debounceQueue.sync {
            debounceWorkItem?.cancel()
            debounceWorkItem = nil
            pendingByScope.removeAll()
        }

        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func handleEventBatch(paths: [String], flags: UnsafePointer<FSEventStreamEventFlags>?, count: Int) {
        guard !paths.isEmpty else { return }

        var additions: [RootScope: Set<String>] = [:]
        let flagBuffer = flags.map { UnsafeBufferPointer(start: $0, count: count) }

        for (index, path) in paths.enumerated() {
            let eventFlag = flagBuffer?[safe: index] ?? 0
            let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            let directoryPath: String
            if isDirectoryEvent(eventFlag) {
                directoryPath = normalizedPath
            } else {
                directoryPath = URL(fileURLWithPath: normalizedPath).deletingLastPathComponent().path
            }

            guard let scope = scopeForPath(directoryPath) else { continue }
            additions[scope, default: []].insert(directoryPath)
        }

        guard !additions.isEmpty else { return }

        debounceQueue.async { [weak self] in
            guard let self else { return }
            for (scope, directories) in additions {
                self.pendingByScope[scope, default: []].formUnion(directories)
            }

            self.debounceWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.flushPendingChanges()
            }
            self.debounceWorkItem = workItem
            self.debounceQueue.asyncAfter(deadline: .now() + self.debounceInterval, execute: workItem)
        }
    }

    private func flushPendingChanges() {
        let snapshot = pendingByScope
        pendingByScope.removeAll()

        let deltas = snapshot.map { entry in
            let directories = entry.value
                .map { URL(fileURLWithPath: $0) }
                .sorted { $0.path < $1.path }
            return ScopedDirectoryDelta(scope: entry.key, directories: directories)
        }
        .sorted { $0.scope.rawValue < $1.scope.rawValue }

        guard !deltas.isEmpty else { return }

        DispatchQueue.main.async { [onChange] in
            onChange(deltas)
        }
    }

    private func scopeForPath(_ path: String) -> RootScope? {
        for root in watchRoots {
            let rootPath = root.url.path
            if path == rootPath || path.hasPrefix(rootPath + "/") {
                return root.scope
            }
        }
        return nil
    }

    private func isDirectoryEvent(_ flag: FSEventStreamEventFlags) -> Bool {
        let directoryMask = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
        return (flag & directoryMask) != 0
    }

    private static let callback: FSEventStreamCallback = { _, info, eventCount, eventPathsPointer, eventFlags, _ in
        guard let info else { return }
        let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
        let count = Int(eventCount)
        guard count > 0 else { return }

        let pathsArray = unsafeBitCast(eventPathsPointer, to: NSArray.self)
        let paths = pathsArray.compactMap { $0 as? String }
        watcher.handleEventBatch(paths: paths, flags: eventFlags, count: count)
    }
}

private extension UnsafeBufferPointer {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}
