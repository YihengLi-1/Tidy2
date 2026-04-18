import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @State private var apiKey: String = FileIntelligenceService.readAPIKeyFromKeychain() ?? ""
    @State private var isCompleting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("欢迎使用 Tidy 2.0")
                        .font(.title2.weight(.semibold))
                    Text("所有操作均可撤销。隔离文件 30 天内可恢复。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Step 1 — Downloads (required)
                stepCard(
                    number: "1",
                    title: "授权 Downloads 文件夹",
                    subtitle: "必须。用于安全扫描和隔离重复文件。",
                    isRequired: true
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

                // Step 2 — Archive Root (optional but recommended)
                stepCard(
                    number: "2",
                    title: "选择归档根目录（推荐）",
                    subtitle: "告诉 Tidy 把整理好的文件放到哪里。之后也可以在 Bundle 详情里设置。",
                    isRequired: false
                ) {
                    Button("选择归档根目录") {
                        Task { await appState.reauthorizeArchiveRoot() }
                    }
                    .buttonStyle(.bordered)
                    if !appState.archiveRootPath.isEmpty {
                        statusRow(icon: "folder.fill", color: .accentColor,
                                  text: appState.archiveRootPath)
                    }
                }

                // Step 3 — Documents (optional)
                stepCard(
                    number: "3",
                    title: "扫描 Documents 文件夹（可选）",
                    subtitle: "启用后可检测散落在多个位置的相关文件并智能归类。",
                    isRequired: false
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

                // Step 4 — Desktop (optional)
                stepCard(
                    number: "4",
                    title: "扫描桌面（可选）",
                    subtitle: "扫描桌面上的文件，一并纳入整理建议。",
                    isRequired: false
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

                // Step 5 — Claude API Key (optional but unlocks AI features)
                stepCard(
                    number: "5",
                    title: "设置 Claude API Key（可选）",
                    subtitle: "用于 AI 智能分类文件内容、生成整理建议。没有 key 仍可使用基础功能。",
                    isRequired: false
                ) {
                    SecureField("sk-ant-...", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: apiKey) { newValue in
                            FileIntelligenceService.saveAPIKey(newValue)
                        }
                    if !apiKey.isEmpty {
                        statusRow(icon: "checkmark.circle.fill", color: .green,
                                  text: "API Key 已设置")
                    } else {
                        Link("获取 API Key → console.anthropic.com",
                             destination: URL(string: "https://console.anthropic.com")!)
                            .font(.caption)
                    }
                }

                // Footer
                HStack(alignment: .center) {
                    Spacer()
                    Button {
                        isCompleting = true
                        Task {
                            await appState.completeOnboarding()
                            if appState.showOnboarding {
                                isCompleting = false
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if isCompleting {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text("开始使用")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.needsDownloadsAuthorization || isCompleting)
                }

                if !appState.statusMessage.isEmpty {
                    Text(appState.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .frame(width: 580)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func stepCard<Content: View>(
        number: String,
        title: String,
        subtitle: String,
        isRequired: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("第 \(number) 步")
                    .font(.headline)
                if isRequired {
                    Text("必须")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor)
                        .clipShape(Capsule())
                }
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func statusRow(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 6) {
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
