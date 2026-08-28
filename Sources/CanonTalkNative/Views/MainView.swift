import SwiftUI

struct MainView: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        Group {
            if model.isRunning {
                SessionView(model: model)
            } else {
                SetupView(model: model)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(
            "CanonTalk",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("Aceptar", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
