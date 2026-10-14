import Foundation
import SwiftUI
import AppKit

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var report: ScanReport?
    @Published private(set) var journal: [JournalEntry] = []
    @Published private(set) var isWorking = false
    @Published private(set) var lastAnalysis: Date?
    @Published var isAdvancedExpanded = false
    @Published var pendingCleanup: CleanupMode?
    @Published var pendingLargeFileDeletion: LargeFileDeletionRequest?
    @Published var errorMessage: String?

    private let service: CleanerService?

    init() {
        service = try? CleanerService()
    }

    var defaultCategories: [CleanupCategory] {
        report?.categories.filter(\.defaultSelected) ?? []
    }

    var optionalCategories: [CleanupCategory] {
        report?.categories.filter { !$0.defaultSelected } ?? []
    }

    var cleanableBytes: Int64 {
        defaultCategories.reduce(0) { $0 + $1.bytes }
    }

    var standaloneLargeFiles: [LargeFileEntry] {
        let installerIDs = Set((report?.installerFiles ?? []).map(\.id))
        return (report?.largeFiles ?? []).filter { !installerIDs.contains($0.id) }
    }

    var totalAnalyzedBytes: Int64 {
        let categories = report?.categories.reduce(0) { $0 + $1.bytes } ?? 0
        let installerFiles = report?.installerFiles ?? []
        let installerIDs = Set(installerFiles.map(\.id))
        let additionalLargeFiles = standaloneLargeFiles
            .filter { !$0.isAlreadyCounted && !installerIDs.contains($0.id) }
            .reduce(0) { $0 + $1.bytes }
        let installers = installerFiles.reduce(0) { $0 + $1.bytes }
        return categories + additionalLargeFiles + installers
    }

    func analyze() {
        guard !isWorking else { return }
        guard let service else {
            errorMessage = CleanerServiceError.missingScript.localizedDescription
            return
        }
        isWorking = true
        journal = [JournalEntry(date: .now, color: .gray, message: "Начат анализ системы…")]

        Task {
            do {
                let newReport = try await service.scan()
                report = newReport
                lastAnalysis = .now
                journal.append(contentsOf: newReport.categories.map {
                    JournalEntry(date: .now, color: $0.tint, message: "Найдено: \($0.title) — \(StorageFormat.string($0.bytes))")
                })
                journal.append(JournalEntry(date: .now, color: .green, message: "Анализ завершён. Можно безопасно освободить \(StorageFormat.string(cleanableBytes))."))
            } catch {
                errorMessage = error.localizedDescription
                journal.append(JournalEntry(date: .now, color: .red, message: "Ошибка анализа: \(error.localizedDescription)"))
            }
            isWorking = false
        }
    }

    func requestCleanup(_ mode: CleanupMode) {
        pendingCleanup = mode
    }

    func confirmCleanup(_ mode: CleanupMode) {
        guard !isWorking, let service else { return }
        isWorking = true
        journal.insert(JournalEntry(date: .now, color: .orange, message: "Начата очистка…"), at: 0)

        Task {
            do {
                let output = try await service.clean(mode)
                let meaningfulLines = output.split(separator: "\n")
                    .map(String.init)
                    .filter { $0.contains("✓") || $0.contains("↷") || $0.contains("Готово") || $0.contains("завершена") }
                for line in meaningfulLines.suffix(8) {
                    journal.append(JournalEntry(date: .now, color: line.contains("↷") ? .orange : .green, message: line.trimmingCharacters(in: .whitespaces)))
                }
                report = try await service.scan()
                lastAnalysis = .now
                journal.append(JournalEntry(date: .now, color: .green, message: "Очистка завершена. Данные пересчитаны."))
            } catch {
                errorMessage = error.localizedDescription
                journal.append(JournalEntry(date: .now, color: .red, message: "Ошибка очистки: \(error.localizedDescription)"))
            }
            isWorking = false
        }
    }

    func confirmBlobCleanup(_ node: BlobDescriptor) {
        guard !isWorking, let service else { return }
        isWorking = true
        journal.append(JournalEntry(
            date: .now,
            color: .orange,
            message: "Очистка: \(node.title) — \(StorageFormat.string(node.bytes))…"
        ))
        Task {
            do {
                let output = try await service.cleanNode(id: node.id)
                let meaningfulLines = output.split(separator: "\n")
                    .map(String.init)
                    .filter { $0.contains("✓") || $0.contains("↷") || $0.contains("завершена") }
                for line in meaningfulLines.suffix(6) {
                    journal.append(JournalEntry(
                        date: .now,
                        color: line.contains("↷") ? .orange : .green,
                        message: line.trimmingCharacters(in: .whitespaces)
                    ))
                }
                report = try await service.scan()
                lastAnalysis = .now
                journal.append(JournalEntry(date: .now, color: .green, message: "Блоб «\(node.title)» очищен. Данные пересчитаны."))
            } catch {
                errorMessage = error.localizedDescription
                journal.append(JournalEntry(date: .now, color: .red, message: "Ошибка очистки «\(node.title)»: \(error.localizedDescription)"))
            }
            isWorking = false
        }
    }

    func requestLargeFileDeletion(_ request: LargeFileDeletionRequest) {
        pendingLargeFileDeletion = request
    }

    func revealLargeFile(_ file: LargeFileEntry) {
        let url = URL(fileURLWithPath: file.path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "Файл больше не найден. Запустите анализ ещё раз."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func confirmLargeFileDeletion(_ request: LargeFileDeletionRequest) {
        guard !isWorking, let service else { return }
        isWorking = true
        journal.append(JournalEntry(date: .now, color: .orange, message: "Перемещение крупных файлов в Корзину…"))
        Task {
            do {
                let moved = try await service.moveToTrash(request.files)
                journal.append(JournalEntry(date: .now, color: .green, message: "Перемещено в Корзину: \(moved.count) файлов."))
                report = try await service.scan()
                lastAnalysis = .now
            } catch {
                errorMessage = error.localizedDescription
                journal.append(JournalEntry(date: .now, color: .red, message: "Не удалось переместить файл: \(error.localizedDescription)"))
            }
            isWorking = false
        }
    }
}
