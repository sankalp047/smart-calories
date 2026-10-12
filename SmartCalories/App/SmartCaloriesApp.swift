import SwiftUI

@main
struct SmartCaloriesApp: App {
    @State private var env = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
                // Appearance is the user's choice now — RootView applies it
                // from settings; nothing here may force a scheme.
                .tint(Theme.Palette.accent)
                .onChange(of: scenePhase) { _, phase in
                    // Pick up anything Siri, a Shortcut or the widget logged
                    // while we were in the background.
                    if phase == .active {
                        env.reloadFromDisk()
                        // Foregrounding is the reliable network moment —
                        // drain any heart samples that queued up.
                        Task { await env.heartShipper.shipPending() }
                    }
                }
        }
    }
}
