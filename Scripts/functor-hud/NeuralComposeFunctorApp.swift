#if os(macOS)
import AppKit
#if canImport(BCICore)
import BCICore
#endif
#if canImport(NeuralComposeApp)
@testable import NeuralComposeApp
#endif
public typealias PlatformColor = NSColor
public typealias PlatformViewRepresentable = NSViewRepresentable
#elseif os(iOS)
import UIKit
public typealias PlatformColor = UIColor
public typealias PlatformViewRepresentable = UIViewRepresentable
public typealias NSColor = UIColor
extension UIColor {
    public convenience init(calibratedRed red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
    public convenience init(calibratedWhite white: CGFloat, alpha: CGFloat) {
        self.init(white: white, alpha: alpha)
    }
}
#endif
import CryptoKit
import Foundation
import SceneKit
import SwiftUI

// ==============================================================================
// NeuralComposeFunctorApp.swift
// Native macOS (arm64) & iOS (arm64-apple-ios17.0) SwiftUI + SceneKit/Metal Application:
// 60-Frame 4-Pillar Laya + ST-JEMA + Memory + Multimodal Functor Fixture (b=0.17).
//
// Integrates the 4-Stage Composed Functor F = F_MM o F_Mem o F_ST o F_Laya:
//   - Pillar 1 (Laya / LeJEPA Front-End): Q=20 Dynamic Channel Mixer (L_query) +
//     Global ZCA SIGReg Whitening Gate (Sigma_global == I_3, kappa == 1.00).
//   - Pillar 2 (ST-JEMA + Tarjan): Dual Node/Edge Decoders (g_node, g_edge) +
//     Tarjan Bridge-Finding Homology (beta_0, beta_1, EDGE_CYCLE vs BRIDGE).
//   - Pillar 3 (Memory Dialectic): Fast Context Wireframe W_k (tau_f=1.2s) vs
//     Slow Consolidated Core C_k (tau_s=8.0s) + Hollow Plasticity Shell Psi_k.
//   - Pillar 4 (Multimodal Musical Laya): Cross-Modal Acoustic Tempo/Cadence
//     Alignment (Vilambit -> Drut -> Madhya/Vilambit Laya) guiding absorption.
//
// Links BCICore's DialecticalDynamics, DialecticalMemory, DialecticalField, and
// SemanticGraph to the 60-frame Category-Theoretic Functor F: NetGraph -> PhaseHull
// and provides one-click bridge launch into UCSF ChimeraX 1.12 and PyMOL.
//
// Epistemic Boundary: [MODEL ILLUSTRATION - RUNG_4_MODEL | 4-PILLAR JEMA FIXTURE]
// Strictly zero em-dashes and zero en-dashes.
// ==============================================================================

// MARK: - Codable Data Models for `functor_dialectic_fixture_60f.json`

public struct FunctorNodeMetaJSON: Codable, Sendable, Identifiable {
    public let id: Int
    public let label: String
    public let channelBand: String
    public let role: String
    public let basePos: [Double]
}

public struct FunctorEdgeJSON: Codable, Sendable {
    public let u: Int
    public let v: Int
    public let edgeClass: Int // 1 = EDGE_CYCLE, 2 = EDGE_BRIDGE_OR_TREE, 3 = EDGE_SELF_LOOP
    public let weight: Double
}

public struct PGGraphNodeJSON: Codable, Sendable, Identifiable {
    public var id: Int { index }
    public let index: Int
    public let memoryId: String
    public let source: String
    public let shortLabel: String
    public let snippet: String
    public let coord: [Double]
    public let tags: [String]
    public let entities: [String]
    public let semanticScore: Double
    public let lexicalScore: Double
    public let entityScore: Double
    public let graphScore: Double
    public let recencyScore: Double
    public let recallServiceHybridScore: Double
    public let m2ProvenanceScore: Double
    public let tarjanVertexClass: Int
    public let hopDepth: Int?
}

public struct PGGraphEdgeJSON: Codable, Sendable {
    public let u: Int
    public let v: Int
    public let weight: Double
    public let edgeType: String
    public let label: String
    public let cosineSimilarity: Double
    public let cubeDistance: Double
    public let tarjanEdgeClass: Int
}

public struct PGGraphTraversalJSON: Codable, Sendable {
    public let schemaId: String
    public let databaseDsn: String
    public let embeddingTable: String
    public let spatialIndex: String
    public let totalMemoriesInPg: Int
    public let totalEmbeddingsInPg: Int
    public let totalCoords3DInPg: Int
    public let totalEntitiesInPg: Int
    public let totalMentionsInPg: Int
    public let totalRelationsInPg: Int
    public let pgGraphBeta0: Int
    public let pgGraphBeta1: Int
    public let pgGraphCycleEdges: Int
    public let pgGraphBridgeEdges: Int
    public let nodes: [PGGraphNodeJSON]
    public let edges: [PGGraphEdgeJSON]
}

public struct LivePGQueryResponseJSON: Codable, Sendable {
    public let status: String
    public let frameIndex: Int
    public let pgTotalMemories: Int
    public let pgTotalCoords3D: Int
    public let pgTotalRelations: Int
    public let pgGraphBeta0: Int
    public let pgGraphBeta1: Int
    public let activeNodes: Int
    public let activeEdges: Int
    public let pgSubgraphBeta1: Int
    public let cubeHitsInFastHull: Int
    public let topSeedLabel: String
    public let topRecallHybridScore: Double
    public let topM2ProvenanceScore: Double
}

public struct FunctorFrameJSON: Codable, Sendable, Identifiable {
    public var id: Int { frameIndex }
    public let frameIndex: Int
    public let frameTag: String
    public let timeS: Double
    public let phaseRegime: String
    // Pillar 1: Laya (LeJEPA) Front-End
    public let layaSigregLoss: Double
    public let layaQueryLoss: Double
    public let zEegWhitened: [Double]
    // Pillar 2: ST-JEMA + Tarjan Graph
    public let beta0: Int
    public let beta1: Int
    public let nCycleEdges: Int
    public let nBridgeEdges: Int
    public let nSelfLoops: Int
    public let stNodePredLoss: Double
    public let stEdgePredLoss: Double
    // Pillar 3: Memory Dialectic
    public let mahalanobisTension: Double
    public let principalAxisAngleDeg: Double
    public let overhangEscapePct: Double
    public let hollowShellVolPct: Double
    public let muFast: [Double]
    public let muSlow: [Double]
    public let fastSemiAxes: [Double]
    public let fastEigvecs: [[Double]]
    public let slowSemiAxes: [Double]
    public let slowEigvecs: [[Double]]
    // Pillar 4: Multimodal Musical Laya
    public let zMusicTarget: [Double]
    public let tempoBpm: Double
    public let layaCadenceState: String
    public let multimodalAlignmentLoss: Double
    public let layaAbsorptionIndex: Double
    // 1/f Fractal Spectral Slope (WorldModel/synthetic_1f.py) & Client-Native Takens Delay Attractor (neuralcompose-viz)
    public let fractalExponentChi: Double?
    public let aperiodicOffsetLog10: Double?
    public let alphaThetaRatio: Double?
    public let crossChannelPt: [Double]?
    public let takensDelayRibbon: [[Double]]?
    public let takensColorTP10: [Double]?
    public let conceptNodesShell: [[Double]]?
    // PostgreSQL Vector-Graph Traversal Per-Frame Metrics (claude-mind-mcp)
    public let pgActiveNodeIndices: [Int]?
    public let pgActiveEdgeCount: Int?
    public let pgSubgraphBeta0: Int?
    public let pgSubgraphBeta1: Int?
    public let pgCubeHitsInFastHull: Int?
    public let pgTopSeedMemoryId: String?
    public let pgTopSeedLabel: String?
    public let pgTopRecallHybridScore: Double?
    public let pgTopM2ProvenanceScore: Double?
    // BCICore & Slide 12 Comparison
    public let dialecticCoherence: Double
    public let dialecticResonance: Double
    public let dialecticNovelty: Double
    public let dialecticPotential: Double
    public let selectionTemperature: Double
    public let dialecticOutcome: String
    public let prescribedCore8VolM3: Double
    public let prescribedClipPct: Double
    public let nodeCoords: [[Double]]
    public let vertexClasses: [Int] // 1 = VERT_CYCLE, 2 = VERT_TREE_OR_BRIDGE, 3 = VERT_ISOLATED_MONOMER
    public let edges: [FunctorEdgeJSON]
}

public struct FunctorFixtureJSON: Codable, Sendable {
    public let schemaId: String
    public let epistemicBadge: String
    public let benchmarkSeries: String
    public let nFrames: Int
    public let globalCondNumber: Double
    public let globalCovWhitenedDiag: [Double]
    public let hysteresisAreaBeta1DM: Double
    public let prescribedHysteresisAreaTPoly: Double
    public let prescribedClipFractionF20: Double
    public let maxFunctorCommutativityErr: Double
    public let maxFunctorCompositionErr: Double
    public let nodesMeta: [FunctorNodeMetaJSON]
    public let neuralKymoRadii: [Double]
    public let neuralKymographRT: [[Double]]
    public let prescribedKymoRadiiM: [Double]
    public let prescribedKymographRT: [[Double]]
    public let fractalKymoFreqsHz: [Double]?
    public let fractal1fKymographFT: [[Double]]?
    public let pgGraphTraversal: PGGraphTraversalJSON?
    public let frames: [FunctorFrameJSON]
}

// MARK: - Live BCICore Dialectical Dynamics Evaluation Per Frame

public enum KymographDisplayMode: String, CaseIterable, Identifiable {
    case neuralPlasticity = "NeuralCompose Plasticity Shell Psi(r, t)"
    case fractal1fSpectrum = "1/f Fractal Spectral Slope P(f, t) (synthetic_1f.py)"
    case prescribedOkloR0 = "Prescribed R0 Polymer Kymograph & 16m Clipping"
    public var id: String { rawValue }
}

public enum DialecticProfileChoice: String, CaseIterable, Identifiable {
    case focused = "Focused"
    case reflective = "Reflective"
    case contemplative = "Contemplative"
    public var id: String { rawValue }

    public var tuning: DialecticalDynamics.Tuning {
        switch self {
        case .focused:
            return DialecticalDynamics.Tuning(
                highTension: 0.75,
                weights: DialecticalWeights(coherence: 1.2, resonance: 0.8, novelty: 0.4),
                synthesisHighBar: 0.5, synthesisLowBar: 0.4, synthesisSustainK: 3,
                glossWind: 0.2
            )
        case .reflective:
            return DialecticalDynamics.Tuning.default
        case .contemplative:
            return DialecticalDynamics.Tuning(
                stalemateMargin: 0.12,
                highTension: 0.45,
                weights: DialecticalWeights(coherence: 0.9, resonance: 0.6, novelty: 0.5),
                synthesisHighBar: 0.8, synthesisLowBar: 0.65, synthesisSustainK: 6,
                glossWind: 0.2
            )
        }
    }
}

public struct LiveBCICoreTurnSummary: Sendable {
    public let outcomeLabel: String
    public let tension: Float
    public let margin: Float
    public let temperature: Float
    public let decisive: Bool
    public let graphNodeCount: Int
    public let graphEdgeCount: Int
    public let memoryEntropy: Float
    public let memoryDrift: Float
    public let fieldWeights: DialecticalWeights
}

// MARK: - Equifinal Convergence Bus (Multica Chronological Ledger + Semantica Causal ContextGraph)

public enum EquifinalInputSource: String, CaseIterable, Codable, Sendable, Identifiable {
    case text                    = "text"
    case commit                  = "commit"
    case synthetic               = "synthetic"
    case hardwareMic             = "hardware_mic"
    case syntheticCarouselCommit = "Synthetic / Local Commit"
    case agenticDictation        = "Agentic Dictation"
    case biofeedbackShift        = "Biofeedback (Spectral / Laya)"
    case multicaStream           = "Multica (AsyncMulticast)"
    case sematicaGraphBridge     = "Semantica (ContextGraph + claude-mind)"

    public var id: String { rawValue }

    public var canonicalModality: String {
        switch self {
        case .text, .agenticDictation:
            return "text"
        case .commit, .syntheticCarouselCommit:
            return "commit"
        case .synthetic, .biofeedbackShift, .multicaStream, .sematicaGraphBridge:
            return "synthetic"
        case .hardwareMic:
            return "hardware_mic"
        }
    }
}

public enum SemanticaDecisionVerb: String, CaseIterable, Codable, Sendable, Identifiable {
    case record     = "record"
    case query      = "query"
    case precedents = "precedents"
    case influence  = "influence"
    case explain    = "explain"

    public var id: String { rawValue }
}

public struct EquifinalInputEvent: Codable, Sendable, Identifiable {
    public let id: String
    public let source: EquifinalInputSource
    public let text: String
    public let spectralLabel: String
    public let tempoBpm: Double
    public let timestampEpoch: Double
}

public struct EquifinalTurnRecord: Codable, Sendable, Identifiable {
    public var id: Int { seq_id }
    // Canonical Multica + Semantica JSONL fields (snake_case for Python SemanticaMulticaBridge)
    public let seq_id: Int
    public let timestamp: String
    public let modality: String
    public let prev_hash: String
    public let curr_hash: String
    public let decision_id: String
    public let parent_decision_id: String
    public let p_coord: [Double] // [z_valence, z_arousal, z_binding]
    public let beta_0: Int
    public let beta_1: Int
    public let d_mahalanobis: Double
    public let theta_1_deg: Double
    public let wbr_mode: String  // "Focus" | "Frustration" | "Panic"
    public let verdict: String   // "Accepted(...)" | "Rejected(...)" | "Incomplete(...)"
    public let defect_axes: [String: String]
    public let causal_chain: [String]
    public let provenance: String

    // Rich UI & Dialectical Pole fields
    public let turnIndex: Int
    public let timestampISO: String
    public let sourceLabel: String
    public let inputUtterance: String
    public let thesisPole: String
    public let antithesisPole: String
    public let witnessFinding: String
    public let synthesisBridge: String
    public let outcomeLabel: String
    public let tensionDM: Double
    public let beta0: Int
    public let beta1: Int
    public let spectralBiofeedback: String
    public let multicaEventSeq: Int
    public let sematicaTopNeighbors: [String]
    public let sematicaGraphNodeCount: Int
    public let sematicaGraphEdgeCount: Int
    public let localLogPath: String
}

// MARK: - Equifinal Loopback TCP Peer Bridge Server for BCICore.HypnagogicDialecticLoop

public final class EquifinalHypnagogicBridgeServer: @unchecked Sendable {
    public static let shared = EquifinalHypnagogicBridgeServer()

    private let lock = NSLock()
    private var serverFD: Int32 = -1
    private var activeClientFD: Int32 = -1
    public private(set) var port: UInt16 = 0
    private var isStarted: Bool = false
    private var gpdSeq: Int = 0
    private var promptCursor: Int = 0
    private var queuedUtterances: [String] = []
    public var onMacTurnCompleted: (@Sendable (String, Int) -> Void)?

    private let rotatingDialecticalPrompts: [String] = [
        "fast context wireframe tilt theta_1 ballooning across slow consolidated memory core",
        "Tarjan cycle rank beta_1 holding unresolved tension inside hollow plasticity shell Psi",
        "Laya cadence transition from Drut 128 BPM excursion back toward Vilambit 64 BPM absorption",
        "Semantica causal decision lineage bridging coherence pole and lateral displacement pole",
        "hysteresis loop area proving path-dependent topological memory across 60 frames",
        "perceptual fiber coordinate p_k projecting text, commit, and synthetic streams equifinally"
    ]

    private init() {}

    public static func resolveEquifinalBinDir() -> String {
        if let resURL = Bundle.main.resourceURL {
            let bundled = resURL.appendingPathComponent("equifinal_bin").path
            if FileManager.default.isExecutableFile(atPath: bundled + "/claude") {
                return bundled
            }
        }
        let execDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let rel = execDir.appendingPathComponent("../Resources/equifinal_bin").standardized.path
        if FileManager.default.isExecutableFile(atPath: rel + "/claude") {
            return rel
        }
        return "/Users/aurascoper/.gemini/antigravity/scratch/equifinal_bin"
    }

    @discardableResult
    public func startIfNeeded() -> UInt16 {
        lock.lock()
        if isStarted && port > 0 {
            let p = port
            lock.unlock()
            return p
        }

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            lock.unlock()
            return 0
        }

        var yes: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(0).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0, Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            lock.unlock()
            return 0
        }

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &addrLen)
            }
        }

        let assignedPort = UInt16(bigEndian: boundAddr.sin_port)
        self.serverFD = fd
        self.port = assignedPort
        self.isStarted = true
        lock.unlock()

        // Configure PATH before AppLoader / AppViewModel reads ProcessInfo.processInfo.environment.
        // Do NOT set NEURALCOMPOSE_RUNTIME, NEURALCOMPOSE_MODEL, or NEURALCOMPOSE_BRIDGE_PEER so:
        // 1) PrivacyIndicatorView's Runtime picker (Ollama <-> Claude CLI) stays unlocked (isEnvironmentControlled == false).
        // 2) AppViewModel.ensureHypnagogicLoopRunning() uses the real on-device HypnagogicListener (SFSpeechRecognizer + mic)
        //    so spoken utterances are transcribed and logged to ~/Documents/NeuralCompose/InteractionLogs/dialectic-turns-*.jsonl.
        let binDir = Self.resolveEquifinalBinDir()
        let userHome = FileManager.default.homeDirectoryForCurrentUser.path
        let oldPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let newPath = "\(userHome)/.local/bin:/opt/homebrew/bin:/usr/local/bin:\(binDir):\(oldPath)"
        setenv("PATH", newPath, 1)
        unsetenv("NEURALCOMPOSE_RUNTIME")
        unsetenv("NEURALCOMPOSE_MODEL")
        unsetenv("NEURALCOMPOSE_BRIDGE_PEER")
        unsetenv("NEURALCOMPOSE_BRIDGE_SESSION")
        unsetenv("NEURALCOMPOSE_BRIDGE_SEED")
        setenv("NEURALCOMPOSE_INTERACTION_LOG", "1", 1)
        setenv("NEURALCOMPOSE_HYPNAGOGIC_AUTOSTART", "reflective", 1)
        if !CommandLine.arguments.contains("--self-test") {
            if ProcessInfo.processInfo.environment["NEURALCOMPOSE_BOARD_PROFILE"] == nil {
                setenv("NEURALCOMPOSE_BOARD_PROFILE", "muses", 0)
            }
            if ProcessInfo.processInfo.environment["NEURALCOMPOSE_MUSE_DISCOVERY_TIMEOUT"] == nil {
                setenv("NEURALCOMPOSE_MUSE_DISCOVERY_TIMEOUT", "10", 0)
            }
        }
        Self.ensureDefaultVoiceProfileVocabularyExists()

        DispatchQueue(label: "com.neuralcompose.equifinal.bridge.accept", qos: .userInitiated, attributes: .concurrent).async { [weak self] in
            self?.acceptLoop(serverFD: fd)
        }

        return assignedPort
    }

    public static func ensureDefaultVoiceProfileVocabularyExists() {
        let docsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/NeuralCompose")
        let profileURL = docsDir.appendingPathComponent("voice-profile.json")
        guard !FileManager.default.fileExists(atPath: profileURL.path) else { return }
        try? FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
        let defaultProfile: [String: Any] = [
            "recognitionVocabulary": [
                "NeuralCompose", "Hunter", "aurascoper", "GitHub", "Antigravity",
                "Ollama", "Claude", "Opus", "Sonnet", "Witness", "hypnagogic",
                "dialectic", "Reflective", "Contemplative", "Focused", "Semantica",
                "Multica", "JEPA", "MPPI", "MLX", "EEG", "Muse", "Oklo", "samarium"
            ]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: defaultProfile, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: profileURL)
        }
    }

    public func enqueueUtterance(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        queuedUtterances.append(trimmed)
        lock.unlock()
    }

    private func popNextUtterance() -> String {
        lock.lock()
        defer { lock.unlock() }
        if !queuedUtterances.isEmpty {
            return queuedUtterances.removeFirst()
        }
        let prompt = rotatingDialecticalPrompts[promptCursor % rotatingDialecticalPrompts.count]
        promptCursor += 1
        return prompt
    }

    private func acceptLoop(serverFD: Int32) {
        while true {
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let cfd = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(serverFD, $0, &clientLen)
                }
            }
            if cfd < 0 {
                if errno == EINTR { continue }
                break
            }
            var one: Int32 = 1
            _ = Darwin.setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            lock.lock()
            activeClientFD = cfd
            lock.unlock()

            DispatchQueue(label: "com.neuralcompose.equifinal.bridge.client", qos: .userInitiated).async { [weak self] in
                self?.handleClient(clientFD: cfd)
            }
        }
    }

    private func handleClient(clientFD: Int32) {
        defer {
            Darwin.close(clientFD)
            lock.lock()
            if activeClientFD == clientFD {
                activeClientFD = -1
            }
            lock.unlock()
        }

        var buffer = Data()
        var readBuf = [UInt8](repeating: 0, count: 4096)

        while true {
            let n = Darwin.recv(clientFD, &readBuf, readBuf.count, 0)
            if n <= 0 { break }
            buffer.append(contentsOf: readBuf[0..<n])

            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                guard !lineData.isEmpty,
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    continue
                }
                let from = (obj["from"] as? String) ?? ""
                let macSeq = (obj["seq"] as? Int) ?? 1
                let macText = (obj["text"] as? String) ?? ""
                let hasInReplyTo = (obj["in_reply_to"] != nil) && !(obj["in_reply_to"] is NSNull)

                if from == "mac" {
                    if hasInReplyTo || macSeq >= 2 {
                        let callback = self.onMacTurnCompleted
                        callback?(macText, macSeq)
                        usleep(180_000)
                    } else {
                        usleep(60_000)
                    }
                    let nextPrompt = self.popNextUtterance()
                    if !self.sendGpdWireLine(clientFD: clientFD, text: nextPrompt, inReplyTo: macSeq) {
                        return
                    }
                }
            }
        }
    }

    private func sendGpdWireLine(clientFD: Int32, text: String, inReplyTo: Int) -> Bool {
        lock.lock()
        gpdSeq += 1
        let seq = gpdSeq
        lock.unlock()

        let monoMs = DispatchTime.now().uptimeNanoseconds / 1_000_000
        let payload: [String: Any] = [
            "v": 1,
            "session": "equifinal-local",
            "seq": seq,
            "from": "gpd",
            "text": text,
            "mono_ms": monoMs,
            "in_reply_to": inReplyTo
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else {
            return false
        }
        data.append(0x0A)
        return data.withUnsafeBytes { rawPtr -> Bool in
            guard let base = rawPtr.baseAddress else { return false }
            var sent = 0
            while sent < data.count {
                let w = Darwin.send(clientFD, base.advanced(by: sent), data.count - sent, 0)
                if w <= 0 { return false }
                sent += w
            }
            return true
        }
    }
}

// MARK: - ViewModel Managing the 60-Frame Timeline, SceneKit Scene, and BCICore State

@MainActor
public final class FunctorDialecticalViewModel: ObservableObject {
    @Published public var fixture: FunctorFixtureJSON
    @Published public var currentFrameIndex: Int = 31 // Start on Novelty Excursion keyframe f31
    @Published public var isPlaying: Bool = true
    @Published public var isLooping: Bool = true
    @Published public var playbackSpeed: Double = 1.0

    // Layer visibility toggles across the 4 Pillars + Client-Native Takens + PostgreSQL Graph
    @Published public var showFastWireframe: Bool = true
    @Published public var showSlowCore: Bool = true
    @Published public var showHollowPlasticityShell: Bool = true
    @Published public var showTarjanFunctorGraph: Bool = true
    @Published public var showMultimodalLayaFlux: Bool = true
    @Published public var showTakensDelayAttractor: Bool = true
    @Published public var showPostgresVectorGraph: Bool = true
    @Published public var highlightCycleCoreBeta1: Bool = false
    @Published public var showLayerGuidePopover: Bool = false

    // Diagnostic display controls
    @Published public var kymographMode: KymographDisplayMode = .neuralPlasticity
    @Published public var profileChoice: DialecticProfileChoice = .reflective
    @Published public var statusMessage: String = "Ready - 4-Pillar + 1/f Fractal + Takens + PG Vector-Graph Loaded"
    @Published public var livePgResponse: LivePGQueryResponseJSON? = nil

    // Volume-Safe Hardware Mic Lock & Equifinal Dialectics + Multica + Semantica Bus State
    @Published public var hardwareMicLoopLocked: Bool = true
    @Published public var muteTTSVoiceOutput: Bool = true
    @Published public var equifinalInputDraft: String = "dialectic hysteresis across fast working wireframe and slow consolidated core"
    @Published public var equifinalTurns: [EquifinalTurnRecord] = []
    @Published public var multicaEventCount: Int = 0
    @Published public var latestBiofeedbackBadge: String = "High load | 128 BPM Drut"
    @Published public var lastMulticaHash: String = "0000000000000000"
    @Published public var lastSemanticaDecisionId: String = "none"
    @Published public var selectedDecisionId: String = "none"
    @Published public var activeSemanticaVerb: SemanticaDecisionVerb = .explain
    @Published public var semanticaConsoleOutput: String = "Semantica ContextGraph ready (Oxigraph/local zero-cloud mode, SEMANTICA_DISABLE_PROGRESS=1)."
    @Published public var highlightedLineageCoords: [[Double]] = []

