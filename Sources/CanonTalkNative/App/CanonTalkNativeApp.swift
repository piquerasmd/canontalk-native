import SwiftUI

@main
struct CanonTalkNativeApp: App {
    @StateObject private var model = AppViewModel()

    var body: some Scene {
        WindowGroup("CanonTalk Native") {
            MainView(model: model)
                .frame(minWidth: 860, minHeight: 650)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
