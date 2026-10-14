import Foundation
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case light
    case dark
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "Светлая"
        case .dark: return "Тёмная"
        case .system: return "Как в системе"
        }
    }

    var systemImage: String {
        switch self {
        case .light: return "sun.max.fill"
        case .dark: return "moon.stars.fill"
        case .system: return "circle.lefthalf.filled"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }
}

struct ScanReport: Codable, Sendable {
    let schemaVersion: Int
    let freeBytes: Int64
    let categories: [CleanupCategory]
    let largeFiles: [LargeFileEntry]?
    let installerFiles: [LargeFileEntry]?
}

struct LargeFileEntry: Codable, Identifiable, Sendable {
    let pathBase64: String
    let bytes: Int64
    var semanticGroup: String?
    var countedInCategories: Bool? = nil

    var id: String { pathBase64 }

    var path: String {
        guard let data = Data(base64Encoded: pathBase64),
              let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var folder: String { URL(fileURLWithPath: path).deletingLastPathComponent().path }
    var isAlreadyCounted: Bool { countedInCategories == true }
}

enum LargeFileDeletionRequest: Identifiable, Sendable {
    case one(LargeFileEntry)
    case all([LargeFileEntry])
    case allInstallers([LargeFileEntry])

    var id: String {
        switch self {
        case let .one(file): return "one:\(file.id)"
        case .all: return "all"
        case .allInstallers: return "all-installers"
        }
    }

    var files: [LargeFileEntry] {
        switch self {
        case let .one(file): return [file]
        case let .all(files): return files
        case let .allInstallers(files): return files
        }
    }

    var title: String {
        switch self {
        case let .one(file): return "Переместить «\(file.name)» в Корзину?"
        case .all: return "Переместить все крупные файлы в Корзину?"
        case .allInstallers: return "Переместить все установщики и архивы в Корзину?"
        }
    }

    var message: String {
        switch self {
        case let .one(file):
            return "Файл занимает \(StorageFormat.string(file.bytes)). Он будет перемещён в Корзину и сможет быть восстановлен."
        case let .all(files):
            let total = files.reduce(0) { $0 + $1.bytes }
            return "Будут перемещены \(files.count) файлов общим размером \(StorageFormat.string(total)), включая модели, установщики и данные приложений. Перед продолжением закройте связанные приложения."
        case let .allInstallers(files):
            let total = files.reduce(0) { $0 + $1.bytes }
            return "Будут перемещены \(files.count) файлов из Downloads общим размером \(StorageFormat.string(total)). Содержимое архивов предварительно не проверяется."
        }
    }
}

struct CleanupCategory: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let bytes: Int64
    let defaultSelected: Bool
    let items: [CleanupItem]?

    var tint: Color {
        switch id {
        case "applications": return Color(red: 0.36, green: 0.50, blue: 0.98)
        case "telegram": return Color(red: 1.00, green: 0.55, blue: 0.63)
        case "development": return Color(red: 1.00, green: 0.66, blue: 0.36)
        case "models": return Color(red: 0.70, green: 0.54, blue: 0.98)
        case "claudeVM": return Color(red: 0.37, green: 0.84, blue: 0.70)
        default: return .blue
        }
    }
}

struct CleanupItem: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let bytes: Int64
}

