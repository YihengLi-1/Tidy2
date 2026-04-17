import AppKit
import SwiftUI

@main
struct Tidy2App: App {
    @StateObject private var launcher = AppLauncher()

    var body: some Scene {
        WindowGroup {
            Group {
                if let appState = launcher.appState {
                    RootView()
                        .environmentObject(appState)
                        .task {
                            await appState.bootstrapIfNeeded()
                        }
                } else {
                    StartupErrorView(launcher: launcher)
                }
            }
            .frame(minWidth: 780, minHeight: 520)
        }
    }
}

@MainActor
private final class AppLauncher: ObservableObject {
    @Published var appState: AppState?
    @Published var startupError: String = ""

    init() {
        bootstrap()
    }

    func bootstrap() {
        do {
            let container = try ServiceContainer()
            appState = AppState(services: container)
            startupError = ""
            print("[Tidy2] launch")
        } catch {
            appState = nil
            startupError = error.localizedDescription
            print("[Tidy2] startup failed: \(error.localizedDescription)")
        }
    }

    func resetDBAndRetry() {
        do {
            try SQLiteStore.resetPersistentStoreOnDisk()
            bootstrap()
        } catch {
            startupError = "Reset DB failed: \(error.localizedDescription)"
            print("[Tidy2] reset db failed: \(error.localizedDescription)")
        }
    }

    func openReauthorize() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func copyDiagnostics() {
        let dbPath = (try? SQLiteStore.defaultDatabasePath()) ?? "unknown"
        let text = """
        [Tidy2 startup diagnostics]
        error: \(startupError)
        db_path: \(dbPath)
        runtime_log: \(runtimeLogPathHint())
        os: \(ProcessInfo.processInfo.operatingSystemVersionString)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func runtimeLogPathHint() -> String {
        if let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            return appSupport
                .appendingPathComponent("Tidy2", isDirectory: true)
                .appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent("runtime.log", isDirectory: false)
                .path
        }
        return "~/Library/Application Support/Tidy2/Logs/runtime.log"
    }
}

private struct StartupErrorView: View {
    @ObservedObject var launcher: AppLauncher

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tidy 2.0 startup failed")
                .font(.title2.weight(.semibold))

            Text("The local database may be inconsistent. You can reset DB without manually finding container paths.")
                .foregroundStyle(.secondary)

            Text(launcher.startupError.isEmpty ? "Unknown startup error" : launcher.startupError)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(10)
                .background(Color.gray.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 10) {
                Button("Reset DB") {
                    launcher.resetDBAndRetry()
                }
                .buttonStyle(.borderedProminent)

                Button("Re-authorize") {
                    launcher.openReauthorize()
                }
                .buttonStyle(.bordered)

                Button("Copy diagnostics") {
                    launcher.copyDiagnostics()
                }
                .buttonStyle(.bordered)

                Button("Retry") {
                    launcher.bootstrap()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(24)
    }
}