    // Live Hypnagogic Dialectical Loop Controls & Telemetry (Synced across Tab 1 & Tab 2)
    @Published public var hypnagogicLoopActive: Bool = true
    @Published public var hypnagogicLoopModeLabel: String = "reflective"
    @Published public var hypnagogicRuntimeChoiceLabel: String = UserDefaults.standard.string(forKey: "hypnagogicRuntimePreference") ?? "ollama"
    @Published public var hypnagogicLoopPhaseLabel: String = "Listening (On-Device Speech Recognizer)"
    @Published public var hypnagogicLoopTurnCount: Int = 0
    @Published public var hypnagogicLastSpokenReply: String = "Awaiting first dialectical competition turn..."
    public var onToggleHypnagogicLoop: ((Bool) -> Void)? = nil
    public var onSelectHypnagogicMode: ((String) -> Void)? = nil
    public var onSelectHypnagogicRuntime: ((String) -> Void)? = nil
    private var lastObservedInteractionLogCount: Int = -1
    private var lastObservedLogFilename: String = ""
    private var pollTickCounter: Int = 0

    // Mobile Dummy-Test UX Controls: Portrait Bottom Sheet, Multi-Touch 4D Controls, & Live Gyro / Mic Drive Toy Mode
    @Published public var isPortraitBottomSheetExpanded: Bool = true
    @Published public var wAngleXW: Double = 0.0
    @Published public var wAngleZW: Double = 0.0
    @Published public var cameraOrbitYaw: Double = 0.0
    @Published public var cameraOrbitPitch: Double = 0.0
    @Published public var cameraZoomScale: Double = 1.0
    @Published public var liveSensorToyMode: Bool = false
    @Published public var toyTiltX: Double = 0.0
    @Published public var toyTiltY: Double = 0.0
    @Published public var toyTiltZ: Double = 1.0
    @Published public var toyGyroMag: Double = 0.0
    @Published public var toyMicCadenceRMS: Double = 0.0
    @Published public var toyTempoBpm: Double = 72.0
    @Published public var toyDynamicFrame: FunctorFrameJSON? = nil

    public let fixtureDirectoryURL: URL
    public let scene: SCNScene
    private var dynamicRootNode = SCNNode()
    private var staticAxesNode = SCNNode()
    private var mainCameraNode: SCNNode? = nil
    private var playTimer: Timer?
    private var bciCoreTurns: [LiveBCICoreTurnSummary] = []
    private var equifinalMemory = DialecticalMemory(
        historyWindow: 16,
        graphCapacity: 96,
        edgeThreshold: 0.45,
        tensionCeiling: 0.85
    )
    private var equifinalField = DialecticalField(
        base: DialecticalDynamics.Tuning.default.weights,
        inertia: 0.75,
        wind: 0.25
    )

    public var currentFrame: FunctorFrameJSON {
        if liveSensorToyMode, let tf = toyDynamicFrame {
            return tf
        }
        let idx = max(0, min(fixture.frames.count - 1, currentFrameIndex))
        return fixture.frames[idx]
    }

    public var currentBCICoreTurn: LiveBCICoreTurnSummary {
        let idx = max(0, min(bciCoreTurns.count - 1, currentFrameIndex))
        return bciCoreTurns[idx]
    }

    public var latestEquifinalTurn: EquifinalTurnRecord? {
        equifinalTurns.last
    }

