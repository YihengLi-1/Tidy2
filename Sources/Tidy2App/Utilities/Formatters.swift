import AppKit
import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

enum SizeFormatter {
    static func string(from bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

enum DateHelper {
    static func startOfCurrentWeek(now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        return calendar.date(from: components) ?? calendar.startOfDay(for: now)
    }

    static func relativeShort(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

enum FileExplanationBuilder {
    static func explanation(path: String, bundleType: BundleType?) -> String {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent
        let modifiedAt = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
        let dateText = modifiedAt.map { dateFormatter.string(from: $0) } ?? "未知时间"

        switch ext {
        case "pdf":
            if let summary = pdfTitleOrFirstLine(url: url) {
                return "PDF：\(summary) · \(dateText)"
            }
            return "PDF 文档 · \(dateText)"
        case "png", "jpg", "jpeg", "heic":
            let dimension = imageDimensionText(url: url)
            if isScreenshotName(name) || bundleType == .weeklyScreenshots {
                if let dimension {
                    return "截图 · \(dateText) · \(dimension)"
                }
                return "截图 · \(dateText)"
            }
            if let dimension {
                return "图片 · \(dimension) · \(dateText)"
            }
            return "图片 · \(dateText)"
        case "dmg", "pkg":
            if let modifiedAt {
                return "安装器文件 · \(DateHelper.relativeShort(modifiedAt)) 下载 · 可能已用完"
            }
            return "安装器文件 · 可能已用完"
        case "zip", "rar", "7z":
            if let modifiedAt {
                return "压缩包 · \(DateHelper.relativeShort(modifiedAt)) 下载 · 适合归档到 Inbox/Archives"
            }
            return "压缩包 · 适合归档到 Inbox/Archives"
        case "doc", "docx", "txt", "md":
            return "文档文件 · \(dateText)"
        case "xls", "xlsx", "csv":
            return "表格文件 · \(dateText)"
        case "ppt", "pptx", "key":
            return "演示文件 · \(dateText)"
        case "mp4", "mov":
            return "视频文件 · \(dateText)"
        case "mp3", "wav":
            return "音频文件 · \(dateText)"
        default:
            return "下载文件 · \(dateText)"
        }
    }

    static func installerCandidateExplanation(for item: SearchResultItem) -> String {
        let ext = item.ext.lowercased()
        if ext == "zip" {
            return "安装器压缩包 · \(DateHelper.relativeShort(item.modifiedAt)) 下载 · 建议确认后再处理"
        }
        return "安装器文件 · \(DateHelper.relativeShort(item.modifiedAt)) 下载 · 可能已用完"
    }

    private static func isScreenshotName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("screenshot") ||
            lower.contains("screen shot") ||
            lower.contains("屏幕快照") ||
            lower.contains("截图")
    }

    private static func imageDimensionText(url: URL) -> String? {
        guard let image = NSImage(contentsOf: url),
              let rep = image.representations.first else {
            return nil
        }
        let width = rep.pixelsWide > 0 ? rep.pixelsWide : Int(rep.size.width)
        let height = rep.pixelsHigh > 0 ? rep.pixelsHigh : Int(rep.size.height)
        guard width > 0, height > 0 else { return nil }
        return "\(width)x\(height)"
    }

    private static func pdfTitleOrFirstLine(url: URL) -> String? {
#if canImport(PDFKit)
        guard let document = PDFDocument(url: url) else { return nil }
        if let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty {
            return title
        }
        guard let firstPage = document.page(at: 0),
              let text = firstPage.string else {
            return nil
        }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return String(trimmed.prefix(80))
            }
        }
#endif
        return nil
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
