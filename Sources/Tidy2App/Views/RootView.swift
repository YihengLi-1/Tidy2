import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showAdvancedEntryConfirm = false
    @State private var advancedUnlocked = false
    @State private var selectedSidebarItem: SidebarItem = .home

    var body: some View {
        NavigationSplitView {
            List {
                sidebarRow(.home, title: "首页", icon: "house")

                sidebarRow(
                    .aiFiles,
                    title: "智能整理",
                    icon: "brain",
                    badge: aiActionableCount,
                    badgeColor: aiDeleteSuggestionCount > 0 ? .red : (aiActionableCount > 0 ? .purple : nil)
                )

                sidebarRow(.search, title: "搜索文件", icon: "magnifyingglass")

                sidebarRow(.caseIntake, title: "案件助手", icon: "doc.badge.clock")

                sidebarRow(.settings, title: "偏好设置", icon: "gearshape")
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            NavigationStack(path: $appState.path) {
                detailRootView
                    .navigationDestination(for: AppState.Route.self) { route in
                        destinationView(for: route)
                    }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if appState.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .help("正在扫描…")
                } else {
                    Button {
                        appState.scanButtonTappedFromHome()
                    } label: {
                        Label("重新扫描", systemImage: "arrow.clockwise")
                    }
                    .help("重新扫描文件")
                }

                Menu {
                    advancedMenuContent
                } label: {
                    Label("更多选项", systemImage: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(
            "这些是高级功能，可能影响统计/耗时",
            isPresented: $showAdvancedEntryConfirm,
            titleVisibility: .visible
        ) {
            Button("继续") { advancedUnlocked = true }
            Button("取消", role: .cancel) {}
        }
        .onChange(of: appState.pendingTab) { route in
            guard let route else { return }
            appState.pendingTab = nil
            switch route {
            case .bundles:              switchTo(.bundles)
            case .duplicates:           switchTo(.duplicates)
            case .quarantine:           switchTo(.quarantine)
            case .search:               switchTo(.search)
            case .cleanup:              switchTo(.cleanup)
            case .aiFiles:              switchTo(.aiFiles)
            case .caseIntake:           switchTo(.caseIntake)
            case .cases:                switchTo(.cases)
            case .installerCandidates:  switchTo(.installerCandidates)
            case .changeLog:            switchTo(.changeLog)
            case .settings:             switchTo(.settings)
            case .rules:                switchTo(.rules)
            case .metrics:              switchTo(.metrics)
            case .versionFiles:         switchTo(.versionFiles)
            case .bundleDetail(let id):
                if selectedSidebarItem != .bundles {
                    switchTo(.bundles)
                    DispatchQueue.main.async {
                        if appState.path.last != .bundleDetail(id) {
                            appState.path.append(.bundleDetail(id))
                        }
                    }
                } else {
                    if appState.path.last != .bundleDetail(id) {
                        appState.path.append(.bundleDetail(id))
                    }
                }
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .sheet(isPresented: $appState.showOnboarding) {
            OnboardingView()
                .environmentObject(appState)
        }
        .task {
            await appState.refreshAIAnalysisState()
        }
    }

    // MARK: - Sidebar row builder

    @ViewBuilder
    private func sidebarRow(_ item: SidebarItem,
                            title: String,
                            icon: String,
                            badge: Int = 0,
                            badgeColor: Color? = nil) -> some View {
        Button {
            switchTo(item)
        } label: {
            Label(title, systemImage: icon)
                .badge(badge)
                .foregroundStyle(badgeColor != nil && badge > 0 ? badgeColor! : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .listRowBackground(
            selectedSidebarItem == item
                ? Color.accentColor.opacity(0.18)
                : Color.clear
        )
        .padding(.vertical, 1)
    }

    private func switchTo(_ item: SidebarItem) {
        selectedSidebarItem = item
        appState.path.removeAll()
    }

    // MARK: - Detail routing

    @ViewBuilder
    private var detailRootView: some View {
        switch selectedSidebarItem {
        case .home:                 DigestView()
        case .search:               SearchView()
        case .duplicates:           DuplicatesView()
        case .cleanup:              CleanupView()
        case .aiFiles:              AIFilesView()
        case .caseIntake:           CaseIntakeView()
        case .cases:                CasesView()
        case .versionFiles:         VersionFilesView()
        case .installerCandidates:  InstallerCandidatesView()
        case .bundles:              BundlesView()
        case .quarantine:           QuarantineView()
        case .changeLog:            ChangeLogView()
        case .settings:             SettingsView()
        case .rules:                RulesView()
        case .metrics:              MetricsView()
        }
    }

    @ViewBuilder
    private func destinationView(for route: AppState.Route) -> some View {
        switch route {
        case .bundles:              BundlesView()
        case .bundleDetail(let id): BundleDetailView(bundleID: id)
        case .quarantine:           QuarantineView()
        case .search:               SearchView()
        case .duplicates:           DuplicatesView()
        case .cleanup:              CleanupView()
        case .aiFiles:              AIFilesView()
        case .caseIntake:           CaseIntakeView()
        case .cases:                CasesView()
        case .versionFiles:         VersionFilesView()
        case .installerCandidates:  InstallerCandidatesView()
        case .changeLog:            ChangeLogView()
        case .settings:             SettingsView()
        case .rules:                RulesView()
        case .metrics:              MetricsView()
        }
    }

    // MARK: - Computed

    private var aiDeleteSuggestionCount: Int {
        appState.aiIntelligenceItems.filter { $0.keepOrDelete == .delete }.count
    }

    private var aiActionableCount: Int {
        appState.aiIntelligenceItems.filter {
            ($0.keepOrDelete == .keep && !$0.suggestedFolder.isEmpty) || $0.keepOrDelete == .delete
        }.count
    }

    // MARK: - Advanced menu

    @ViewBuilder
    private var advancedMenuContent: some View {
        Section("操作") {
            Button { switchTo(.installerCandidates); appState.openInstallerCandidates() } label: {
                Label("待处理安装包", systemImage: "tray")
            }
            Button { switchTo(.bundles); appState.openBundles() } label: {
                Label("整理建议", systemImage: "square.stack.3d.up")
            }
            Button { switchTo(.quarantine); appState.openQuarantine() } label: {
                Label("隔离区", systemImage: "shield")
            }
        }

        Section("归档范围") {
            Button(labelForWindow(.days7))  { Task { await appState.setArchiveTimeWindow(.days7)  } }
            Button(labelForWindow(.days30)) { Task { await appState.setArchiveTimeWindow(.days30) } }
            Button(labelForWindow(.all))    { Task { await appState.setArchiveTimeWindow(.all)    } }
        }

        Section("高级") {
            if advancedUnlocked {
                Button { Task { await appState.forceFullScanDownloads() } } label: { Label("重新完整扫描", systemImage: "arrow.clockwise.circle") }
                Button { Task { await appState.runRepairNow() } } label: { Label("修复统计", systemImage: "wrench.and.screwdriver") }
                Button { Task { await appState.exportDebugBundle() } } label: { Label("导出诊断包", systemImage: "square.and.arrow.up") }
                Button { Task { await appState.reportIssue() } } label: { Label("反馈问题", systemImage: "exclamationmark.bubble") }
                Button { switchTo(.metrics) } label: { Label("使用情况", systemImage: "chart.bar") }
                Toggle(isOn: Binding(
                    get: { appState.isTestModeEnabled },
                    set: { v in Task { await appState.setTestModeEnabled(v) } }
                )) { Label("安全试运行", systemImage: "testtube.2") }
                Button(role: .destructive) { Task { await appState.resetDatabase() } } label: { Label("重置应用数据", systemImage: "trash") }
                Divider()
                Button { advancedUnlocked = false } label: { Label("收起高级功能", systemImage: "chevron.up") }
            } else {
                Button { showAdvancedEntryConfirm = true } label: { Label("展开高级功能", systemImage: "wrench.and.screwdriver") }
            }
        }
    }

    private func labelForWindow(_ window: ArchiveTimeWindow) -> String {
        let mark = appState.archiveTimeWindow == window ? "✓ " : ""
        switch window {
        case .days7:  return "\(mark)最近 7 天"
        case .days30: return "\(mark)最近 30 天"
        case .all:    return "\(mark)全部（仅移动）"
        }
    }
}

// MARK: - Sidebar items enum

private enum SidebarItem: Hashable {
    case home, search, duplicates, cleanup, aiFiles, caseIntake, cases, versionFiles
    case installerCandidates, bundles, quarantine, changeLog
    case settings, rules, metrics

    var isPrimary: Bool {
        switch self {
        case .home, .search, .settings, .aiFiles, .caseIntake:
            return true
        default:
            return false
        }
    }
}
