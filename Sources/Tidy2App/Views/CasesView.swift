import SwiftUI

struct CasesView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if appState.aiAnalyzedFilesCount == 0 {
                    EmptyStateView(
                        icon: "person.2.fill",
                        title: "先运行 AI 分析",
                        subtitle: "AI 识别文件所属人后，这里会按人名自动归类，并提示缺少哪些材料",
                        action: { Task { await appState.runAIAnalysisNow() } },
                        actionLabel: "开始 AI 分析"
                    )
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else if appState.detectedCases.isEmpty {
                    EmptyStateView(
                        icon: "person.2.fill",
                        title: "暂未识别到案例",
                        subtitle: "AI 分析到文件包含人名后会自动出现在这里（需要 2 个以上相关文件）"
                    )
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    Text("共识别 \(appState.detectedCases.count) 个案例")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ForEach(appState.detectedCases) { cas in
                        CaseCard(cas: cas)
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("案例归档")
        .task {
            await appState.loadDetectedCases()
        }
    }
}

private struct CaseCard: View {
    @EnvironmentObject private var appState: AppState
    let cas: DetectedCase
    @State private var isOrganizing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(cas.name)
                        .font(.headline)
                    Text("\(cas.files.count) 个已识别文件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(isOrganizing ? "归档中…" : "一键归档") {
                    isOrganizing = true
                    Task {
                        await appState.organizeCaseFiles(cas)
                        isOrganizing = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isOrganizing || appState.archiveRootPath.isEmpty)
            }

            Divider()

            if !cas.presentTypes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("已有材料", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                    chipRow(Array(cas.presentTypes).sorted { $0.rawValue < $1.rawValue }, color: .green)
                }
            }

            if !cas.missingImmigrationDocs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("常见移民材料中缺少", systemImage: "exclamationmark.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    chipRow(cas.missingImmigrationDocs, color: .orange)
                }
            }

            DisclosureGroup("查看文件列表 (\(cas.files.count))") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(cas.files, id: \.filePath) { intel in
                        HStack(spacing: 6) {
                            Image(systemName: intel.docType.icon)
                                .frame(width: 16)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(fileURLWithPath: intel.filePath).lastPathComponent)
                                    .font(.caption)
                                    .lineLimit(1)
                                if let date = intel.documentDate, !date.isEmpty {
                                    Text(date)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            Text(intel.docType.rawValue)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption)
        }
        .padding(16)
        .background(Color.gray.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func chipRow(_ types: [DocType], color: Color) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(types, id: \.self) { type in
                    Label(type.rawValue, systemImage: type.icon)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(color.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
        }
    }
}
