import Foundation
import Security
#if canImport(PDFKit)
import PDFKit
#endif

// MARK: - Provider

enum AIProvider: String {
    case ollama = "ollama"
    case claude = "claude"

    static var current: AIProvider {
        let raw = UserDefaults.standard.string(forKey: "ai_provider") ?? "ollama"
        return AIProvider(rawValue: raw) ?? .ollama
    }

    static func setCurrent(_ p: AIProvider) {
        UserDefaults.standard.set(p.rawValue, forKey: "ai_provider")
    }

    var displayName: String {
        switch self {
        case .ollama: return "Ollama（本地免费）"
        case .claude: return "Claude API（付费）"
        }
    }
}

// MARK: - Service

actor FileIntelligenceService {
    enum AIError: Equatable, Sendable {
        case invalidAPIKey
        case rateLimited
        case ollamaUnavailable(String)
        case analysisFailed(String)

        var userMessage: String {
            switch self {
            case .invalidAPIKey:
                return "Claude API Key 无效，请重新检查"
            case .rateLimited:
                return "请求过多，稍后自动重试"
            case .ollamaUnavailable:
                return "Ollama 未启动或无法连接，请先运行 ollama serve"
            case let .analysisFailed(message):
                return message
            }
        }

        var diagnosticText: String {
            switch self {
            case .invalidAPIKey:
                return "claude invalid api key"
            case .rateLimited:
                return "claude rate limited"
            case let .ollamaUnavailable(message):
                return message
            case let .analysisFailed(message):
                return message
            }
        }

        var isOllamaConnectionIssue: Bool {
            let lower = diagnosticText.lowercased()
            return lower.contains("connection") || lower.contains("refused") || lower.contains("ollama")
        }

        var shouldStopBatch: Bool {
            switch self {
            case .invalidAPIKey, .ollamaUnavailable:
                return true
            case .rateLimited, .analysisFailed:
                return false
            }
        }
    }

    private enum KeychainKey {
        static let service = "com.tidy2.app"
        static let claudeAPIKey = "claude_api_key"
    }

    // MARK: Ollama (OpenAI-compatible /v1/chat/completions)
    private struct OllamaRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
        let stream: Bool
        let format: String          // "json" — Ollama extension, forces JSON output
        let temperature: Double     // top-level per OpenAI spec
        let max_tokens: Int         // maps to num_predict in Ollama
    }
    private struct OllamaResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        let choices: [Choice]?      // OpenAI-compat endpoint
        // Native endpoint fallback
        let response: String?
    }

    // MARK: Claude (Anthropic)
    private struct ClaudeRequest: Encodable {
        struct Message: Encodable {
            struct Content: Encodable { let type: String; let text: String }
            let role: String
            let content: [Content]
        }
        let model: String
        let max_tokens: Int
        let system: String
        let messages: [Message]
    }
    private struct ClaudeResponse: Decodable {
        struct Content: Decodable { let type: String; let text: String? }
        let content: [Content]
    }

    // Shared output shape
    private struct AIOutput: Decodable {
        let category: String
        let docType: String?
        let extractedName: String?
        let documentDate: String?
        let summary: String
        let suggestedFolder: String
        let keepOrDelete: FileIntelligence.KeepOrDelete
        let reason: String
        let confidence: Double
    }

    private let store: SQLiteStore
    private let session: URLSession
    private(set) var lastError: AIError?

    private let systemPrompt = """
    你是专业文档分析助手，处理法律、移民、财务、医疗、HR 和个人文档。
    输出严格合法 JSON，不加 markdown，不加任何解释文字。

    字段规范：
    - category: 文件类别中文标签（自由文本，≤10字）
    - docType: 严格从以下枚举选一个值：护照|身份证件|驾照|出生证明|结婚证|离婚证|死亡证明|无犯罪证明|移民申请表|签证文件|授权书|法院文件|律师文件|合同|就业证明|录用通知|工资单|简历|推荐信|银行流水|税务记录|发票|收据|保险文件|地址证明|房产文件|医疗记录|处方|学历证明|成绩单|技术文档|截图|安装包|照片|其他
    - extractedName: 文件所属人、公司或项目名称（原文，不翻译）；无法判断填 null
    - documentDate: 文件上注明的日期，格式 yyyy-MM-dd 或 yyyy-MM 或 yyyy；无法判断填 null
    - summary: 一句话描述文件内容，≤80字
    - suggestedFolder: 归档路径建议（相对路径，无首尾斜杠）。
      规则：若 extractedName 非空则用 "Cases/[姓名]/[docType]"；
      否则按内容用通用路径如 "财务/发票/2024"。
    - keepOrDelete: keep|delete|unsure
    - reason: 分类依据，≤60字
    - confidence: 0.0-1.0
    """

    private let analysisBatchSize = 50
    private let maxFilesToAnalyze = 500

    init(store: SQLiteStore) {
        self.store = store
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: cfg)
        Self.purgeLegacyAPIKeyFromDefaults()
    }

    // MARK: - Public API

    func analyzeNewFiles() async { await runBatchAnalysis() }
    func currentError() -> AIError? { lastError }
    func clearLastError() { lastError = nil }

    func runBatchAnalysis() async {
        let provider = AIProvider.current
        // For Claude require a key; for Ollama just try
        if provider == .claude {
            guard !claudeAPIKey.isEmpty else { return }
        }

        do {
            lastError = nil
            let paths = try store.pathsNeedingAnalysis(limit: maxFilesToAnalyze)
            guard !paths.isEmpty else { return }

            for batchStart in stride(from: 0, to: paths.count, by: analysisBatchSize) {
                if Task.isCancelled { break }
                let batchEnd = min(batchStart + analysisBatchSize, paths.count)
                let batch = paths[batchStart..<batchEnd]

                for (offset, path) in batch.enumerated() {
                    if Task.isCancelled { break }
                    guard let file = try store.fileByPath(path) else { continue }
                    let text = extractTextSnippet(filePath: path, ext: file.ext)
                    if let intel = await analyze(
                        filePath: path, pdfText: text,
                        fileName: file.name, ext: file.ext,
                        sizeBytes: file.sizeBytes, modifiedAt: file.modifiedAt
                    ) {
                        try store.upsertFileIntelligence(intel)
                        RuntimeLog.append("[AI] analyzed path=\(path) category=\(intel.category) confidence=\(String(format: "%.2f", intel.confidence))")
                    }

                    if lastError?.shouldStopBatch == true {
                        break
                    }
                    if offset < batch.count - 1 {
                        let delay: UInt64 = provider == .ollama ? 100_000_000 : 300_000_000
                        try? await Task.sleep(nanoseconds: delay)
                    }
                }

                if lastError?.shouldStopBatch == true || Task.isCancelled {
                    break
                }
                if batchEnd < paths.count {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        } catch {
            RuntimeLog.append("[AI] batch_failed error=\(error.localizedDescription)")
        }
    }

    func analyze(filePath: String, pdfText: String?,
                 fileName: String, ext: String,
                 sizeBytes: Int64, modifiedAt: Date) async -> FileIntelligence? {
        let userPrompt = makeUserPrompt(fileName: fileName, ext: ext,
                                        sizeBytes: sizeBytes, modifiedAt: modifiedAt,
                                        extractedText: pdfText)
        switch AIProvider.current {
        case .ollama: return await analyzeWithOllama(filePath: filePath, userPrompt: userPrompt)
        case .claude: return await analyzeWithClaude(filePath: filePath, userPrompt: userPrompt)
        }
    }

    // MARK: - Ollama

    private func analyzeWithOllama(filePath: String, userPrompt: String) async -> FileIntelligence? {
        let model = UserDefaults.standard.string(forKey: "ollama_model") ?? "qwen2.5:3b"
        // Use OpenAI-compat endpoint so we get choices[] back
        guard let endpoint = URL(string: "http://localhost:11434/v1/chat/completions") else { return nil }

        let body = OllamaRequest(
            model: model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user",   content: userPrompt)
            ],
            stream: false,
            format: "json",
            temperature: 0.1,
            max_tokens: 300
        )

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            req.httpBody = try JSONEncoder().encode(body)
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return nil }

            if http.statusCode == 404 || http.statusCode == 0 {
                RuntimeLog.append("[AI] ollama not running or model not found")
                lastError = .ollamaUnavailable("ollama connection refused or model not found")
                return nil
            }
            guard (200..<300).contains(http.statusCode) else {
                RuntimeLog.append("[AI] ollama_failed status=\(http.statusCode) path=\(filePath)")
                lastError = .ollamaUnavailable("ollama service returned HTTP \(http.statusCode)")
                return nil
            }

            let decoded = try JSONDecoder().decode(OllamaResponse.self, from: data)
            let text = decoded.choices?.first?.message.content
                    ?? decoded.response
                    ?? ""
            lastError = nil
            return parseOutput(text: text, filePath: filePath)
        } catch let urlError as URLError where urlError.code == .cannotConnectToHost
                                             || urlError.code == .networkConnectionLost
                                             || urlError.code == .cannotFindHost
                                             || urlError.code == .notConnectedToInternet
                                             || urlError.code == .timedOut {
            RuntimeLog.append("[AI] ollama not running — start with: ollama serve")
            lastError = .ollamaUnavailable("ollama connection refused")
            return nil
        } catch {
            RuntimeLog.append("[AI] ollama_failed path=\(filePath) error=\(error.localizedDescription)")
            lastError = .analysisFailed("AI 分析失败：\(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Claude

    private var claudeAPIKey: String {
        Self.readAPIKeyFromKeychain()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func analyzeWithClaude(filePath: String, userPrompt: String) async -> FileIntelligence? {
        let key = claudeAPIKey
        guard !key.isEmpty else { return nil }

        let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
        let body = ClaudeRequest(
            model: "claude-haiku-4-5-20251001",
            max_tokens: 200,
            system: systemPrompt,
            messages: [.init(role: "user", content: [.init(type: "text", text: userPrompt)])]
        )

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json",  forHTTPHeaderField: "Content-Type")
        req.setValue(key,                 forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",        forHTTPHeaderField: "anthropic-version")

        do {
            req.httpBody = try JSONEncoder().encode(body)
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return nil }

            switch http.statusCode {
            case 200..<300: lastError = nil
            case 401:
                RuntimeLog.append("[AI] claude auth_failed: invalid API key")
                lastError = .invalidAPIKey
                return nil
            case 429:
                let retry = Int(http.value(forHTTPHeaderField: "retry-after") ?? "60") ?? 60
                RuntimeLog.append("[AI] claude rate_limited, waiting \(retry)s")
                lastError = .rateLimited
                try? await Task.sleep(nanoseconds: UInt64(retry) * 1_000_000_000)
                return nil
            default:
                RuntimeLog.append("[AI] claude_failed status=\(http.statusCode) path=\(filePath)")
                lastError = .analysisFailed("Claude 分析失败：HTTP \(http.statusCode)")
                return nil
            }

            let decoded = try JSONDecoder().decode(ClaudeResponse.self, from: data)
            guard let text = decoded.content.first(where: { $0.type == "text" })?.text else { return nil }
            return parseOutput(text: text, filePath: filePath)
        } catch {
            RuntimeLog.append("[AI] claude_failed path=\(filePath) error=\(error.localizedDescription)")
            lastError = .analysisFailed("Claude 分析失败：\(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Shared parsing

    private func parseOutput(text: String, filePath: String) -> FileIntelligence? {
        let json = extractJSON(from: text)
        guard !json.isEmpty else {
            RuntimeLog.append("[AI] parse_failed path=\(filePath) text=\(text.prefix(120))")
            return nil
        }

        if let output = try? JSONDecoder().decode(AIOutput.self, from: Data(json.utf8)) {
            return makeFileIntelligence(filePath: filePath, output: output)
        }

        guard let fallback = relaxedOutput(from: json) else {
            RuntimeLog.append("[AI] parse_failed path=\(filePath) text=\(text.prefix(120))")
            return nil
        }
        RuntimeLog.append("[AI] parse_relaxed_success path=\(filePath)")
        return makeFileIntelligence(filePath: filePath, output: fallback)
    }

    private func makeFileIntelligence(filePath: String, output: AIOutput) -> FileIntelligence {
        let extractedName = output.extractedName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let documentDate = output.documentDate?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let docType = DocType(
            rawValue: output.docType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? DocType.other.rawValue
        ) ?? .other

        return FileIntelligence(
            filePath: filePath,
            category: output.category.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: String(output.summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)),
            suggestedFolder: output.suggestedFolder.trimmingCharacters(in: .whitespacesAndNewlines),
            keepOrDelete: output.keepOrDelete,
            reason: String(output.reason.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)),
            confidence: min(max(output.confidence, 0), 1),
            analyzedAt: Date(),
            extractedName: extractedName,
            documentDate: documentDate,
            docType: docType
        )
    }

    private func relaxedOutput(from json: String) -> AIOutput? {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        let category = (raw["category"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "其他"
        let docType = (raw["docType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let extractedName = (raw["extractedName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let documentDate = (raw["documentDate"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = (raw["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let suggestedFolder = (raw["suggestedFolder"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reason = (raw["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let keepRaw = ((raw["keepOrDelete"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let keepOrDelete = FileIntelligence.KeepOrDelete(rawValue: keepRaw) ?? .unsure

        let confidence: Double
        if let number = raw["confidence"] as? NSNumber {
            confidence = number.doubleValue
        } else if let string = raw["confidence"] as? String, let value = Double(string) {
            confidence = value
        } else {
            confidence = 0.5
        }

        return AIOutput(
            category: category,
            docType: docType,
            extractedName: extractedName?.nilIfEmpty,
            documentDate: documentDate?.nilIfEmpty,
            summary: summary,
            suggestedFolder: suggestedFolder,
            keepOrDelete: keepOrDelete,
            reason: reason,
            confidence: confidence
        )
    }

    // MARK: - Prompt building

    private func makeUserPrompt(fileName: String, ext: String,
                                sizeBytes: Int64, modifiedAt: Date,
                                extractedText: String?) -> String {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        var prompt = "fileName: \(fileName.replacingOccurrences(of: "\n", with: " "))\next: \(ext)\nsizeBytes: \(sizeBytes)\nmodifiedAt: \(fmt.string(from: modifiedAt))"
        if let t = extractedText?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            let normalized = t.replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\u{0}", with: " ")
            prompt += "\ncontent:\n" + String(normalized.prefix(max(0, 1200 - prompt.count)))
        }
        return String(prompt.prefix(1200))
    }

    private func extractJSON(from text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("{"), t.hasSuffix("}") { return t }
        if let s = t.firstIndex(of: "{"), let e = t.lastIndex(of: "}") { return String(t[s...e]) }
        return t
    }

    // MARK: - Text extraction

    private func extractTextSnippet(filePath: String, ext: String) -> String? {
        switch ext.lowercased() {
        case "pdf": return extractPDFText(filePath: filePath)
        case "txt", "md": return extractPlainText(filePath: filePath)
        default: return nil
        }
    }

    private func extractPlainText(filePath: String) -> String? {
        guard let c = try? String(contentsOfFile: filePath, encoding: .utf8) else { return nil }
        let n = c.replacingOccurrences(of: "\r", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? nil : String(n.prefix(800))
    }

    private func extractPDFText(filePath: String) -> String? {
#if canImport(PDFKit)
        guard let doc = PDFDocument(url: URL(fileURLWithPath: filePath)) else { return nil }
        var result = ""; var chars = 0
        for i in 0..<min(doc.pageCount, 4) {
            guard let page = doc.page(at: i), let text = page.string else { continue }
            let norm = text.replacingOccurrences(of: "\u{0}", with: " ")
                          .replacingOccurrences(of: "\r", with: "\n")
                          .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !norm.isEmpty else { continue }
            let remain = 800 - chars; guard remain > 0 else { break }
            let slice = String(norm.prefix(remain))
            result += (result.isEmpty ? "" : "\n") + slice
            chars += slice.count
        }
        return result.isEmpty ? nil : result
#else
        return nil
#endif
    }

    // MARK: - Keychain

    static func readAPIKeyFromKeychain() -> String? {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                   kSecAttrService: KeychainKey.service,
                                   kSecAttrAccount: KeychainKey.claudeAPIKey,
                                   kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var r: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess,
              let data = r as? Data,
              let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    static func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let del: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                     kSecAttrService: KeychainKey.service,
                                     kSecAttrAccount: KeychainKey.claudeAPIKey]
        SecItemDelete(del as CFDictionary)
        UserDefaults.standard.removeObject(forKey: KeychainKey.claudeAPIKey)
        guard !trimmed.isEmpty else { return }
        let add: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                     kSecAttrService: KeychainKey.service,
                                     kSecAttrAccount: KeychainKey.claudeAPIKey,
                                     kSecValueData: Data(trimmed.utf8)]
        SecItemAdd(add as CFDictionary, nil)
    }

    static func hasStoredAPIKey() -> Bool { readAPIKeyFromKeychain() != nil }

    private static func purgeLegacyAPIKeyFromDefaults() {
        UserDefaults.standard.removeObject(forKey: KeychainKey.claudeAPIKey)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
