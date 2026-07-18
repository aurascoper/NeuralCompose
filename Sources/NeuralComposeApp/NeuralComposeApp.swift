import SwiftUI
import BCICore

@main
struct NeuralComposeAppEntry: App {

    @StateObject private var loader = AppLoader()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("NeuralCompose") {
            Group {
                if let viewModel = loader.viewModel, let dispatcher = loader.dispatcher {
                    ContentView(viewModel: viewModel, dispatcher: dispatcher)
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
                    if let dispatcher = loader.dispatcher {
                        Task { await dispatcher.perform(.resetComposition) }
                    }
                }.keyboardShortcut("r", modifiers: [.command])
            }
        }

        // Phase B Sleep Validation Toolkit — debug window. Opened from the
        // menu below or with Cmd+Shift+D. This is the host for the
        // EEGScalpPlotterView and the upcoming components (PSD, blink
        // detector, etc.). Not user-facing in the v1 sleep-cycle flow.
        Window("Phase B Debug", id: "phase-b-debug") {
            // `loader.viewModel` is nil until the pipeline finishes
            // loading. `SleepValidationView` tolerates nil and re-runs
            // its health-polling task when the view model binds, because
            // this scene re-evaluates when the observed loader publishes.
            SleepValidationView(viewModel: loader.viewModel)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandMenu("Debug") {
                // Routes through the dispatcher rather than calling
                // `openWindow(id:)` directly. The dispatcher sets
                // `viewModel.pendingWindowOpen = "phase-b-debug"`, and
                // the view's `.onChange(of: pendingWindowOpen)`
                // performs the actual `openWindow(id:)` call. This
                // keeps the openWindow env var off the App scene's
                // button and on the view, where the SwiftUI bridge
                // already lives.
                Button("Open Phase B Debug Window") {
                    if let dispatcher = loader.dispatcher {
                        Task { await dispatcher.perform(.openPhaseBDebug) }
                    }
                }.keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }

        // World Model demo — synthetic-task JEPA+MPC research window (see
        // WorldModel/README.md, Sources/WorldModelDemo/). Always reachable
        // like Phase B Debug; `AppViewModel.worldModelDemoEnabled` (off by
        // default) gates whether the view's content actually runs the
        // simulation, not whether the window/menu item exists.
        Window("World Model Demo", id: "world-model-demo") {
            WorldModelMPCDemoView(viewModel: loader.viewModel)
        }
        .defaultSize(width: 900, height: 640)
        .commands {
            CommandMenu("World Model") {
                Button("Open World Model Demo") {
                    if let dispatcher = loader.dispatcher {
                        Task { await dispatcher.perform(.openWorldModelDemo) }
                    }
                }.keyboardShortcut("m", modifiers: [.command, .shift])
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

    /// The command dispatcher, built once the view model is up. `nil`
    /// during the brief loading window. Both the menu items in
    /// `NeuralComposeAppEntry` and the future debug palette consume
    /// this so a single `AppCommand` resolution path is used by every
    /// control surface.
    @Published var dispatcher: AppCommandDispatcher?

    func load() async {
        let container = await AppContainer.makeDefault()
        let vm = AppViewModel(container: container)
        await vm.start()
        let disp = AppCommandDispatcher(target: vm)
        // Wire the dispatcher back into the view model so
        // voice commands resolved by `stopCommandListening()`
        // route through the same `AppCommand` execution path
        // the palette and menus use. The ref is `weak` so
        // the dispatcher's lifetime stays owned by the loader.
        vm.commandDispatcher = disp
        self.viewModel = vm
        self.dispatcher = disp
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
