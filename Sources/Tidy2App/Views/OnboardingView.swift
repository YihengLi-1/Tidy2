import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @State private var geminiKey: String = FileIntelligenceService.readGeminiAPIKeyFromKeychain() ?? ""
    @State private var claudeKey: String = FileIntelligenceService.readAPIKeyFromKeychain() ?? ""
    @State private var isCompleting = false

    // Track which steps are expanded for progressive disclosure
    @State private var expandedStep: Int? = 1

    private var hasAnyKey: Bool { !geminiKey.isEmpty || !claudeKey.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ────────────────────────────────────────────────
            header

            Divider()

            // ── Steps ─────────────────────────────────────────────────
            ScrollView {
                VStack(alignment: .leading, spacing: TidySpacing.md) {
                    stepCard(
                        step: 1,
                        title: "授权 Downloads 文件夹",
                        subtitle: "必须。用于安全扫描和隔离重复文件。",
                        isRequired: true,
                        isComplete: !appState.needsDownloadsAuthorization
                    ) {
                        if appState.needsDownloadsAuthorization {
                            Button("授权 Downloads") {
                                Task { await appState.requestDownloadsAuthorization() }
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            statusRow(icon: "checkmark.circle.fill", color: .green,
                                      text: appState.downloadsFolderPath)
                        }
                    }

                    stepCard(
                        step: 2,
                        title: "整理好的文件放哪里？",
                        subtitle: "选择一个文件夹，作为整理后文件的归档位置。",
                        isRequired: false,
                        isComplete: !appState.archiveRootPath.isEmpty
                    ) {
                        if appState.archiveRootPath.isEmpty {
                            VStack(alignment: .leading, spacing: TidySpacing.sm) {
                                Button {
                                    Task { await appState.setupDefaultArchiveRoot() }
                                } label: {
                                    HStack(spacing: TidySpacing.md) {
                                        Image(systemName: "folder.badge.plus")
                                            .font(.title3)
                                            .foregroundColor(.accentColor)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("使用推荐位置")
                                                .font(.subheadline.weight(.medium))
                                            Text("~/Documents/Tidy Archive")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text("推荐")
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, TidySpacing.sm)
                                            .padding(.vertical, 3)
                                            .background(Color.accentColor)
                                            .clipShape(Capsule())
                                    }
                                    .padding(TidySpacing.lg)
                                    .background(Color.blue.opacity(TidyOpacity.light))
                                    .clipShape(RoundedRectangle(cornerRadius: TidyRadius.md))
                                }
                                .buttonStyle(.plain)

                                Button("自定义位置…") {
                                    Task { await appState.reauthorizeArchiveRoot() }
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        } else {
                            statusRow(icon: "folder.fill", color: .accentColor,
                                      text: appState.archiveRootPath)
                        }
                    }

                    stepCard(
                        step: 3,
                        title: "扫描 Documents 文件夹（可选）",
                        subtitle: "启用后可检测散落在多个位置的相关文件并智能归类。",
                        isRequired: false,
                        isComplete: !appState.documentsFolderPath.isEmpty
                    ) {
                        if appState.documentsFolderPath.isEmpty {
                            Button("启用 Documents 扫描") {
                                Task { await appState.requestDocumentsAuthorization() }
                            }
                            .buttonStyle(.bordered)
                        } else {
                            statusRow(icon: "checkmark.circle.fill", color: .green,
                                      text: appState.documentsFolderPath)
                        }
                    }

                    stepCard(
                        step: 4,
                        title: "扫描桌面（可选）",
                        subtitle: "扫描桌面上的文件，一并纳入整理建议。",
                        isRequired: false,
                        isComplete: !appState.desktopFolderPath.isEmpty
                    ) {
                        if appState.desktopFolderPath.isEmpty {
                            Button("启用桌面扫描") {
                                Task { await appState.requestDesktopAuthorization() }
                            }
                            .buttonStyle(.bordered)
                        } else {
                            statusRow(icon: "checkmark.circle.fill", color: .green,
                                      text: appState.desktopFolderPath)
                        }
                    }

                    stepCard(
                        step: 5,
                        title: "开启 AI 分析（免费）",
                        subtitle: "Tidy 用 AI 读懂文件内容，生成精准整理建议。Gemini Flash 完全免费，只需 Google 账号。",
                        isRequired: false,
                        isComplete: hasAnyKey
                    ) {
                        // Gemini (free, default)
                        VStack(alignment: .leading, spacing: TidySpacing.sm) {
                            HStack(spacing: TidySpacing.sm) {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(.blue)
                                Text("Gemini Flash（推荐 · 免费）")
                                    .font(.subheadline.weight(.medium))
                                Text("免费")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(Color.green)
                                    .clipShape(Capsule())
                            }

                            SecureField("AIza...", text: $geminiKey)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: geminiKey) { newValue in
                                    FileIntelligenceService.saveGeminiAPIKey(newValue)
                                    if !newValue.isEmpty { AIProvider.setCurrent(.gemini) }
                                }

                            if geminiKey.isEmpty {
                                Link("免费获取 Key → aistudio.google.com/apikey",
                                     destination: URL(string: "https://aistudio.google.com/apikey")!)
                                    .font(.caption)
                            } else {
                                statusRow(icon: "checkmark.circle.fill", color: .green,
                                          text: "Gemini API Key 已设置")
                            }

                            Divider()

                            // Claude (paid, optional)
                            DisclosureGroup("也有 Claude API Key？") {
                                VStack(alignment: .leading, spacing: TidySpacing.xs) {
                                    SecureField("sk-ant-...", text: $claudeKey)
                                        .textFieldStyle(.roundedBorder)
                                        .onChange(of: claudeKey) { newValue in
                                            FileIntelligenceService.saveAPIKey(newValue)
                                            if !newValue.isEmpty { AIProvider.setCurrent(.claude) }
                                        }
                                    if !claudeKey.isEmpty {
                                        statusRow(icon: "checkmark.circle.fill", color: .green,
                                                  text: "Claude API Key 已设置")
                                    }
                                }
                                .padding(.top, TidySpacing.xs)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }

                    // ── Footer ─────────────────────────────────────────
                    VStack(spacing: TidySpacing.sm) {
                        Button {
                            isCompleting = true
                            Task {
                                await appState.completeOnboarding()
                                if appState.showOnboarding {
                                    isCompleting = false
                                }
                            }
                        } label: {
                            HStack(spacing: TidySpacing.sm) {
                                if isCompleting {
                                    ProgressView().controlSize(.small)
                                }
                                Text("开始使用")
                                    .frame(maxWidth: .infinity)
                            }
                            .padding(.vertical, TidySpacing.xs)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(appState.needsDownloadsAuthorization || isCompleting)

                        if !appState.statusMessage.isEmpty {
                            Text(appState.statusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text("所有操作均可撤销，隔离文件 30 天内可恢复")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, TidySpacing.sm)
                }
                .padding(TidySpacing.xxl)
            }
        }
        .frame(width: 520)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: TidySpacing.lg) {
            // App icon placeholder
            ZStack {
                RoundedRectangle(cornerRadius: TidyRadius.lg)
                    .fill(Color.accentColor.gradient)
                    .frame(width: 48, height: 48)
                Image(systemName: "folder.badge.gearshape")
                    .font(.title2)
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("欢迎使用 Tidy 2.0")
                    .font(.title2.weight(.semibold))
                Text("本地优先 · AI 驱动 · 数据不离本机")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Progress indicator
            progressRing
        }
        .padding(.horizontal, TidySpacing.xxl)
        .padding(.vertical, TidySpacing.xl)
    }

    private var progressRing: some View {
        let completed = completedStepCount
        let total = 5
        return ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 4)
            Circle()
                .trim(from: 0, to: CGFloat(completed) / CGFloat(total))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: completed)
            VStack(spacing: 0) {
                Text("\(completed)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Text("/\(total)")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 52, height: 52)
    }

    private var completedStepCount: Int {
        var count = 0
        if !appState.needsDownloadsAuthorization { count += 1 }
        if !appState.archiveRootPath.isEmpty { count += 1 }
        if !appState.documentsFolderPath.isEmpty { count += 1 }
        if !appState.desktopFolderPath.isEmpty { count += 1 }
        if hasAnyKey { count += 1 }
        return count
    }

    // MARK: - Step card

    @ViewBuilder
    private func stepCard<Content: View>(
        step: Int,
        title: String,
        subtitle: String,
        isRequired: Bool,
        isComplete: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: TidySpacing.md) {
            // Step header row
            HStack(spacing: TidySpacing.sm) {
                stepCircle(number: step, isComplete: isComplete)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: TidySpacing.xs) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                        if isRequired {
                            Text("必须")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.accentColor)
                                .clipShape(Capsule())
                        }
                        if isComplete && !isRequired {
                            Text("已完成")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                    }
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }

            // Content
            content()
                .padding(.leading, 36) // align with text after step circle
        }
        .padding(TidySpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isComplete
                ? Color.green.opacity(TidyOpacity.ultraLight)
                : Color.gray.opacity(TidyOpacity.light)
        )
        .clipShape(RoundedRectangle(cornerRadius: TidyRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: TidyRadius.lg)
                .strokeBorder(
                    isComplete ? Color.green.opacity(0.3) : Color.clear,
                    lineWidth: 1
                )
        )
        .animation(.easeInOut(duration: 0.25), value: isComplete)
    }

    private func stepCircle(number: Int, isComplete: Bool) -> some View {
        ZStack {
            Circle()
                .fill(isComplete ? Color.green : Color.accentColor.opacity(0.15))
                .frame(width: 28, height: 28)
            if isComplete {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            } else {
                Text("\(number)")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.accentColor)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isComplete)
    }

    // MARK: - Status row

    @ViewBuilder
    private func statusRow(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: TidySpacing.xs) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
