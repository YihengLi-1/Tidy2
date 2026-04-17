import Foundation
import SwiftUI

struct FileIntelligence: Codable, Hashable {
    let filePath: String
    let category: String
    let summary: String
    let suggestedFolder: String
    let keepOrDelete: KeepOrDelete
    let reason: String
    let confidence: Double
    let analyzedAt: Date

    enum KeepOrDelete: String, Codable {
        case keep
        case delete
        case unsure
    }
}

extension FileIntelligence {
    static func categoryColor(for category: String) -> Color {
        switch category {
        case "发票":
            return .orange
        case "合同":
            return .blue
        case "截图":
            return .gray
        case "安装包":
            return .red
        case "简历":
            return .green
        case "技术文档":
            return .purple
        case "照片":
            return .teal
        case "其他":
            return .secondary
        default:
            return .secondary
        }
    }
}
