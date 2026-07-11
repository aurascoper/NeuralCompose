import SwiftUI
import BCICore

/// Shows the result of one `DialecticEngine.refine(_:)` pass — thesis,
/// antithesis, and the recommended synthesis — with explicit Accept/Dismiss
/// actions. Accepting replaces the composed sentence outright (see
/// `TextCompositionController.applyRefinement`); dismissing leaves it
/// untouched. Never appears unless the user explicitly pressed "Refine."
struct RefinementSuggestionView: View {
    let refinement: Refinement
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Refinement suggestion", systemImage: "sparkles")
                    .font(.callout.bold())
                Spacer()
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.borderless)
                Button("Accept", action: onAccept)
                    .buttonStyle(.borderedProminent)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(refinement.synthesis)
                    .font(.system(size: 18, weight: .medium, design: .serif))
                    .textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08))
            .cornerRadius(6)

            DisclosureGroup("Show reasoning") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Thesis: \(refinement.thesis)")
                    Text("Antithesis: \(refinement.antithesis)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
            .font(.caption)
        }
    }
}
