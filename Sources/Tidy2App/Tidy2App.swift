import AppKit
import SwiftUI
import UserNotifications

enum AppSceneID {
    static let mainWindow = "main-window"
}

@main
struct Tidy2App: App {
    @StateObject private var launcher = AppLauncher()
    private let isBackgroundScan = CommandLine.arguments.contains("--background-scan")
    private let notificationDelegate = NotificationDelegate()

    init() {
        if CommandLine.arguments.contains("--background-scan") {
            NSApp.setActivationPolicy(.prohibited)
        }
        UNUserNotificationCenter.current().delegate = notificationDelegate
    }

    var body: some Scene {
        WindowGroup(id: AppSceneID.mainWindow) {
            Group {
                if isBackgroundScan {
                    if let appState = launcher.appState {
                        BackgroundScanView(appState: appState, notificationDelegate: notificationDelegate)
                    } else {
                        EmptyView()
                    }
                } else if let appState = launcher.appState {
                    MainWindowRootView(appState: appState, notificationDelegate: notificationDelegate)
                } else {
                    StartupErrorView(launcher: launcher)
                }
            }
            .frame(minWidth: 900, minHeight: 580)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                if let appState = launcher.appState {
                    Button("重新扫描") {
                        appState.scanButtonTappedFromHome()
                    }
                    .keyboardShortcut("r", modifiers: .command)

                    Button("撤销上次操作") {
                        Task { await appState.undoLastOperation() }
                    }
                    .keyboardShortcut("z", modifiers: .command)

                    Button("AI 分析") {
                        Task { await appState.analyzeNewFiles() }
                    }
                    .keyboardShortcut("a", modifiers: [.command, .shift])

                    Divider()

                    Button("智能整理") {
                        appState.pendingTab = .aiFiles
                    }
                    .keyboardShortcut("1", modifiers: .command)

                    Button("搜索文件") {
                        appState.pendingTab = .search
                    }
                    .keyboardShortcut("f", modifiers: .command)

                    Button("案件助手") {
                        appState.pendingTab = .caseIntake
                    }
                    .keyboardShortcut("2", modifiers: .command)

                    Button("偏好设置") {
                        appState.pendingTab = .settings
                    }
                    .keyboardShortcut(",", modifiers: .command)
                }
            }
        }

        MenuBarExtra {
            Group {
                if let appState = launcher.appState {
                    MenuBarContentView()
                        .environmentObject(appState)
                } else {
                    Text("正在启动…")
                        .padding(12)
                }
            }
        } label: {
            let bundles = launcher.appState?.bundles.count ?? 0
            let aiDelete = launcher.appState?.aiIntelligenceItems.filter { $0.keepOrDelete == .delete }.count ?? 0
            let aiArchive = launcher.appState?.aiIntelligenceItems.filter { $0.keepOrDelete == .keep && !$0.suggestedFolder.isEmpty }.count ?? 0
            let expired = launcher.appState?.digest.expiredQuarantineCount ?? 0
            let total = bundles + aiDelete + aiArchive + expired
            Label(total > 0 ? "\(total)" : "", systemImage: "folder.badge.gearshape")
        }
        .menuBarExtraStyle(.menu)
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
            appState?.requestNotificationPermission()
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

private struct MainWindowRootView: View {
    @ObservedObject var appState: AppState
    let notificationDelegate: NotificationDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        RootView()
            .environmentObject(appState)
            .task {
                configureNotificationDelegate()
                await appState.bootstrapIfNeeded()
            }
    }

    private func configureNotificationDelegate() {
        notificationDelegate.openBundlesTab = {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: AppSceneID.mainWindow)
            appState.openBundlesTab()
            if let window = NSApp.windows.first {
                window.makeKeyAndOrderFront(nil)
            }
        }
        UNUserNotificationCenter.current().delegate = notificationDelegate
    }
}

private struct BackgroundScanView: View {
    @ObservedObject var appState: AppState
    let notificationDelegate: NotificationDelegate

    var body: some View {
        EmptyView()
            .task {
                notificationDelegate.openBundlesTab = {
                    NSApp.activate(ignoringOtherApps: true)
                    appState.openBundlesTab()
                    if let window = NSApp.windows.first {
                        window.makeKeyAndOrderFront(nil)
                    }
                }
                UNUserNotificationCenter.current().delegate = notificationDelegate
                await appState.bootstrapIfNeeded()
                await appState.runBackgroundScanAndAutoApply()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                NSApp.terminate(nil)
            }
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