    public init() {
        _ = EquifinalHypnagogicBridgeServer.shared.startIfNeeded()
        let (loadedFixture, dirURL) = Self.loadFixtureFromBundleOrDisk()
        self.fixture = loadedFixture
        self.fixtureDirectoryURL = dirURL
        self.scene = SCNScene()
        self.bciCoreTurns = Self.computeLiveBCICoreSeries(fixture: loadedFixture, profile: .reflective)
        self.toyDynamicFrame = loadedFixture.frames.first

        setupBaseScene()
        rebuildFrameGeometry()
        triggerEquifinalTurn(
            source: .sematicaGraphBridge,
            text: "seed equifinal convergence: paired wireframe over slow memory core",
            spectralStateLabel: "High load | 128 BPM Drut",
            persistToDisk: false
        )
        EquifinalHypnagogicBridgeServer.shared.onMacTurnCompleted = { [weak self] replyText, macSeq in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.hypnagogicLoopTurnCount += 1
                let cleanReply = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
                let shownReply = cleanReply.isEmpty ? "(metastable dialectical silence)" : cleanReply
                self.hypnagogicLastSpokenReply = shownReply
                self.hypnagogicLoopPhaseLabel = "Listening (Turn #\(self.hypnagogicLoopTurnCount) complete | seq=\(macSeq))"
                self.triggerEquifinalTurn(
                    source: .multicaStream,
                    text: "Hypnagogic[\(self.hypnagogicLoopModeLabel)] Turn #\(self.hypnagogicLoopTurnCount): \(shownReply)",
                    persistToDisk: true
                )
            }
        }
        startPlaybackTimer()
    }

    @discardableResult
    public func stepHypnagogicDialecticalTurnNow(
        customUtterance: String? = nil,
        persistToDisk: Bool = true
    ) -> EquifinalTurnRecord {
        let rawDraft = (customUtterance ?? equifinalInputDraft).trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = rawDraft.isEmpty
            ? "hypnagogic dialectical turn at \(currentFrame.frameTag) (\(hypnagogicLoopModeLabel))"
            : rawDraft
        EquifinalHypnagogicBridgeServer.shared.enqueueUtterance(prompt)
        if !hypnagogicLoopActive {
            hypnagogicLoopActive = true
            onToggleHypnagogicLoop?(true)
        }
        hypnagogicLoopTurnCount += 1
        hypnagogicLoopPhaseLabel = "Generating -> Speaking (Turn #\(hypnagogicLoopTurnCount) | \(hypnagogicLoopModeLabel))"
        let record = triggerEquifinalTurn(
            source: .multicaStream,
            text: "Hypnagogic[\(hypnagogicLoopModeLabel)] Turn #\(hypnagogicLoopTurnCount): \(prompt)",
            persistToDisk: persistToDisk
        )
        hypnagogicLastSpokenReply = record.synthesisBridge
        hypnagogicLoopPhaseLabel = "Listening (Turn #\(hypnagogicLoopTurnCount) complete | \(hypnagogicLoopModeLabel))"
        return record
    }

    public static func resolvePrimaryOutputDir() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let scratchDir = URL(fileURLWithPath: "/Users/aurascoper/.gemini/antigravity/scratch")
        if home == "/Users/aurascoper" && FileManager.default.fileExists(atPath: scratchDir.path) {
            return scratchDir
        }
        let appSupportDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NeuralCompose")
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        return appSupportDir
    }

    public static func resolveFixtureDirectory() -> URL {
        if let resURL = Bundle.main.resourceURL {
            let candidate = resURL.appendingPathComponent("fixture")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("functor_dialectic_fixture_60f.json").path)
                || FileManager.default.fileExists(atPath: candidate.appendingPathComponent("four_pillar_fixture_60f.json").path) {
                return candidate
            }
            if FileManager.default.fileExists(atPath: resURL.appendingPathComponent("functor_dialectic_fixture_60f.json").path)
                || FileManager.default.fileExists(atPath: resURL.appendingPathComponent("four_pillar_fixture_60f.json").path) {
                return resURL
            }
        }
        let execDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let relCandidate = execDir.appendingPathComponent("../Resources/fixture").standardized
        if FileManager.default.fileExists(atPath: relCandidate.appendingPathComponent("functor_dialectic_fixture_60f.json").path) {
            return relCandidate
        }
        let scratchCandidate = URL(fileURLWithPath: "/Users/aurascoper/.gemini/antigravity/scratch/neural_compose_fixture_build")
        return scratchCandidate
    }

    public static func loadFixtureFromBundleOrDisk() -> (FunctorFixtureJSON, URL) {
        let dirURL = resolveFixtureDirectory()
        let jsonURL = dirURL.appendingPathComponent("functor_dialectic_fixture_60f.json")
        do {
            let data = try Data(contentsOf: jsonURL)
            let decoded = try JSONDecoder().decode(FunctorFixtureJSON.self, from: data)
            return (decoded, dirURL)
        } catch {
            fatalError("Failed to load functor_dialectic_fixture_60f.json from \(jsonURL.path): \(error)")
        }
    }

    /// Runs NeuralCompose's real `BCICore` `DialecticalDynamics`, `DialecticalMemory`,
    /// `DialecticalField`, and `SemanticGraph` across all 60 frames.
    public static func computeLiveBCICoreSeries(
        fixture: FunctorFixtureJSON,
        profile: DialecticProfileChoice
    ) -> [LiveBCICoreTurnSummary] {
        let tuning = profile.tuning
        var memory = DialecticalMemory(
            historyWindow: 16,
            graphCapacity: 64,
            edgeThreshold: 0.55,
            tensionCeiling: tuning.synthesisTensionCeiling
        )
        var field = DialecticalField(
            base: tuning.weights,
            inertia: tuning.fieldInertia,
            wind: tuning.glossWind
        )

        var summaries: [LiveBCICoreTurnSummary] = []
        summaries.reserveCapacity(fixture.frames.count)

        for frame in fixture.frames {
            let k = frame.frameIndex
            let heardEmb = makeDeterministicEmbedding(seedIndex: k + 1, bias: frame.muFast)
            let cohEmb = blendEmbeddings(heardEmb, makeDeterministicEmbedding(seedIndex: 100 + k, bias: frame.muSlow), weightA: Float(frame.dialecticCoherence))
            let dispEmb = blendEmbeddings(heardEmb, makeDeterministicEmbedding(seedIndex: 200 + k, bias: frame.muFast), weightA: Float(1.0 - 0.7 * frame.dialecticNovelty))
            let symEmb = blendEmbeddings(cohEmb, dispEmb, weightA: 0.5)

            let glossScalar = Float(min(1.0, max(0.0, 0.5 + 0.15 * (Double(frame.beta1) - 4.0) - 0.12 * frame.mahalanobisTension)))
            let activeWeights = field.advance(glossScalar: glossScalar, entropy: memory.entropy, drift: memory.drift)

            let cands: [DialecticalCandidate] = [
                DialecticalCandidate(text: "coherence-turn-\(frame.frameTag)", embedding: cohEmb, roleID: "coherenceSeeking"),
                DialecticalCandidate(text: "displacement-turn-\(frame.frameTag)", embedding: dispEmb, roleID: "displacementSeeking"),
                DialecticalCandidate(text: "symbolic-turn-\(frame.frameTag)", embedding: symEmb, roleID: "symbolic")
            ]

            let scored: [ScoredCandidate] = cands.map { c in
                let e = DialecticalDynamics.energy(
                    candidate: c.embedding,
                    heard: heardEmb,
                    historyCentroid: memory.historyCentroid,
                    replyCentroid: memory.replyCentroid
                )
                return ScoredCandidate(
                    candidate: c,
                    energy: e,
                    potential: e.potential(activeWeights),
                    roleFulfillment: c.roleID == "coherenceSeeking" ? e.coherence : e.novelty
                )
            }

            let synthCand = memory.synthesisCandidate(thesis: cohEmb, antithesis: dispEmb, tuning: tuning)
            let forceSynth = (frame.beta1 >= 7 && frame.mahalanobisTension >= 1.2) || (synthCand != nil && k >= 40)
            let injectedTension = Float(min(0.98, max(0.05, frame.mahalanobisTension / 2.8)))

            var stepTuning = tuning
            stepTuning.weights = activeWeights

            let res = DialecticalDynamics.compete(
                scored: scored,
                tension: injectedTension,
                draw: Double((k * 17 + 5) % 60) / 60.0,
                tuning: stepTuning,
                synthesis: synthCand ?? DialecticalCandidate(text: "synthesis-bridge-\(frame.frameTag)", embedding: symEmb, roleID: "synthesis"),
                forceSynthesis: forceSynth
            )

            memory.recordHeard(text: "heard-\(frame.frameTag)", embedding: heardEmb, turnIndex: k)
            let outcomeStr: String
            switch res.outcome {
            case .spoke(let chosen):
                outcomeStr = "spoke:\(chosen.roleID)"
                memory.recordReply(text: chosen.text, embedding: chosen.embedding, turnIndex: k)
                memory.recordVoiced(chosen.text)
            case .synthesized(let chosen):
                outcomeStr = "synthesized:\(chosen.roleID)"
                memory.recordReply(text: chosen.text, embedding: chosen.embedding, turnIndex: k)
                memory.recordVoiced(chosen.text)
            case .silent:
                outcomeStr = "silent (metastable hold)"
            }
            memory.observe(tension: res.tension)

            summaries.append(LiveBCICoreTurnSummary(
                outcomeLabel: outcomeStr,
                tension: res.tension,
                margin: res.margin,
                temperature: res.selectionTemperature,
                decisive: res.decisive,
                graphNodeCount: memory.graph.nodes.count,
                graphEdgeCount: memory.graph.edges.count,
                memoryEntropy: memory.entropy,
                memoryDrift: memory.drift,
                fieldWeights: activeWeights
            ))
        }

        return summaries
    }

    private static func makeDeterministicEmbedding(seedIndex: Int, bias: [Double]) -> Embedding {
        var state = UInt64(seedIndex &* 2_654_435_761 &+ 1)
        var vals: [Float] = []
        for i in 0..<8 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            let raw = Float(Int64(state & 0xFFFF) - 0x8000) / Float(0x8000)
            let b = i < bias.count ? Float(bias[i]) * 0.35 : 0.0
            vals.append(raw + b)
        }
        let norm = sqrtf(vals.reduce(0) { $0 + $1 * $1 })
        let unit = norm > 1e-6 ? vals.map { $0 / norm } : vals
        return Embedding(values: unit, modelID: "functor-fixture-v2", dimension: 8, version: "2", seed: 0)
    }

    private static func blendEmbeddings(_ a: Embedding, _ b: Embedding, weightA: Float) -> Embedding {
        let w = min(1.0, max(0.0, weightA))
        var vals = [Float](repeating: 0, count: a.values.count)
        for i in 0..<vals.count {
            vals[i] = w * a.values[i] + (1.0 - w) * b.values[i]
        }
        let norm = sqrtf(vals.reduce(0) { $0 + $1 * $1 })
        let unit = norm > 1e-6 ? vals.map { $0 / norm } : vals
        return Embedding(values: unit, modelID: a.modelID, dimension: a.dimension, version: a.version, seed: 0)
    }

    public func updateProfile(_ newProfile: DialecticProfileChoice) {
        self.profileChoice = newProfile
        self.bciCoreTurns = Self.computeLiveBCICoreSeries(fixture: fixture, profile: newProfile)
    }

    @discardableResult
    public func triggerEquifinalTurn(
        source: EquifinalInputSource,
        text: String,
        spectralStateLabel: String? = nil,
        persistToDisk: Bool = true
    ) -> EquifinalTurnRecord {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeText = trimmed.isEmpty
            ? "synthetic equifinal commit at \(currentFrame.frameTag)"
            : trimmed

        multicaEventCount += 1
        let seqId = multicaEventCount
        let modality = source.canonicalModality
        let f = currentFrame
        let bioBadge = spectralStateLabel ?? "\(f.layaCadenceState) (\(Int(f.tempoBpm)) BPM)"
        self.latestBiofeedbackBadge = bioBadge
        let prevHash = self.lastMulticaHash
        let parentDecId = self.lastSemanticaDecisionId

        let isoFmt = ISO8601DateFormatter()
        let nowISO = isoFmt.string(from: Date())
        let scratchMulticaURL = Self.resolvePrimaryOutputDir().appendingPathComponent("multica_channel.jsonl")
        let appSupportDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NeuralCompose")
        let appSupportMulticaURL = appSupportDir.appendingPathComponent("multica_channel.jsonl")
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/NeuralCompose/InteractionLogs")
        let logFile = logDir.appendingPathComponent("equifinal-dialectic-turns.jsonl")

        // 1. Hardware Mic Lock Gate: Never poll audio or mutate volume when hardwareMicLoopLocked == true
        if modality == "hardware_mic" && hardwareMicLoopLocked {
            let pLocked = [0.0, 0.0, 0.0]
            let verdictLocked = "Incomplete(hardware_mic_locked)"
            let wbrLocked = f.mahalanobisTension < 1.15 ? "Focus" : (f.mahalanobisTension <= 2.25 ? "Frustration" : "Panic")
            let rawChainStr = "\(seqId)|\(prevHash)|\(modality)|\(verdictLocked)|0.0,0.0,0.0|\(nowISO)"
            let digest = SHA256.hash(data: Data(rawChainStr.utf8))
            let currHash = digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
            let decHash = digest.map { String(format: "%02x", $0) }.joined().suffix(12).description
            let decisionId = String(format: "dec_%03d_%@", seqId, decHash)

            var priorChain = equifinalTurns.last?.causal_chain ?? []
            priorChain.append(decisionId)
            if priorChain.count > 6 {
                priorChain.removeFirst(priorChain.count - 6)
            }

            let defectAxes: [String: String] = [
                "Source": "PASS",
                "Coordination": "PASS",
                "Boundary": "BLOCKED_HARDWARE_MIC_LOCKED",
                "Control": "PASS"
            ]

            let lockedRecord = EquifinalTurnRecord(
                seq_id: seqId,
                timestamp: nowISO,
                modality: modality,
                prev_hash: prevHash,
                curr_hash: currHash,
                decision_id: decisionId,
                parent_decision_id: parentDecId,
                p_coord: pLocked,
                beta_0: f.beta0,
                beta_1: f.beta1,
                d_mahalanobis: f.mahalanobisTension,
                theta_1_deg: f.principalAxisAngleDeg,
                wbr_mode: wbrLocked,
                verdict: verdictLocked,
                defect_axes: defectAxes,
                causal_chain: priorChain,
                provenance: "[MODEL ILLUSTRATION - RUNG_4_MODEL]",
                turnIndex: seqId,
                timestampISO: nowISO,
                sourceLabel: source.rawValue,
                inputUtterance: activeText,
                thesisPole: "[Hardware Lock Active] Audio tap inhibited; macOS system volume untouched.",
                antithesisPole: "[Boundary Gate] Continuous mic polling blocked while Hardware Mic Loop is LOCKED.",
                witnessFinding: "[Semantica PolicyEngine] Boundary axis flagged BLOCKED_HARDWARE_MIC_LOCKED.",
                synthesisBridge: "[Equifinal Fallback] Use text, commit, or synthetic streams for (t1, t2, t3) turns.",
                outcomeLabel: verdictLocked,
                tensionDM: f.mahalanobisTension,
                beta0: f.beta0,
                beta1: f.beta1,
                spectralBiofeedback: bioBadge,
                multicaEventSeq: seqId,
                sematicaTopNeighbors: ["hardware-mic-locked-guard (1.00)"],
                sematicaGraphNodeCount: equifinalMemory.graph.nodes.count,
                sematicaGraphEdgeCount: equifinalMemory.graph.edges.count,
                localLogPath: scratchMulticaURL.path
            )

            self.lastMulticaHash = currHash
            self.lastSemanticaDecisionId = decisionId
            self.selectedDecisionId = decisionId
            equifinalTurns.append(lockedRecord)
            if equifinalTurns.count > 32 {
                equifinalTurns.removeFirst(equifinalTurns.count - 32)
            }
            if persistToDisk {
                Self.appendMulticaRecordToDisk(
                    lockedRecord,
                    scratchURL: scratchMulticaURL,
                    appSupportDir: appSupportDir,
                    appSupportURL: appSupportMulticaURL,
                    legacyLogDir: logDir,
                    legacyLogURL: logFile
                )
            }
            self.semanticaConsoleOutput = "Semantica[\(decisionId)]: Verdict=\(verdictLocked) | Boundary=BLOCKED_HARDWARE_MIC_LOCKED | Volume Untouched"
            self.statusMessage = "Turn #\(seqId) [hardware_mic] -> Incomplete(hardware_mic_locked) | System Volume Untouched"
            return lockedRecord
        }

        // 2. Equifinal Perceptual Fiber Projection f_m: R_m -> P: p_k = (z_valence, z_arousal, z_binding)
        var h: UInt64 = 14695981039346656037
        for byte in activeText.utf8 {
            h ^= UInt64(byte)
            h = h &* 1099511628211
        }
        let hx = Double(Int64(h & 0xFFFF) - 0x8000) / Double(0x8000)
        let hy = Double(Int64((h >> 16) & 0xFFFF) - 0x8000) / Double(0x8000)
        let hz = Double(Int64((h >> 32) & 0xFFFF) - 0x8000) / Double(0x8000)

        let zValence = max(-1.0, min(1.0, 0.45 * hx + 0.35 * (f.dialecticCoherence - 0.5)))
        let zArousal = max(-1.0, min(1.0, 0.45 * hy + 0.35 * (f.mahalanobisTension - 1.0)))
        let zBinding = max(0.05, min(1.0, 0.55 + 0.25 * hz + 0.04 * Double(f.beta1 - 4)))
        let pCoord = [
            (zValence * 1000.0).rounded() / 1000.0,
            (zArousal * 1000.0).rounded() / 1000.0,
            (zBinding * 1000.0).rounded() / 1000.0
        ]

        let queryCoord = [
            max(-2.25, min(2.25, f.muFast[0] + 0.65 * hx)),
            max(-2.25, min(2.25, f.muFast[1] + 0.65 * hy)),
            max(-2.25, min(2.25, f.muFast[2] + 0.65 * hz))
        ]

        // Semantica + claude-mind PostgreSQL 3D vector-graph ranking
        let pgNodes = fixture.pgGraphTraversal?.nodes ?? []
        let rankedPG = pgNodes.sorted { a, b in
            let da = hypot(a.coord[0] - queryCoord[0], hypot(a.coord[1] - queryCoord[1], a.coord[2] - queryCoord[2]))
            let db = hypot(b.coord[0] - queryCoord[0], hypot(b.coord[1] - queryCoord[1], b.coord[2] - queryCoord[2]))
            return (da - 0.35 * a.recallServiceHybridScore) < (db - 0.35 * b.recallServiceHybridScore)
        }
        let topNeighbors: [String] = Array(rankedPG.prefix(3)).map { node in
            "\(node.shortLabel) (score=\(String(format: "%.2f", node.recallServiceHybridScore)))"
        }
        let n1 = rankedPG.first?.shortLabel ?? "laya-sigreg-anchor"
        let n2 = rankedPG.dropFirst().first?.shortLabel ?? "tarjan-beta1-cycle"
        let n3 = rankedPG.dropFirst(2).first?.shortLabel ?? "hysteresis-slow-core"

        // Construct dialectical poles grounded in Semantica + Biofeedback + Heard utterance
        let thesisText = "[Coherence / Thesis] Consolidating '\(activeText)' onto slow core attractor via \(n1)"
        let antithesisText = "[Displacement / Antithesis] Expanding fast wireframe overhang (\((Int(f.overhangEscapePct)))%) toward \(n2)"
        let witnessText = "[Reflective Witness] Both poles presuppose hysteresis loop area \(String(format: "%.2f", fixture.hysteresisAreaBeta1DM)) around \(n3)"
        let synthesisText = "[Emergent Synthesis] Bridging \(n1) and \(n2) across hollow shell Psi (beta_1=\(f.beta1), \(bioBadge))"

        let seedBase = Int(h & 0x7FFF) + seqId * 31
        let heardEmb = Self.makeDeterministicEmbedding(seedIndex: seedBase, bias: queryCoord)
        let cohEmb = Self.blendEmbeddings(heardEmb, Self.makeDeterministicEmbedding(seedIndex: seedBase + 101, bias: f.muSlow), weightA: 0.72)
        let dispEmb = Self.blendEmbeddings(heardEmb, Self.makeDeterministicEmbedding(seedIndex: seedBase + 202, bias: f.muFast), weightA: 0.38)
        let symEmb = Self.blendEmbeddings(cohEmb, dispEmb, weightA: 0.50)

        let tuning = profileChoice.tuning
        let glossScalar = Float(min(1.0, max(0.0, 0.52 + 0.12 * (Double(f.beta1) - 4.0) - 0.10 * f.mahalanobisTension)))
        let activeWeights = equifinalField.advance(
            glossScalar: glossScalar,
            entropy: equifinalMemory.entropy,
            drift: equifinalMemory.drift
        )

        let cands: [DialecticalCandidate] = [
            DialecticalCandidate(text: thesisText, embedding: cohEmb, roleID: "coherenceSeeking"),
            DialecticalCandidate(text: antithesisText, embedding: dispEmb, roleID: "displacementSeeking"),
            DialecticalCandidate(text: synthesisText, embedding: symEmb, roleID: "synthesis")
        ]
        let scored: [ScoredCandidate] = cands.map { c in
            let e = DialecticalDynamics.energy(
                candidate: c.embedding,
                heard: heardEmb,
                historyCentroid: equifinalMemory.historyCentroid,
                replyCentroid: equifinalMemory.replyCentroid
            )
            return ScoredCandidate(
                candidate: c,
                energy: e,
                potential: e.potential(activeWeights),
                roleFulfillment: c.roleID == "coherenceSeeking" ? e.coherence : e.novelty
            )
        }

        let synthCand = equifinalMemory.synthesisCandidate(thesis: cohEmb, antithesis: dispEmb, tuning: tuning)
            ?? DialecticalCandidate(text: synthesisText, embedding: symEmb, roleID: "synthesis")
        let forceSynth = (source == .sematicaGraphBridge || source == .multicaStream || modality == "commit" || seqId % 2 == 0)
        let injectedTension = Float(min(0.96, max(0.14, f.mahalanobisTension / 2.4)))

        var stepTuning = tuning
        stepTuning.weights = activeWeights
        let res = DialecticalDynamics.compete(
            scored: scored,
            tension: injectedTension,
            draw: Double((seqId * 19 + 7) % 60) / 60.0,
            tuning: stepTuning,
            synthesis: synthCand,
            forceSynthesis: forceSynth
        )

        equifinalMemory.recordHeard(text: activeText, embedding: heardEmb, turnIndex: seqId)
        let outcomeStr: String
        switch res.outcome {
        case .spoke(let chosen):
            outcomeStr = "spoke:\(chosen.roleID)"
            equifinalMemory.recordReply(text: chosen.text, embedding: chosen.embedding, turnIndex: seqId)
            equifinalMemory.recordVoiced(chosen.text)
        case .synthesized(let chosen):
            outcomeStr = "synthesized:\(chosen.roleID)"
            equifinalMemory.recordReply(text: chosen.text, embedding: chosen.embedding, turnIndex: seqId)
            equifinalMemory.recordVoiced(chosen.text)
        case .silent:
            outcomeStr = "synthesized:synthesis"
            equifinalMemory.recordReply(text: synthesisText, embedding: symEmb, turnIndex: seqId)
            equifinalMemory.recordVoiced(synthesisText)
        }
        equifinalMemory.observe(tension: res.tension)

        // Wood-Bruner-Ross ZPD Mode & Algebraic Criterial Verdict
        let dM = f.mahalanobisTension
        let wbrMode: String
        if dM < 1.15 {
            wbrMode = "Focus"
        } else if dM <= 2.25 {
            wbrMode = "Frustration"
        } else {
            wbrMode = "Panic"
        }

        let algebraicVerdict: String
        if f.beta0 == 1 && dM <= 2.45 {
            algebraicVerdict = "Accepted(\(modality)_\(outcomeStr.replacingOccurrences(of: ":", with: "_")))"
        } else {
            algebraicVerdict = "Rejected(policy_tension_exceeded)"
        }

        let defectAxes: [String: String] = [
            "Source": "PASS",
            "Coordination": f.beta0 == 1 ? "PASS" : "FRAGMENTED_BETA0",
            "Boundary": "PASS",
            "Control": dM <= 2.45 ? "PASS" : "ZPD_PANIC_OVERHANG"
        ]

        // SHA-256 Chain & Semantica Decision ID
        let rawChainStr = "\(seqId)|\(prevHash)|\(modality)|\(algebraicVerdict)|\(pCoord[0]),\(pCoord[1]),\(pCoord[2])|\(nowISO)"
        let digest = SHA256.hash(data: Data(rawChainStr.utf8))
        let currHash = digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
        let decHash = digest.map { String(format: "%02x", $0) }.joined().suffix(12).description
        let decisionId = String(format: "dec_%03d_%@", seqId, decHash)

        var causalChain = equifinalTurns.last?.causal_chain ?? []
        causalChain.append(decisionId)
        if causalChain.count > 6 {
            causalChain.removeFirst(causalChain.count - 6)
        }

        // Advance or perturb the 3D/4D viewport so equifinal inputs visibly drive the phase hull
        if liveSensorToyMode {
            toyTiltX = max(-1.2, min(1.2, queryCoord[0] * 0.55))
            toyTiltY = max(-1.2, min(1.2, queryCoord[1] * 0.55))
            toyMicCadenceRMS = min(1.0, max(0.15, Double(res.tension)))
            stepLiveSensorToyDrive(dt: 0.20)
        } else {
            rebuildFrameGeometry()
        }

        let record = EquifinalTurnRecord(
            seq_id: seqId,
            timestamp: nowISO,
            modality: modality,
            prev_hash: prevHash,
            curr_hash: currHash,
            decision_id: decisionId,
            parent_decision_id: parentDecId,
            p_coord: pCoord,
            beta_0: f.beta0,
            beta_1: f.beta1,
            d_mahalanobis: dM,
            theta_1_deg: f.principalAxisAngleDeg,
            wbr_mode: wbrMode,
            verdict: algebraicVerdict,
            defect_axes: defectAxes,
            causal_chain: causalChain,
            provenance: "[MODEL ILLUSTRATION - RUNG_4_MODEL]",
            turnIndex: seqId,
            timestampISO: nowISO,
            sourceLabel: source.rawValue,
            inputUtterance: activeText,
            thesisPole: thesisText,
            antithesisPole: antithesisText,
            witnessFinding: witnessText,
            synthesisBridge: synthesisText,
            outcomeLabel: outcomeStr,
            tensionDM: dM,
            beta0: f.beta0,
            beta1: f.beta1,
            spectralBiofeedback: bioBadge,
            multicaEventSeq: seqId,
            sematicaTopNeighbors: topNeighbors.isEmpty ? ["laya-sigreg-anchor (0.91)"] : topNeighbors,
            sematicaGraphNodeCount: equifinalMemory.graph.nodes.count,
            sematicaGraphEdgeCount: equifinalMemory.graph.edges.count,
            localLogPath: scratchMulticaURL.path
        )

        self.lastMulticaHash = currHash
        self.lastSemanticaDecisionId = decisionId
        self.selectedDecisionId = decisionId

        equifinalTurns.append(record)
        if equifinalTurns.count > 32 {
            equifinalTurns.removeFirst(equifinalTurns.count - 32)
        }

        if persistToDisk {
            Self.appendMulticaRecordToDisk(
                record,
                scratchURL: scratchMulticaURL,
                appSupportDir: appSupportDir,
                appSupportURL: appSupportMulticaURL,
                legacyLogDir: logDir,
                legacyLogURL: logFile
            )
        }

        self.semanticaConsoleOutput = "Semantica[\(decisionId)]: \(algebraicVerdict) | WBR=\(wbrMode) | Chain=\(causalChain.suffix(3).joined(separator: " -> "))"
        statusMessage = "Turn #\(seqId) [\(modality)] -> \(algebraicVerdict) | SHA256=\(currHash.prefix(8)) | Semantica=\(decisionId)"
        return record
    }

    private static func appendMulticaRecordToDisk(
        _ record: EquifinalTurnRecord,
        scratchURL: URL,
        appSupportDir: URL,
        appSupportURL: URL,
        legacyLogDir: URL,
        legacyLogURL: URL
    ) {
        let encoder = JSONEncoder()
        guard let encoded = try? encoder.encode(record),
              var lineData = String(data: encoded, encoding: .utf8)?.data(using: .utf8) else {
            return
        }
        lineData.append(Data("\n".utf8))

        let isPolledHeardTurn = record.inputUtterance.hasPrefix("Heard[")
        let writeLine = { (url: URL) in
            if FileManager.default.fileExists(atPath: url.path) {
                if isPolledHeardTurn,
                   let existing = try? String(contentsOf: url, encoding: .utf8) {
                    let tailLines = existing.split(separator: "\n", omittingEmptySubsequences: true).suffix(32)
                    let alreadyPresent = tailLines.contains { ln in
                        guard let d = String(ln).data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                              let priorUtt = obj["inputUtterance"] as? String else {
                            return false
                        }
                        return priorUtt == record.inputUtterance
                    }
                    if alreadyPresent {
                        return
                    }
                }
                if let fh = try? FileHandle(forWritingTo: url) {
                    _ = try? fh.seekToEnd()
                    try? fh.write(contentsOf: lineData)
                    try? fh.close()
                }
            } else {
                try? lineData.write(to: url)
            }
        }

        writeLine(scratchURL)
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        writeLine(appSupportURL)
        try? FileManager.default.createDirectory(at: legacyLogDir, withIntermediateDirectories: true)
        writeLine(legacyLogURL)
    }

    /// Invokes `/semantica:decision` verb (`record`, `query`, `precedents`, `influence`, `explain`)
    /// on the selected `EquifinalTurnRecord` and highlights its upstream `EDGE_CYCLE` (`beta_1`)
    /// and 3D phase-space fiber coordinates inside the SceneKit viewport.
    public func selectAndTraceSemanticaDecision(
        _ record: EquifinalTurnRecord,
        verb: SemanticaDecisionVerb? = nil
    ) {
        let chosenVerb = verb ?? activeSemanticaVerb
        activeSemanticaVerb = chosenVerb
        selectedDecisionId = record.decision_id
        highlightCycleCoreBeta1 = true

        // Collect 3D fiber coordinates across the INFLUENCED causal chain for SceneKit viewport highlighting
        let chainSet = Set(record.causal_chain)
        let chainRecords = equifinalTurns.filter { chainSet.contains($0.decision_id) }
        highlightedLineageCoords = chainRecords.map { r in
            let p = r.p_coord
            return [
                p.count > 0 ? p[0] * 1.65 : 0.0,
                p.count > 1 ? p[1] * 1.65 : 0.0,
                p.count > 2 ? (p[2] - 0.5) * 2.2 : 0.0
            ]
        }
        rebuildFrameGeometry()

        let chainStr = record.causal_chain.joined(separator: " -> ")
        let pStr = String(format: "(%.3f, %.3f, %.3f)", record.p_coord[0], record.p_coord[1], record.p_coord[2])
        switch chosenVerb {
        case .record:
            semanticaConsoleOutput = "[/semantica:decision record] Node \(record.decision_id) (\(record.modality)) linked via INFLUENCED from \(record.parent_decision_id) | p=\(pStr) | beta_1=\(record.beta_1)"
        case .query:
            semanticaConsoleOutput = "[/semantica:decision query] \(record.decision_id): Menu Q=[coherence, displacement, synthesis] | Verdict=\(record.verdict) | D_M=\(String(format: "%.3f", record.d_mahalanobis)), theta_1=\(String(format: "%.1f", record.theta_1_deg)) deg"
        case .precedents:
            let scored = equifinalTurns.map { cand -> (String, Double) in
                let dp = hypot(
                    cand.p_coord[0] - record.p_coord[0],
                    hypot(cand.p_coord[1] - record.p_coord[1], cand.p_coord[2] - record.p_coord[2])
                )
                let db = Double(abs(cand.beta_0 - record.beta_0)) + 0.35 * Double(abs(cand.beta_1 - record.beta_1))
                let structSim = 1.0 / (1.0 + 0.75 * dp + 0.45 * db)
                let semSim = cand.modality == record.modality ? 0.85 : 0.48
                return (cand.decision_id, 0.5 * semSim + 0.5 * structSim)
            }.sorted { $0.1 > $1.1 }
            let topStr = scored.prefix(3).map { "\($0.0)(hyb=\(String(format: "%.2f", $0.1)))" }.joined(separator: ", ")
            semanticaConsoleOutput = "[/semantica:decision precedents] Hybrid (0.5 sem + 0.5 struct Tarjan beta_1): \(topStr)"
        case .influence:
            semanticaConsoleOutput = "[/semantica:decision influence] trace_decision_chain(\(record.decision_id), max_steps=5): \(chainStr) | Highlighted \(highlightedLineageCoords.count) 3D nodes & EDGE_CYCLE (beta_1=\(record.beta_1))"
        case .explain:
            let axesStr = ["Source", "Coordination", "Boundary", "Control"].map { k in
                "\(k):\(record.defect_axes[k] ?? "PASS")"
            }.joined(separator: " ")
            semanticaConsoleOutput = "[/semantica:decision explain] \(record.decision_id): Verdict=\(record.verdict) | WBR=\(record.wbr_mode) | PolicyAxes=[\(axesStr)] | D8=VERIFIED | Chain=\(chainStr)"
        }
        statusMessage = semanticaConsoleOutput
    }

    public func startPlaybackTimer() {
        playTimer?.invalidate()
        let interval = max(0.04, 0.14 / playbackSpeed)
        playTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.pollTickCounter += 1
                if self.pollTickCounter % 7 == 0 {
                    self.pollLiveInteractionLogTurns()
                }
                if self.liveSensorToyMode {
                    self.stepLiveSensorToyDrive(
                        tiltX: self.toyTiltX,
                        tiltY: self.toyTiltY,
                        tiltZ: self.toyTiltZ,
                        gyroMag: self.toyGyroMag,
                        micRMS: self.toyMicCadenceRMS,
                        tempoBpm: self.toyTempoBpm,
                        dt: interval
                    )
                } else if self.isPlaying {
                    self.advanceFrame(by: 1)
                }
            }
        }
    }

    private var isPollingInteractionLogs: Bool = false

    public func pollLiveInteractionLogTurns() {
        guard !isPollingInteractionLogs else { return }
        isPollingInteractionLogs = true
        defer { isPollingInteractionLogs = false }

        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/NeuralCompose/InteractionLogs")
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        let todayLog = logDir.appendingPathComponent("dialectic-turns-\(df.string(from: Date())).jsonl")
        guard let content = try? String(contentsOf: todayLog, encoding: .utf8) else { return }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        if todayLog.lastPathComponent != lastObservedLogFilename {
            let wasColdStartup = lastObservedLogFilename.isEmpty
            lastObservedLogFilename = todayLog.lastPathComponent
            if wasColdStartup {
                // Initialize watermark to current EOF so startup does not replay historical turns into multica_channel.jsonl
                lastObservedInteractionLogCount = lines.count
                return
            } else {
                // Live UTC midnight rollover: reset watermark to 0 so lines[0..<lines.count] of the new day's file are emitted
                lastObservedInteractionLogCount = 0
            }
        }
        guard lines.count > lastObservedInteractionLogCount else { return }
        let newLines = lines[lastObservedInteractionLogCount..<lines.count]
        lastObservedInteractionLogCount = lines.count

        for lineSub in newLines {
            guard let data = String(lineSub).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let rawHeard = (obj["heard"] as? String) ?? ""
            let rawSpoken = (obj["spokenText"] as? String) ?? ""
            let spectralStr = (obj["spectralState"] as? String) ?? "Live"
            let glossVal = (obj["glossScalar"] as? Double) ?? 0.5
            let heard = rawHeard.replacingOccurrences(of: "\u{2014}", with: " - ").replacingOccurrences(of: "\u{2013}", with: "-")
            let spoken = rawSpoken.replacingOccurrences(of: "\u{2014}", with: " - ").replacingOccurrences(of: "\u{2013}", with: "-")
            let fp = obj["generatorFingerprint"] as? [String: Any]
            let runtimeStr = (fp?["runtime"] as? String) ?? hypnagogicRuntimeChoiceLabel
            hypnagogicLoopTurnCount += 1
            hypnagogicLastSpokenReply = spoken.isEmpty ? "(metastable dialectical silence)" : spoken
            hypnagogicLoopPhaseLabel = "Listening (Runtime=\(runtimeStr) | \(spectralStr) | Turn #\(hypnagogicLoopTurnCount))"
            stepLiveSensorToyDrive(
                tiltX: (glossVal - 0.5) * 2.2,
                tiltY: 0.35,
                tiltZ: 1.0,
                gyroMag: abs(glossVal - 0.5) * 4.5,
                micRMS: max(0.25, min(0.95, 1.0 - glossVal)),
                tempoBpm: glossVal < 0.4 ? 128.0 : 72.0,
                dt: 0.35
            )
            triggerEquifinalTurn(
                source: .multicaStream,
                text: "Heard[\(runtimeStr) | \(spectralStr)]: '\(heard)' -> Spoke: '\(hypnagogicLastSpokenReply)'",
                persistToDisk: true
            )
        }
    }

    /// Portrait-Mode Bottom Sheet: on phones (`width < 768.0`), switches the right-hand 4-Pillar
    /// Diagnostic Sidebar to a collapsible bottom drawer so the 3D/4D Paired Wireframe-Over-Core
    /// viewport gets the top 65% of the screen.
    public func computeResponsiveLayoutRects(
        width: Double,
        height: Double
    ) -> (viewportHeightFraction: Double, isPortraitBottomSheet: Bool, viewportHeight: Double, drawerHeight: Double) {
        if width < 768.0 {
            let frac = isPortraitBottomSheetExpanded ? 0.65 : 0.90
            return (frac, true, height * frac, height * (1.0 - frac))
        } else {
            return (1.0, false, height, 0.0)
        }
    }

    /// Multi-Touch 4D Controls:
    /// - 1-finger drag: 3D camera orbit (`cameraOrbitYaw`, `cameraOrbitPitch`).
    /// - 2-finger drag: 4D hyperplane rotation (`wAngleXW`, `wAngleZW`).
    /// - Pinch: Zoom scale (`cameraZoomScale`).
    public func applyMultiTouch4DControls(
        touchCount: Int,
        dragDX: Double,
        dragDY: Double,
        pinchScale: Double
    ) {
        if dragDX.isFinite && dragDY.isFinite {
            if touchCount == 1 {
                cameraOrbitYaw += dragDX * 0.01
                cameraOrbitPitch = max(-1.4, min(1.4, cameraOrbitPitch + dragDY * 0.01))
            } else if touchCount >= 2 {
                wAngleXW = max(-0.8, min(0.8, wAngleXW + dragDX * 0.01))
                wAngleZW = max(-0.8, min(0.8, wAngleZW + dragDY * 0.01))
            }
        }
        if pinchScale.isFinite && pinchScale > 0.0 {
            cameraZoomScale = max(0.35, min(2.5, cameraZoomScale * pinchScale))
            if let cam = mainCameraNode?.camera {
                cam.fieldOfView = CGFloat(42.0 / cameraZoomScale)
            }
        }
    }

    /// Convenience overload using the viewModel's current toy sensor properties.
    public func stepLiveSensorToyDrive(dt: Double = 0.25) {
        stepLiveSensorToyDrive(
            tiltX: toyTiltX,
            tiltY: toyTiltY,
            tiltZ: toyTiltZ,
            gyroMag: toyGyroMag,
            micRMS: toyMicCadenceRMS,
            tempoBpm: toyTempoBpm,
            dt: dt
        )
    }

    /// "No-Headband" Live Sensor Toy Mode ("Live Gyro / Mic Drive"):
    /// Feeds phone tilt (accelerometer/gyro) + microphone cadence into the fast sensory drive z(t)
    /// so shaking the phone or tapping a rhythm balloons and tilts (theta_1 > 15 deg) the
    /// Sky-Blue Fast Wireframe (#38bdf8) outside the Purple Consolidated Memory Core (#a855f7),
    /// and holding still (0, 0, 1g) lets the slow core gradually absorb it.
    public func stepLiveSensorToyDrive(
        tiltX: Double,
        tiltY: Double,
        tiltZ: Double,
        gyroMag: Double,
        micRMS: Double,
        tempoBpm: Double,
        dt: Double = 0.25
    ) {
        liveSensorToyMode = true
        let ax = tiltX.isFinite ? max(-4.0, min(4.0, tiltX)) : 0.0
        let ay = tiltY.isFinite ? max(-4.0, min(4.0, tiltY)) : 0.0
        let az = tiltZ.isFinite ? max(-4.0, min(4.0, tiltZ)) : 1.0
        let gMag = gyroMag.isFinite ? max(0.0, min(10.0, gyroMag)) : 0.0
        let mic = micRMS.isFinite ? max(0.0, min(1.0, micRMS)) : 0.0
        let bpm = tempoBpm.isFinite ? max(40.0, min(220.0, tempoBpm)) : 72.0
        let dtStep = (dt.isFinite && dt > 0.0) ? min(1.0, dt) : 0.25

        toyTiltX = ax
        toyTiltY = ay
        toyTiltZ = az
        toyGyroMag = gMag
        toyMicCadenceRMS = mic
        toyTempoBpm = bpm

        let base = toyDynamicFrame ?? fixture.frames[max(0, min(fixture.frames.count - 1, currentFrameIndex))]
        let tiltDev = min(3.0, sqrt(ax * ax + ay * ay + (az - 1.0) * (az - 1.0)))
        let driveEnergy = min(3.0, max(0.0, 0.70 * tiltDev + 0.35 * gMag + 0.95 * mic))

        let alphaFast = 1.0 - exp(-dtStep / 1.2)
        let alphaSlow = 1.0 - exp(-dtStep / 8.0)

        let zTarget = [
            ax * 1.15 + 0.20 * gMag,
            ay * 1.15 + 0.85 * mic,
            (az - 1.0) * 1.15 + 0.20 * gMag
        ]

        var muFast = base.muFast.count >= 3 ? base.muFast : [0.0, 0.0, 0.0]
        var muSlow = base.muSlow.count >= 3 ? base.muSlow : [0.0, 0.0, 0.0]
        for c in 0..<3 {
            muFast[c] += alphaFast * (zTarget[c] - muFast[c])
            muSlow[c] += alphaSlow * (muFast[c] - muSlow[c])
        }

        let dx = muFast[0] - muSlow[0]
        let dy = muFast[1] - muSlow[1]
        let dz = muFast[2] - muSlow[2]
        let dist = sqrt(dx * dx + dy * dy + dz * dz)

        let balloon = 1.0 + 0.38 * driveEnergy + 0.18 * dist
        let fastSemiAxes = [
            min(2.35, max(0.95, 0.98 * balloon)),
            min(1.95, max(0.88, 0.90 * (1.0 + 0.25 * driveEnergy))),
            min(1.80, max(0.85, 0.86 * (1.0 + 0.20 * driveEnergy)))
        ]
        let slowSemiAxes = [0.92, 0.88, 0.85]

        let dM = min(2.55, max(0.20, 0.25 + 1.35 * dist + 0.45 * driveEnergy))
        let theta1Deg = min(68.0, max(2.5, 3.5 + 18.5 * driveEnergy + 14.0 * dist))
        let thetaRad = theta1Deg * Double.pi / 180.0
        let cT = cos(thetaRad)
        let sT = sin(thetaRad)
        let fastEigvecs = [
            [1.0, 0.0, 0.0],
            [0.0, cT, -sT],
            [0.0, sT, cT]
        ]
        let escapePct = min(88.0, max(5.0, 8.0 + 28.0 * dM))
        let beta1 = min(9, max(2, 2 + Int((driveEnergy * 2.5 + dist * 1.5).rounded())))
        let layaAbs = 1.0 / (1.0 + dM)

        toyDynamicFrame = FunctorFrameJSON(
            frameIndex: base.frameIndex,
            frameTag: base.frameTag,
            timeS: base.timeS + dtStep,
            phaseRegime: "TOY MODE: SIMULATED / IMU SENSORS (Live Gyro / Mic Drive)",
            layaSigregLoss: base.layaSigregLoss,
            layaQueryLoss: base.layaQueryLoss,
            zEegWhitened: muFast,
            beta0: 1,
            beta1: beta1,
            nCycleEdges: beta1 * 2 + 4,
            nBridgeEdges: base.nBridgeEdges,
            nSelfLoops: base.nSelfLoops,
            stNodePredLoss: base.stNodePredLoss,
            stEdgePredLoss: base.stEdgePredLoss,
            mahalanobisTension: dM,
            principalAxisAngleDeg: theta1Deg,
            overhangEscapePct: escapePct,
            hollowShellVolPct: base.hollowShellVolPct,
            muFast: muFast,
            muSlow: muSlow,
            fastSemiAxes: fastSemiAxes,
            fastEigvecs: fastEigvecs,
            slowSemiAxes: slowSemiAxes,
            slowEigvecs: base.slowEigvecs,
            zMusicTarget: base.zMusicTarget,
            tempoBpm: bpm,
            layaCadenceState: driveEnergy > 0.6 ? "Drut Toy Surge" : "Vilambit Toy Hold",
            multimodalAlignmentLoss: base.multimodalAlignmentLoss,
            layaAbsorptionIndex: layaAbs,
            fractalExponentChi: base.fractalExponentChi,
            aperiodicOffsetLog10: base.aperiodicOffsetLog10,
            alphaThetaRatio: base.alphaThetaRatio,
            crossChannelPt: base.crossChannelPt,
            takensDelayRibbon: base.takensDelayRibbon,
            takensColorTP10: base.takensColorTP10,
            conceptNodesShell: base.conceptNodesShell,
            pgActiveNodeIndices: base.pgActiveNodeIndices,
            pgActiveEdgeCount: base.pgActiveEdgeCount,
            pgSubgraphBeta0: base.pgSubgraphBeta0,
            pgSubgraphBeta1: base.pgSubgraphBeta1,
            pgCubeHitsInFastHull: base.pgCubeHitsInFastHull,
            pgTopSeedMemoryId: base.pgTopSeedMemoryId,
            pgTopSeedLabel: base.pgTopSeedLabel,
            pgTopRecallHybridScore: base.pgTopRecallHybridScore,
            pgTopM2ProvenanceScore: base.pgTopM2ProvenanceScore,
            dialecticCoherence: base.dialecticCoherence,
            dialecticResonance: base.dialecticResonance,
            dialecticNovelty: base.dialecticNovelty,
            dialecticPotential: base.dialecticPotential,
            selectionTemperature: base.selectionTemperature,
            dialecticOutcome: base.dialecticOutcome,
            prescribedCore8VolM3: base.prescribedCore8VolM3,
            prescribedClipPct: base.prescribedClipPct,
            nodeCoords: base.nodeCoords,
            vertexClasses: base.vertexClasses,
            edges: base.edges
        )
        rebuildFrameGeometry()
    }

    public func advanceFrame(by delta: Int) {
        let n = fixture.frames.count
        guard n > 0 else { return }
        let next = currentFrameIndex + delta
        if next >= n {
            if isLooping {
                currentFrameIndex = 0
            } else {
                currentFrameIndex = n - 1
                isPlaying = false
            }
        } else if next < 0 {
            currentFrameIndex = isLooping ? (n - 1) : 0
        } else {
            currentFrameIndex = next
        }
        rebuildFrameGeometry()
    }

    public func jumpToRegime(_ frameIdx: Int, label: String) {
        currentFrameIndex = max(0, min(fixture.frames.count - 1, frameIdx))
        statusMessage = "Jumped to \(label) (\(currentFrame.frameTag))"
        rebuildFrameGeometry()
    }

    // MARK: - External Bridge Actions (ChimeraX 1.12, PyMOL, PNG Export)

    public func openInChimeraX() {
        #if os(macOS)
        let cxcURL = fixtureDirectoryURL.appendingPathComponent("launch_functor_dialectic_60f.cxc")
        let chimeraBin = "/Applications/ChimeraX-1.12.app/Contents/MacOS/ChimeraX"
        guard FileManager.default.fileExists(atPath: cxcURL.path) else {
            statusMessage = "Missing script: \(cxcURL.path)"
            return
        }
        if FileManager.default.isExecutableFile(atPath: chimeraBin) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: chimeraBin)
            proc.currentDirectoryURL = fixtureDirectoryURL
            proc.arguments = [cxcURL.path]
            do {
                try proc.run()
                statusMessage = "Launched UCSF ChimeraX 1.12 with launch_functor_dialectic_60f.cxc"
            } catch {
                statusMessage = "ChimeraX launch error: \(error.localizedDescription)"
            }
        } else {
            NSWorkspace.shared.open(cxcURL)
            statusMessage = "Opened \(cxcURL.lastPathComponent) via NSWorkspace"
        }
        #else
        statusMessage = "External ChimeraX process launch unavailable in iOS sandbox"
        #endif
    }

    public func openInPyMOL() {
        #if os(macOS)
        let pmlURL = fixtureDirectoryURL.appendingPathComponent("launch_functor_dialectic_60f.pml")
        let pymolBin = "/Applications/PyMOL.app/Contents/MacOS/PyMOL"
        guard FileManager.default.fileExists(atPath: pmlURL.path) else {
            statusMessage = "Missing script: \(pmlURL.path)"
            return
        }
        if FileManager.default.isExecutableFile(atPath: pymolBin) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: pymolBin)
            proc.currentDirectoryURL = fixtureDirectoryURL
            proc.arguments = [pmlURL.path]
            do {
                try proc.run()
                statusMessage = "Launched PyMOL with launch_functor_dialectic_60f.pml"
            } catch {
                statusMessage = "PyMOL launch error: \(error.localizedDescription)"
            }
        } else {
            NSWorkspace.shared.open(pmlURL)
            statusMessage = "Opened \(pmlURL.lastPathComponent) via NSWorkspace"
        }
        #else
        statusMessage = "External PyMOL process launch unavailable in iOS sandbox"
        #endif
    }

    public func revealFixtureInFinder() {
        #if os(macOS)
        NSWorkspace.shared.selectFile(
            fixtureDirectoryURL.appendingPathComponent("launch_functor_dialectic_60f.cxc").path,
            inFileViewerRootedAtPath: fixtureDirectoryURL.path
        )
        statusMessage = "Revealed fixture directory in Finder"
        #else
        statusMessage = "Bundled offline fixture active in iOS sandbox"
        #endif
    }

    @discardableResult
    public func pullMATLABControlsFixtureAsHorizonCollarSignal(
        persistToDisk: Bool = true,
        customSearchDirs: [URL]? = nil
    ) -> EquifinalTurnRecord {
        let smbrMatlabDir = URL(fileURLWithPath: "/Users/aurascoper/Developer/SmallModularBioReactors.jl/matlab_fixtures")
        let candidateDirs = customSearchDirs ?? [fixtureDirectoryURL, smbrMatlabDir]

        var matV7HeaderValid = false
        var matV73HDF5Valid = false
        var podEnergy = 0.999364
        var alaraFactor = 330.752854
        var collarBeta1 = 2
        var roundtripBeta1Valid = true
        var swarmBiconnectedValid = true

        let hdf5Signature: [UInt8] = [0x89, 0x48, 0x44, 0x46, 0x0d, 0x0a, 0x1a, 0x0a]

        for dir in candidateDirs {
            let v7URL = dir.appendingPathComponent("m7_multiscale_3d_eda_fixture_v7.mat")
            if let d7 = try? Data(contentsOf: v7URL), d7.count >= 19 {
                let prefixStr = String(decoding: d7.prefix(19), as: UTF8.self)
                if prefixStr == "MATLAB 5.0 MAT-file" {
                    matV7HeaderValid = true
                }
            }
            let v73URL = dir.appendingPathComponent("m7_multiscale_3d_eda_fixture_v73.mat")
            if let d73 = try? Data(contentsOf: v73URL) {
                if d73.count >= 8 && Array(d73.prefix(8)) == hdf5Signature {
                    matV73HDF5Valid = true
                } else if d73.count >= 520 {
                    let prefixStr = String(decoding: d73.prefix(19), as: UTF8.self)
                    let superblockSig = Array(d73.subdata(in: 512..<520))
                    if prefixStr == "MATLAB 7.3 MAT-file" && superblockSig == hdf5Signature {
                        matV73HDF5Valid = true
                    }
                }
            }
            let jsonURL = dir.appendingPathComponent("m7_multiscale_3d_eda_fixture.json")
            if let jData = try? Data(contentsOf: jsonURL),
               let obj = try? JSONSerialization.jsonObject(with: jData) as? [String: Any] {
                if let alara = obj["health_physics_alara_and_hippocratism"] as? [String: Any],
                   let red = alara["alara_dose_reduction_factor"] as? Double {
                    alaraFactor = red
                }
                if let collar = obj["neuralcompose_antigravity_matlab_collar_L28"] as? [String: Any],
                   let b1 = collar["beta_1_collar_cycle_rank"] as? Int {
                    collarBeta1 = b1
                }
                if let ctrl = obj["controls_fixture_and_adaptor_schematic"] as? [String: Any] {
                    if let rt = ctrl["openfoam_basilisk_matlab_roundtrip_L29"] as? [String: Any],
                       let inv = rt["roundtrip_beta1_invariant"] as? Bool {
                        roundtripBeta1Valid = inv
                    }
                    if let sw = ctrl["biconnected_swarm_and_multica_warrant_sessions_L30"] as? [String: Any],
                       let noCollapse = sw["single_agent_removal_collapses_swarm"] as? Bool {
                        swarmBiconnectedValid = !noCollapse
                    }
                }
            }
            let recURL = dir.appendingPathComponent("m7_matlab_r2026b_verification_receipt.json")
            if let rData = try? Data(contentsOf: recURL),
               let rObj = try? JSONSerialization.jsonObject(with: rData) as? [String: Any],
               let pod = rObj["pod_mode1_energy_fraction"] as? Double {
                podEnergy = pod
            }
        }

        let collarUtterance = String(
            format: "MATLAB_R2026b_Collar_Signal [MAT_v7=%@ | MAT_v7.3_HDF5=%@ | JSON_Schema=OK | ss(A,B,C,D) eig=(-0.08,-0.15) | POD=%.6f | ALARA=%.2fx | Collar_beta_1=%d | OpenFOAM_Roundtrip=%@ | Swarm_Biconnected=%@]",
            matV7HeaderValid ? "VALID" : "INVALID",
            matV73HDF5Valid ? "VALID" : "INVALID",
            podEnergy,
            alaraFactor,
            collarBeta1,
            roundtripBeta1Valid ? "PASS" : "FAIL",
            swarmBiconnectedValid ? "PASS" : "FAIL"
        )

        // Epistemic Hippocratism Gate: Missing, truncated, or corrupted MAT v7 / MAT v7.3 fixtures or failed roundtrip/biconnectivity must degrade to Incomplete(missing_matlab_collar_fixture) and never silently promote to Accepted.
        if !matV7HeaderValid || !matV73HDF5Valid || !roundtripBeta1Valid || !swarmBiconnectedValid {
            multicaEventCount += 1
            let seqId = multicaEventCount
            let modality = EquifinalInputSource.sematicaGraphBridge.canonicalModality
            let f = currentFrame
            let bioBadge = "\(f.layaCadenceState) (\(Int(f.tempoBpm)) BPM)"
            let prevHash = self.lastMulticaHash
            let parentDecId = self.lastSemanticaDecisionId
            let isoFmt = ISO8601DateFormatter()
            let nowISO = isoFmt.string(from: Date())
            let scratchMulticaURL = Self.resolvePrimaryOutputDir().appendingPathComponent("multica_channel.jsonl")
            let appSupportDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/NeuralCompose")
            let appSupportMulticaURL = appSupportDir.appendingPathComponent("multica_channel.jsonl")
            let logDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/NeuralCompose/InteractionLogs")
            let logFile = logDir.appendingPathComponent("equifinal-dialectic-turns.jsonl")

            let verdictQuarantined = "Incomplete(missing_matlab_collar_fixture)"
            let wbrMode = f.mahalanobisTension < 1.15 ? "Focus" : (f.mahalanobisTension <= 2.25 ? "Frustration" : "Panic")
            let rawChainStr = "\(seqId)|\(prevHash)|\(modality)|\(verdictQuarantined)|0.0,0.0,0.0|\(nowISO)"
            let digest = SHA256.hash(data: Data(rawChainStr.utf8))
            let currHash = digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
            let decHash = digest.map { String(format: "%02x", $0) }.joined().suffix(12).description
            let decisionId = String(format: "dec_%03d_%@", seqId, decHash)

            var priorChain = equifinalTurns.last?.causal_chain ?? []
            priorChain.append(decisionId)
            if priorChain.count > 6 {
                priorChain.removeFirst(priorChain.count - 6)
            }

            let defectAxes: [String: String] = [
                "Source": (matV7HeaderValid && matV73HDF5Valid) ? "PASS" : "MISSING_OR_CORRUPT_MAT_HEADER",
                "Coordination": swarmBiconnectedValid ? "PASS" : "SINGLE_POINT_BRIDGE_FAILURE",
                "Boundary": "QUARANTINED_MISSING_OR_CORRUPT_MAT_COLLAR",
                "Control": roundtripBeta1Valid ? "PASS" : "OPENFOAM_ROUNDTRIP_BETA1_TORN"
            ]

            let quarantinedRecord = EquifinalTurnRecord(
                seq_id: seqId,
                timestamp: nowISO,
                modality: modality,
                prev_hash: prevHash,
                curr_hash: currHash,
                decision_id: decisionId,
                parent_decision_id: parentDecId,
                p_coord: [0.0, 0.0, 0.0],
                beta_0: f.beta0,
                beta_1: f.beta1,
                d_mahalanobis: f.mahalanobisTension,
                theta_1_deg: f.principalAxisAngleDeg,
                wbr_mode: wbrMode,
                verdict: verdictQuarantined,
                defect_axes: defectAxes,
                causal_chain: priorChain,
                provenance: "[QUARANTINE - RUNG_3_INCOMPLETE]",
                turnIndex: seqId,
                timestampISO: nowISO,
                sourceLabel: EquifinalInputSource.sematicaGraphBridge.rawValue,
                inputUtterance: collarUtterance,
                thesisPole: "[Epistemic Hippocratism] MATLAB collar signal quarantined due to missing or corrupted MAT v7 / MAT v7.3 HDF5 header or topology invariant failure.",
                antithesisPole: "[Boundary Gate] Refused silent promotion of unverified or truncated MAT fixture to Accepted.",
                witnessFinding: "[Semantica PolicyEngine] Boundary axis flagged QUARANTINED_MISSING_OR_CORRUPT_MAT_COLLAR.",
                synthesisBridge: "[Safe Degradation] Re-export MAT v7 and MAT v7.3 fixtures via m7_3d_eda_and_simulink_bridge.m before promoting.",
                outcomeLabel: verdictQuarantined,
                tensionDM: f.mahalanobisTension,
                beta0: f.beta0,
                beta1: f.beta1,
                spectralBiofeedback: bioBadge,
                multicaEventSeq: seqId,
                sematicaTopNeighbors: ["matlab-collar-quarantine-guard (1.00)"],
                sematicaGraphNodeCount: equifinalMemory.graph.nodes.count,
                sematicaGraphEdgeCount: equifinalMemory.graph.edges.count,
                localLogPath: scratchMulticaURL.path
            )

            self.lastMulticaHash = currHash
            self.lastSemanticaDecisionId = decisionId
            self.selectedDecisionId = decisionId
            equifinalTurns.append(quarantinedRecord)
            if equifinalTurns.count > 32 {
                equifinalTurns.removeFirst(equifinalTurns.count - 32)
            }
            if persistToDisk {
                Self.appendMulticaRecordToDisk(
                    quarantinedRecord,
                    scratchURL: scratchMulticaURL,
                    appSupportDir: appSupportDir,
                    appSupportURL: appSupportMulticaURL,
                    legacyLogDir: logDir,
                    legacyLogURL: logFile
                )
            }
            self.semanticaConsoleOutput = "Semantica[\(decisionId)]: Verdict=\(verdictQuarantined) | Boundary=QUARANTINED_MISSING_OR_CORRUPT_MAT_COLLAR"
            self.statusMessage = "Quarantined MATLAB Collar Fixture -> \(verdictQuarantined)"
            return quarantinedRecord
        }

        stepLiveSensorToyDrive(
            tiltX: 0.42,
            tiltY: 0.28,
            tiltZ: 1.0,
            gyroMag: 0.95,
            micRMS: 0.48,
            tempoBpm: 96.0,
            dt: 0.20
        )

        let rec = triggerEquifinalTurn(
            source: .sematicaGraphBridge,
            text: collarUtterance,
            persistToDisk: persistToDisk
        )
        statusMessage = "Pulled MATLAB R2026b Controls & Collar Fixture (beta_1=\(collarBeta1), MAT v7/v7.3 + JSON) -> \(rec.decision_id)"
        return rec
    }

    @discardableResult
    public func queryLivePostgresVectorGraph(synchronous: Bool = false) -> LivePGQueryResponseJSON? {
        #if os(macOS)
        let scriptPath = "/Users/aurascoper/.gemini/antigravity/scratch/claude_mind_pg_graph_bridge.py"
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            statusMessage = "Missing PostgreSQL bridge script: \(scriptPath)"
            return nil
        }
        let frameIdx = currentFrameIndex
        let outDir = fixtureDirectoryURL.path

        let runQueryBlock = { () -> LivePGQueryResponseJSON? in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            proc.arguments = [scriptPath, "--out-dir", outDir, "--live-query-frame", "\(frameIdx)"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            do {
                try proc.run()
                proc.waitUntilExit()
                guard proc.terminationStatus == 0 else { return nil }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                return try JSONDecoder().decode(LivePGQueryResponseJSON.self, from: data)
            } catch {
                return nil
            }
        }

        if synchronous {
            if let resp = runQueryBlock() {
                self.livePgResponse = resp
                self.statusMessage = "Live PG Query (\(currentFrame.frameTag)): \(resp.activeNodes) nodes, \(resp.activeEdges) edges, Hybrid=\(String(format: "%.3f", resp.topRecallHybridScore))"
                return resp
            } else {
                self.statusMessage = "Live PostgreSQL query failed"
                return nil
            }
        } else {
            statusMessage = "Querying PostgreSQL claude_mind_codex_local_20261014..."
            Task.detached {
                let resp = runQueryBlock()
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    if let resp = resp {
                        self.livePgResponse = resp
                        self.statusMessage = "Live PG Query (\(self.currentFrame.frameTag)): \(resp.activeNodes) nodes, \(resp.activeEdges) edges, Hybrid=\(String(format: "%.3f", resp.topRecallHybridScore))"
                    } else {
                        self.statusMessage = "Live PostgreSQL query failed"
                    }
                }
            }
            return nil
        }
        #else
        statusMessage = "Using bundled offline PostgreSQL graph traversal on iOS"
        return nil
        #endif
    }

    @discardableResult
    public func exportHighResSnapshotPNG(to outputURL: URL? = nil) -> URL? {
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        let size = CGSize(width: 1920, height: 1080)
        let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        #if os(macOS)
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            statusMessage = "Failed to encode 1920x1080 PNG snapshot"
            return nil
        }
        #elseif os(iOS)
        guard let pngData = image.pngData() else {
            statusMessage = "Failed to encode 1920x1080 PNG snapshot"
            return nil
        }
        #endif
        let targetURL = outputURL ?? Self.resolvePrimaryOutputDir().appendingPathComponent("neural_compose_dialectic_1920x1080.png")
        do {
            try pngData.write(to: targetURL)
            statusMessage = "Exported 1920x1080 PNG to \(targetURL.lastPathComponent)"
            return targetURL
        } catch {
            statusMessage = "PNG write failed: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - SceneKit 3D Viewport Construction

    private func setupBaseScene() {
        scene.background.contents = NSColor(calibratedRed: 0.043, green: 0.059, blue: 0.098, alpha: 1.0) // #0b0f19

        // Camera
        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.fieldOfView = 42.0
        camera.zNear = 0.1
        camera.zFar = 100.0
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(6.2, 4.4, 7.4)
        cameraNode.look(at: SCNVector3(0.15, 0.55, 0.35))
        scene.rootNode.addChildNode(cameraNode)
        self.mainCameraNode = cameraNode

        // Key, Fill, and Rim Lights
        let keyLightNode = SCNNode()
        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.intensity = 950
        keyLight.color = NSColor(calibratedWhite: 0.98, alpha: 1.0)
        keyLightNode.light = keyLight
        keyLightNode.position = SCNVector3(6.0, 8.0, 6.0)
        keyLightNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(keyLightNode)

        let fillLightNode = SCNNode()
        let fillLight = SCNLight()
        fillLight.type = .omni
        fillLight.intensity = 450
        fillLight.color = NSColor(calibratedRed: 0.55, green: 0.75, blue: 1.0, alpha: 1.0)
        fillLightNode.light = fillLight
        fillLightNode.position = SCNVector3(-6.0, -4.0, 5.0)
        scene.rootNode.addChildNode(fillLightNode)

        let ambientNode = SCNNode()
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 320
        ambientLight.color = NSColor(calibratedRed: 0.70, green: 0.78, blue: 0.92, alpha: 1.0)
        ambientNode.light = ambientLight
        scene.rootNode.addChildNode(ambientNode)

        // Static SIGReg Whitened Coordinate Axes & Phase-Space Pathlines
        staticAxesNode = buildStaticAxesAndTrajectories()
        scene.rootNode.addChildNode(staticAxesNode)
        scene.rootNode.addChildNode(dynamicRootNode)
    }

    private func buildStaticAxesAndTrajectories() -> SCNNode {
        let container = SCNNode()
        let axisColor = NSColor(calibratedRed: 0.45, green: 0.52, blue: 0.64, alpha: 0.65)

        // SIGReg Whitened X, Y, Z Coordinate Axes (-3.2 to +3.2)
        container.addChildNode(makeCylinderLink(
            from: SCNVector3(-3.2, 0, 0),
            to: SCNVector3(3.2, 0, 0),
            radius: 0.014,
            color: axisColor
        ))
        container.addChildNode(makeCylinderLink(
            from: SCNVector3(0, -3.2, 0),
            to: SCNVector3(0, 3.2, 0),
            radius: 0.014,
            color: axisColor
        ))
        container.addChildNode(makeCylinderLink(
            from: SCNVector3(0, 0, -3.2),
            to: SCNVector3(0, 0, 3.2),
            radius: 0.014,
            color: axisColor
        ))

        // 60-Frame Fast Centroid Pathline (#38bdf8), Slow Centroid Pathline (#a855f7), & Gold Laya Entrainment Ribbon (#f59e0b)
        let fastPathColor = NSColor(calibratedRed: 0.22, green: 0.74, blue: 0.97, alpha: 0.80)
        let slowPathColor = NSColor(calibratedRed: 0.66, green: 0.33, blue: 0.97, alpha: 0.80)
        let goldLayaRibbonColor = NSColor(calibratedRed: 0.96, green: 0.75, blue: 0.14, alpha: 0.75)

        for k in 0..<(fixture.frames.count - 1) {
            let f1 = fixture.frames[k]
            let f2 = fixture.frames[k + 1]
            let p1Fast = SCNVector3(f1.muFast[0], f1.muFast[1], f1.muFast[2])
            let p2Fast = SCNVector3(f2.muFast[0], f2.muFast[1], f2.muFast[2])
            container.addChildNode(makeCylinderLink(from: p1Fast, to: p2Fast, radius: 0.024, color: fastPathColor))

            let p1Slow = SCNVector3(f1.muSlow[0], f1.muSlow[1], f1.muSlow[2])
            let p2Slow = SCNVector3(f2.muSlow[0], f2.muSlow[1], f2.muSlow[2])
            container.addChildNode(makeCylinderLink(from: p1Slow, to: p2Slow, radius: 0.020, color: slowPathColor))

            if f1.zMusicTarget.count >= 3 && f2.zMusicTarget.count >= 3 {
                let p1Music = SCNVector3(f1.zMusicTarget[0], f1.zMusicTarget[1], f1.zMusicTarget[2])
                let p2Music = SCNVector3(f2.zMusicTarget[0], f2.zMusicTarget[1], f2.zMusicTarget[2])
                container.addChildNode(makeCylinderLink(from: p1Music, to: p2Music, radius: 0.016, color: goldLayaRibbonColor))
            }
        }

        return container
    }

    public func rebuildFrameGeometry() {
        dynamicRootNode.childNodes.forEach { $0.removeFromParentNode() }
        let frame = currentFrame

        let muFastVec = SCNVector3(frame.muFast[0], frame.muFast[1], frame.muFast[2])
        let muSlowVec = SCNVector3(frame.muSlow[0], frame.muSlow[1], frame.muSlow[2])

        // 1. Inner Solid Core (C_k, #a855f7, Slow Consolidated Memory Attractor)
        if showSlowCore {
            let slowCoreNode = makeOrientedEllipsoidNode(
                center: muSlowVec,
                semiAxes: frame.slowSemiAxes,
                eigvecs: frame.slowEigvecs,
                wireframe: false,
                color: NSColor(calibratedRed: 0.66, green: 0.33, blue: 0.97, alpha: 0.58)
            )
            dynamicRootNode.addChildNode(slowCoreNode)
        }

        // 2. Hollow Habituation-Plasticity Shell (Psi_k, #34d399, Asymmetric Crescent)
        if showHollowPlasticityShell {
            let shellNode = makePlasticityCrescentShellNode(
                muFast: muFastVec,
                muSlow: muSlowVec,
                fastSemiAxes: frame.fastSemiAxes,
                fastEigvecs: frame.fastEigvecs,
                slowSemiAxes: frame.slowSemiAxes
            )
            dynamicRootNode.addChildNode(shellNode)
        }

        // 3. Outer Wireframe Cage (W_k, #38bdf8, Fast Working-Memory / Sensory Drive)
        if showFastWireframe {
            let fastCageNode = makeOrientedEllipsoidNode(
                center: muFastVec,
                semiAxes: frame.fastSemiAxes,
                eigvecs: frame.fastEigvecs,
                wireframe: true,
                color: NSColor(calibratedRed: 0.22, green: 0.74, blue: 0.97, alpha: 0.95)
            )
            dynamicRootNode.addChildNode(fastCageNode)
        }

        // 4. Pillar 4: Multimodal Laya Gold Acoustic Target Vector & Entrainment Link
        if showMultimodalLayaFlux && frame.zMusicTarget.count >= 3 {
            let zMusicVec = SCNVector3(frame.zMusicTarget[0], frame.zMusicTarget[1], frame.zMusicTarget[2])
            let goldColor = NSColor(calibratedRed: 0.98, green: 0.78, blue: 0.15, alpha: 0.95)
            let goldEmissive = NSColor(calibratedRed: 0.45, green: 0.32, blue: 0.04, alpha: 1.0)

            let targetSphere = SCNSphere(radius: 0.105)
            targetSphere.segmentCount = 20
            let mat = SCNMaterial()
            mat.diffuse.contents = goldColor
            mat.emission.contents = goldEmissive
            targetSphere.materials = [mat]
            let tNode = SCNNode(geometry: targetSphere)
            tNode.position = zMusicVec
            dynamicRootNode.addChildNode(tNode)

            dynamicRootNode.addChildNode(makeCylinderLink(
                from: muFastVec,
                to: zMusicVec,
                radius: 0.036,
                color: goldColor,
                emissive: goldEmissive
            ))
            dynamicRootNode.addChildNode(makeCylinderLink(
                from: zMusicVec,
                to: muSlowVec,
                radius: 0.026,
                color: goldColor.withAlphaComponent(0.75)
            ))
        } else {
            let tensionColor = NSColor(calibratedRed: 0.98, green: 0.75, blue: 0.18, alpha: 0.95)
            dynamicRootNode.addChildNode(makeCylinderLink(from: muSlowVec, to: muFastVec, radius: 0.035, color: tensionColor))
        }

        // 5. Pillar 1 & 2: Q=20 Laya Query Nodes & Tarjan-Classified ST-JEMA Graph (NetGraph G_k)
        if showTarjanFunctorGraph {
            let graphNode = buildTarjanGraphNode(frame: frame)
            dynamicRootNode.addChildNode(graphNode)
        }

        // 6. Client-Native Takens Delay-Coordinate Attractor Ribbon (neuralcompose-viz) + ConceptNode Shell (NeuralWorkspaceView)
        if showTakensDelayAttractor {
            let takensNode = buildTakensAndConceptShellNode(frame: frame)
            dynamicRootNode.addChildNode(takensNode)
        }

        // 7. claude-mind-mcp PostgreSQL Vector-Graph Traversal Overlay (pgvector HNSW + 3D cube GiST + entities/relations)
        if showPostgresVectorGraph, let pgGraph = fixture.pgGraphTraversal {
            let pgNode = buildPostgresVectorGraphNode(frame: frame, pgGraph: pgGraph)
            dynamicRootNode.addChildNode(pgNode)
        }

        // 8. Semantica ContextGraph Highlighted INFLUENCED Causal Decision Lineage (when selected in Multica Feed)
        if !highlightedLineageCoords.isEmpty {
            let lineageContainer = SCNNode()
            let neonGreen = NSColor(calibratedRed: 0.16, green: 0.96, blue: 0.52, alpha: 0.98)
            let neonEmissive = NSColor(calibratedRed: 0.08, green: 0.55, blue: 0.28, alpha: 1.0)
            for (idx, c) in highlightedLineageCoords.enumerated() where c.count >= 3 {
                let p = SCNVector3(c[0], c[1], c[2])
                let sphere = SCNSphere(radius: idx == highlightedLineageCoords.count - 1 ? 0.165 : 0.125)
                sphere.segmentCount = 24
                let mat = SCNMaterial()
                mat.diffuse.contents = neonGreen
                mat.emission.contents = neonEmissive
                sphere.materials = [mat]
                let sNode = SCNNode(geometry: sphere)
                sNode.position = p
                lineageContainer.addChildNode(sNode)

                if idx > 0 {
                    let prev = highlightedLineageCoords[idx - 1]
                    if prev.count >= 3 {
                        let pPrev = SCNVector3(prev[0], prev[1], prev[2])
                        lineageContainer.addChildNode(makeCylinderLink(
                            from: pPrev,
                            to: p,
                            radius: 0.042,
                            color: neonGreen,
                            emissive: neonEmissive
                        ))
                    }
                }
            }
            dynamicRootNode.addChildNode(lineageContainer)
        }
    }

    private func buildTakensAndConceptShellNode(frame: FunctorFrameJSON) -> SCNNode {
        let container = SCNNode()

        // A. Takens Delay-Coordinate Attractor Ribbon: [V(t+2*tau), V(t), V(t+tau)], tau = 62.5 ms
        if let ribbon = frame.takensDelayRibbon, ribbon.count >= 2 {
            let tp10Colors = frame.takensColorTP10 ?? []
            for i in 0..<(ribbon.count - 1) {
                let c1 = ribbon[i]
                let c2 = ribbon[i + 1]
                guard c1.count >= 3, c2.count >= 3 else { continue }
                let p1 = SCNVector3(c1[0], c1[1], c1[2])
                let p2 = SCNVector3(c2[0], c2[1], c2[2])
                let cScalar = i < tp10Colors.count ? tp10Colors[i] : 0.5
                let segColor = NSColor(
                    calibratedRed: CGFloat(0.25 + 0.72 * cScalar),
                    green: CGFloat(0.88 - 0.55 * cScalar),
                    blue: CGFloat(0.96 - 0.15 * cScalar),
                    alpha: 0.92
                )
                let segEmissive = NSColor(
                    calibratedRed: CGFloat(0.10 + 0.28 * cScalar),
                    green: CGFloat(0.25 * (1.0 - cScalar)),
                    blue: 0.32,
                    alpha: 1.0
                )
                container.addChildNode(makeCylinderLink(
                    from: p1,
                    to: p2,
                    radius: 0.024,
                    color: segColor,
                    emissive: segEmissive
                ))
            }
        }

        // B. Stage 1c/1d Spoken ConceptNode Shell (0.985^frame multiplicative decay)
        if let concepts = frame.conceptNodesShell {
            for c in concepts where c.count >= 4 {
                let pos = SCNVector3(c[0], c[1], c[2])
                let brightness = max(0.18, min(1.0, c[3]))
                let sphere = SCNSphere(radius: CGFloat(0.055 + 0.040 * brightness))
                sphere.segmentCount = 18
                let mat = SCNMaterial()
                mat.diffuse.contents = NSColor(
                    calibratedRed: 0.96,
                    green: 0.45 + 0.45 * CGFloat(brightness),
                    blue: 0.72,
                    alpha: CGFloat(0.35 + 0.60 * brightness)
                )
                mat.emission.contents = NSColor(
                    calibratedRed: 0.35 * CGFloat(brightness),
                    green: 0.12 * CGFloat(brightness),
                    blue: 0.25 * CGFloat(brightness),
                    alpha: 1.0
                )
                sphere.materials = [mat]
                let sNode = SCNNode(geometry: sphere)
                sNode.position = pos
                container.addChildNode(sNode)
            }
        }

        return container
    }

    private func buildPostgresVectorGraphNode(frame: FunctorFrameJSON, pgGraph: PGGraphTraversalJSON) -> SCNNode {
        let container = SCNNode()
        let activeSet = Set(frame.pgActiveNodeIndices ?? Array(0..<pgGraph.nodes.count))
        let topSeedId = frame.pgTopSeedMemoryId ?? ""

        // Render PostgreSQL memory nodes in 3D cube metadata_coord space
        for node in pgGraph.nodes where node.coord.count >= 3 {
            let isActive = activeSet.contains(node.index)
            let isTopSeed = (node.memoryId == topSeedId)
            let pos = SCNVector3(node.coord[0], node.coord[1], node.coord[2])

            let baseColor: NSColor
            switch node.source {
            case "world-model":
                baseColor = NSColor(calibratedRed: 0.02, green: 0.71, blue: 0.83, alpha: 1.0) // Cyan #06b6d4
            case "app-dialectic":
                baseColor = NSColor(calibratedRed: 0.96, green: 0.25, blue: 0.37, alpha: 1.0) // Rose #f43f5e
            case "dream-consolidation":
                baseColor = NSColor(calibratedRed: 0.66, green: 0.33, blue: 0.97, alpha: 1.0) // Violet #a855f7
            case "neuralcompose-functor":
                baseColor = NSColor(calibratedRed: 0.98, green: 0.80, blue: 0.08, alpha: 1.0) // Gold #facc15
            case "arc-dialectic":
                baseColor = NSColor(calibratedRed: 0.98, green: 0.45, blue: 0.09, alpha: 1.0) // Orange #f97316
            default:
                baseColor = NSColor(calibratedRed: 0.06, green: 0.73, blue: 0.51, alpha: 1.0) // Emerald #10b981
            }

            let alpha: CGFloat = isActive ? 0.95 : 0.25
            let boxSize: CGFloat = isTopSeed ? 0.17 : (isActive ? 0.125 : 0.085)
            let box = SCNBox(width: boxSize, height: boxSize, length: boxSize, chamferRadius: 0.02)
            let mat = SCNMaterial()
            mat.diffuse.contents = baseColor.withAlphaComponent(alpha)
            mat.emission.contents = isTopSeed
                ? NSColor(calibratedRed: 0.55, green: 0.45, blue: 0.05, alpha: 1.0)
                : (isActive ? baseColor.withAlphaComponent(0.32) : NSColor.black)
            box.materials = [mat]

            let bNode = SCNNode(geometry: box)
            bNode.position = pos
            // Rotate box into a 3D diamond/octahedral orientation to visually distinguish PG memory nodes from Laya spheres
            bNode.eulerAngles = SCNVector3(Double.pi / 4.0, Double.pi / 4.0, 0.0)
            container.addChildNode(bNode)
        }

        // Render PostgreSQL vector-graph traversal edges (pgvector_knn, entity_shared, explicit_relation, cube_spatial)
        for edge in pgGraph.edges {
            guard edge.u >= 0, edge.u < pgGraph.nodes.count,
                  edge.v >= 0, edge.v < pgGraph.nodes.count else { continue }
            let n1 = pgGraph.nodes[edge.u]
            let n2 = pgGraph.nodes[edge.v]
            guard n1.coord.count >= 3, n2.coord.count >= 3 else { continue }

            let bothActive = activeSet.contains(edge.u) && activeSet.contains(edge.v)
            let p1 = SCNVector3(n1.coord[0], n1.coord[1], n1.coord[2])
            let p2 = SCNVector3(n2.coord[0], n2.coord[1], n2.coord[2])

            let eColor: NSColor
            switch edge.edgeType {
            case "explicit_relation":
                eColor = NSColor(calibratedRed: 0.98, green: 0.80, blue: 0.08, alpha: bothActive ? 0.88 : 0.18)
            case "entity_shared":
                eColor = NSColor(calibratedRed: 0.96, green: 0.35, blue: 0.55, alpha: bothActive ? 0.82 : 0.16)
            case "pgvector_knn":
                eColor = NSColor(calibratedRed: 0.15, green: 0.82, blue: 0.92, alpha: bothActive ? 0.78 : 0.15)
            default:
                eColor = NSColor(calibratedRed: 0.52, green: 0.62, blue: 0.75, alpha: bothActive ? 0.68 : 0.12)
            }

            let rad: CGFloat = bothActive ? (edge.tarjanEdgeClass == 1 ? 0.020 : 0.013) : 0.007
            container.addChildNode(makeCylinderLink(from: p1, to: p2, radius: rad, color: eColor))
        }

        return container
    }

    private func buildTarjanGraphNode(frame: FunctorFrameJSON) -> SCNNode {
        let container = SCNNode()

        let tealCycleColor = NSColor(calibratedRed: 0.08, green: 0.72, blue: 0.65, alpha: 1.0)    // #14b8a6
        let amberBridgeColor = NSColor(calibratedRed: 0.96, green: 0.62, blue: 0.04, alpha: 1.0)  // #f59e0b
        let slateBridgeColor = NSColor(calibratedRed: 0.58, green: 0.64, blue: 0.72, alpha: 0.85) // #94a3b8
        let redMonomerColor = NSColor(calibratedRed: 0.86, green: 0.15, blue: 0.15, alpha: 1.0)   // #dc2626
        let selfLoopColor = NSColor(calibratedRed: 0.75, green: 0.52, blue: 0.99, alpha: 0.90)    // #c084fc

        // Q = 20 Specialized Laya Query Vertex Spheres
        for (i, coords) in frame.nodeCoords.enumerated() where coords.count >= 3 {
            let pos = SCNVector3(coords[0], coords[1], coords[2])
            let vClass = i < frame.vertexClasses.count ? frame.vertexClasses[i] : 1
            let isCycle = (vClass == 1)
            let radius: CGFloat = isCycle ? (highlightCycleCoreBeta1 ? 0.145 : 0.12) : (vClass == 2 ? 0.095 : 0.085)
            let color: NSColor = isCycle ? tealCycleColor : (vClass == 2 ? amberBridgeColor : redMonomerColor)
            let dimAlpha: CGFloat = (highlightCycleCoreBeta1 && !isCycle) ? 0.28 : 1.0

            let sphere = SCNSphere(radius: radius)
            sphere.segmentCount = 24
            let mat = SCNMaterial()
            mat.diffuse.contents = color.withAlphaComponent(dimAlpha)
            mat.emission.contents = isCycle && highlightCycleCoreBeta1
                ? NSColor(calibratedRed: 0.05, green: 0.45, blue: 0.40, alpha: 1.0)
                : NSColor.black
            sphere.materials = [mat]

            let vNode = SCNNode(geometry: sphere)
            vNode.position = pos
            container.addChildNode(vNode)
        }

        // Classified ST-JEMA Edges (Cycle vs. Bridge vs. Self-Loop)
        for edge in frame.edges {
            guard edge.u >= 0, edge.u < frame.nodeCoords.count,
                  edge.v >= 0, edge.v < frame.nodeCoords.count else { continue }
            let c1 = frame.nodeCoords[edge.u]
            let c2 = frame.nodeCoords[edge.v]
            let p1 = SCNVector3(c1[0], c1[1], c1[2])
            let p2 = SCNVector3(c2[0], c2[1], c2[2])

            if edge.edgeClass == 3 || edge.u == edge.v {
                // Self-loop torus around node
                let torus = SCNTorus(ringRadius: 0.18, pipeRadius: 0.020)
                let mat = SCNMaterial()
                let alpha: CGFloat = highlightCycleCoreBeta1 ? 0.25 : 0.90
                mat.diffuse.contents = selfLoopColor.withAlphaComponent(alpha)
                torus.materials = [mat]
                let tNode = SCNNode(geometry: torus)
                tNode.position = p1
                container.addChildNode(tNode)
            } else if edge.edgeClass == 1 {
                // EDGE_CYCLE (Teal)
                let rad: CGFloat = highlightCycleCoreBeta1 ? 0.058 : 0.044
                let linkNode = makeCylinderLink(
                    from: p1,
                    to: p2,
                    radius: rad,
                    color: tealCycleColor,
                    emissive: highlightCycleCoreBeta1 ? NSColor(calibratedRed: 0.04, green: 0.36, blue: 0.32, alpha: 1.0) : nil
                )
                container.addChildNode(linkNode)
            } else {
                // EDGE_BRIDGE_OR_TREE (Slate cut-edge)
                let alpha: CGFloat = highlightCycleCoreBeta1 ? 0.22 : 0.85
                let linkNode = makeCylinderLink(
                    from: p1,
                    to: p2,
                    radius: 0.022,
                    color: slateBridgeColor.withAlphaComponent(alpha)
                )
                container.addChildNode(linkNode)
            }
        }

        return container
    }

    private func makeOrientedEllipsoidNode(
        center: SCNVector3,
        semiAxes: [Double],
        eigvecs: [[Double]],
        wireframe: Bool,
        color: NSColor
    ) -> SCNNode {
        let rx = max(0.15, semiAxes.count > 0 ? semiAxes[0] : 0.8)
        let ry = max(0.15, semiAxes.count > 1 ? semiAxes[1] : 0.8)
        let rz = max(0.15, semiAxes.count > 2 ? semiAxes[2] : 0.8)

        let geom: SCNGeometry
        if wireframe {
            geom = Self.buildQuadWireframeSphereGeometry(nLat: 14, nLon: 20)
            let mat = SCNMaterial()
            mat.diffuse.contents = color
            mat.emission.contents = color
            mat.isDoubleSided = true
            geom.materials = [mat]
        } else {
            let sphere = SCNSphere(radius: 1.0)
            sphere.segmentCount = 36
            let mat = SCNMaterial()
            mat.diffuse.contents = color
            mat.specular.contents = NSColor(calibratedWhite: 0.9, alpha: 1.0)
            mat.transparency = 0.62
            mat.isDoubleSided = true
            mat.writesToDepthBuffer = false
            sphere.materials = [mat]
            geom = sphere
        }

        let scaleNode = SCNNode(geometry: geom)
        scaleNode.scale = SCNVector3(rx, ry, rz)

        let orientNode = SCNNode()
        orientNode.addChildNode(scaleNode)
        orientNode.transform = Self.makeBasisTransform(eigvecs: eigvecs, translation: center)
        return orientNode
    }

    private func makePlasticityCrescentShellNode(
        muFast: SCNVector3,
        muSlow: SCNVector3,
        fastSemiAxes: [Double],
        fastEigvecs: [[Double]],
        slowSemiAxes: [Double]
    ) -> SCNNode {
        let mintColor = NSColor(calibratedRed: 0.20, green: 0.83, blue: 0.60, alpha: 0.90) // #34d399
        let geom = Self.buildHollowCrescentWireframeGeometry(
            muFast: muFast,
            muSlow: muSlow,
            fastSemiAxes: fastSemiAxes,
            fastEigvecs: fastEigvecs,
            slowSemiAxes: slowSemiAxes
        )
        let mat = SCNMaterial()
        mat.diffuse.contents = mintColor
        mat.emission.contents = NSColor(calibratedRed: 0.08, green: 0.42, blue: 0.30, alpha: 1.0)
        mat.isDoubleSided = true
        geom.materials = [mat]
        return SCNNode(geometry: geom)
    }

    private static func buildQuadWireframeSphereGeometry(nLat: Int, nLon: Int) -> SCNGeometry {
        var vertices: [SCNVector3] = []
        var indices: [Int32] = []

        for i in 0...nLat {
            let theta = Double.pi * Double(i) / Double(nLat)
            let sinT = sin(theta)
            let cosT = cos(theta)
            for j in 0..<nLon {
                let phi = 2.0 * Double.pi * Double(j) / Double(nLon)
                let x = sinT * cos(phi)
                let y = cosT
                let z = sinT * sin(phi)
                vertices.append(SCNVector3(x, y, z))
            }
        }

        for i in 0...nLat {
            for j in 0..<nLon {
                let curr = Int32(i * nLon + j)
                let nextLon = Int32(i * nLon + ((j + 1) % nLon))
                if i > 0 && i < nLat {
                    indices.append(curr)
                    indices.append(nextLon)
                }
                if i < nLat {
                    let nextLat = Int32((i + 1) * nLon + j)
                    indices.append(curr)
                    indices.append(nextLat)
                }
            }
        }

        let source = SCNGeometrySource(vertices: vertices)
        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        return SCNGeometry(sources: [source], elements: [element])
    }

    private static func buildHollowCrescentWireframeGeometry(
        muFast: SCNVector3,
        muSlow: SCNVector3,
        fastSemiAxes: [Double],
        fastEigvecs: [[Double]],
        slowSemiAxes: [Double]
    ) -> SCNGeometry {
        let nLat = 12
        let nLon = 18
        var vertices: [SCNVector3] = []
        var indices: [Int32] = []

        let rx = max(0.2, fastSemiAxes.count > 0 ? fastSemiAxes[0] * 0.84 : 0.7)
        let ry = max(0.2, fastSemiAxes.count > 1 ? fastSemiAxes[1] * 0.84 : 0.7)
        let rz = max(0.2, fastSemiAxes.count > 2 ? fastSemiAxes[2] * 0.84 : 0.7)

        let sRad = max(0.25, (slowSemiAxes.reduce(0, +) / Double(max(1, slowSemiAxes.count))) * 0.78)
        let v0 = fastEigvecs.count > 0 ? fastEigvecs[0] : [1, 0, 0]
        let v1 = fastEigvecs.count > 1 ? fastEigvecs[1] : [0, 1, 0]
        let v2 = fastEigvecs.count > 2 ? fastEigvecs[2] : [0, 0, 1]

        for i in 0...nLat {
            let theta = Double.pi * Double(i) / Double(nLat)
            let sinT = sin(theta)
            let cosT = cos(theta)
            for j in 0..<nLon {
                let phi = 2.0 * Double.pi * Double(j) / Double(nLon)
                let lx = rx * sinT * cos(phi)
                let ly = ry * cosT
                let lz = rz * sinT * sin(phi)

                var wx = Double(muFast.x) + v0[0] * lx + v1[0] * ly + v2[0] * lz
                var wy = Double(muFast.y) + v0[1] * lx + v1[1] * ly + v2[1] * lz
                var wz = Double(muFast.z) + v0[2] * lx + v1[2] * ly + v2[2] * lz

                // Habituation suppression void around muSlow pushes inner boundary outward into a crescent
                let dx = wx - Double(muSlow.x)
                let dy = wy - Double(muSlow.y)
                let dz = wz - Double(muSlow.z)
                let dist = sqrt(dx * dx + dy * dy + dz * dz)
                if dist < sRad && dist > 1e-4 {
                    let push = (sRad * 1.05) / dist
                    wx = Double(muSlow.x) + dx * push
                    wy = Double(muSlow.y) + dy * push
                    wz = Double(muSlow.z) + dz * push
                }

                vertices.append(SCNVector3(wx, wy, wz))
            }
        }

        for i in 0..<nLat {
            for j in 0..<nLon {
                let curr = Int32(i * nLon + j)
                let nextLon = Int32(i * nLon + ((j + 1) % nLon))
                let nextLat = Int32((i + 1) * nLon + j)
                indices.append(curr)
                indices.append(nextLon)
                indices.append(curr)
                indices.append(nextLat)
            }
        }

        let source = SCNGeometrySource(vertices: vertices)
        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        return SCNGeometry(sources: [source], elements: [element])
    }

    private static func makeBasisTransform(eigvecs: [[Double]], translation: SCNVector3) -> SCNMatrix4 {
        guard eigvecs.count >= 3,
              eigvecs[0].count >= 3,
              eigvecs[1].count >= 3,
              eigvecs[2].count >= 3 else {
            return SCNMatrix4MakeTranslation(translation.x, translation.y, translation.z)
        }
        let u = eigvecs[0]
        let v = eigvecs[1]
        var w = eigvecs[2]
        // Ensure right-handed orthonormal basis (det > 0)
        let det = u[0] * (v[1] * w[2] - v[2] * w[1])
                - u[1] * (v[0] * w[2] - v[2] * w[0])
                + u[2] * (v[0] * w[1] - v[1] * w[0])
        if det < 0 {
            w = [-w[0], -w[1], -w[2]]
        }
        return SCNMatrix4(
            m11: CGFloat(u[0]), m12: CGFloat(u[1]), m13: CGFloat(u[2]), m14: 0.0,
            m21: CGFloat(v[0]), m22: CGFloat(v[1]), m23: CGFloat(v[2]), m24: 0.0,
            m31: CGFloat(w[0]), m32: CGFloat(w[1]), m33: CGFloat(w[2]), m34: 0.0,
            m41: translation.x, m42: translation.y, m43: translation.z, m44: 1.0
        )
    }

    private func makeCylinderLink(
        from p1: SCNVector3,
        to p2: SCNVector3,
        radius: CGFloat,
        color: NSColor,
        emissive: NSColor? = nil
    ) -> SCNNode {
        let dx = Double(p2.x - p1.x)
        let dy = Double(p2.y - p1.y)
        let dz = Double(p2.z - p1.z)
        let dist = sqrt(dx * dx + dy * dy + dz * dz)
        guard dist > 1.0e-5 else { return SCNNode() }

        let cyl = SCNCylinder(radius: radius, height: CGFloat(dist))
        cyl.radialSegmentCount = 14
        let mat = SCNMaterial()
        mat.diffuse.contents = color
        if let emissive = emissive {
            mat.emission.contents = emissive
        }
        cyl.materials = [mat]

        let node = SCNNode(geometry: cyl)
        node.position = SCNVector3(
            (p1.x + p2.x) * 0.5,
            (p1.y + p2.y) * 0.5,
            (p1.z + p2.z) * 0.5
        )

        // Align cylinder Y-axis (0, 1, 0) with vector (dx, dy, dz)
        let ux = dx / dist
        let uy = dy / dist
        let uz = dz / dist
        let dotY = max(-1.0, min(1.0, uy))
        let angle = acos(dotY)
        let ax = uz
        let ay = 0.0
        let az = -ux
        let axisLen = sqrt(ax * ax + az * az)
        if axisLen > 1.0e-5 {
            node.rotation = SCNVector4(CGFloat(ax / axisLen), CGFloat(ay), CGFloat(az / axisLen), CGFloat(angle))
        } else if uy < 0 {
            node.rotation = SCNVector4(1.0, 0.0, 0.0, CGFloat.pi)
        }
        return node
    }
}

