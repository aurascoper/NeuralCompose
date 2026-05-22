import SwiftUI
import BCICore

@main
struct NeuralComposeAppEntry: App {

    @State private var loader = AppLoader()

    var body: some Scene {
        WindowGroup("NeuralCompose") {
            Group {
                if let viewModel = loader.viewModel {
                    ContentView(viewModel: viewModel)
                } else {
                    LoadingView()
                        .task { await loader.load() }
                }
            }
            .frame(minWidth: 640, minHeight: 420)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandMenu("Composition") {
                Button("Reset") {
                    if let vm = loader.viewModel {
                        Task { await vm.resetComposition() }
                    }
                }.keyboardShortcut("r", modifiers: [.command])
            }
        }

        MenuBarExtra("NeuralCompose", systemImage: "brain.head.profile") {
            if let viewModel = loader.viewModel {
                MenuBarView(viewModel: viewModel)
            } else {
                Text("Loading…").padding()
            }
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppLoader: ObservableObject {
    @Published var viewModel: AppViewModel?

    func load() async {
        let container = await AppContainer.makeDefault()
        let vm = AppViewModel(container: container)
        await vm.start()
        self.viewModel = vm
    }
}

private struct LoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Initializing pipeline…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
