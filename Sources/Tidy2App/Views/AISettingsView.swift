import SwiftUI

struct AISettingsView: View {
    private enum OllamaStatus {
        case unknown
        case running
        case notRunning
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @State private var selectedProvider: AIProvider = AIProvider.current
    @State private var apiKey = ""
    @State private var ollamaModel = UserDefaults.standard.string(forKey: "ollama_model") ?? "qwen2.5:3b"
    @State private var isRunning = false
    @State private var ollamaStatus: OllamaStatus = .unknown

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Title row
            HStack {
                Text("AI 文件分析")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(.bordered)
            }

            // Provider picker
            VStack(alignment: .leading, spacing: 6) {
                Text("AI 引擎")
                    .font(.subheadline.weight(.semibold))
                Picker("", selection: $selectedProvider) {
                    ForEach([AIProvider.ollama, .claude], id: \.self) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: selectedProvider) { newValue in
                    AIProvider.setCurrent(newValue)
                    if newValue == .ollama {
                        Task { await refreshOllamaStatus() }
                    } else {
                        ollamaStatus = .unknown
                    }
                }
            }

            Divider()

            // Provider-specific settings
            if selectedProvider == .ollama {
                ollamaSection
            } else {
                claudeSection
            }

            // Error banner
            if let error = appState.aiAnalysisLastError {
                errorBanner(error)
            }

            Divider()

            // Run analysis
            HStack(spacing: 10) {
                Button {
                    isRunning = true
                    Task {
                        await appState.triggerAIAnalysis()
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        await MainActor.run { isRunning = false }
                    }
                } label: {
                    if isRunning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("分析中…")
                        }
                    } else {
                        Text("立即分析文件")
                    }
                }
                .buttonStyle(.borderedProminent)

                Text("已分析 \(appState.aiAnalyzedFilesCount) 个文件")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(24)
        .frame(minWidth: 500, minHeight: 300)
        .onAppear {
            selectedProvider = AIProvider.current
            apiKey = FileIntelligenceService.readAPIKeyFromKeychain() ?? ""
            ollamaModel = UserDefaults.standard.string(forKey: "ollama_model") ?? "qwen2.5:3b"
            appState.clearAIAnalysisError()
            Task { await appState.refreshAIAnalysisState() }
        }
        .task {
            guard selectedProvider == .ollama else { return }
            await refreshOllamaStatus()
        }
    }

    // MARK: - Ollama Section

    private var ollamaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ollama 本地运行，完全免费，无需 API Key。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("模型名称")
                    .font(.caption.weight(.semibold))
                TextField("qwen2.5:3b", text: $ollamaModel)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: ollamaModel) { newValue in
                        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            UserDefaults.standard.set(trimmed, forKey: "ollama_model")
                        }
                    }
                Text("推荐：qwen2.5:3b（快，约 2 GB）或 qwen2.5:7b（准，约 5 GB）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("安装说明")
                    .font(.caption.weight(.semibold))
                ollamaStatusLabel
                VStack(alignment: .leading, spacing: 3) {
                    commandLine("brew install ollama")
                    commandLine("ollama pull qwen2.5:3b")
                    commandLine("ollama serve")
                }
                Text("运行 ollama serve 之后，点【立即分析文件】即可。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.gray.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Link("Ollama 官网 → ollama.com",
                 destination: URL(string: "https://ollama.com")!)
                .font(.caption)
        }
    }

    // MARK: - Claude Section

    private var claudeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude API（付费）— 精度更高，需要 Anthropic API Key。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("API Key")
                    .font(.caption.weight(.semibold))
                SecureField("sk-ant-...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: apiKey) { newValue in
                        FileIntelligenceService.saveAPIKey(newValue)
                        appState.clearAIAnalysisError()
                    }
            }

            Link("获取 API Key → console.anthropic.com",
                 destination: URL(string: "https://console.anthropic.com")!)
                .font(.caption)
        }
    }

    // MARK: - Helpers

    private func commandLine(_ cmd: String) -> some View {
        Text(cmd)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private var ollamaStatusLabel: some View {
        switch ollamaStatus {
        case .unknown:
            Text("正在检测 Ollama 状态…")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        case .running:
            Text("✓ Ollama 已在运行")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        case .notRunning:
            Text("⚠️ Ollama 未启动")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        }
    }

    @MainActor
    private func refreshOllamaStatus() async {
        guard let url = URL(string: "http://localhost:11434") else {
            ollamaStatus = .notRunning
            return
        }

        ollamaStatus = .unknown

        await withTaskGroup(of: OllamaStatus.self) { group in
            group.addTask {
                if let _ = try? await URLSession.shared.data(from: url) {
                    return .running
                }
                return .notRunning
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return .notRunning
            }

            if let status = await group.next() {
                group.cancelAll()
                ollamaStatus = status
            }
        }
    }

    private func errorBanner(_ error: FileIntelligenceService.AIError) -> some View {
        let (message, color, foreground, opacity): (String, Color, Color, Double)
        switch error {
        case .invalidAPIKey:
            (message, color, foreground, opacity) = (error.userMessage, .red, .white, 0.85)
        case .rateLimited:
            (message, color, foreground, opacity) = (error.userMessage, .yellow, .primary, 0.25)
        case .ollamaUnavailable:
            (message, color, foreground, opacity) = (error.userMessage, .orange, .white, 0.85)
        case .analysisFailed:
            (message, color, foreground, opacity) = (error.userMessage, .red, .white, 0.85)
        }

        return Text(message)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(color.opacity(opacity))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