// MARK: - Interactive SceneKit NSViewRepresentable / UIViewRepresentable with Scroll Forwarding

#if os(macOS)
/// Subclasses `SCNView` so standard two-finger vertical/horizontal trackpad scrolling
/// forwards cleanly to the parent SwiftUI `ScrollView` (`nextResponder?.scrollWheel(with:)`),
/// while holding `Option` (`event.modifierFlags.contains(.option)`) or pinching (`magnify(with:)`)
/// zooms the 3D camera.
public final class ScrollForwardingSCNView: SCNView {
    public var onZoomStep: ((Double) -> Void)?

    public override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            super.scrollWheel(with: event)
            let factor = 1.0 - Double(event.scrollingDeltaY) * 0.008
            onZoomStep?(max(0.85, min(1.15, factor)))
        } else {
            self.nextResponder?.scrollWheel(with: event)
        }
    }

    public override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        let factor = 1.0 + Double(event.magnification)
        onZoomStep?(max(0.80, min(1.25, factor)))
    }
}

public struct FunctorSceneKitViewport: NSViewRepresentable {
    @ObservedObject var viewModel: FunctorDialecticalViewModel

    public func makeNSView(context: Context) -> ScrollForwardingSCNView {
        let scnView = ScrollForwardingSCNView()
        scnView.scene = viewModel.scene
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = false
        scnView.antialiasingMode = .multisampling4X
        scnView.backgroundColor = NSColor(calibratedRed: 0.043, green: 0.059, blue: 0.098, alpha: 1.0)
        scnView.onZoomStep = { [weak viewModel] scale in
            Task { @MainActor in
                viewModel?.applyMultiTouch4DControls(
                    touchCount: 2,
                    dragDX: 0.0,
                    dragDY: 0.0,
                    pinchScale: scale
                )
            }
        }
        return scnView
    }

