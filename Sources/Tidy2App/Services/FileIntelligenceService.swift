import AppKit
import Foundation
import ImageIO
import Security
#if canImport(PDFKit)
import PDFKit
#endif

// MARK: - Provider

enum AIProvider: String {
    case gemini = "gemini"
    case ollama = "ollama"
    case claude = "claude"

    static var current: AIProvider {
        let raw = UserDefaults.standard.string(forKey: "ai_provider") ?? "gemini"
        return AIProvider(rawValue: raw) ?? .gemini
    }

    static func setCurrent(_ p: AIProvider) {
        UserDefaults.standard.set(p.rawValue, forKey: "ai_provider")
    }

    var displayName: String {
        switch self {
        case .gemini: return "Gemini Flash（免费）"
        case .ollama: return "Ollama（本地）"
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
        static let geminiAPIKey = "gemini_api_key"
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
            struct Content: Encodable {
                struct Source: Encodable {
                    let type: String
                    let mediaType: String
                    let data: String

                    enum CodingKeys: String, CodingKey {
                        case type
                        case mediaType = "media_type"
                        case data
                    }
                }

                let type: String
                let text: String?
                let source: Source?

                static func text(_ value: String) -> Content {
                    Content(type: "text", text: value, source: nil)
                }

                static func image(data: String, mediaType: String) -> Content {
                    Content(
                        type: "image",
                        text: nil,
                        source: Source(type: "base64", mediaType: mediaType, data: data)
                    )
                }
            }
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
        let projectGroup: String?
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
    你是专业文件整理助手。分析文件并输出严格合法 JSON，不加 markdown，不加任何解释文字。

    字段规范：
    - category: 文件类别中文标签（自由文本，≤10字）
    - docType: 严格从以下枚举选一个值：护照|身份证件|驾照|出生证明|结婚证|离婚证|死亡证明|无犯罪证明|移民申请表|签证文件|授权书|法院文件|律师文件|合同|就业证明|录用通知|工资单|简历|推荐信|银行流水|税务记录|发票|收据|保险文件|地址证明|房产文件|医疗记录|处方|学历证明|成绩单|技术文档|截图|安装包|照片|其他
    - projectGroup: 这个文件所属的项目或主题名称（≤20字，中英文均可）。例如：iOS开发、税务2024、求职材料、旅行规划。无明确项目关联填 null
    - extractedName: 文件所属人、公司或项目名称（原文，不翻译）；无法判断填 null
    - documentDate: 文件上注明的日期，格式 yyyy-MM-dd 或 yyyy-MM 或 yyyy；无法判断填 null
    - summary: 一句话描述文件内容，≤80字
    - suggestedFolder: 归档路径建议（相对路径，无首尾斜杠）。
      规则（按优先级）：
      1. 若 projectGroup 非空：用 "[projectGroup]/[docType类别]" 格式，如 "iOS开发/技术文档"
      2. 若 extractedName 非空且是人名/公司名：用 "案例/[名称]/[docType]"
      3. 截图 → "截图/[yyyy-MM]"；安装包 → "安装包/[yyyy]"
      4. 财务类（发票/收据/银行流水/税务记录）→ "财务/[docType]/[yyyy]"
      5. 其他 → "[category]/[yyyy-MM]"
    - keepOrDelete: keep|delete|unsure
      - delete: 安装包（已不需要）、明显重复、临时文件
      - keep: 重要证件、合同、财务记录、技术文档
      - unsure: 截图、普通下载
    - reason: 分类依据，≤60字
    - confidence: 0.0-1.0
    """

    private let legalSystemPrompt = """
    你是移民律师的文件分析助手。专门分析 EB-1A/O-1 签证申请材料。

    分析文件并输出严格合法 JSON，不加 markdown，不加任何解释文字：
    {
      "category": "证据类别",
      "docType": "pdf",
      "projectGroup": "2019",
      "extractedName": "申请人或机构名称",
      "documentDate": "2019-05-20",
      "summary": "一句话描述：什么组织/机构 授予/报道/认可了什么成就（≤100字）",
      "suggestedFolder": "奖项",
      "keepOrDelete": "keep",
      "reason": "证据类型和相关性说明",
      "confidence": 0.9
    }

    suggestedFolder 必须严格从以下10个类别选一个：
    奖项|媒体报道|专家推荐信|学术论文|证书|会员资格|评审经历|原创贡献|薪资证明|关键职位|推荐信|其他

    类别说明：
    - 奖项：国家级/国际级奖励、prize、honor，如 IEEE Fellow、ACM Award
    - 媒体报道：报纸、杂志、网络媒体关于申请人的文章/报道
    - 专家推荐信：领域专家（教授、院士）出具的关于申请人工作的推荐函/支持信
    - 学术论文：已发表的研究论文、期刊文章、会议论文
    - 证书：证书、文凭、学位证、结业证
    - 会员资格：专业学会会员资格，如 ACM Fellow、IEEE Senior Member
    - 评审经历：担任期刊编委、会议评审、奖项评委的证明
    - 原创贡献：专利证书、重大原创技术/作品的证明
    - 薪资证明：offer letter、工资单、劳动合同中体现的薪资水平
    - 关键职位：在知名机构担任 lead/director/principal 等关键角色的证明
    - 推荐信：一般性推荐信（非专家评价类）
    - 其他：不符合上述任何类别

    projectGroup 规则：
    - 找文件中日期，以 成就/奖励/发表 发生的年份为准（不是文件打印日期）
    - 必须是4位数字年份字符串，如 "2019"
    - 完全无法判断则填 "未知"

    keepOrDelete 规则：
    - 一律填 "keep"，除非文件明显空白、重复或完全无关移民申请

    extractedName：申请人姓名或授奖机构名称（英文原文，不翻译）
    """

    private let analysisBatchSize = 50
    private let maxFilesToAnalyze = 500
    var existingFolders: [String] = []

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
    func setExistingFolders(_ folders: [String]) { existingFolders = folders }

    func runBatchAnalysis() async {
        let provider = AIProvider.current
        // Require a key for cloud providers
        if provider == .claude { guard !claudeAPIKey.isEmpty else { return } }
        if provider == .gemini { guard !geminiAPIKey.isEmpty else { return } }

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
                        sizeBytes: file.sizeBytes, modifiedAt: file.modifiedAt,
                        existingFolders: existingFolders
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
                 sizeBytes: Int64, modifiedAt: Date,
                 existingFolders: [String] = [],
                 systemPromptOverride: String? = nil) async -> FileIntelligence? {
        let userPrompt = makeUserPrompt(fileName: fileName, ext: ext,
                                        sizeBytes: sizeBytes, modifiedAt: modifiedAt,
                                        extractedText: pdfText,
                                        existingFolders: existingFolders)
        let sysPrompt = systemPromptOverride ?? systemPrompt
        switch AIProvider.current {
        case .gemini: return await analyzeWithGemini(filePath: filePath, userPrompt: userPrompt, systemPromptOverride: sysPrompt)
        case .ollama: return await analyzeWithOllama(filePath: filePath, userPrompt: userPrompt, systemPromptOverride: sysPrompt)
        case .claude: return await analyzeWithClaude(filePath: filePath, userPrompt: userPrompt, systemPromptOverride: sysPrompt)
        }
    }

    func analyzeLegalDocument(url: URL) async -> FileIntelligence? {
        let path = url.path
        let ext = url.pathExtension.lowercased()
        let fileName = url.lastPathComponent
        let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
        let size = (attrs[.size] as? Int64) ?? 0
        let modDate = (attrs[.modificationDate] as? Date) ?? Date()
        let text = extractTextSnippet(filePath: path, ext: ext)
        return await analyze(
            filePath: path, pdfText: text,
            fileName: fileName, ext: ext,
            sizeBytes: size, modifiedAt: modDate,
            existingFolders: [],
            systemPromptOverride: legalSystemPrompt
        )
    }

    // MARK: - Ollama

    private func analyzeWithOllama(filePath: String, userPrompt: String, systemPromptOverride: String? = nil) async -> FileIntelligence? {
        let model = UserDefaults.standard.string(forKey: "ollama_model") ?? "qwen2.5:3b"
        // Use OpenAI-compat endpoint so we get choices[] back
        guard let endpoint = URL(string: "http://localhost:11434/v1/chat/completions") else { return nil }

        let body = OllamaRequest(
            model: model,
            messages: [
                .init(role: "system", content: systemPromptOverride ?? systemPrompt),
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

    // MARK: - Gemini

    private var geminiAPIKey: String {
        Self.readGeminiAPIKeyFromKeychain()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func analyzeWithGemini(filePath: String, userPrompt: String, systemPromptOverride: String? = nil) async -> FileIntelligence? {
        let key = geminiAPIKey
        guard !key.isEmpty else { return nil }

        let model = "gemini-1.5-flash"
        guard let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(key)") else { return nil }

        // Build parts: optionally include image, then text
        let ext = URL(fileURLWithPath: filePath).pathExtension.lowercased()
        var parts: [[String: Any]] = []
        if let imageData = extractImageData(filePath: filePath, ext: ext) {
            parts.append([
                "inline_data": [
                    "mime_type": imageData.mediaType,
                    "data": imageData.data
                ]
            ])
        }
        parts.append(["text": userPrompt])

        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": systemPromptOverride ?? systemPrompt]]],
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": [
                "temperature": 0.1,
                "maxOutputTokens": 512,
                "responseMimeType": "application/json"
            ]
        ]

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return nil }

            switch http.statusCode {
            case 200..<300:
                lastError = nil
            case 400:
                RuntimeLog.append("[AI] gemini bad request path=\(filePath)")
                lastError = .analysisFailed("Gemini 请求错误，请检查 API Key")
                return nil
            case 401, 403:
                RuntimeLog.append("[AI] gemini auth_failed")
                lastError = .invalidAPIKey
                return nil
            case 429:
                RuntimeLog.append("[AI] gemini rate_limited")
                lastError = .rateLimited
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                return nil
            default:
                RuntimeLog.append("[AI] gemini_failed status=\(http.statusCode) path=\(filePath)")
                lastError = .analysisFailed("Gemini 分析失败：HTTP \(http.statusCode)")
                return nil
            }

            // Parse Gemini response: candidates[0].content.parts[0].text
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let first = candidates.first,
                  let content = first["content"] as? [String: Any],
                  let responseParts = content["parts"] as? [[String: Any]],
                  let text = responseParts.first?["text"] as? String else {
                RuntimeLog.append("[AI] gemini parse_failed path=\(filePath)")
                return nil
            }

            return parseOutput(text: text, filePath: filePath)
        } catch {
            RuntimeLog.append("[AI] gemini_failed path=\(filePath) error=\(error.localizedDescription)")
            lastError = .analysisFailed("Gemini 分析失败：\(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Claude

    private var claudeAPIKey: String {
        Self.readAPIKeyFromKeychain()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func analyzeWithClaude(filePath: String, userPrompt: String, systemPromptOverride: String? = nil) async -> FileIntelligence? {
        let key = claudeAPIKey
        guard !key.isEmpty else { return nil }

        let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
        let ext = URL(fileURLWithPath: filePath).pathExtension
        let imageData = extractImageData(filePath: filePath, ext: ext)
        var content: [ClaudeRequest.Message.Content] = []
        if let imageData {
            content.append(.image(data: imageData.data, mediaType: imageData.mediaType))
        }
        content.append(.text(userPrompt))
        let body = ClaudeRequest(
            model: "claude-haiku-4-5-20251001",
            max_tokens: 200,
            system: systemPromptOverride ?? systemPrompt,
            messages: [.init(role: "user", content: content)]
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
        let projectGroup = output.projectGroup?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

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
            docType: docType,
            projectGroup: projectGroup
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
        let projectGroup = (raw["projectGroup"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
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
            projectGroup: projectGroup?.nilIfEmpty,
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
                                extractedText: String?,
                                existingFolders: [String] = []) -> String {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        var prompt = "fileName: \(fileName.replacingOccurrences(of: "\n", with: " "))\next: \(ext)\nsizeBytes: \(sizeBytes)\nmodifiedAt: \(fmt.string(from: modifiedAt))"
        if let t = extractedText?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            let normalized = t.replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\u{0}", with: " ")
            prompt += "\ncontent:\n" + String(normalized.prefix(max(0, 1200 - prompt.count)))
        }
        if !existingFolders.isEmpty {
            prompt += "\nexistingFolders: " + existingFolders.prefix(20).joined(separator: "|")
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

    private func extractImageData(filePath: String, ext: String) -> (data: String, mediaType: String)? {
        let lower = ext.lowercased()

        if ["jpg", "jpeg", "png", "heic", "heif", "tiff", "bmp", "gif"].contains(lower) {
            guard let image = NSImage(contentsOfFile: filePath),
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                return nil
            }
            let resized = resizeImageDataIfNeeded(png, maxDimension: 1568)
            return (data: resized.base64EncodedString(), mediaType: "image/png")
        }

        if lower == "pdf" {
#if canImport(PDFKit)
            guard let doc = PDFDocument(url: URL(fileURLWithPath: filePath)),
                  let page = doc.page(at: 0) else {
                return nil
            }
            let pageRect = page.bounds(for: .mediaBox)
            let longestSide = max(pageRect.width, pageRect.height)
            guard longestSide > 0 else { return nil }
            let scale = min(1200.0 / longestSide, 2.0)
            let renderSize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
            let image = NSImage(size: renderSize)
            image.lockFocus()
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(CGRect(origin: .zero, size: renderSize))
                ctx.scaleBy(x: scale, y: scale)
                page.draw(with: .mediaBox, to: ctx)
            }
            image.unlockFocus()
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                return nil
            }
            return (data: png.base64EncodedString(), mediaType: "image/png")
#else
            return nil
#endif
        }

        return nil
    }

    private func resizeImageDataIfNeeded(_ data: Data, maxDimension: CGFloat) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return data
        }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        guard max(width, height) > maxDimension else { return data }

        let scale = maxDimension / max(width, height)
        let newSize = CGSize(width: width * scale, height: height * scale)
        guard let ctx = CGContext(
            data: nil,
            width: Int(newSize.width),
            height: Int(newSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return data
        }

        ctx.draw(cgImage, in: CGRect(origin: .zero, size: newSize))
        guard let resized = ctx.makeImage() else { return data }

        let destinationData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            destinationData,
            "public.png" as CFString,
            1,
            nil
        ) else {
            return data
        }

        CGImageDestinationAddImage(destination, resized, nil)
        CGImageDestinationFinalize(destination)
        return destinationData as Data
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

    // MARK: Gemini keychain helpers

    static func readGeminiAPIKeyFromKeychain() -> String? {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                   kSecAttrService: KeychainKey.service,
                                   kSecAttrAccount: KeychainKey.geminiAPIKey,
                                   kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var r: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess,
              let data = r as? Data,
              let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    static func saveGeminiAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let del: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                     kSecAttrService: KeychainKey.service,
                                     kSecAttrAccount: KeychainKey.geminiAPIKey]
        SecItemDelete(del as CFDictionary)
        guard !trimmed.isEmpty else { return }
        let add: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                     kSecAttrService: KeychainKey.service,
                                     kSecAttrAccount: KeychainKey.geminiAPIKey,
                                     kSecValueData: Data(trimmed.utf8)]
        SecItemAdd(add as CFDictionary, nil)
    }

    static func hasGeminiAPIKey() -> Bool { readGeminiAPIKeyFromKeychain() != nil }

    private static func purgeLegacyAPIKeyFromDefaults() {
        UserDefaults.standard.removeObject(forKey: KeychainKey.claudeAPIKey)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
