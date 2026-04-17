import AppKit
import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var appState: AppState

    @State private var showAdvancedFilters: Bool
    @State private var didSearch: Bool = false
    @State private var lastParsedQuery: String = ""
    @FocusState private var isSearchFieldFocused: Bool

    init(initialShowAdvancedFilters: Bool = false) {
        _showAdvancedFilters = State(initialValue: initialShowAdvancedFilters)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            searchHeader
            advancedFilters
            resultsSection
        }
        .padding(20)
        .navigationTitle("搜索文件")
        .onAppear {
            isSearchFieldFocused = true
        }
    }

    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("搜索文件名、类型或时间…", text: $appState.queryText)
                .textFieldStyle(.roundedBorder)
                .focused($isSearchFieldFocused)
                .onSubmit {
                    performSearch()
                }

            quickChips

            HStack(spacing: 8) {
                filterBadge("范围", scopeLabel)
                filterBadge("类型", typeLabel)
                filterBadge("时间", timeLabel)
            }

            Button("搜索") {
                performSearch()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(appState.isBusy)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var quickChips: some View {
        HStack(spacing: 8) {
            Button("最近7天 PDF") {
                applyQuickSearch(.pdfLast7DaysDownloads)
            }
            .buttonStyle(.bordered)

            Button("最近30天截图") {
                applyQuickSearch(.screenshotsLast30Days)
            }
            .buttonStyle(.bordered)

            Button("大文件 >200MB") {
                applyQuickSearch(.largeFiles200MB)
            }
            .buttonStyle(.bordered)
        }
    }

    private var advancedFilters: some View {
        DisclosureGroup("筛选条件", isExpanded: $showAdvancedFilters) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("范围", selection: $appState.parsedFilters.location) {
                    Text("全部").tag(RootScope?.none)
                    Text("下载").tag(RootScope?.some(.downloads))
                    Text("桌面").tag(RootScope?.some(.desktop))
                    Text("文稿").tag(RootScope?.some(.documents))
                    Text("已归档").tag(RootScope?.some(.archived))
                }
                .pickerStyle(.segmented)

                TextField("文件类型（如 pdf、jpg）", text: fileTypeBinding)
                    .textFieldStyle(.roundedBorder)

                Toggle("开始日期", isOn: dateFromEnabled)
                if appState.parsedFilters.dateFrom != nil {
                    DatePicker("从", selection: dateFromBinding, displayedComponents: .date)
                }

                Toggle("结束日期", isOn: dateToEnabled)
                if appState.parsedFilters.dateTo != nil {
                    DatePicker("到", selection: dateToBinding, displayedComponents: .date)
                }
            }
            .padding(.top, 8)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var resultsSection: some View {
        if trimmedQuery.isEmpty {
            EmptyStateView(
                icon: "magnifyingglass",
                title: "开始搜索",
                subtitle: "输入文件名、类型（如 pdf、dmg）或关键词"
            )
        } else if didSearch && appState.searchResults.isEmpty {
            EmptyStateView(
                icon: "magnifyingglass",
                title: "没有找到文件",
                subtitle: "试试搜索文件名、扩展名或关键词"
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(appState.searchResults) { item in
                        let intel = appState.searchResultIntelMap[item.path]
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name)
                                    .font(.headline)
                                Text(compactPath(item.path))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let excerpt = item.excerpt, !excerpt.isEmpty {
                                    Text(excerpt)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Text("\(SizeFormatter.string(from: item.sizeBytes)) · \(DateHelper.relativeShort(item.modifiedAt))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                if let intel {
                                    aiMetadata(for: intel)
                                }
                            }
                            Spacer()
                            HStack(spacing: 8) {
                                Button("显示") {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button("移到废纸篓") {
                                    Task {
                                        _ = await appState.moveFileToTrash(path: item.path)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                if let intel, !intel.suggestedFolder.isEmpty {
                                    Button("移到建议位置") {
                                        Task {
                                            await appState.moveFileToSuggestedFolder(intel)
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.gray.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }

    private var scopeLabel: String {
        switch appState.parsedFilters.location {
        case .downloads: return "下载"
        case .desktop:   return "桌面"
        case .documents: return "文稿"
        case .archived:  return "已归档"
        case nil:        return "全部"
        }
    }

    private var typeLabel: String {
        if let fileType = appState.parsedFilters.fileType, !fileType.isEmpty {
            return fileType.uppercased()
        }
        if appState.parsedFilters.minSizeBytes != nil {
            return "大文件"
        }
        return "全部"
    }

    private var timeLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd"

        switch (appState.parsedFilters.dateFrom, appState.parsedFilters.dateTo) {
        case (let from?, let to?):
            return "\(formatter.string(from: from))–\(formatter.string(from: to))"
        case (let from?, nil):
            return "从 \(formatter.string(from: from))"
        case (nil, let to?):
            return "到 \(formatter.string(from: to))"
        default:
            return "全部"
        }
    }

    private var fileTypeBinding: Binding<String> {
        Binding {
            appState.parsedFilters.fileType ?? ""
        } set: { value in
            appState.parsedFilters.fileType = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .nilIfEmpty
        }
    }

    private var dateFromEnabled: Binding<Bool> {
        Binding {
            appState.parsedFilters.dateFrom != nil
        } set: { enabled in
            appState.parsedFilters.dateFrom = enabled ? Date() : nil
        }
    }

    private var dateToEnabled: Binding<Bool> {
        Binding {
            appState.parsedFilters.dateTo != nil
        } set: { enabled in
            appState.parsedFilters.dateTo = enabled ? Date() : nil
        }
    }

    private var dateFromBinding: Binding<Date> {
        Binding {
            appState.parsedFilters.dateFrom ?? Date()
        } set: { value in
            appState.parsedFilters.dateFrom = value
        }
    }

    private var dateToBinding: Binding<Date> {
        Binding {
            appState.parsedFilters.dateTo ?? Date()
        } set: { value in
            appState.parsedFilters.dateTo = value
        }
    }

    private func performSearch() {
        if appState.queryText != lastParsedQuery {
            appState.parseSearch()
            lastParsedQuery = appState.queryText
        }
        appState.executeSearch()
        didSearch = true
    }

    private func applyQuickSearch(_ preset: QuickSearchPreset) {
        let now = Date()
        var filters = SearchFilters()
        switch preset {
        case .pdfLast7DaysDownloads:
            appState.queryText = "pdf last7days downloads"
            filters.location = .downloads
            filters.fileType = "pdf"
            filters.dateFrom = Calendar.current.date(byAdding: .day, value: -7, to: now)
            filters.dateTo = now
        case .screenshotsLast30Days:
            appState.queryText = "screenshots last30days downloads"
            filters.location = .downloads
            filters.keywords = ["screen"]
            filters.dateFrom = Calendar.current.date(byAdding: .day, value: -30, to: now)
            filters.dateTo = now
        case .largeFiles200MB:
            appState.queryText = "large >200mb downloads"
            filters.location = .downloads
            filters.minSizeBytes = 200 * 1024 * 1024
        }

        appState.parsedFilters = filters
        lastParsedQuery = appState.queryText
        appState.executeSearch()
        didSearch = true
    }

    private func compactPath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        let components = URL(fileURLWithPath: path).pathComponents.filter { $0 != "/" }
        guard components.count > 2 else { return path }
        return "…/\(components.suffix(2).joined(separator: "/"))"
    }

    private func aiMetadata(for intel: FileIntelligence) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "brain")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(intel.category)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FileIntelligence.categoryColor(for: intel.category))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(FileIntelligence.categoryColor(for: intel.category).opacity(0.12))
                    .clipShape(Capsule())

                if !intel.suggestedFolder.isEmpty {
                    Text("建议：\(intel.suggestedFolder)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if !intel.suggestedFolder.isEmpty {
                Text("AI 建议路径：\(intel.suggestedFolder)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func filterBadge(_ title: String, _ value: String) -> some View {
        Text("\(title)：\(value)")
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.gray.opacity(0.14))
            .clipShape(Capsule())
    }

    private var trimmedQuery: String {
        appState.queryText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum QuickSearchPreset {
    case pdfLast7DaysDownloads
    case screenshotsLast30Days
    case largeFiles200MB
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
