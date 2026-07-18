import Foundation
import BCICore
import WorldModelDemo

/// One (x, y) sample for the spatial trajectory panel.
struct WorldModelDemoPoint: Sendable, Equatable {
    let x: Float
    let y: Float
}

/// Owns all demo-runtime state itself (trajectory history, diagnostics,
/// illustrative candidates) rather than growing `AppViewModel`'s
/// `@Published` surface — this is throwaway, in-memory-only state that
/// resets on window close, unrelated to the real pipeline's state.
@MainActor
final class WorldModelMPCDemoViewModel: ObservableObject {
    @Published private(set) var trajectory: [WorldModelDemoPoint] = []
    @Published private(set) var goal: WorldModelDemoPoint?
    @Published private(set) var scenarioName: String = ""
    @Published private(set) var diagnostics: WorldModelDemoDiagnostics?
    @Published private(set) var essHistory: [Double] = []
    @Published private(set) var costMeanHistory: [Double] = []
    @Published private(set) var latencyHistoryMs: [Double] = []
    @Published private(set) var engineKind: WorldModelDemoFactory.Kind
    @Published private(set) var isRunning: Bool = false

    @Published private(set) var illustrativeCandidates: [PredictedWord] = []
    @Published private(set) var illustrativeWarning: String?

    private let session: WorldModelDemoSession
    private let predictor: any NextWordPredicting
    private let config = WorldModelMPCConfig()
    private var tickTask: Task<Void, Never>?
    private let historyLimit = 60
    private var tickCount = 0
    /// The illustrative panel shares the SAME actor-serialized
    /// `MLXNextWordPredictor` instance the real Track A carousel uses for
    /// actual word suggestions ("running two on the Apple GPU at once just
    /// thrashes," per that actor's own doc comment) — calling it on every
    /// ~700ms tick meant a real word commit landing mid-demo could queue
    /// behind a purely-illustrative call. Throttling to every Nth tick
    /// keeps the panel live while meaningfully cutting how often that
    /// collision can happen.
    private let illustrativePanelTickInterval = 5

    init(container: AppContainer) {
        self.engineKind = container.worldModelDemoResolved.kind
        self.session = WorldModelDemoSession(engine: container.worldModelDemoResolved.engine, mpcConfig: config)
        self.predictor = container.predictorResolved.predictor
    }

    func start() {
        guard tickTask == nil else { return }
        isRunning = true
        tickTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.tick()
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
        isRunning = false
    }

    private func tick() async {
        guard let record = try? await session.tick() else { return }

        if record.stepIndex == 1 {
            trajectory = []
            essHistory = []
            costMeanHistory = []
            latencyHistoryMs = []
        }
        scenarioName = record.scenarioName
        goal = WorldModelDemoPoint(x: record.goal[0], y: record.goal[1])
        trajectory.append(WorldModelDemoPoint(x: record.state[0], y: record.state[1]))
        diagnostics = record.diagnostics

        essHistory = appending(essHistory, record.diagnostics.effectiveSampleSize)
        costMeanHistory = appending(costMeanHistory, record.diagnostics.costMean)
        latencyHistoryMs = appending(latencyHistoryMs, record.planningLatencyMs)

        tickCount += 1
        if tickCount % illustrativePanelTickInterval == 0 {
            await updateIllustrativePanel(diagnostics: record.diagnostics)
        }
    }

    private func appending(_ history: [Double], _ value: Double) -> [Double] {
        var updated = history
        updated.append(value)
        if updated.count > historyLimit { updated.removeFirst(updated.count - historyLimit) }
        return updated
    }

    /// Maps the MPPI planner's own effective-sample-size ratio — a
    /// genuine health signal already computed by `planStep`, not an extra
    /// derivation — onto `GenerationAdaptation`, then calls the REAL
    /// on-device predictor. See `WorldModelDemoHonesty.illustrativeMappingCaveat`
    /// for why this mapping is illustrative only, not trained or validated.
    private func updateIllustrativePanel(diagnostics: WorldModelDemoDiagnostics) async {
        let confidence = min(1.0, max(0.0, diagnostics.effectiveSampleSize / Double(config.numCandidates)))
        let adaptation = GenerationAdaptation(
            maxCandidates: 2 + Int((confidence * 4).rounded()),
            temperature: 0.3 + confidence * 0.5
        )
        do {
            let words = try await predictor.predictNextWords(
                context: WorldModelDemoHonesty.illustrativeContext,
                maxCandidates: adaptation.maxCandidates,
                temperature: adaptation.temperature,
                cancellationID: UUID()
            )
            illustrativeCandidates = words
            illustrativeWarning = nil
        } catch {
            illustrativeWarning = error.localizedDescription
        }
    }
}
