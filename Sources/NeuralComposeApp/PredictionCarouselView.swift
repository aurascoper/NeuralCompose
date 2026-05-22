import SwiftUI
import BCICore

/// Three-slot carousel. The active slot is highlighted; an automatic 1.5 s
/// tick (driven by `AppViewModel`) rotates the highlight, and a confirmed
/// `selectActive` smoothed intent triggers a commit + new predictions.
///
/// The view itself is dumb — all state changes flow through the view model.
/// We use a smooth visual transition between highlight indices so the
/// rotation feels predictable to the user.
struct PredictionCarouselView: View {
    let candidates: [PredictedWord]
    let highlightIndex: Int
    let isPredicting: Bool
    let lastCommittedWord: String?

    var body: some View {
        VStack(spacing: 8) {
            if let lastCommittedWord = lastCommittedWord {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("Committed: \(lastCommittedWord.trimmingCharacters(in: .whitespaces))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                ForEach(Array(candidates.enumerated()), id: \.element.id) { (index, word) in
                    candidateChip(word: word, isActive: index == highlightIndex)
                        .frame(maxWidth: .infinity)
                }
                if candidates.isEmpty {
                    Text(isPredicting ? "Predicting…" : "No suggestions")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .animation(.easeInOut(duration: 0.20), value: highlightIndex)
            .frame(minHeight: 64)

            if isPredicting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("LLM thinking…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func candidateChip(word: PredictedWord, isActive: Bool) -> some View {
        VStack(spacing: 2) {
            Text(word.displayText)
                .font(.system(size: 22, weight: isActive ? .semibold : .regular, design: .rounded))
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(String(format: "%.0f%%", word.probability * 100))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isActive
                      ? Color.accentColor.opacity(0.18)
                      : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isActive ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .scaleEffect(isActive ? 1.04 : 1.0)
    }
}
