import Foundation
import SwiftUI

enum DocType: String, Codable, CaseIterable, Hashable {
    case passport = "护照"
    case nationalID = "身份证件"
    case driverLicense = "驾照"
    case birthCert = "出生证明"
    case marriageCert = "结婚证"
    case divorceCert = "离婚证"
    case deathCert = "死亡证明"
    case policeClearance = "无犯罪证明"
    case immigrationForm = "移民申请表"
    case visaDoc = "签证文件"
    case powerOfAttorney = "授权书"
    case courtDoc = "法院文件"
    case legalLetter = "律师文件"
    case contract = "合同"
    case employmentLetter = "就业证明"
    case offerLetter = "录用通知"
    case payStub = "工资单"
    case resume = "简历"
    case referenceLetterDoc = "推荐信"
    case bankStatement = "银行流水"
    case taxRecord = "税务记录"
    case invoice = "发票"
    case receipt = "收据"
    case insurance = "保险文件"
    case addressProof = "地址证明"
    case propertyDoc = "房产文件"
    case medicalRecord = "医疗记录"
    case prescription = "处方"
    case academicCred = "学历证明"
    case transcript = "成绩单"
    case techDoc = "技术文档"
    case screenshot = "截图"
    case installer = "安装包"
    case photo = "照片"
    case other = "其他"

    var icon: String {
        switch self {
        case .passport, .nationalID, .driverLicense:
            return "person.text.rectangle"
        case .birthCert, .marriageCert, .divorceCert, .deathCert:
            return "doc.text.fill"
        case .policeClearance, .visaDoc, .immigrationForm:
            return "airplane.circle"
        case .powerOfAttorney, .courtDoc, .legalLetter:
            return "scale.3d"
        case .contract:
            return "signature"
        case .employmentLetter, .offerLetter, .referenceLetterDoc:
            return "briefcase"
        case .payStub, .resume:
            return "person.crop.rectangle"
        case .bankStatement, .taxRecord, .invoice, .receipt:
            return "dollarsign.circle"
        case .insurance:
            return "shield.checkerboard"
        case .addressProof, .propertyDoc:
            return "house"
        case .medicalRecord, .prescription:
            return "cross.case"
        case .academicCred, .transcript:
            return "graduationcap"
        case .screenshot:
            return "camera.viewfinder"
        case .installer:
            return "arrow.down.app"
        case .photo:
            return "photo"
        default:
            return "doc"
        }
    }

    var defaultChecklist: [DocType] {
        switch self {
        default:
            return []
        }
    }

    static var immigrationChecklist: [DocType] {
        [
            .passport, .birthCert, .nationalID, .policeClearance,
            .employmentLetter, .bankStatement, .addressProof, .marriageCert
        ]
    }
}

struct FileIntelligence: Codable, Hashable {
    let filePath: String
    let category: String
    let summary: String
    let suggestedFolder: String
    let keepOrDelete: KeepOrDelete
    let reason: String
    let confidence: Double
    let analyzedAt: Date
    let extractedName: String?
    let documentDate: String?
    let docType: DocType
    let projectGroup: String?

    enum KeepOrDelete: String, Codable {
        case keep
        case delete
        case unsure
    }

    init(filePath: String,
         category: String,
         summary: String,
         suggestedFolder: String,
         keepOrDelete: KeepOrDelete,
         reason: String,
         confidence: Double,
         analyzedAt: Date = Date(),
         extractedName: String? = nil,
         documentDate: String? = nil,
         docType: DocType = .other,
         projectGroup: String? = nil) {
        self.filePath = filePath
        self.category = category
        self.summary = summary
        self.suggestedFolder = suggestedFolder
        self.keepOrDelete = keepOrDelete
        self.reason = reason
        self.confidence = confidence
        self.analyzedAt = analyzedAt
        self.extractedName = extractedName
        self.documentDate = documentDate
        self.docType = docType
        self.projectGroup = projectGroup
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
