import SwiftUI
import BCICore

/// Input controls for the hypnagogic loop: a Microphone / Typed prompts
/// picker and, in typed mode, a text field that feeds `TypedPromptListener`.
/// Shown in the main window only while the loop is enabled. Submitting
/// queues the prompt; the loop consumes it on its next listen turn, so a line
/// typed while the voice is speaking is not lost and never interrupts it.
///
/// Honest scope: typed mode captures no audio and requests no mic or speech
/// authorization, but transcript text still goes to the configured runtime
/// exactly as a spoken turn would. The privacy banner's badge reflects the
/// active input ("Typed + Cloud" vs "Listening + Cloud").
struct TypedPromptPanel: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var draft: String = ""
    @FocusState private var draftFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("Input", selection: $viewModel.dialecticInputSource) {
                    ForEach(DialecticInputSource.allCases) { source in
                        Text(source.label).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                Text(viewModel.dialecticInputSource == .typedPrompt
                     ? "Typed prompts replace the microphone; speech output stays on."
                     : "The mic opens for each listen turn and closes before the voice speaks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if viewModel.dialecticInputSource == .typedPrompt {
                HStack(spacing: 8) {
                    TextField("Type a prompt for the loop and press Return", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .focused($draftFocused)
                        .onSubmit(submit)
                    Button {
                        submit()
                    } label: {
                        Label("Send", systemImage: "arrow.up.circle.fill")
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .onAppear { draftFocused = true }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task { await viewModel.submitTypedPrompt(text) }
    }
}
