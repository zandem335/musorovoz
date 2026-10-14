import SwiftUI

@main
struct MusorovozApp: App {
    var body: some Scene {
        WindowGroup {
            DashboardView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1160, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