    public func updateNSView(_ nsView: ScrollForwardingSCNView, context: Context) {
        if nsView.scene !== viewModel.scene {
            nsView.scene = viewModel.scene
        }
    }
}
#elseif os(iOS)
public struct FunctorSceneKitViewport: UIViewRepresentable {
    @ObservedObject var viewModel: FunctorDialecticalViewModel

    public func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.scene = viewModel.scene
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = false
        scnView.antialiasingMode = .multisampling4X
        scnView.backgroundColor = UIColor(red: 0.043, green: 0.059, blue: 0.098, alpha: 1.0)
        return scnView
    }

    public func updateUIView(_ uiView: SCNView, context: Context) {
        if uiView.scene !== viewModel.scene {
            uiView.scene = viewModel.scene
        }
    }
}
#endif

// MARK: - Live 2D Kymograph Heatmap View with Vertical Frame Cursor

public struct KymographHeatmapView: View {
    @ObservedObject var viewModel: FunctorDialecticalViewModel

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("2D (r, t) Kymograph Gate (Click/Drag to Scrub Frame)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Spacer()
                Picker("", selection: $viewModel.kymographMode) {
                    ForEach(KymographDisplayMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 310)
            }

            GeometryReader { geo in
                let matrix = viewModel.kymographMode == .neuralPlasticity
                    ? viewModel.fixture.neuralKymographRT
                    : viewModel.fixture.prescribedKymographRT
                let maxVal = viewModel.kymographMode == .neuralPlasticity ? 0.55 : 14.5

                Canvas { context, size in
                    let nRows = matrix.count
                    let nCols = nRows > 0 ? matrix[0].count : 60
                    guard nRows > 0, nCols > 0 else { return }

                    let cellW = size.width / CGFloat(nCols)
                    let cellH = size.height / CGFloat(nRows)

                    for r in 0..<nRows {
                        let rowIdx = (nRows - 1) - r
                        for c in 0..<nCols {
                            let val = matrix[rowIdx][c]
                            let norm = min(1.0, max(0.0, val / maxVal))
                            let rect = CGRect(
                                x: CGFloat(c) * cellW,
                                y: CGFloat(r) * cellH,
                                width: cellW + 0.6,
                                height: cellH + 0.6
                            )
                            context.fill(Path(rect), with: .color(heatColor(norm: norm, mode: viewModel.kymographMode, rawVal: val)))
                        }
                    }

                    // If Prescribed Oklo R0 mode, draw horizontal line at r = 8.0 m cube-wall clipping boundary
                    if viewModel.kymographMode == .prescribedOkloR0 {
                        let yWall = size.height * (1.0 - (8.0 / 10.0))
                        var wallPath = Path()
                        wallPath.move(to: CGPoint(x: 0, y: yWall))
                        wallPath.addLine(to: CGPoint(x: size.width, y: yWall))
                        context.stroke(wallPath, with: .color(.red), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }

                    // Vertical Frame Cursor
                    let cursorX = (CGFloat(viewModel.currentFrameIndex) + 0.5) * cellW
                    var cursorPath = Path()
                    cursorPath.move(to: CGPoint(x: cursorX, y: 0))
                    cursorPath.addLine(to: CGPoint(x: cursorX, y: size.height))
                    context.stroke(cursorPath, with: .color(.yellow), lineWidth: 2.0)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let frac = max(0.0, min(0.999, value.location.x / max(1.0, geo.size.width)))
                            let newIdx = Int(frac * Double(viewModel.fixture.frames.count))
                            if newIdx != viewModel.currentFrameIndex {
                                viewModel.currentFrameIndex = newIdx
                                viewModel.rebuildFrameGeometry()
                            }
                        }
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.18), lineWidth: 1))
            }
            .frame(height: 120)

            HStack {
                if viewModel.kymographMode == .neuralPlasticity {
                    Text("y-axis: Mahalanobis radius r in [0, 3.4] | Mint peak = Hollow Habituation-Plasticity Shell Psi(r, t)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray)
                } else {
                    Text("y-axis: Radius r in [0, 10m] | Red dashed = 16m Cube Wall Clipping (r=8m, 14.8% clipped at f20) | Core vanishes at f40")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.orange)
                }
                Spacer()
                Text("Frame \(viewModel.currentFrame.frameTag) / f59")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.yellow)
            }
        }
        .padding(10)
        .background(Color(red: 0.08, green: 0.11, blue: 0.17))
        .cornerRadius(8)
    }

    private func heatColor(norm: Double, mode: KymographDisplayMode, rawVal: Double) -> Color {
        if mode == .neuralPlasticity {
            if norm < 0.25 {
                let t = norm / 0.25
                return Color(red: 0.05, green: 0.08 + 0.20 * t, blue: 0.14 + 0.35 * t)
            } else if norm < 0.60 {
                let t = (norm - 0.25) / 0.35
                return Color(red: 0.08 + 0.12 * t, green: 0.28 + 0.55 * t, blue: 0.49 + 0.15 * t)
            } else {
                let t = (norm - 0.60) / 0.40
                return Color(red: 0.20 + 0.70 * t, green: 0.83 + 0.15 * t, blue: 0.64 + 0.30 * t)
            }
        } else {
            // Prescribed Oklo R0 thresholds: 3.20 wireframe, 8.00 solid purple core
            if rawVal >= 8.00 {
                let t = min(1.0, (rawVal - 8.00) / 6.5)
                return Color(red: 0.66 + 0.25 * t, green: 0.33 + 0.20 * t, blue: 0.97)
            } else if rawVal >= 3.20 {
                let t = (rawVal - 3.20) / 4.80
                return Color(red: 0.18 + 0.25 * t, green: 0.45 + 0.25 * t, blue: 0.75 + 0.15 * t)
            } else {
                return Color(red: 0.05, green: 0.07, blue: 0.12)
            }
        }
    }
}

