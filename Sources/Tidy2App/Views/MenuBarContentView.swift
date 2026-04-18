import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if appState.bundles.count > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(appState.bundles.count) 条整理建议")
                        .font(.headline)

                    Button("立即整理") {
                        openMainWindow()
                        appState.openBundlesTab()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Text("当前没有待处理建议")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(lastScanText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("立即扫描") {
                Task {
                    await appState.runAutopilotNow()
                }
            }
            .buttonStyle(.bordered)
            .disabled(appState.isBusy)

            Divider()

            Button("退出") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(minWidth: 220, alignment: .leading)
    }

    private var lastScanText: String {
        if let lastScanDate = appState.lastScanDate {
            return "上次扫描：\(DateHelper.relativeShort(lastScanDate))"
        }
        return "上次扫描：尚未扫描"
    }

    private func openMainWindow() {
        openWindow(id: AppSceneID.mainWindow)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.isVisible || $0.canBecomeKey }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
