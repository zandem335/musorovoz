import Foundation

enum CleanerServiceError: LocalizedError {
    case missingScript
    case commandFailed(Int32, String)
    case invalidReport
    case unsafePath(String)

    var errorDescription: String? {
        switch self {
        case .missingScript:
            return "Внутренний модуль очистки не найден."
        case let .commandFailed(code, output):
            return "Команда завершилась с кодом \(code).\n\(output)"
        case .invalidReport:
            return "Не удалось прочитать результат анализа."
        case let .unsafePath(path):
            return "Операция заблокирована для небезопасного пути: \(path)"
        }
    }
}

struct CleanerService: Sendable {
    private let scriptURL: URL

    init(bundle: Bundle = .main) throws {
        guard let scriptURL = bundle.url(forResource: "MacCare", withExtension: "command") else {
            throw CleanerServiceError.missingScript
        }
        self.scriptURL = scriptURL
    }

    func scan() async throws -> ScanReport {
        let result = try await run(arguments: ["--scan-json"])
        guard let data = result.data(using: .utf8),
              let report = try? JSONDecoder().decode(ScanReport.self, from: data) else {
            throw CleanerServiceError.invalidReport
        }
        return report
    }

    func clean(_ mode: CleanupMode) async throws -> String {
        try await run(arguments: mode.arguments)
    }

    func cleanNode(id: String) async throws -> String {
        try await run(arguments: ["--clean-node", id, "--yes"])
    }

    func moveToTrash(_ files: [LargeFileEntry]) async throws -> [String] {
        try await Task.detached(priority: .userInitiated) {
            let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path + "/"
            var moved: [String] = []
            for file in files {
                let url = URL(fileURLWithPath: file.path).standardizedFileURL
                guard url.path.hasPrefix(home), url.path != String(home.dropLast()) else {
                    throw CleanerServiceError.unsafePath(url.path)
                }
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                var resultingURL: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
                moved.append(file.name)
            }
            return moved
        }.value
    }

    private func run(arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = [scriptURL.path] + arguments
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    guard process.terminationStatus == 0 else {
                        continuation.resume(throwing: CleanerServiceError.commandFailed(process.terminationStatus, output))
                        return
                    }
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