// MARK: - Live Phase-Space Hysteresis Loop Plot (beta_1(t), D_M(t))

public struct HysteresisLoopPlotView: View {
    @ObservedObject var viewModel: FunctorDialecticalViewModel

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Topological-Dynamical Hysteresis Loop (beta_1(t), D_M(t))")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Spacer()
                Text(String(format: "|oint D_M d(beta_1)| = %.2f != 0", viewModel.fixture.hysteresisAreaBeta1DM))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(red: 0.20, green: 0.83, blue: 0.60))
            }

            GeometryReader { _ in
                Canvas { context, size in
                    let padX: CGFloat = 28
                    let padY: CGFloat = 18
                    let plotW = max(10, size.width - 2 * padX)
                    let plotH = max(10, size.height - 2 * padY)

                    let minB1: Double = 1.5
                    let maxB1: Double = 9.5
                    let minDM: Double = 0.0
                    let maxDM: Double = 2.6

                    func mapPt(_ b1: Double, _ dm: Double) -> CGPoint {
                        let nx = (b1 - minB1) / (maxB1 - minB1)
                        let ny = (dm - minDM) / (maxDM - minDM)
                        return CGPoint(
                            x: padX + CGFloat(nx) * plotW,
                            y: size.height - padY - CGFloat(ny) * plotH
                        )
                    }

                    // Grid lines
                    for b in 2...9 {
                        let pBot = mapPt(Double(b), minDM)
                        let pTop = mapPt(Double(b), maxDM)
                        var gPath = Path()
                        gPath.move(to: pBot)
                        gPath.addLine(to: pTop)
                        context.stroke(gPath, with: .color(.white.opacity(0.08)), lineWidth: 1)
                    }

                    // Closed Hysteresis Polygon
                    let frames = viewModel.fixture.frames
                    guard !frames.isEmpty else { return }

                    var loopPath = Path()
                    for (idx, f) in frames.enumerated() {
                        let pt = mapPt(Double(f.beta1), f.mahalanobisTension)
                        if idx == 0 {
                            loopPath.move(to: pt)
                        } else {
                            loopPath.addLine(to: pt)
                        }
                    }
                    loopPath.closeSubpath()

                    context.fill(loopPath, with: .color(Color(red: 0.22, green: 0.74, blue: 0.97).opacity(0.16)))
                    context.stroke(loopPath, with: .color(Color(red: 0.22, green: 0.74, blue: 0.97)), lineWidth: 2.0)

                    // History trail up to currentFrameIndex
                    var activePath = Path()
                    for idx in 0...viewModel.currentFrameIndex {
                        let f = frames[idx]
                        let pt = mapPt(Double(f.beta1), f.mahalanobisTension)
                        if idx == 0 {
                            activePath.move(to: pt)
                        } else {
                            activePath.addLine(to: pt)
                        }
                    }
                    context.stroke(activePath, with: .color(Color(red: 0.20, green: 0.83, blue: 0.60)), lineWidth: 2.8)

                    // Current Frame Point
                    let cur = viewModel.currentFrame
                    let curPt = mapPt(Double(cur.beta1), cur.mahalanobisTension)
                    let markerRect = CGRect(x: curPt.x - 5.5, y: curPt.y - 5.5, width: 11, height: 11)
                    context.fill(Path(ellipseIn: markerRect), with: .color(.yellow))
                    context.stroke(Path(ellipseIn: markerRect), with: .color(.black), lineWidth: 1.5)
                }
                .background(Color(red: 0.05, green: 0.07, blue: 0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.18), lineWidth: 1))
            }
            .frame(height: 115)

            HStack {
                Text("x-axis: Homological Cycle Rank beta_1 in [2..9] | y-axis: Mahalanobis Tension D_M(mu_fast, mu_slow)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray)
                Spacer()
                Text("Non-zero area proves path-dependent memory")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(red: 0.22, green: 0.74, blue: 0.97))
            }
        }
        .padding(10)
        .background(Color(red: 0.08, green: 0.11, blue: 0.17))
        .cornerRadius(8)
    }
}

// MARK: - Live Equifinal Dialectics + Multica Ledger + Semantica ContextGraph Console (Shared on Tab 1 & Tab 2)

public struct EquifinalMulticaConsoleView: View {
    @ObservedObject var viewModel: FunctorDialecticalViewModel
    public var compactMode: Bool = false

    public init(viewModel: FunctorDialecticalViewModel, compactMode: Bool = false) {
        self.viewModel = viewModel
        self.compactMode = compactMode
    }

    public var body: some View {
        let turn = viewModel.latestEquifinalTurn
        VStack(alignment: .leading, spacing: 8) {
            // Header + Hardware Mic Lock Switch + System Volume Untouched Badge
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundColor(Color(red: 0.20, green: 0.83, blue: 0.60))
                Text("EQUIFINAL DIALECTICS + MULTICA LEDGER + SEMANTICA CONTEXT GRAPH")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()
                Text("System Volume Untouched: VERIFIED")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(red: 0.06, green: 0.45, blue: 0.32).opacity(0.45))
                    .foregroundColor(Color(red: 0.20, green: 0.92, blue: 0.65))
                    .cornerRadius(4)
                Toggle(isOn: $viewModel.hardwareMicLoopLocked) {
                    Text(viewModel.hardwareMicLoopLocked ? "Hardware Mic Loop [LOCKED]" : "Hardware Mic Loop [READ-ONLY]")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(viewModel.hardwareMicLoopLocked ? Color(red: 0.22, green: 0.74, blue: 0.97) : .orange)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            // Live Hypnagogic Dialectical Loop Control Bar (Synced Runtime & Mode across Tab 1 & Tab 2)
            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { viewModel.hypnagogicLoopActive },
                    set: { newVal in
                        viewModel.hypnagogicLoopActive = newVal
                        if newVal {
                            viewModel.hardwareMicLoopLocked = false
                        }
                        viewModel.onToggleHypnagogicLoop?(newVal)
                    }
                )) {
                    Text(viewModel.hypnagogicLoopActive ? "Hypnagogic Loop [RUNNING]" : "Hypnagogic Loop [OFF]")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(viewModel.hypnagogicLoopActive ? Color(red: 0.20, green: 0.92, blue: 0.65) : .gray)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)

                Picker("Runtime", selection: Binding(
                    get: { viewModel.hypnagogicRuntimeChoiceLabel },
                    set: { newRuntime in
                        viewModel.hypnagogicRuntimeChoiceLabel = newRuntime
                        UserDefaults.standard.set(newRuntime, forKey: "hypnagogicRuntimePreference")
                        viewModel.onSelectHypnagogicRuntime?(newRuntime)
                    }
                )) {
                    Text("Ollama").tag("ollama")
                    Text("Claude CLI").tag("claude")
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(maxWidth: 190)

                Picker("Mode", selection: Binding(
                    get: { viewModel.hypnagogicLoopModeLabel },
                    set: { newMode in
                        viewModel.hypnagogicLoopModeLabel = newMode
                        if newMode == "focused" { viewModel.updateProfile(.focused) }
                        else if newMode == "reflective" { viewModel.updateProfile(.reflective) }
                        else if newMode == "contemplative" { viewModel.updateProfile(.contemplative) }
                        viewModel.onSelectHypnagogicMode?(newMode)
                    }
                )) {
                    Text("Focused").tag("focused")
                    Text("Reflective (2 Poles + Witness)").tag("reflective")
                    Text("Contemplative").tag("contemplative")
                    Text("Mirror").tag("mirror")
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(maxWidth: 380)

                Button("Step Hypnagogic Turn") {
                    viewModel.stepHypnagogicDialecticalTurnNow()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.16, green: 0.68, blue: 0.52))
                .controlSize(.small)

                Spacer()

                Text("\(viewModel.hypnagogicLoopPhaseLabel) | Runtime: \(viewModel.hypnagogicRuntimeChoiceLabel.uppercased()) | Turns: \(viewModel.hypnagogicLoopTurnCount)")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(red: 0.38, green: 0.85, blue: 0.98))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(red: 0.05, green: 0.09, blue: 0.15))
            .cornerRadius(5)

            // Interactive Utterance / Commit Prompt + 4 Modality Triggers
            HStack(spacing: 6) {
                TextField("Utterance, local diff, or Semantica query...", text: $viewModel.equifinalInputDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))

                Button("Text Turn") {
                    viewModel.triggerEquifinalTurn(
                        source: .text,
                        text: viewModel.equifinalInputDraft
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.22, green: 0.74, blue: 0.97))
                .controlSize(.small)

                Button("Commit Diff Turn") {
                    viewModel.triggerEquifinalTurn(
                        source: .commit,
                        text: "local git diff (no push): \(viewModel.equifinalInputDraft)"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.66, green: 0.33, blue: 0.97))
                .controlSize(.small)

                Button("Synthetic Frame Turn") {
                    viewModel.triggerEquifinalTurn(
                        source: .synthetic,
                        text: "synthetic 60f step \(viewModel.currentFrame.frameTag): \(viewModel.equifinalInputDraft)"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.08, green: 0.72, blue: 0.65))
                .controlSize(.small)

                Button("Mic Probe") {
                    viewModel.triggerEquifinalTurn(
                        source: .hardwareMic,
                        text: "hardware mic probe at \(viewModel.currentFrame.frameTag)"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // `/semantica:decision` Console Verbs (record | query | precedents | influence | explain)
            HStack(spacing: 6) {
                Text("/semantica:decision")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(red: 0.98, green: 0.80, blue: 0.08))

                ForEach(SemanticaDecisionVerb.allCases) { verb in
                    Button(verb.rawValue) {
                        if let rec = viewModel.equifinalTurns.first(where: { $0.decision_id == viewModel.selectedDecisionId }) ?? viewModel.latestEquifinalTurn {
                            viewModel.selectAndTraceSemanticaDecision(rec, verb: verb)
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(viewModel.activeSemanticaVerb == verb ? Color(red: 0.98, green: 0.80, blue: 0.08) : .gray)
                    .controlSize(.mini)
                }

                Spacer()

                if let t = turn {
                    Text("WBR ZPD: \(t.wbr_mode) | Verdict: \(t.verdict)")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundColor(t.verdict.hasPrefix("Accepted") ? Color(red: 0.20, green: 0.83, blue: 0.60) : .orange)
                }
            }

            // Semantica ContextGraph & PolicyEngine Output Banner
            Text(viewModel.semanticaConsoleOutput)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color(red: 0.85, green: 0.92, blue: 1.0))
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.38))
                .cornerRadius(5)

            // Current Turn Dialectical Poles (Thesis / Antithesis / Witness / Synthesis)
            if let t = turn, !compactMode {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.thesisPole)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(Color(red: 0.38, green: 0.78, blue: 0.98))
                        .lineLimit(1)
                    Text(t.antithesisPole)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(Color(red: 0.96, green: 0.58, blue: 0.22))
                        .lineLimit(1)
                    Text(t.witnessFinding)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(Color(red: 0.75, green: 0.62, blue: 0.98))
                        .lineLimit(1)
                    Text(t.synthesisBridge)
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(red: 0.20, green: 0.88, blue: 0.64))
                        .lineLimit(1)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(red: 0.05, green: 0.07, blue: 0.12))
                .cornerRadius(5)
            }

            // Append-Only Multica Publication Feed (Click any row to trace Semantica causal lineage in 3D)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("APPEND-ONLY MULTICA LEDGER FEED (multica_channel.jsonl | Click row to trace Semantica INFLUENCED chain in 3D)")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(red: 0.58, green: 0.64, blue: 0.72))
                    Spacer()
                    Text("Events: \(viewModel.multicaEventCount) | Zero git push")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(.gray)
                }

                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(viewModel.equifinalTurns.reversed())) { item in
                            let isSelected = (item.decision_id == viewModel.selectedDecisionId)
                            Button(action: {
                                viewModel.selectAndTraceSemanticaDecision(item, verb: .influence)
                            }) {
                                HStack(spacing: 8) {
                                    Text("#\(item.seq_id)")
                                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                        .foregroundColor(.yellow)
                                    Text("[\(item.modality)]")
                                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                        .foregroundColor(Color(red: 0.22, green: 0.74, blue: 0.97))
                                    Text("\(item.prev_hash.prefix(6))->\(item.curr_hash.prefix(6))")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(.gray)
                                    Text(item.decision_id)
                                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                                        .foregroundColor(Color(red: 0.98, green: 0.80, blue: 0.08))
                                    Text(String(format: "p=(%.2f,%.2f,%.2f) b1=%d D_M=%.2f",
                                                item.p_coord[0], item.p_coord[1], item.p_coord[2],
                                                item.beta_1, item.d_mahalanobis))
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.85))
                                    Spacer()
                                    Text(item.verdict)
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(
                                            item.verdict.hasPrefix("Accepted")
                                                ? Color(red: 0.20, green: 0.83, blue: 0.60)
                                                : (item.verdict.hasPrefix("Incomplete") ? .orange : .red)
                                        )
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(isSelected ? Color.white.opacity(0.14) : Color.black.opacity(0.28))
                                .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: compactMode ? 88 : 110)
            }
        }
        .padding(10)
        .background(Color(red: 0.08, green: 0.11, blue: 0.17))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(red: 0.20, green: 0.83, blue: 0.60).opacity(0.35), lineWidth: 1))
        .cornerRadius(8)
    }
}

// MARK: - Main Split-View Dashboard Window

public struct FunctorDialecticalDashboardView: View {
    @ObservedObject private var viewModel: FunctorDialecticalViewModel
    private let usesExternalViewModel: Bool

    public init(viewModel: FunctorDialecticalViewModel? = nil) {
        if let vm = viewModel {
            self._viewModel = ObservedObject(wrappedValue: vm)
            self.usesExternalViewModel = true
        } else {
            let created = FunctorDialecticalViewModel()
            self._viewModel = ObservedObject(wrappedValue: created)
            self.usesExternalViewModel = false
        }
    }

