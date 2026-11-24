import SwiftUI

@main
struct ExpedienteApp: App {
    @StateObject private var app = DemoSeeder.isActive ? DemoSeeder.makeAppState() : AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
        }
        .onChange(of: scenePhase) { _, phase in
            app.scenePhaseChanged(phase)
        }
    }
}
