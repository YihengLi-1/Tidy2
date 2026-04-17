import Foundation

enum SearchParser {
    static func parse(_ query: String, now: Date = Date()) -> SearchFilters {
        let lowered = query.lowercased()
        var filters = SearchFilters()

        if lowered.contains("downloads") || lowered.contains("下载") {
            filters.location = .downloads
        } else if lowered.contains("desktop") || lowered.contains("桌面") {
            filters.location = .desktop
        }

        let knownTypes = ["pdf", "png", "jpg", "jpeg", "doc", "docx", "txt", "zip", "dmg", "pkg"]
        if let matchedType = knownTypes.first(where: { lowered.contains($0) }) {
            filters.fileType = matchedType
        }

        if lowered.contains("本周") || lowered.contains("this week") {
            let start = DateHelper.startOfCurrentWeek(now: now)
            filters.dateFrom = start
            filters.dateTo = now
        } else if lowered.contains("today") || lowered.contains("今天") {
            let start = Calendar.current.startOfDay(for: now)
            filters.dateFrom = start
            filters.dateTo = now
        } else if lowered.contains("last 7 days") || lowered.contains("last7days") || lowered.contains("近7天") {
            filters.dateFrom = Calendar.current.date(byAdding: .day, value: -7, to: now)
            filters.dateTo = now
        } else if lowered.contains("last 30 days") || lowered.contains("last30days") || lowered.contains("近30天") {
            filters.dateFrom = Calendar.current.date(byAdding: .day, value: -30, to: now)
            filters.dateTo = now
        }

        if lowered.contains(">200mb") || lowered.contains("200mb+") || lowered.contains("large") || lowered.contains("大文件") {
            filters.minSizeBytes = 200 * 1024 * 1024
        }

        let split = query
            .split(whereSeparator: { $0 == " " || $0 == "," || $0 == "，" })
            .map { String($0) }

        let reserved = Set([
            "downloads", "desktop", "this", "week", "today", "last", "7", "days", "last7days",
            "30", "last30days", "large", "200mb", "200mb+", ">200mb", "大文件",
            "下载", "桌面", "本周", "今天", "近7天", "近30天",
            "pdf", "png", "jpg", "jpeg", "doc", "docx", "txt", "zip", "dmg", "pkg"
        ])
        filters.keywords = split.filter { !reserved.contains($0.lowercased()) }

        return filters
    }
}
