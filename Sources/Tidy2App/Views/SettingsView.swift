import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    @AppStorage("auto_scan_enabled") private var autoScanEnabled = true
    @AppStorage("scan_interval_hours") private var scanIntervalHours = 1.0
    @AppStorage("auto_analyze_enabled") private var autoAnalyzeEnabled = true
    @AppStorage("quarantine_retention_days") private var retentionDays = 30
    @AppStorage("notify_ai_done") private var notifyAIDone = true
    @AppStorage("dailyScanEnabled") private var dailyScanEnabled = false
    @AppStorage("downloads_archive_time_window") private var downloadTimeWindow = "all"
    @AppStorage("activeChecklistTemplateId") private var activeChecklistTemplateId = ChecklistTemplate.presets[0].id

    @State private var showResetConfirm = false

    var body: some View {
        Form {
            Section("归档设置") {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("归档目标文件夹")
                            .font(.headline)
                        Text(appState.archiveRootPath.isEmpty ? "未设置" : appState.archiveRootPath)
                            .font(.caption)
                            .foregroundStyle(appState.archiveRootPath.isEmpty ? .red : .secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button("选择文件夹") {
                        appState.chooseArchiveRoot()
                    }
                    .buttonStyle(.borderedProminent)
                }

                Toggle("自动扫描", isOn: $autoScanEnabled)

                HStack {
                    Text("扫描间隔")
                    Spacer()
                    Picker("扫描间隔", selection: $scanIntervalHours) {
                        Text("1 小时").tag(1.0)
                        Text("3 小时").tag(3.0)
                        Text("6 小时").tag(6.0)
                        Text("12 小时").tag(12.0)
                        Text("24 小时").tag(24.0)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                    .disabled(!autoScanEnabled)
                }

                Toggle("扫描后自动 AI 分析", isOn: $autoAnalyzeEnabled)
            }

            Section("扫描范围") {
                accessRow(title: "下载文件夹", target: .downloads)
                accessRow(title: "桌面", target: .desktop)
                accessRow(title: "文稿", target: .documents)

                Picker("下载文件夹扫描范围", selection: $downloadTimeWindow) {
                    Text("最近 7 天").tag(ArchiveTimeWindow.days7.rawValue)
                    Text("最近 30 天").tag(ArchiveTimeWindow.days30.rawValue)
                    Text("全部历史文件").tag(ArchiveTimeWindow.all.rawValue)
                }
                .pickerStyle(.segmented)

                Text("选择“全部历史文件”可在首次使用时清理积压文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("隔离区") {
                HStack {
                    Text("隔离保留天数")
                    Spacer()
                    Picker("隔离保留天数", selection: $retentionDays) {
                        Text("7 天").tag(7)
                        Text("14 天").tag(14)
                        Text("30 天").tag(30)
                        Text("60 天").tag(60)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                }

                Toggle(
                    "每周自动清理过期文件",
                    isOn: Binding(
                        get: { appState.autoPurgeExpiredQuarantine },
                        set: { enabled in
                            Task { await appState.setAutoPurgeExpiredQuarantine(enabled) }
                        }
                    )
                )

                Toggle("AI 分析完成后通知我", isOn: $notifyAIDone)
            }

            Section("后台自动整理") {
                Toggle("每天早上 9 点自动整理低风险文件", isOn: $dailyScanEnabled)
                Text("仅自动处理低风险建议，高风险文件仍会保留给你确认。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("案例清单模板") {
                Picker("案例材料清单", selection: $activeChecklistTemplateId) {
                    ForEach(ChecklistTemplate.presets) { template in
                        Text(template.name).tag(template.id)
                    }
                }
                .pickerStyle(.menu)

                Text("切换模板后，案例页会按对应行业的标准材料清单显示缺失项。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("危险区域") {
                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Label("重置应用数据", systemImage: "trash")
                }
            }

            Section("关于") {
                Text("Tidy 2.0")
                    .font(.headline)
                Text("版本 0.9.5")
                    .foregroundStyle(.secondary)
                Text("本地优先的文件整理助手，AI 驱动，数据不离本机。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("反馈与建议", destination: URL(string: "mailto:feedback@tidy.app")!)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("偏好设置")
        .task {
            downloadTimeWindow = appState.archiveTimeWindow.rawValue
            activeChecklistTemplateId = appState.activeChecklist.id
        }
        .confirmationDialog(
            "这将清除所有扫描记录和整理建议，不影响你的实际文件。确认重置？",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("确认重置", role: .destructive) {
                Task { await appState.resetDatabase() }
            }
            Button("取消", role: .cancel) {}
        }
        .onChange(of: dailyScanEnabled) { enabled in
            let plist = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents/com.tidy2.dailyscan.plist")
            if enabled {
                try? appState.installLaunchAgent()
            } else {
                try? FileManager.default.removeItem(at: plist)
            }
        }
        .onChange(of: downloadTimeWindow) { newValue in
            guard let window = ArchiveTimeWindow(rawValue: newValue) else { return }
            Task {
                await appState.setArchiveTimeWindow(window)
            }
        }
        .onChange(of: appState.archiveTimeWindow) { newValue in
            if downloadTimeWindow != newValue.rawValue {
                downloadTimeWindow = newValue.rawValue
            }
        }
        .onChange(of: activeChecklistTemplateId) { newValue in
            appState.setActiveChecklist(id: newValue)
        }
        .onChange(of: appState.activeChecklist) { newValue in
            if activeChecklistTemplateId != newValue.id {
                activeChecklistTemplateId = newValue.id
            }
        }
    }

    @ViewBuilder
    private func accessRow(title: String, target: AccessTarget) -> some View {
        let item = appState.accessHealth[target]
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                if let path = item?.path, !path.isEmpty {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if item?.status == .ok {
                Label("已授权", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                Button("去授权") {
                    Task { await appState.requestAccess(for: target) }
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
