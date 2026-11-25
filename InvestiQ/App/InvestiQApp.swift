import SwiftUI
import InvestiQPresentation

@main
struct InvestiQApp: App {
    @State private var app = AppModel(environment: AppDependencies.makeEnvironment())

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .frame(minWidth: 960, minHeight: 640)
        }
        .commands { AppCommands(app: app) }
    }
}