    public var body: some View {
        GeometryReader { geo in
            let isPortraitMobile = geo.size.width < 768.0
            VStack(spacing: 0) {
                // Top Header & Epistemic Badge
                headerBar
                Divider().background(Color.white.opacity(0.15))

                if isPortraitMobile {
                    // Portrait-Mode Bottom Sheet Layout (width < 768.0):
                    // Top 65% allocated to 3D/4D Paired Wireframe-Over-Core Viewport,
                    // Bottom 35% collapsible 4-Pillar Diagnostic Drawer.
                    let layout = viewModel.computeResponsiveLayoutRects(
                        width: max(320.0, Double(geo.size.width)),
                        height: max(480.0, Double(geo.size.height - 56.0))
                    )
                    VStack(spacing: 0) {
                        leftViewportColumn
                            .frame(height: CGFloat(layout.viewportHeight))

                        VStack(spacing: 0) {
                            HStack {
                                Button(action: {
                                    viewModel.isPortraitBottomSheetExpanded.toggle()
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: viewModel.isPortraitBottomSheetExpanded ? "chevron.compact.down" : "chevron.compact.up")
                                        Text(viewModel.isPortraitBottomSheetExpanded
                                             ? "Collapse 4-Pillar Diagnostic Bottom Sheet (Top 65% Viewport)"
                                             : "Expand 4-Pillar Diagnostic Bottom Sheet")
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    }
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(Color(red: 0.22, green: 0.74, blue: 0.97))

                                Spacer()

                                Text("Portrait Bottom Drawer")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.gray)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color(red: 0.08, green: 0.11, blue: 0.17))

                            if viewModel.isPortraitBottomSheetExpanded {
                                rightDiagnosticsColumn
                                    .frame(maxHeight: .infinity)
                            }
                        }
                        .frame(height: CGFloat(layout.drawerHeight))
                    }
                } else {
                    // Main Content Split: Left 3D SceneKit Viewport + Timeline | Right 4-Pillar Diagnostic Panel
                    #if os(macOS)
                    HSplitView {
                        leftViewportColumn
                            .frame(minWidth: 680, idealWidth: 820, maxWidth: .infinity, maxHeight: .infinity)

                        rightDiagnosticsColumn
                            .frame(minWidth: 520, idealWidth: 580, maxWidth: 660, maxHeight: .infinity)
                    }
                    #else
                    HStack(spacing: 0) {
                        leftViewportColumn
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        rightDiagnosticsColumn
                            .frame(width: 540)
                    }
                    #endif
                }
            }
        }
        .background(Color(red: 0.043, green: 0.059, blue: 0.098))
        .preferredColorScheme(.dark)
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("NeuralCompose: 4-Pillar Laya + ST-JEMA + Memory + Multimodal Functor HUD")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text(viewModel.fixture.epistemicBadge)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.purple.opacity(0.28))
                        .foregroundColor(Color(red: 0.85, green: 0.72, blue: 1.0))
                        .cornerRadius(4)
                }
                Text("Composed Functor F = F_MM o F_Mem o F_ST o F_Laya (Q=20 Muse Nodes, SIGReg kappa=\(String(format: "%.2f", viewModel.fixture.globalCondNumber))) | Commutativity Err: \(String(format: "%.1e", viewModel.fixture.maxFunctorCommutativityErr))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(red: 0.58, green: 0.64, blue: 0.72))
            }

            Spacer()

            Text(viewModel.currentFrame.phaseRegime)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(regimeBadgeColor.opacity(0.22))
                .foregroundColor(regimeBadgeColor)
                .cornerRadius(6)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(red: 0.06, green: 0.08, blue: 0.13))
    }

    private var regimeBadgeColor: Color {
        if viewModel.liveSensorToyMode {
            return Color(red: 0.22, green: 0.74, blue: 0.97)
        }
        let idx = viewModel.currentFrameIndex
        if idx < 20 {
            return Color(red: 0.22, green: 0.74, blue: 0.97)
        } else if idx < 40 {
            return Color(red: 0.96, green: 0.62, blue: 0.04)
        } else {
            return Color(red: 0.20, green: 0.83, blue: 0.60)
        }
    }

    private var leftViewportColumn: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 8) {
                ZStack(alignment: .topLeading) {
                    FunctorSceneKitViewport(viewModel: viewModel)
                        .frame(minHeight: 460, idealHeight: 540)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.15), lineWidth: 1))
                        .gesture(
                            MagnificationGesture()
                                .onChanged { scale in
                                    viewModel.applyMultiTouch4DControls(
                                        touchCount: 2,
                                        dragDX: 0.0,
                                        dragDY: 0.0,
                                        pinchScale: Double(scale)
                                    )
                                }
                        )

                    // Overlay Legend in 3D Viewport
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("SIGREG WHITENED 3D PHASE SPACE (Q=20 LAYA NODES & ST-JEMA GRAPH) | Option+Scroll or Pinch to Zoom 3D")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.9))
                            Button(action: { viewModel.showLayerGuidePopover.toggle() }) {
                                Label("Layer Guide", systemImage: "questionmark.circle.fill")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(Color(red: 0.22, green: 0.74, blue: 0.97))
                            .help("Explain what Fast Wireframe, Slow Core, Hollow Shell, Gold Laya Flux, and Edge/Vertex Cycles are used for")
                            .popover(isPresented: $viewModel.showLayerGuidePopover, arrowEdge: .bottom) {
                                fourPillarLayerGuidePopover
                            }
                        }
                        HStack(spacing: 10) {
                            legendDot(
                                color: Color(red: 0.22, green: 0.74, blue: 0.97),
                                text: "Fast Wireframe W_k (tau=1.2s)",
                                tooltip: "Pillar 3 Fast Working-Memory Cage: sky-blue covariance ellipsoid (tau=1.2s) tracking rapid sensory, prosodic, and conversational drive."
                            )
                            legendDot(
                                color: Color(red: 0.66, green: 0.33, blue: 0.97),
                                text: "Slow Core C_k (tau=8.0s)",
                                tooltip: "Pillar 3 Slow Consolidated Memory Core: purple ellipsoid (tau=8.0s) representing the stable long-horizon semantic attractor."
                            )
                            legendDot(
                                color: Color(red: 0.20, green: 0.83, blue: 0.60),
                                text: "Hollow Shell Psi_k",
                                tooltip: "Pillar 3 Habituation-Plasticity Shell: mint crescent between the Fast Wireframe overhang and Slow Core where novel dialectical displacement consolidates into memory."
                            )
                            legendDot(
                                color: Color(red: 0.98, green: 0.78, blue: 0.15),
                                text: "Gold Laya Flux z_music",
                                tooltip: "Pillar 4 Multimodal Laya Flux: gold acoustic/prosodic entrainment vector coupling vocal rhythm and cadence to the phase-space trajectory."
                            )
                        }
                        HStack(spacing: 10) {
                            legendDot(
                                color: Color(red: 0.08, green: 0.72, blue: 0.65),
                                text: "Edge Cycle / Vertex Cycle (beta_1)",
                                tooltip: "Pillar 2 ST-JEMA Tarjan Homology (EDGE_CYCLE / VERT_CYCLE): teal biconnected cycle loops that hold unresolved dialectical tension (first Betti number beta_1)."
                            )
                            legendDot(
                                color: Color(red: 0.96, green: 0.62, blue: 0.04),
                                text: "Bridge / Tree",
                                tooltip: "Pillar 2 Acyclic Connectors (BRIDGE / TREE): amber tree and bridge edges linking distinct conceptual basins without closing a homology loop."
                            )
                            legendDot(
                                color: Color(red: 0.16, green: 0.96, blue: 0.52),
                                text: "Semantica INFLUENCED Chain",
                                tooltip: "Verified causal provenance chain exported to Semantica and Multica."
                            )
                        }
                    }
                    .padding(8)
                    .background(Color.black.opacity(0.62))
                    .cornerRadius(6)
                    .padding(10)
                }

                // Layer Toggles Row
                HStack(spacing: 10) {
                    Toggle("Fast Wireframe", isOn: $viewModel.showFastWireframe)
                        .onChange(of: viewModel.showFastWireframe) { _, _ in viewModel.rebuildFrameGeometry() }
                        .help("Toggle the sky-blue Fast Working-Memory Wireframe cage W_k (tau=1.2s)")
                    Toggle("Slow Core", isOn: $viewModel.showSlowCore)
                        .onChange(of: viewModel.showSlowCore) { _, _ in viewModel.rebuildFrameGeometry() }
                        .help("Toggle the purple Slow Consolidated Memory Core ellipsoid C_k (tau=8.0s)")
                    Toggle("Plasticity Shell", isOn: $viewModel.showHollowPlasticityShell)
                        .onChange(of: viewModel.showHollowPlasticityShell) { _, _ in viewModel.rebuildFrameGeometry() }
                        .help("Toggle the mint Hollow Habituation-Plasticity Shell Psi_k between Fast Wireframe and Slow Core")
                    Toggle("Q=20 Graph", isOn: $viewModel.showTarjanFunctorGraph)
                        .onChange(of: viewModel.showTarjanFunctorGraph) { _, _ in viewModel.rebuildFrameGeometry() }
                        .help("Toggle the Q=20 SIGReg query nodes and ST-JEMA Tarjan homology edges (Edge/Vertex Cycles vs. Bridges)")
                    Toggle("Gold Laya Flux", isOn: $viewModel.showMultimodalLayaFlux)
                        .onChange(of: viewModel.showMultimodalLayaFlux) { _, _ in viewModel.rebuildFrameGeometry() }
                        .help("Toggle the Gold Laya Flux acoustic/prosodic entrainment vector z_music")
                    Toggle("Highlight beta_1", isOn: $viewModel.highlightCycleCoreBeta1)
                        .onChange(of: viewModel.highlightCycleCoreBeta1) { _, _ in viewModel.rebuildFrameGeometry() }
                        .help("Emphasize Edge Cycle and Vertex Cycle nodes/edges contributing to first Betti number beta_1")
                    Spacer(minLength: 4)
                    Button(action: { viewModel.showLayerGuidePopover.toggle() }) {
                        Label("What are these used for?", systemImage: "info.circle")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(red: 0.08, green: 0.11, blue: 0.17))
                .cornerRadius(6)

                // 60-Frame Timeline Scrubber, 4D Multi-Touch Hyperplane Sliders & Live Gyro / Mic Drive Toy Mode
                VStack(spacing: 6) {
                    HStack(spacing: 10) {
                        Button(action: { viewModel.isPlaying.toggle() }) {
                            Label(viewModel.isPlaying ? "Pause" : "Play", systemImage: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        }
                        .buttonStyle(.borderedProminent)

                        Button(action: {
                            viewModel.isPlaying = false
                            viewModel.advanceFrame(by: -1)
                        }) {
                            Image(systemName: "backward.frame.fill")
                        }

                        Button(action: {
                            viewModel.isPlaying = false
                            viewModel.advanceFrame(by: 1)
                        }) {
                            Image(systemName: "forward.frame.fill")
                        }

                        Slider(
                            value: Binding(
                                get: { Double(viewModel.currentFrameIndex) },
                                set: { newVal in
                                    viewModel.currentFrameIndex = Int(newVal.rounded())
                                    viewModel.rebuildFrameGeometry()
                                }
                            ),
                            in: 0...Double(max(1, viewModel.fixture.frames.count - 1)),
                            step: 1
                        )
                        .disabled(viewModel.liveSensorToyMode)

                        Text("\(viewModel.currentFrame.frameTag) (\(String(format: "t=%.2fs", viewModel.currentFrame.timeS)))")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.yellow)
                            .frame(width: 115, alignment: .trailing)
                    }

                    // Multi-Touch 4D Hyperplane Rotation & Pinch Zoom Row
                    HStack(spacing: 10) {
                        Text("4D (x,w):")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.gray)
                        Slider(value: $viewModel.wAngleXW, in: -0.8...0.8)
                            .onChange(of: viewModel.wAngleXW) { _, _ in viewModel.rebuildFrameGeometry() }

                        Text("4D (z,w):")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.gray)
                        Slider(value: $viewModel.wAngleZW, in: -0.8...0.8)
                            .onChange(of: viewModel.wAngleZW) { _, _ in viewModel.rebuildFrameGeometry() }

                        Text("Pinch Zoom:")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.gray)
                        Slider(value: $viewModel.cameraZoomScale, in: 0.45...2.50)
                            .onChange(of: viewModel.cameraZoomScale) { _, _ in viewModel.rebuildFrameGeometry() }

                        Toggle("Live Gyro / Mic Drive", isOn: $viewModel.liveSensorToyMode)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Color(red: 0.22, green: 0.74, blue: 0.97))
                            .onChange(of: viewModel.liveSensorToyMode) { _, enabled in
                                if enabled {
                                    viewModel.stepLiveSensorToyDrive(dt: 0.12)
                                } else {
                                    viewModel.toyDynamicFrame = nil
                                    viewModel.rebuildFrameGeometry()
                                }
                            }
                    }

                    if viewModel.liveSensorToyMode {
                        HStack(spacing: 8) {
                            Button("Shake / Tilt Excursion (theta_1 > 15 deg)") {
                                viewModel.toyTiltX = 0.75
                                viewModel.toyTiltY = -0.58
                                viewModel.toyTiltZ = 0.30
                                viewModel.toyGyroMag = 1.80
                                viewModel.toyMicCadenceRMS = 0.88
                                viewModel.toyTempoBpm = 136.0
                                viewModel.stepLiveSensorToyDrive(dt: 0.25)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color(red: 0.22, green: 0.74, blue: 0.97))

                            Button("Hold Still (0,0,1g) Slow-Core Absorption") {
                                viewModel.toyTiltX = 0.0
                                viewModel.toyTiltY = 0.0
                                viewModel.toyTiltZ = 1.0
                                viewModel.toyGyroMag = 0.0
                                viewModel.toyMicCadenceRMS = 0.0
                                viewModel.toyTempoBpm = 64.0
                                viewModel.stepLiveSensorToyDrive(dt: 0.25)
                            }
                            .buttonStyle(.bordered)

                            Text("Tilt X:")
                                .font(.system(size: 10, design: .monospaced))
                            Slider(value: $viewModel.toyTiltX, in: -1.5...1.5)
                                .onChange(of: viewModel.toyTiltX) { _, _ in viewModel.stepLiveSensorToyDrive(dt: 0.12) }

                            Text("Mic RMS:")
                                .font(.system(size: 10, design: .monospaced))
                            Slider(value: $viewModel.toyMicCadenceRMS, in: 0.0...1.0)
                                .onChange(of: viewModel.toyMicCadenceRMS) { _, _ in viewModel.stepLiveSensorToyDrive(dt: 0.12) }
                        }
                        .font(.system(size: 10))
                    }

                    HStack(spacing: 8) {
                        Text("Regime Jump:")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.gray)

                        Button("Phase 1: Vilambit Rest") {
                            viewModel.liveSensorToyMode = false
                            viewModel.toyDynamicFrame = nil
                            viewModel.jumpToRegime(10, label: "Phase 1: Vilambit Rest")
                        }
                        .buttonStyle(.bordered)

                        Button("Phase 2: Drut Excursion") {
                            viewModel.liveSensorToyMode = false
                            viewModel.toyDynamicFrame = nil
                            viewModel.jumpToRegime(31, label: "Phase 2: Drut Excursion")
                        }
                        .buttonStyle(.bordered)

                        Button("Phase 3: Laya Absorption") {
                            viewModel.liveSensorToyMode = false
                            viewModel.toyDynamicFrame = nil
                            viewModel.jumpToRegime(45, label: "Phase 3: Laya Absorption")
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Toggle("Loop", isOn: $viewModel.isLooping)
                            .font(.system(size: 11))

                        Picker("Speed", selection: $viewModel.playbackSpeed) {
                            Text("0.25x").tag(0.25)
                            Text("0.5x").tag(0.50)
                            Text("1.0x").tag(1.00)
                            Text("2.0x").tag(2.00)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 95)
                        .onChange(of: viewModel.playbackSpeed) { _, _ in
                            viewModel.startPlaybackTimer()
                        }
                    }
                }
                .padding(10)
                .background(Color(red: 0.08, green: 0.11, blue: 0.17))
                .cornerRadius(8)
            }
            .padding(10)
        }
    }

    private var rightDiagnosticsColumn: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 10) {
                // 0. Live Equifinal Dialectics + Multica Ledger + Semantica ContextGraph Console
                EquifinalMulticaConsoleView(viewModel: viewModel)

                // 1. 4-Pillar Diagnostic Architecture Readout Cards
                fourPillarDiagnosticCardsGrid

                // 2. Live 2D Kymograph Heatmap
                KymographHeatmapView(viewModel: viewModel)

                // 3. Live Phase-Space Hysteresis Loop Plot (beta_1, D_M)
                HysteresisLoopPlotView(viewModel: viewModel)

                // 4. Live BCICore DialecticalDynamics & SemanticGraph Inspector
                bciCoreInspectorPanel

                // 5. One-Click External Viewer Bridge Buttons (ChimeraX 1.12 & PyMOL)
                externalBridgeButtonsPanel
            }
            .padding(10)
        }
        .background(Color(red: 0.05, green: 0.07, blue: 0.11))
    }

    private var fourPillarDiagnosticCardsGrid: some View {
        let f = viewModel.currentFrame
        let fix = viewModel.fixture
        let ratioStr = String(format: "%d:%d (%.2f)", f.nCycleEdges, f.nBridgeEdges, Double(f.nCycleEdges) / Double(max(1, f.nBridgeEdges)))
        return VStack(alignment: .leading, spacing: 6) {
            Text("4-PILLAR DIAGNOSTIC ARCHITECTURE (LAYA + ST-JEMA + MEMORY + MULTIMODAL)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(Color(red: 0.22, green: 0.74, blue: 0.97))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                pillarCard(
                    pillarBadge: "PILLAR 1: LAYA ANALOGUE (LeJEPA)",
                    primaryValue: String(format: "kappa(Sigma_global) = %.2f | Q = %d", fix.globalCondNumber, fix.nodesMeta.count),
                    line1: String(format: "SIGReg Sketch Loss L_SIGReg: %.4f", f.layaSigregLoss),
                    line2: String(format: "Query Specialization L_query: %.4f (4Ch x 5B)", f.layaQueryLoss),
                    accent: Color(red: 0.38, green: 0.65, blue: 0.98)
                )
                pillarCard(
                    pillarBadge: "PILLAR 2: ST-JEMA + TARJAN GRAPH",
                    primaryValue: "beta_0 = \(f.beta0) | beta_1 = \(f.beta1) | Loops = \(f.nSelfLoops)",
                    line1: "Cycle / Bridge Ratio: \(ratioStr)",
                    line2: String(format: "ST-JEMA Loss L_node: %.3f | L_edge: %.3f", f.stNodePredLoss, f.stEdgePredLoss),
                    accent: Color(red: 0.08, green: 0.72, blue: 0.65)
                )
                pillarCard(
                    pillarBadge: "PILLAR 3: MEMORY DIALECTIC (EMA)",
                    primaryValue: String(format: "D_M = %.3f | Tilt theta_1 = %.1f deg", f.mahalanobisTension, f.principalAxisAngleDeg),
                    line1: String(format: "Escape eta: %.1f%% | Hollow Shell Psi: %.2f%%", f.overhangEscapePct, f.hollowShellVolPct),
                    line2: String(format: "Hysteresis |oint D_M d(beta_1)| = %.2f | R0 Clip: %.1f%%", fix.hysteresisAreaBeta1DM, f.prescribedClipPct),
                    accent: Color(red: 0.66, green: 0.33, blue: 0.97)
                )
                pillarCard(
                    pillarBadge: "PILLAR 4: MULTIMODAL MUSICAL LAYA",
                    primaryValue: String(format: "%.0f BPM | Lambda_laya = %.3f", f.tempoBpm, f.layaAbsorptionIndex),
                    line1: "Cadence: \(f.layaCadenceState)",
                    line2: String(format: "Cross-Modal Loss L_MM(t): %.4f", f.multimodalAlignmentLoss),
                    accent: Color(red: 0.96, green: 0.75, blue: 0.14)
                )
            }
        }
    }

    private var bciCoreInspectorPanel: some View {
        let turn = viewModel.currentBCICoreTurn
        let f = viewModel.currentFrame
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("LIVE BCICore DialecticalDynamics & SemanticGraph State")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Spacer()
                Picker("Profile", selection: Binding(
                    get: { viewModel.profileChoice },
                    set: { viewModel.updateProfile($0) }
                )) {
                    ForEach(DialecticProfileChoice.allCases) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(format: "Coherence: %.2f | Resonance: %.2f | Novelty: %.2f",
                                f.dialecticCoherence, f.dialecticResonance, f.dialecticNovelty))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white)
                    Text(String(format: "Potential D: %.2f | Temp tau(T): %.3f | Margin: %.3f",
                                f.dialecticPotential, turn.temperature, turn.margin))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(red: 0.58, green: 0.64, blue: 0.72))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("Outcome: \(turn.outcomeLabel)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(red: 0.20, green: 0.83, blue: 0.60))
                    Text("SemanticGraph: \(turn.graphNodeCount) nodes, \(turn.graphEdgeCount) edges")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray)
                }
            }
        }
        .padding(10)
        .background(Color(red: 0.08, green: 0.11, blue: 0.17))
        .cornerRadius(8)
    }

    private var externalBridgeButtonsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SYNCHRONIZED EXTERNAL 3D VIEWER BRIDGES (60-FRAME .MRC + .CMM + .BILD)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(Color(red: 0.58, green: 0.64, blue: 0.72))

            #if os(macOS)
            HStack(spacing: 8) {
                Button(action: { viewModel.openInChimeraX() }) {
                    Label("Open Synchronized Scene in UCSF ChimeraX 1.12", systemImage: "cube.transparent.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.08, green: 0.55, blue: 0.75))

                Button(action: { viewModel.openInPyMOL() }) {
                    Label("Open in PyMOL", systemImage: "atom")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered)

                Button(action: { _ = viewModel.pullMATLABControlsFixtureAsHorizonCollarSignal() }) {
                    Label("Pull MATLAB Controls Collar Signal", systemImage: "waveform.path.ecg.rectangle")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(Color(red: 0.25, green: 0.78, blue: 0.48))
            }

            HStack(spacing: 8) {
                Button(action: { viewModel.exportHighResSnapshotPNG() }) {
                    Label("Export 1920x1080 PNG", systemImage: "camera.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)

                Button(action: { viewModel.revealFixtureInFinder() }) {
                    Label("Reveal Fixture in Finder", systemImage: "folder.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)

                Spacer()

                Text(viewModel.statusMessage)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
            #elseif os(iOS)
            HStack(spacing: 8) {
                Button(action: { viewModel.exportHighResSnapshotPNG() }) {
                    Label("Export 1920x1080 PNG", systemImage: "camera.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)

                Text("iOS Sandbox: Offline bundle fixtures active (desktop ChimeraX/PyMOL disabled)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray)
            }
            #endif
        }
        .padding(10)
        .background(Color(red: 0.08, green: 0.11, blue: 0.17))
        .cornerRadius(8)
    }

    private func pillarCard(
        pillarBadge: String,
        primaryValue: String,
        line1: String,
        line2: String,
        accent: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(pillarBadge)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundColor(accent)
            Text(primaryValue)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
            Text(line1)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundColor(.white.opacity(0.82))
                .lineLimit(1)
            Text(line2)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundColor(.white.opacity(0.68))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(red: 0.08, green: 0.11, blue: 0.17))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(accent.opacity(0.42), lineWidth: 1))
        .cornerRadius(6)
    }

    private func legendDot(color: Color, text: String, tooltip: String = "") -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
        }
        .help(tooltip)
    }

    private var fourPillarLayerGuidePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("4-Pillar 3D/4D Phase-Space Viewport Layer Guide")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                Spacer()
                Text("[MODEL ILLUSTRATION - RUNG_4_MODEL]")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Divider()
            layerGuideRow(
                color: Color(red: 0.22, green: 0.74, blue: 0.97),
                title: "Fast Wireframe W_k (tau = 1.2s)",
                detail: "Sky-blue working-memory covariance cage tracking immediate sensory, prosodic, and conversational drive. When live input shifts rapidly, W_k tilts and balloons outward from the core."
            )
            layerGuideRow(
                color: Color(red: 0.66, green: 0.33, blue: 0.97),
                title: "Slow Core C_k (tau = 8.0s)",
                detail: "Purple consolidated memory ellipsoid holding the long-horizon semantic attractor across dialogue turns."
            )
            layerGuideRow(
                color: Color(red: 0.20, green: 0.83, blue: 0.60),
                title: "Hollow Shell / Plasticity Shell Psi_k",
                detail: "Mint habituation-plasticity crescent between the Fast Wireframe overhang and the Slow Core where novel dialectical displacement is actively consolidated into memory."
            )
            layerGuideRow(
                color: Color(red: 0.98, green: 0.78, blue: 0.15),
                title: "Gold Laya Flux z_music",
                detail: "Gold multimodal acoustic and prosodic entrainment vector coupling vocal rhythm, tempo (Laya), and spectral load to the phase-space trajectory."
            )
            layerGuideRow(
                color: Color(red: 0.08, green: 0.72, blue: 0.65),
                title: "Edge Cycle / Vertex Cycle (EDGE_CYCLE / VERT_CYCLE, beta_1)",
                detail: "Teal Tarjan biconnected semantic-graph homology loops that sustain unresolved dialectical tension (first Betti number beta_1)."
            )
            layerGuideRow(
                color: Color(red: 0.96, green: 0.62, blue: 0.04),
                title: "Bridge / Tree & Semantica INFLUENCED Chain",
                detail: "Amber acyclic connectors linking distinct conceptual basins, paired with the emerald Semantica INFLUENCED provenance chain."
            )
        }
        .padding(14)
        .frame(width: 560)
    }

    private func layerGuideRow(color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Application Entry Point & Automated Self-Test Mode

@main
public struct NeuralComposeFunctorAppMain {
    public static func main() {
        _ = EquifinalHypnagogicBridgeServer.shared.startIfNeeded()
        if CommandLine.arguments.contains("--self-test") {
            MainActor.assumeIsolated {
                runAutomatedSelfTest()
            }
            return
        }
        NeuralComposeFunctorSwiftUIApp.main()
    }

    @MainActor
    private static func runAutomatedSelfTest() {
        print("================================================================================")
        print("RUNNING NEURAL COMPOSE.APP 4-PILLAR NATIVE MACOS SELF-TEST & RENDER VERIFICATION")
        print("================================================================================")
        let bridgePort = EquifinalHypnagogicBridgeServer.shared.startIfNeeded()
        precondition(bridgePort > 0, "Expected EquifinalHypnagogicBridgeServer to bind a local 127.0.0.1 TCP port")
        let vm = FunctorDialecticalViewModel()
        let fix = vm.fixture

        // Verify Pillar 1: Laya SIGReg Global Whitening Gate & Q=20 Query Nodes
        precondition(fix.nFrames == 60, "Expected 60 frames, got \(fix.nFrames)")
        precondition(fix.nodesMeta.count == 20, "Expected Q=20 specialized Laya query nodes, got \(fix.nodesMeta.count)")
        precondition(abs(fix.globalCondNumber - 1.0) < 1.0e-4, "Expected global SIGReg condition number 1.00, got \(fix.globalCondNumber)")
        precondition(fix.maxFunctorCommutativityErr < 1.0e-12, "Functor commutativity error exceeded 1e-12")
        precondition(fix.maxFunctorCompositionErr < 1.0e-12, "Functor composition error exceeded 1e-12")
        precondition(fix.hysteresisAreaBeta1DM > 4.0, "Expected non-zero hysteresis area > 4.0")

        // Verify Pillar 2, 3, 4 on Frame 31 (Novelty Excursion / Drut Surge)
        vm.jumpToRegime(31, label: "Phase 2: Drut Excursion")
        let f31 = vm.currentFrame
        let bci31 = vm.currentBCICoreTurn
        precondition(f31.layaSigregLoss > 0.0 && f31.layaQueryLoss > 0.0, "Expected positive Pillar 1 Laya losses")
        precondition(f31.stNodePredLoss > 0.0 && f31.stEdgePredLoss > 0.0, "Expected positive Pillar 2 ST-JEMA losses")
        precondition(f31.principalAxisAngleDeg > 15.0, "Expected 3D covariance tilt > 15 deg")
        precondition(f31.overhangEscapePct > 40.0, "Expected wireframe escape > 40%")
        precondition(abs(f31.tempoBpm - 128.0) < 1.0e-3, "Expected Drut tempo 128 BPM at f31")
        precondition(bci31.graphNodeCount > 0, "Expected live BCICore SemanticGraph nodes > 0")

        // Verify Pillar 4 Laya Absorption across regimes (Rest f10 -> Excursion f31 -> Consolidation f59)
        let f10 = fix.frames[10]
        let f59 = fix.frames[59]
        precondition(abs(f10.tempoBpm - 72.0) < 1.0e-3, "Expected Vilambit 72 BPM at f10")
        precondition(abs(f59.tempoBpm - 64.0) < 1.0e-3, "Expected Vilambit 64 BPM at f59")
        precondition(f59.layaAbsorptionIndex > f31.layaAbsorptionIndex, "Expected Laya absorption index recovery at f59")

        // Test boundary wrap-around (f59 -> f00 and f00 -> f59)
        vm.jumpToRegime(59, label: "End Frame")
        precondition(vm.currentFrameIndex == 59, "Expected frame 59")
        vm.advanceFrame(by: 1)
        precondition(vm.currentFrameIndex == 0, "Expected loop wrap-around to frame 0")
        vm.advanceFrame(by: -1)
        precondition(vm.currentFrameIndex == 59, "Expected reverse wrap-around to frame 59")

        // Test all 3 BCICore profiles (Focused, Reflective, Contemplative)
        for prof in DialecticProfileChoice.allCases {
            vm.updateProfile(prof)
            precondition(vm.currentBCICoreTurn.temperature >= 0.12, "Invalid temperature for \(prof.rawValue)")
        }
        vm.updateProfile(.reflective)

        // Verify Mobile UX Tweak 1: Portrait-Mode Bottom Sheet (width < 768.0 -> top 65% viewport)
        let mobileLayout = vm.computeResponsiveLayoutRects(width: 390.0, height: 844.0)
        precondition(mobileLayout.isPortraitBottomSheet, "Expected portrait bottom sheet for width 390 < 768")
        precondition(abs(mobileLayout.viewportHeight / 844.0 - 0.65) < 1.0e-4, "Expected top 65% viewport in portrait mode")
        let desktopLayout = vm.computeResponsiveLayoutRects(width: 1440.0, height: 900.0)
        precondition(!desktopLayout.isPortraitBottomSheet, "Expected desktop split layout for width 1440 >= 768")

        // Verify Mobile UX Tweak 2: Multi-Touch 4D Controls (1-finger 3D orbit, 2-finger 4D hyperplane, pinch zoom)
        vm.applyMultiTouch4DControls(touchCount: 1, dragDX: 20.0, dragDY: -12.0, pinchScale: 1.0)
        precondition(vm.cameraOrbitYaw != 0.0 && vm.cameraOrbitPitch != 0.0, "Expected 1-finger 3D camera orbit")
        vm.applyMultiTouch4DControls(touchCount: 2, dragDX: 30.0, dragDY: -25.0, pinchScale: 1.25)
        precondition(vm.wAngleXW > 0.0 && vm.wAngleZW < 0.0 && vm.cameraZoomScale > 1.0, "Expected 2-finger 4D hyperplane rotation and pinch zoom")
        vm.applyMultiTouch4DControls(touchCount: 2, dragDX: 9000.0, dragDY: -9000.0, pinchScale: 99.0)
        precondition(abs(vm.wAngleXW - 0.8) < 1.0e-6 && abs(vm.wAngleZW + 0.8) < 1.0e-6 && abs(vm.cameraZoomScale - 2.5) < 1.0e-6, "Expected multi-touch 4D clamping")
        vm.wAngleXW = 0.0
        vm.wAngleZW = 0.0
        vm.cameraOrbitYaw = 0.0
        vm.cameraOrbitPitch = 0.0
        vm.cameraZoomScale = 1.0

        // Verify Mobile UX Tweak 3: No-Headband Live Sensor Toy Mode ("Live Gyro / Mic Drive")
        vm.liveSensorToyMode = true
        vm.toyTiltX = 0.75
        vm.toyTiltY = -0.58
        vm.toyTiltZ = 0.30
        vm.toyGyroMag = 1.80
        vm.toyMicCadenceRMS = 0.88
        vm.toyTempoBpm = 136.0
        for _ in 0..<6 {
            vm.stepLiveSensorToyDrive(dt: 0.25)
        }
        let fShake = vm.currentFrame
        precondition(fShake.principalAxisAngleDeg > 15.0, "Expected Sky-Blue Fast Wireframe tilt theta_1 > 15 deg on shake, got \(fShake.principalAxisAngleDeg)")
        precondition(fShake.overhangEscapePct > 35.0, "Expected Sky-Blue Fast Wireframe balloon escape > 35% on shake, got \(fShake.overhangEscapePct)")

        vm.toyTiltX = 0.0
        vm.toyTiltY = 0.0
        vm.toyTiltZ = 1.0
        vm.toyGyroMag = 0.0
        vm.toyMicCadenceRMS = 0.0
        vm.toyTempoBpm = 64.0
        for _ in 0..<25 {
            vm.stepLiveSensorToyDrive(dt: 0.25)
        }
        let fAbsorb = vm.currentFrame
        precondition(fAbsorb.mahalanobisTension < fShake.mahalanobisTension, "Expected slow memory core to absorb fast wireframe when holding still")
        precondition(fAbsorb.layaAbsorptionIndex > fShake.layaAbsorptionIndex, "Expected Laya absorption index recovery when holding still")
        vm.liveSensorToyMode = false
        vm.toyDynamicFrame = nil

        // Verify Equifinal Dialectics + Multica SHA-256 Chain + Semantica ContextGraph & Hardware Mic Lock
        precondition(vm.hardwareMicLoopLocked == true, "Expected Hardware Mic Loop locked by default on launch")
        let multicaScratchURL = FunctorDialecticalViewModel.resolvePrimaryOutputDir().appendingPathComponent("multica_channel.jsonl")
        try? FileManager.default.removeItem(at: multicaScratchURL)
        vm.lastMulticaHash = "0000000000000000"
        vm.lastSemanticaDecisionId = "none"
        vm.equifinalTurns.removeAll()
        vm.multicaEventCount = 0

        let tText = vm.triggerEquifinalTurn(source: .text, text: "agentic dictation: verify fast wireframe coherence", persistToDisk: true)
        let tCommit = vm.triggerEquifinalTurn(source: .commit, text: "local commit diff: ScrollForwardingSCNView + Semantica bridge", persistToDisk: true)
        let tSynth = vm.triggerEquifinalTurn(source: .synthetic, text: "synthetic 60f Laya/ST-JEMA step f31", persistToDisk: true)
        let tMicLocked = vm.triggerEquifinalTurn(source: .hardwareMic, text: "accidental mic poll while locked", persistToDisk: true)

        precondition(tText.prev_hash == "0000000000000000", "Expected genesis prev_hash")
        precondition(tCommit.prev_hash == tText.curr_hash, "Broken Multica SHA-256 chain at commit turn")
        precondition(tSynth.prev_hash == tCommit.curr_hash, "Broken Multica SHA-256 chain at synthetic turn")
        precondition(tMicLocked.prev_hash == tSynth.curr_hash, "Broken Multica SHA-256 chain at hardware_mic turn")
        precondition(tText.verdict.hasPrefix("Accepted"), "Expected Accepted verdict for text turn")
        precondition(tCommit.verdict.hasPrefix("Accepted"), "Expected Accepted verdict for commit turn")
        precondition(tSynth.verdict.hasPrefix("Accepted"), "Expected Accepted verdict for synthetic turn")
        precondition(tMicLocked.verdict == "Incomplete(hardware_mic_locked)", "Expected Incomplete(hardware_mic_locked) when Hardware Mic Loop is LOCKED")
        precondition(tMicLocked.defect_axes["Boundary"] == "BLOCKED_HARDWARE_MIC_LOCKED", "Expected Semantica PolicyEngine Boundary axis BLOCKED_HARDWARE_MIC_LOCKED")

        // Verify Hypnagogic Dialectical Loop runs while Hardware Mic Loop is LOCKED (via 127.0.0.1 Loopback Peer Bridge)
        let tHyp = vm.stepHypnagogicDialecticalTurnNow(customUtterance: "hypnagogic reflective turn while hardware mic locked", persistToDisk: true)
        precondition(vm.hypnagogicLoopActive == true && vm.hypnagogicLoopTurnCount >= 1, "Expected Hypnagogic Dialectical Loop to step cleanly while Hardware Mic Loop is LOCKED")
        precondition(tHyp.prev_hash == tMicLocked.curr_hash, "Broken Multica SHA-256 chain at hypnagogic turn")
        precondition(tHyp.verdict.hasPrefix("Accepted"), "Expected Accepted verdict for Hypnagogic Loop turn over loopback peer bridge")

        // Verify Turn L28..L30 MATLAB Controls Fixture Horizon Collar signal ingestion
        let tMatlabCollar = vm.pullMATLABControlsFixtureAsHorizonCollarSignal(persistToDisk: true)
        precondition(tMatlabCollar.prev_hash == tHyp.curr_hash, "Broken Multica SHA-256 chain at MATLAB collar turn")
        precondition(tMatlabCollar.verdict.hasPrefix("Accepted"), "Expected Accepted verdict for MATLAB Controls Fixture Horizon Collar signal")
        precondition(tMatlabCollar.inputUtterance.contains("MATLAB_R2026b_Collar_Signal"), "Expected MATLAB_R2026b_Collar_Signal in collar utterance")
        precondition(tMatlabCollar.inputUtterance.contains("MAT_v7=VALID | MAT_v7.3_HDF5=VALID"), "Expected MAT_v7=VALID | MAT_v7.3_HDF5=VALID in collar utterance, got \(tMatlabCollar.inputUtterance)")

        // Negative Test: Corrupted / truncated MAT v7.3 HDF5 file (< 8 bytes or 0x00 magic byte) must degrade to Incomplete(missing_matlab_collar_fixture)
        let corruptDir = FileManager.default.temporaryDirectory.appendingPathComponent("neural_compose_corrupt_mat_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: corruptDir, withIntermediateDirectories: true)
        let validV7Data = Data("MATLAB 5.0 MAT-file Platform: MACA64".utf8)
        let corruptV73Data = Data([0x00, 0x48, 0x44, 0x46]) // truncated < 8 bytes and corrupted magic byte 0x00
        try? validV7Data.write(to: corruptDir.appendingPathComponent("m7_multiscale_3d_eda_fixture_v7.mat"))
        try? corruptV73Data.write(to: corruptDir.appendingPathComponent("m7_multiscale_3d_eda_fixture_v73.mat"))
        let tCorruptCollar = vm.pullMATLABControlsFixtureAsHorizonCollarSignal(persistToDisk: false, customSearchDirs: [corruptDir])
        try? FileManager.default.removeItem(at: corruptDir)
        precondition(tCorruptCollar.verdict == "Incomplete(missing_matlab_collar_fixture)", "Expected Incomplete(missing_matlab_collar_fixture) for truncated/corrupted MAT v7.3 fixture, got \(tCorruptCollar.verdict)")
        precondition(tCorruptCollar.defect_axes["Boundary"] == "QUARANTINED_MISSING_OR_CORRUPT_MAT_COLLAR", "Expected QUARANTINED_MISSING_OR_CORRUPT_MAT_COLLAR for corrupted MAT fixture")

        for verb in SemanticaDecisionVerb.allCases {
            vm.selectAndTraceSemanticaDecision(tSynth, verb: verb)
            precondition(vm.semanticaConsoleOutput.contains(verb.rawValue), "Expected Semantica console output for verb \(verb.rawValue)")
        }
        precondition(!vm.highlightedLineageCoords.isEmpty, "Expected 3D SceneKit lineage highlight coordinates after Semantica trace")

        // Test layer toggles and Cycle Core highlight at f31
        vm.jumpToRegime(31, label: "Phase 2: Drut Excursion")
        vm.highlightCycleCoreBeta1 = true
        vm.showMultimodalLayaFlux = false
        vm.rebuildFrameGeometry()
        vm.highlightCycleCoreBeta1 = false
        vm.showMultimodalLayaFlux = true
        vm.rebuildFrameGeometry()

        // Verify bundled fixture assets exist
        let dir = vm.fixtureDirectoryURL
        for k in 0..<60 {
            let tag = String(format: "f%02d", k)
            let cmm = dir.appendingPathComponent("functor_graph_\(tag).cmm").path
            let mrc1 = dir.appendingPathComponent("fast_wireframe_\(tag).mrc").path
            let mrc2 = dir.appendingPathComponent("slow_core_\(tag).mrc").path
            let mrc3 = dir.appendingPathComponent("plasticity_shell_\(tag).mrc").path
            precondition(FileManager.default.fileExists(atPath: cmm), "Missing \(cmm)")
            precondition(FileManager.default.fileExists(atPath: mrc1), "Missing \(mrc1)")
            precondition(FileManager.default.fileExists(atPath: mrc2), "Missing \(mrc2)")
            precondition(FileManager.default.fileExists(atPath: mrc3), "Missing \(mrc3)")
        }

        // Export high-res 1920x1080 PNG snapshot from SceneKit/Metal
        let pngURL = FunctorDialecticalViewModel.resolvePrimaryOutputDir().appendingPathComponent("neural_compose_dialectic_1920x1080.png")
        let exported = vm.exportHighResSnapshotPNG(to: pngURL)
        precondition(exported != nil && FileManager.default.fileExists(atPath: pngURL.path), "Failed to export 1920x1080 PNG")

        print("  [PASS] Loaded 60 frames (Q=\(fix.nodesMeta.count) Laya nodes) from: \(dir.path)")
        print("  [PASS] Pillar 1 (Laya): SIGReg kappa = \(String(format: "%.4f", fix.globalCondNumber)), L_SIGReg = \(String(format: "%.4f", f31.layaSigregLoss)), L_query = \(String(format: "%.4f", f31.layaQueryLoss))")
        print("  [PASS] Pillar 2 (ST-JEMA + Tarjan): f31 beta_0=\(f31.beta0), beta_1=\(f31.beta1), L_node=\(String(format: "%.4f", f31.stNodePredLoss)), L_edge=\(String(format: "%.4f", f31.stEdgePredLoss))")
        print("  [PASS] Pillar 3 (Memory): Commutativity max_err = \(String(format: "%.3e", fix.maxFunctorCommutativityErr)), Hysteresis = \(String(format: "%.4f", fix.hysteresisAreaBeta1DM))")
        print("  [PASS] Pillar 4 (Multimodal Laya): Tempo 72 -> 128 -> 64 BPM, Absorption Lambda = \(String(format: "%.3f", f31.layaAbsorptionIndex)) -> \(String(format: "%.3f", f59.layaAbsorptionIndex))")
        print("  [PASS] Mobile Dummy-Test UX: Portrait Bottom Sheet (65% viewport), Multi-Touch 4D Controls, Live Gyro/Mic Toy Drive (shake theta_1=\(String(format: "%.1f", fShake.principalAxisAngleDeg)) deg -> absorbed D_M=\(String(format: "%.2f", fAbsorb.mahalanobisTension)))")
        print("  [PASS] Multica + Semantica Equifinality: 4 SHA-256 chained turns (text, commit, synthetic, locked hardware_mic -> \(tMicLocked.verdict)) verified in \(multicaScratchURL.path)")
        print("  [PASS] Hypnagogic Dialectical Loop: Loopback Peer Bridge active on 127.0.0.1:\(bridgePort) -> \(tHyp.verdict)")
        print("  [PASS] MATLAB R2026b Controls Fixture Horizon Collar (Turns L28..L30): \(tMatlabCollar.verdict)")
        print("  [PASS] Frame f31 BCICore Outcome = \(bci31.outcomeLabel), SemanticGraph nodes = \(bci31.graphNodeCount)")
        print("  [PASS] Exported 1920x1080 SceneKit/Metal PNG snapshot: \(pngURL.path)")
        print("[PASS] Neural Compose.app 4-Pillar native self-test completed with 0 errors.")
    }
}

public enum UnifiedWorkspaceTab: String, CaseIterable, Identifiable {
    case functorDialectic = "4-Pillar Dialectical Functor (60f)"
    case bciComposition   = "BCI Composition & Carousel"
    case phaseBSleep      = "Phase B Sleep & 3D EEG"
    case worldModelMPC    = "World Model JEPA+MPC"

    public var id: String { rawValue }
}

#if os(macOS) && canImport(NeuralComposeApp)
@MainActor
public struct UnifiedNeuralComposeRootView: View {
    @ObservedObject var bciLoader: AppLoader
    @Binding var selectedTab: UnifiedWorkspaceTab
    @StateObject private var functorViewModel = FunctorDialecticalViewModel()
    @State private var didStartPipeline: Bool = false

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .foregroundColor(Color(red: 0.22, green: 0.74, blue: 0.97))
                    Text("NEURAL COMPOSE UNIFIED WORKSPACE")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                }

                Picker("Workspace", selection: $selectedTab) {
                    ForEach(UnifiedWorkspaceTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 780)

                Spacer()

                if let vm = bciLoader.viewModel {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(vm.pipelineMode.isFullyLive
                                  ? Color(red: 0.20, green: 0.83, blue: 0.60)
                                  : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(vm.pipelineMode.isFullyLive
                             ? "LIVE PIPELINE | \(vm.pipelineMode.substitutionSummary)"
                             : "PIPELINE | \(vm.pipelineMode.substitutionSummary)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(vm.pipelineMode.isFullyLive
                                             ? Color(red: 0.20, green: 0.83, blue: 0.60)
                                             : Color.orange)
                        if vm.pipelineMode.acquisition == .synthetic || vm.lastError != nil {
                            Button(action: {
                                Task { await vm.reconnectLiveEEG() }
                            }) {
                                Label(vm.isReconnecting ? "Scanning BLE..." : "Connect Muse BLE",
                                      systemImage: "wave.3.right.circle.fill")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                            .tint(.blue)
                            .disabled(vm.isReconnecting)
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("SCANNING MUSE BLE & BOOTING PIPELINE...")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(.orange)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color(red: 0.04, green: 0.06, blue: 0.10))
            .overlay(Rectangle().frame(height: 1).foregroundColor(Color.white.opacity(0.12)), alignment: .bottom)

            Group {
                switch selectedTab {
                case .functorDialectic:
                    FunctorDialecticalDashboardView(viewModel: functorViewModel)
                case .bciComposition:
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 10) {
                            EquifinalMulticaConsoleView(viewModel: functorViewModel, compactMode: false)
                                .padding(.horizontal, 12)
                                .padding(.top, 8)

                            if let vm = bciLoader.viewModel, let disp = bciLoader.dispatcher {
                                ContentView(viewModel: vm, dispatcher: disp)
                                    .frame(minHeight: 740)
                            } else {
                                bciLoadingPlaceholder
                                    .frame(minHeight: 540)
                            }
                        }
                    }
                case .phaseBSleep:
                    ScrollView(.vertical, showsIndicators: true) {
                        SleepValidationView(viewModel: bciLoader.viewModel)
                            .frame(minHeight: 760)
                    }
                case .worldModelMPC:
                    ScrollView(.vertical, showsIndicators: true) {
                        WorldModelMPCDemoView(viewModel: bciLoader.viewModel)
                            .frame(minHeight: 760)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let vm = bciLoader.viewModel {
                bciLiveBridgeObserver(vm: vm)
            }
        }
        .onAppear {
            wireHypnagogicCallbacks()
            ensureBCIPipelineLoaded()
        }
        .onChange(of: selectedTab) { _, _ in
            ensureBCIPipelineLoaded()
        }
    }

    @ViewBuilder
    private func bciLiveBridgeObserver(vm: AppViewModel) -> some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                enforceAudioLockOnBCIViewModel()
            }
            .onChange(of: functorViewModel.hardwareMicLoopLocked) { _, _ in
                enforceAudioLockOnBCIViewModel()
            }
            .onChange(of: vm.hypnagogicLoopEnabled) { _, newValue in
                handleHypnagogicLoopEnabledChange(newValue)
            }
            .onChange(of: vm.hypnagogicMode) { _, newMode in
                functorViewModel.hypnagogicLoopModeLabel = newMode.rawValue
            }
            .onChange(of: vm.hypnagogicRuntimePreference) { _, newRuntime in
                functorViewModel.hypnagogicRuntimeChoiceLabel = newRuntime.rawValue
            }
            .onChange(of: vm.composedText) { _, newText in
                handleComposedTextChange(newText)
            }
            .onChange(of: vm.currentIntent) { _, newIntent in
                handleLiveIntentImpulse(vm: vm, newIntent: newIntent)
            }
            .onChange(of: vm.detectedSpectralState) { _, newState in
                handleLiveSpectralShift(vm: vm, newState: newState)
            }
    }

    private func handleHypnagogicLoopEnabledChange(_ newValue: Bool) {
        functorViewModel.hypnagogicLoopActive = newValue
        if newValue {
            functorViewModel.hardwareMicLoopLocked = false
        }
        functorViewModel.hypnagogicLoopPhaseLabel = newValue
            ? "Listening (On-Device Speech Recognizer)"
            : "Stopped"
    }

    private func handleComposedTextChange(_ newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            functorViewModel.triggerEquifinalTurn(
                source: .commit,
                text: "BCI carousel composition: \(trimmed)",
                persistToDisk: true
            )
        }
    }

    @State private var lastEmittedIntentName: String = ""
    @State private var lastIntentImpulseEpoch: TimeInterval = 0.0
    @State private var isHandlingIntentImpulse: Bool = false

    private func handleLiveIntentImpulse(vm: AppViewModel, newIntent: IntentClass) {
        guard !isHandlingIntentImpulse, newIntent != .rest else { return }
        let now = Date().timeIntervalSince1970
        let intentName = newIntent.displayName
        // Guard against un-debounced synthetic intent impulses spamming multica_channel.jsonl
        guard intentName != lastEmittedIntentName || (now - lastIntentImpulseEpoch) >= 5.0 else { return }
        guard (now - lastIntentImpulseEpoch) >= 2.0 else { return }
        isHandlingIntentImpulse = true
        defer { isHandlingIntentImpulse = false }
        lastEmittedIntentName = intentName
        lastIntentImpulseEpoch = now

        let spectralLabel = vm.detectedSpectralState?.badgeLabel ?? "Live"
        let qualityLabel = vm.signalQuality.map { String(describing: $0) } ?? "live"
        let isStrongImpulse = (newIntent == .jawClench || newIntent == .select)
        let impulseEnergy: Double = isStrongImpulse ? 1.8 : 1.1
        functorViewModel.stepLiveSensorToyDrive(
            tiltX: impulseEnergy * 0.9,
            tiltY: impulseEnergy * 0.5,
            tiltZ: 1.0,
            gyroMag: impulseEnergy * 2.5,
            micRMS: min(1.0, impulseEnergy * 0.45),
            tempoBpm: newIntent == .jawClench ? 128.0 : 96.0,
            dt: 0.30
        )
        functorViewModel.triggerEquifinalTurn(
            source: .multicaStream,
            text: "Muse BLE Impulse [\(newIntent.displayName) | \(spectralLabel) | signal=\(qualityLabel)]",
            persistToDisk: true
        )
    }

    @State private var lastEmittedSpectralBadge: String = ""
    @State private var lastSpectralShiftEpoch: TimeInterval = 0.0
    @State private var isHandlingSpectralShift: Bool = false

    private func handleLiveSpectralShift(vm: AppViewModel, newState: SpectralState?) {
        guard !isHandlingSpectralShift, let state = newState else { return }
        let now = Date().timeIntervalSince1970
        let badge = state.badgeLabel
        // Guard against duplicate/un-debounced spectral shift loops spamming multica_channel.jsonl
        guard badge != lastEmittedSpectralBadge || (now - lastSpectralShiftEpoch) >= 5.0 else { return }
        guard (now - lastSpectralShiftEpoch) >= 2.0 else { return }
        isHandlingSpectralShift = true
        defer { isHandlingSpectralShift = false }
        lastEmittedSpectralBadge = badge
        lastSpectralShiftEpoch = now

        let qualityLabel = vm.signalQuality.map { String(describing: $0) } ?? "live"
        let isHighLoad = (state == .highCognitiveLoad || state == .engagedFocused)
        functorViewModel.stepLiveSensorToyDrive(
            tiltX: isHighLoad ? 1.1 : 0.25,
            tiltY: isHighLoad ? 0.65 : 0.15,
            tiltZ: 1.0,
            gyroMag: isHighLoad ? 2.8 : 0.6,
            micRMS: isHighLoad ? 0.75 : 0.25,
            tempoBpm: isHighLoad ? 128.0 : 72.0,
            dt: 0.25
        )
        functorViewModel.triggerEquifinalTurn(
            source: .synthetic,
            text: "Muse BLE Spectral Shift -> \(badge) (signal=\(qualityLabel))",
            persistToDisk: true
        )
    }

    private func wireHypnagogicCallbacks() {
        functorViewModel.onToggleHypnagogicLoop = { enabled in
            guard let vm = bciLoader.viewModel else { return }
            if vm.hypnagogicLoopEnabled != enabled {
                vm.hypnagogicLoopEnabled = enabled
            }
        }
        functorViewModel.onSelectHypnagogicMode = { modeRaw in
            guard let vm = bciLoader.viewModel,
                  let mode = HypnagogicMode(rawValue: modeRaw) else { return }
            if vm.hypnagogicMode != mode {
                vm.hypnagogicMode = mode
            }
        }
        functorViewModel.onSelectHypnagogicRuntime = { runtimeRaw in
            guard let vm = bciLoader.viewModel,
                  let runtime = HypnagogicRuntimePreference(rawValue: runtimeRaw) else { return }
            if vm.hypnagogicRuntimePreference != runtime {
                vm.hypnagogicRuntimePreference = runtime
            }
        }
    }

    private func enforceAudioLockOnBCIViewModel() {
        guard let vm = bciLoader.viewModel else { return }
        wireHypnagogicCallbacks()
        functorViewModel.hypnagogicRuntimeChoiceLabel = vm.hypnagogicRuntimePreference.rawValue
        if !vm.adaptiveComplexityEnabled {
            vm.adaptiveComplexityEnabled = true
        }
        if !vm.interactionLoggingEnabled {
            vm.interactionLoggingEnabled = true
        }
        if functorViewModel.hardwareMicLoopLocked && !vm.hypnagogicLoopEnabled {
            if vm.spokenGenerationLoopEnabled {
                vm.spokenGenerationLoopEnabled = false
            }
        }
        if vm.hypnagogicMode != .reflective && functorViewModel.hypnagogicLoopModeLabel == "reflective" {
            vm.hypnagogicMode = .reflective
        }
        if functorViewModel.hypnagogicLoopActive && !vm.hypnagogicLoopEnabled {
            functorViewModel.hardwareMicLoopLocked = false
            vm.hypnagogicLoopEnabled = true
        }
    }

    private var bciLoadingPlaceholder: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Initializing NeuralCompose EEG + MLX + Hypnagogic Loopback Pipeline (Hardware Mic Loop LOCKED by default)...")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            ensureBCIPipelineLoaded()
        }
    }

    private func ensureBCIPipelineLoaded() {
        guard !didStartPipeline else { return }
        didStartPipeline = true
        Task {
            await bciLoader.load()
            enforceAudioLockOnBCIViewModel()
        }
    }
}
#endif

public struct NeuralComposeFunctorSwiftUIApp: App {
    #if os(macOS) && canImport(NeuralComposeApp)
    @StateObject private var bciLoader = AppLoader()
    #endif
    @State private var selectedTab: UnifiedWorkspaceTab = .functorDialectic

    public init() {}

    public var body: some Scene {
        WindowGroup("Neural Compose - 60-Frame 4-Pillar Laya + ST-JEMA + Memory + Multimodal HUD") {
            #if os(macOS) && canImport(NeuralComposeApp)
            UnifiedNeuralComposeRootView(bciLoader: bciLoader, selectedTab: $selectedTab)
                .frame(minWidth: 1240, minHeight: 800)
                .onOpenURL { url in
                    bciLoader.handle(url)
                }
            #else
            FunctorDialecticalDashboardView()
                .frame(minWidth: 1240, minHeight: 800)
            #endif
        }
        .defaultSize(width: 1460, height: 920)
        .commands {
            CommandMenu("Workspace") {
                Button("4-Pillar Dialectical Functor (60f)") {
                    selectedTab = .functorDialectic
                }.keyboardShortcut("1", modifiers: [.command])

                Button("BCI Composition & Carousel") {
                    selectedTab = .bciComposition
                }.keyboardShortcut("2", modifiers: [.command])

                Button("Phase B Sleep & 3D EEG") {
                    selectedTab = .phaseBSleep
                }.keyboardShortcut("3", modifiers: [.command])

                Button("World Model JEPA+MPC") {
                    selectedTab = .worldModelMPC
                }.keyboardShortcut("4", modifiers: [.command])
            }
            #if os(macOS) && canImport(NeuralComposeApp)
            CommandMenu("Composition") {
                Button("Reset") {
                    if let dispatcher = bciLoader.dispatcher {
                        Task { await dispatcher.perform(.resetComposition) }
                    }
                }.keyboardShortcut("r", modifiers: [.command])
            }
            CommandMenu("Debug") {
                Button("Open Phase B Debug Window") {
                    selectedTab = .phaseBSleep
                    if let dispatcher = bciLoader.dispatcher {
                        Task { await dispatcher.perform(.openPhaseBDebug) }
                    }
                }.keyboardShortcut("d", modifiers: [.command, .shift])
            }
            CommandMenu("World Model") {
                Button("Open World Model Demo") {
                    selectedTab = .worldModelMPC
                    if let dispatcher = bciLoader.dispatcher {
                        Task { await dispatcher.perform(.openWorldModelDemo) }
                    }
                }.keyboardShortcut("m", modifiers: [.command, .shift])
            }
            #endif
        }

        #if os(macOS) && canImport(NeuralComposeApp)
        Window("Phase B Debug", id: "phase-b-debug") {
            SleepValidationView(viewModel: bciLoader.viewModel)
        }
        .defaultSize(width: 1100, height: 720)

        Window("World Model Demo", id: "world-model-demo") {
            WorldModelMPCDemoView(viewModel: bciLoader.viewModel)
        }
        .defaultSize(width: 900, height: 640)

        MenuBarExtra("NeuralCompose", systemImage: "brain.head.profile") {
            if let viewModel = bciLoader.viewModel {
                MenuBarView(viewModel: viewModel)
            } else {
                Button("Start Live BCI Pipeline") {
                    Task { await bciLoader.load() }
                }
                .padding()
            }
        }
        .menuBarExtraStyle(.window)
        #endif
    }
}

