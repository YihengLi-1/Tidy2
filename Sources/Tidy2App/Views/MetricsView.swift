import SwiftUI

struct MetricsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TidySpacing.xxl) {
                // ── Summary cards ─────────────────────────────────────
                summaryGrid

                // ── Weekly breakdown ──────────────────────────────────
                if !appState.metricsRows.isEmpty {
                    VStack(alignment: .leading, spacing: TidySpacing.lg) {
                        Text("按周统计（最近 4 周）")
                            .font(.headline)
                            .padding(.horizontal, 2)

                        ForEach(appState.metricsRows.prefix(4)) { row in
                            weeklyRow(row)
                        }
                    }
                } else {
                    EmptyStateView(
                        icon: "chart.bar",
                        title: "暂无统计数据",
                        subtitle: "整理一次文件后，这里会显示每周使用情况"
                    )
                }
            }
            .padding(24)
        }
        .navigationTitle("使用情况")
        .task {
            // metricsRows are loaded as part of refreshAll; trigger if empty
            if appState.metricsRows.isEmpty && appState.changeLogEntries.isEmpty {
                await appState.loadChangeLog()
            }
        }
    }

    // MARK: - Summary grid

    private var summaryGrid: some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: cols, spacing: TidySpacing.lg) {
            statCard(
                icon: "arrow.right.doc.on.clipboard",
                color: .blue,
                value: "\(totalOrganizedFiles)",
                label: "已整理文件"
            )
            statCard(
                icon: "externaldrive.badge.minus",
                color: .orange,
                value: SizeFormatter.string(from: totalFreedBytes),
                label: "已释放空间"
            )
            statCard(
                icon: "brain",
                color: .purple,
                value: "\(appState.aiAnalyzedFilesCount)",
                label: "AI 已分析"
            )
            statCard(
                icon: "shield",
                color: .green,
                value: "\(appState.digest.autoIsolatedCount)",
                label: "隔离区文件"
            )
        }
    }

    private func statCard(icon: String, color: Color, value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: TidySpacing.sm) {
            HStack(spacing: TidySpacing.xs) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(TidySpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(TidyOpacity.light))
        .clipShape(RoundedRectangle(cornerRadius: TidyRadius.lg))
    }

    // MARK: - Weekly row

    private func weeklyRow(_ row: WeeklyMetricsRow) -> some View {
        VStack(alignment: .leading, spacing: TidySpacing.sm) {
            HStack {
                Text(row.weekKey)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(row.confirmedFilesTotal) 个文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: TidySpacing.xl) {
                metricPill("确认 \(row.weeklyConfirmCount) 次", .blue)
                metricPill(SizeFormatter.string(from: row.autopilotIsolatedBytes) + " 自动隔离", .green)
                if row.undoRate > 0 {
                    metricPill("撤销率 \(Int(row.undoRate * 100))%", .orange)
                }
            }
        }
        .padding(TidySpacing.lg)
        .background(Color.gray.opacity(TidyOpacity.ultraLight))
        .clipShape(RoundedRectangle(cornerRadius: TidyRadius.md))
    }

    private func metricPill(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, TidySpacing.sm)
            .padding(.vertical, 3)
            .background(color.opacity(TidyOpacity.strong))
            .clipShape(Capsule())
    }

    // MARK: - Computed totals from change log

    private var totalOrganizedFiles: Int {
        appState.changeLogEntries.reduce(0) { sum, entry in
            // Extract file count from titles like "移动了 N 个文件" or "整理完成"
            sum + extractFileCount(from: entry.title)
        }
    }

    private var totalFreedBytes: Int64 {
        // Use weekly metrics if available
        appState.metricsRows.reduce(Int64(0)) { $0 + $1.autopilotIsolatedBytes }
    }

    private func extractFileCount(from title: String) -> Int {
        // Try to extract number from strings like "移动了 5 个文件" or "已清理 3 个"
        let pattern = #"(\d+)\s*个"#
        if let range = title.range(of: pattern, options: .regularExpression),
           let numRange = title.range(of: #"\d+"#, options: .regularExpression, range: range) {
            return Int(title[numRange]) ?? 0
        }
        return 0
    }
}
