import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "folder.badge.gearshape").foregroundStyle(.blue)
                Text("Tidy").font(.headline)
                Spacer()
                if appState.isBusy { ProgressView().controlSize(.mini) }
            }

            Divider()

            if totalPending > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    if appState.bundles.count > 0 {
                        statRow("square.stack.3d.up", "\(appState.bundles.count) 条整理建议", .green)
                    }
                    let aiDel = appState.aiIntelligenceItems.filter { $0.keepOrDelete == .delete }.count
                    if aiDel > 0 {
                        statRow("trash", "\(aiDel) 个 AI 建议删除", .orange)
                    }
                    if appState.duplicateGroups.count > 0 {
                        statRow("doc.on.doc", "\(appState.duplicateGroups.count) 组重复文件", .red)
                    }
                    if appState.digest.expiredQuarantineCount > 0 {
                        statRow("shield", "\(appState.digest.expiredQuarantineCount) 个隔离已过期", .secondary)
                    }
                }
                Button("打开 Tidy") { openMainWindow() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("一切井井有条").font(.subheadline).foregroundStyle(.secondary)
                }
            }

            Divider()

            Text(lastScanText).font(.caption).foregroundStyle(.secondary)

            Button("立即扫描") {
                Task { await appState.runAutopilotNow() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(appState.isBusy)

            Divider()

            Button("退出 Tidy") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .padding(12)
        .frame(minWidth: 240, alignment: .leading)
    }

    private var totalPending: Int {
        appState.bundles.count +
        appState.aiIntelligenceItems.filter { $0.keepOrDelete == .delete }.count +
        appState.duplicateGroups.count +
        appState.digest.expiredQuarantineCount
    }

    private func statRow(_ icon: String, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 14)
            Text(label).font(.caption)
        }
    }

    private var lastScanText: String {
        if let d = appState.lastScanDate { return "上次扫描：\(DateHelper.relativeShort(d))" }
        return "尚未扫描"
    }

    private func openMainWindow() {
        openWindow(id: AppSceneID.mainWindow)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.isVisible || $0.canBecomeKey }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
