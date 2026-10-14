import SwiftUI
import AppKit

struct BrandLogo: View {
    private let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "logo", withExtension: "svg") else { return nil }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.primary)
            } else {
                Text("мусоровоз ♡")
                    .font(.title2.bold())
            }
        }
        .frame(width: 150, height: 48, alignment: .leading)
        .accessibilityLabel("мусоровоз")
    }
}

struct PrimarySummary: View {
    @ObservedObject var model: DashboardViewModel

    private var lastAnalysisText: String {
        guard let date = model.lastAnalysis else { return "Анализ ещё не запускался" }
        return "Последний анализ: \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer(minLength: 20)
            Text("НАЙДЕНО НА ДИСКЕ")
                .font(.subheadline.weight(.semibold))
                .tracking(1.5)
                .foregroundStyle(.secondary)
            Text(StorageFormat.string(model.totalAnalyzedBytes))
                .font(.system(size: 70, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
            Text("Безопасная очистка освободит \(StorageFormat.string(model.cleanableBytes)). Крупные файлы, модели ИИ и Claude VM удаляются только отдельно.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button {
                    model.analyze()
                } label: {
                    Label("Анализ", systemImage: "magnifyingglass")
                        .frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isWorking)

                Button {
                    model.requestCleanup(.all)
                } label: {
                    Label("Очистить всё", systemImage: "sparkles")
                        .frame(minWidth: 160)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(model.isWorking || model.cleanableBytes == 0)
            }

            HStack(spacing: 8) {
                if model.isWorking { ProgressView().controlSize(.small) }
                Text(model.isWorking ? "Идёт проверка…" : lastAnalysisText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
        }
    }
}

struct AdvancedSection: View {
    @ObservedObject var model: DashboardViewModel

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy) { model.isAdvancedExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(model.isAdvancedExpanded ? 90 : 0))
                    Text("Дополнительно").font(.headline)
                    Spacer()
                    Text("По умолчанию: \(StorageFormat.string(model.cleanableBytes))")
                        .foregroundStyle(.secondary)
                    Image(systemName: "slider.horizontal.3")
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 18)
                .frame(height: 52)
            }
            .buttonStyle(.plain)

            if model.isAdvancedExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    Text("ПРЕСЕТЫ ОЧИСТКИ")
                        .font(.caption.weight(.semibold))
                        .tracking(1.1)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 18)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                        CleanupPresetCard(title: "Быстро", subtitle: "Пакеты, Codex, Yandex", icon: "bolt.fill", color: .blue) {
                            model.requestCleanup(.quick)
                        }
                        CleanupPresetCard(title: "Приложения", subtitle: "Telegram, Claude, VS Code", icon: "square.stack.3d.up.fill", color: .pink) {
                            model.requestCleanup(.applications)
                        }
                        CleanupPresetCard(title: "Разработка", subtitle: "Codex и pnpm", icon: "terminal.fill", color: .orange) {
                            model.requestCleanup(.developer)
                        }
                        CleanupPresetCard(title: "Всё безопасное", subtitle: "Все обычные кэши", icon: "sparkles", color: .green) {
                            model.requestCleanup(.all)
                        }
                    }
                    .padding(.horizontal, 18)
                    .disabled(model.isWorking)

                    Divider().padding(.horizontal, 18)

                    Text("ЧТО НАЙДЕНО")
                        .font(.caption.weight(.semibold))
                        .tracking(1.1)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 18)

                    ForEach(model.report?.categories ?? []) { category in
                        HStack(spacing: 12) {
                            Image(systemName: category.systemImage)
                                .foregroundStyle(category.tint)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.title).fontWeight(.medium)
                                Text(category.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(StorageFormat.string(category.bytes)).fontWeight(.semibold)
                            if category.defaultSelected {
                                Label("Входит", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            } else if category.id == "models" {
                                Button("Очистить") { model.requestCleanup(.models) }
                                    .disabled(model.isWorking || category.bytes == 0)
                            } else if category.id == "claudeVM" {
                                Button("Удалить VM") { model.requestCleanup(.claudeVM) }
                                    .disabled(model.isWorking || category.bytes == 0)
                            }
                        }
                        .padding(.horizontal, 18)
                        .frame(minHeight: 46)
                    }
                }
                .padding(.vertical, 10)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(nsColor: .separatorColor).opacity(0.45)))
    }
}

