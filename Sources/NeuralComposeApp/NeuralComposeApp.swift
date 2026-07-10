import SwiftUI
import BCICore

@main
struct NeuralComposeAppEntry: App {

    @StateObject private var loader = AppLoader()

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

        // Phase B Sleep Validation Toolkit — debug window. Opened from the
        // menu below or with Cmd+Shift+D. This is the host for the
        // EEGScalpPlotterView and the upcoming components (PSD, blink
        // detector, etc.). Not user-facing in the v1 sleep-cycle flow.
        Window("Phase B Debug", id: "phase-b-debug") {
            SleepValidationView()
        }
        .defaultSize(width: 1100, height: 720)
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .commands {
            CommandMenu("Debug") {
                Button("Open Phase B Debug Window") {
                    NSApp.sendAction(
                        #selector(NSWindowController.showWindow(_:)),
                        to: nil,
                        from: nil
                    )
                }.keyboardShortcut("d", modifiers: [.command, .shift])
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
