import Foundation

enum RuntimeLog {
    static func append(_ message: String) {
        do {
            let fileURL = try logFileURL()
            try ensureParentFolder(for: fileURL)
            let line = "[\(DateFormatter.runtimeLogStamp.string(from: Date()))] \(message)\n"

            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                if let data = line.data(using: .utf8) {
                    handle.write(data)
                }
            } else {
                try line.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        } catch {
            print("[Tidy2] runtime log append failed: \(error.localizedDescription)")
        }
    }

    @discardableResult
    static func writeLaunchMarker() -> URL? {
        do {
            let fileURL = try logFileURL()
            try ensureParentFolder(for: fileURL)
            let line = "[\(DateFormatter.runtimeLogStamp.string(from: Date()))] launch\n"

            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                if let data = line.data(using: .utf8) {
                    handle.write(data)
                }
            } else {
                try line.write(to: fileURL, atomically: true, encoding: .utf8)
            }

            print("[Tidy2] runtime log: \(fileURL.path)")
            return fileURL
        } catch {
            print("[Tidy2] runtime log init failed: \(error.localizedDescription)")
            return nil
        }
    }

    static func defaultPathHint() -> String {
        if let url = try? logFileURL() {
            return url.path
        }
        return "~/Library/Application Support/Tidy2/Logs/runtime.log"
    }

    private static func logFileURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Tidy2", isDirectory: true)

        return appSupport
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("runtime.log", isDirectory: false)
    }

    private static func ensureParentFolder(for fileURL: URL) throws {
        let parent = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
    }
}

private extension DateFormatter {
    static let runtimeLogStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
