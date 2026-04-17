import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    @AppStorage("auto_scan_enabled") private var autoScanEnabled = true
    @AppStorage("scan_interval_hours") private var scanIntervalHours = 1.0
    @AppStorage("auto_analyze_enabled") private var autoAnalyzeEnabled = true
    @AppStorage("quarantine_retention_days") private var retentionDays = 30
    @AppStorage("dailyScanEnabled") private var dailyScanEnabled = false

    @State private var showResetConfirmation = false

    var body: some View {
        Form {
            Section("归档设置") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("归档目标文件夹")
                        .font(.headline)

                    Text(currentArchiveRootText)
                        .font(.subheadline)
                        .foregroundStyle(appState.archiveRootPath.isEmpty ? .red : .secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)

                    Button("选择文件夹") {
                        selectArchiveRoot()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
                .padding(.vertical, 4)
            }

            Section("扫描范围") {
                authorizationRow(title: "Downloads", target: .downloads)
                authorizationRow(title: "Desktop", target: .desktop)
                authorizationRow(title: "Documents", target: .documents)

                Toggle("自动扫描", isOn: $autoScanEnabled)

                if autoScanEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("每 \(Int(scanIntervalHours)) 小时扫描一次")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: $scanIntervalHours, in: 1...24, step: 1)
                    }
                    .padding(.vertical, 4)
                }

                Toggle("扫描后自动 AI 分析", isOn: $autoAnalyzeEnabled)
            }

            Section("隔离区") {
                Picker("隔离保留天数", selection: $retentionDays) {
                    Text("7 天").tag(7)
                    Text("14 天").tag(14)
                    Text("30 天").tag(30)
                    Text("60 天").tag(60)
                }

                Toggle(
                    "每周自动清理过期文件",
                    isOn: Binding(
                        get: { appState.autoPurgeExpiredQuarantine },
                        set: { newValue in
                            Task { await appState.setAutoPurgeExpiredQuarantine(newValue) }
                        }
                    )
                )
            }

            Section("后台自动整理") {
                Toggle("每天早上 9 点自动整理低风险文件", isOn: $dailyScanEnabled)
            }

            Section("危险区域") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("重置不会删除你的实际文件，只会清除本地扫描记录、AI 分析结果和整理建议。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("重置应用数据", role: .destructive) {
                        showResetConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                .padding(.vertical, 6)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("偏好设置")
        .onChange(of: dailyScanEnabled) { enabled in
            if enabled {
                try? appState.installLaunchAgent()
            } else {
                removeDailyLaunchAgent()
            }
        }
        .confirmationDialog(
            "确认重置应用数据？",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("确认重置", role: .destructive) {
                Task { await appState.resetDatabase() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这将清除所有扫描记录和整理建议，不影响你的实际文件。确认重置？")
        }
    }

    private var currentArchiveRootText: String {
        let trimmed = appState.archiveRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未设置" : trimmed
    }

    @ViewBuilder
    private func authorizationRow(title: String, target: AccessTarget) -> some View {
        let item = appState.accessHealth[target]
        let isAuthorized = item?.status == .ok

        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                Text(accessSubtitle(for: item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            Spacer()

            if isAuthorized {
                Label("已授权", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                Button("去授权") {
                    Task { await appState.requestAccess(for: target) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private func accessSubtitle(for item: AccessHealthItem?) -> String {
        guard let item else { return "尚未授权" }
        let path = item.path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch item.status {
        case .ok:
            return path.isEmpty ? "已授权" : path
        case .missing:
            return "尚未授权"
        case .stale:
            return path.isEmpty ? "权限已失效，请重新授权" : "权限已失效：\(path)"
        case .denied:
            return path.isEmpty ? "当前无法访问，请重新授权" : "当前无法访问：\(path)"
        }
    }

    private func selectArchiveRoot() {
        let panel = NSOpenPanel()
        panel.message = "选择归档目标文件夹"
        panel.prompt = "选择文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if !appState.archiveRootPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: appState.archiveRootPath)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await appState.saveDefaultArchiveRoot(url: url) }
    }

    private func removeDailyLaunchAgent() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("com.tidy2.dailyscan.plist")
        try? FileManager.default.removeItem(at: url)
    }
}