struct BlobDescriptor: Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let bytes: Int64
    let defaultSelected: Bool
    let tint: Color
    let children: [BlobDescriptor]

    init(category: CleanupCategory) {
        id = category.id
        title = category.title
        subtitle = category.subtitle
        systemImage = category.systemImage
        bytes = category.bytes
        defaultSelected = category.defaultSelected
        tint = category.tint
        children = (category.items ?? [])
            .filter { $0.bytes > 0 }
            .enumerated()
            .map { index, item in BlobDescriptor(item: item, parentTint: category.tint, index: index) }
    }

    private init(item: CleanupItem, parentTint: Color, index: Int) {
        id = item.id
        title = item.title
        subtitle = item.subtitle
        systemImage = item.systemImage
        bytes = item.bytes
        defaultSelected = true
        tint = BlobDescriptor.childColor(parent: parentTint, index: index)
        children = []
    }

    init(largeFile: LargeFileEntry, index: Int) {
        id = largeFile.id
        title = largeFile.name
        subtitle = largeFile.semanticGroup ?? largeFile.folder
        systemImage = "doc.fill"
        bytes = largeFile.bytes
        defaultSelected = false
        tint = BlobDescriptor.childColor(parent: .blue, index: index)
        children = []
    }

    init(largeFiles: [LargeFileEntry]) {
        id = "largeFiles"
        title = "Крупные файлы"
        subtitle = "Найдены на диске — удаление только через Корзину"
        systemImage = "externaldrive.badge.magnifyingglass"
        bytes = largeFiles.reduce(0) { $0 + $1.bytes }
        defaultSelected = false
        tint = Color(red: 0.42, green: 0.72, blue: 0.98)
        children = largeFiles.enumerated().map { BlobDescriptor(largeFile: $0.element, index: $0.offset) }
    }

    init(installerFiles: [LargeFileEntry]) {
        id = "installers"
        title = "Установщики и архивы"
        subtitle = "Downloads — удаление только через Корзину"
        systemImage = "shippingbox.and.arrow.backward.fill"
        bytes = installerFiles.reduce(0) { $0 + $1.bytes }
        defaultSelected = false
        tint = Color(red: 0.96, green: 0.58, blue: 0.40)
        children = installerFiles.enumerated().map { BlobDescriptor(largeFile: $0.element, index: $0.offset + 3) }
    }

    private static func childColor(parent: Color, index: Int) -> Color {
        let palette: [Color] = [
            parent,
            Color(red: 0.39, green: 0.72, blue: 0.98),
            Color(red: 0.48, green: 0.84, blue: 0.70),
            Color(red: 0.98, green: 0.65, blue: 0.42),
            Color(red: 0.77, green: 0.57, blue: 0.98),
            Color(red: 0.98, green: 0.52, blue: 0.64)
        ]
        return palette[index % palette.count]
    }
}

enum CleanupMode: String, Identifiable, Sendable {
    case quick
    case applications
    case developer
    case all
    case models
    case claudeVM

    var id: String { rawValue }

    var arguments: [String] {
        switch self {
        case .quick: return ["--clean-safe", "--yes"]
        case .applications: return ["--clean-apps", "--yes"]
        case .developer: return ["--clean-dev", "--yes"]
        case .all: return ["--clean-all", "--yes"]
        case .models: return ["--clean-models", "--yes"]
        case .claudeVM: return ["--clean-claude-vm", "--yes"]
        }
    }

    var title: String {
        switch self {
        case .quick: return "Быстрая очистка?"
        case .applications: return "Очистить кэши приложений?"
        case .developer: return "Очистить файлы разработки?"
        case .all: return "Очистить всё безопасное?"
        case .models: return "Удалить загруженные модели?"
        case .claudeVM: return "Удалить Claude VM?"
        }
    }

    var message: String {
        switch self {
        case .quick:
            return "Будут очищены повторно создаваемые кэши npm, npx, pip, uv, Codex и Yandex. Документы, проекты и история приложений сохраняются."
        case .applications:
            return "Будут очищены Telegram media/cache, кэши Claude и VS Code, установочные архивы и старые версии выбранных расширений. Сообщения, настройки и проекты сохраняются."
        case .developer:
            return "Будут очищены кэши разработки, старые версии Codex и неиспользуемые пакеты pnpm. Проектные node_modules и история Codex сохраняются."
        case .all:
            return "Будут очищены кэши приложений, Telegram media/cache и файлы разработки. История Codex, сообщения Telegram, проекты, модели ИИ и Claude VM сохраняются. Закройте Telegram, Claude, VS Code и Yandex."
        case .models:
            return "SigLIP и Hugging Face будут удалены с диска. При следующем использовании приложения загрузят их повторно."
        case .claudeVM:
            return "Будут удалены инструменты и локальное состояние Cowork внутри виртуальной машины. Claude создаст VM заново. Закройте Claude."
        }
    }
}

struct JournalEntry: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let color: Color
    let message: String
}

enum StorageFormat {
    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        formatter.isAdaptive = true
        formatter.includesUnit = true
        return formatter
    }()

    static func string(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "—" }
        return formatter.string(fromByteCount: bytes)
            .replacingOccurrences(of: "GB", with: "ГБ")
            .replacingOccurrences(of: "MB", with: "МБ")
            .replacingOccurrences(of: "TB", with: "ТБ")
    }
}