private struct CleanupPresetCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                Text(title).fontWeight(.semibold)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
            .padding(12)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}

struct JournalView: View {
    let entries: [JournalEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Журнал").font(.headline)
                Spacer()
                Text("\(entries.count) событий")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(entries.suffix(8)) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(entry.date.formatted(date: .omitted, time: .standard))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 62, alignment: .leading)
                            Circle().fill(entry.color).frame(width: 7, height: 7)
                            Text(entry.message)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .frame(minHeight: 142, maxHeight: 178)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(nsColor: .separatorColor).opacity(0.45)))
    }
}

struct DashboardView: View {
    @StateObject private var model = DashboardViewModel()
    @AppStorage("appearance") private var appearance = AppTheme.light.rawValue
    @Environment(\.colorScheme) private var colorScheme

    private var selectedTheme: AppTheme {
        AppTheme(rawValue: appearance) ?? .light
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(nsColor: .windowBackgroundColor), Color.blue.opacity(0.09), Color.purple.opacity(0.07)]
                    : [Color(nsColor: .windowBackgroundColor), Color.blue.opacity(0.035), Color.pink.opacity(0.04)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    HStack {
                        BrandLogo()
                        Spacer()
                        Menu {
                            Button("Повторить анализ") { model.analyze() }
                            Divider()
                            Picker("Оформление", selection: $appearance) {
                                ForEach(AppTheme.allCases) { theme in
                                    Label(theme.title, systemImage: theme.systemImage)
                                        .tag(theme.rawValue)
                                }
                            }
                            Divider()
                            Text("мусоровоз \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 32, height: 32)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                    }
                    .zIndex(10)

                    HStack(spacing: 26) {
                        PrimarySummary(model: model)
                            .frame(width: 410, alignment: .leading)
                            .zIndex(2)
                        BlobExplorer(
                            categories: model.report?.categories ?? [],
                            largeFiles: model.standaloneLargeFiles,
                            installerFiles: model.report?.installerFiles ?? [],
                            onLargeFileSelect: { model.requestLargeFileDeletion(.one($0)) },
                            onDeleteAllLargeFiles: {
                                model.requestLargeFileDeletion(.all(model.standaloneLargeFiles))
                            },
                            onDeleteAllInstallers: {
                                model.requestLargeFileDeletion(.allInstallers(model.report?.installerFiles ?? []))
                            },
                            onLargeFileDeleteConfirmed: { model.confirmLargeFileDeletion(.one($0)) },
                            onLargeFileReveal: { model.revealLargeFile($0) },
                            onCleanupNodeDeleteConfirmed: { model.confirmBlobCleanup($0) }
                        )
                            .frame(maxWidth: .infinity, minHeight: 500)
                            .zIndex(0)
                    }

                    AdvancedSection(model: model)
                    JournalView(entries: model.journal)
                }
                .padding(26)
            }
        }
        .frame(minWidth: 1040, minHeight: 760)
        .tint(Color(red: 0.12, green: 0.43, blue: 0.94))
        .preferredColorScheme(selectedTheme.colorScheme)
        .alert(item: $model.pendingCleanup) { mode in
            Alert(
                title: Text(mode.title),
                message: Text(mode.message),
                primaryButton: .destructive(Text("Продолжить")) { model.confirmCleanup(mode) },
                secondaryButton: .cancel(Text("Отмена"))
            )
        }
        .alert(item: $model.pendingLargeFileDeletion) { request in
            Alert(
                title: Text(request.title),
                message: Text(request.message),
                primaryButton: .destructive(Text("В Корзину")) { model.confirmLargeFileDeletion(request) },
                secondaryButton: .cancel(Text("Отмена"))
            )
        }
        .alert("Ошибка", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Неизвестная ошибка")
        }
        .task {
            if model.report == nil { model.analyze() }
        }
    }
}
