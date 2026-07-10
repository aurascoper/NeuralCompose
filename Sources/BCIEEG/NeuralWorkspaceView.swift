import Foundation
import AppKit
import SceneKit
import BCICore
import QuartzCore

/// 3D neural workspace — live topographical visualization of the 4 Muse
/// electrodes as nodes in 3D space, animated by real-time EEG features.
///
/// ## Mathematical interpretation
///
/// The 4 Muse electrodes (TP9, AF7, AF8, TP10) are modeled as a point cloud
/// in 3D head-space, with approximate scalp positions from the
/// international 10-20 system:
///
/// ```
///     AF7 --- AF8         (forehead, above eyebrows)
///      |       |
///     TP9 --- TP10        (behind ears, mastoids)
/// ```
///
/// The visualization applies a perspective camera projection
/// `p = K[R|t] x` where `x ∈ R^3` is the electrode position in head
/// coordinates and `p ∈ R^2` is the screen-space pixel. SceneKit handles
/// this automatically; the structure of the scene graph is what we own.
///
/// Per-channel features (computed from the live EEG stream) drive
/// node animations:
///
/// - **Alpha-band power** → emissive intensity (brightness) of each node
///   via the alpha bandpass + RMS. Higher alpha = brighter node.
/// - **Theta-band power** → Y-position offset (elevation). Higher theta
///   = node rises above its rest position.
/// - **Classifier confidence** → edge thickness between the active
///   electrode and the highest-confidence neighbor. Optional; only
///   enabled when a classifier output is bound.
/// - **FSM state** → overall scene tint. The 4 sleep-stage predictions
///   (Wake, N1, N2_N3, Uncertain_REM) map to 4 distinct color tints.
///
/// ## Why a 3D scene graph and not a 2D heatmap
///
/// 2D topographical maps are a 30-year-old standard. A 3D scene lets
/// the user see the signal as a moving object rather than a colored
/// surface, which makes subtle changes (e.g., one electrode's alpha
/// rising independently of the others) more legible. The 3D scene
/// also lets us animate the FSM state as a real transition through
/// a state graph, not just a color change.
///
/// ## Where this lives in the Sleep Validation Toolkit
///
/// §21 of `SLEEP_CYCLE_DESIGN.md` defines the toolkit as 8 small
/// components. The 3D workspace is component #2 (the plotter is #1).
/// The workspace consumes the same `EEGStream` as the plotter; both
/// can be open simultaneously without contention.
@MainActor
public final class NeuralWorkspaceView: NSView {

    // MARK: - Public configuration

    /// The four Muse electrodes, in display order. The order is the
    /// standard Muse S / Muse 2 GATT layout: TP9, AF7, AF8, TP10.
    public struct Electrode {
        public let id: String       // "TP9", "AF7", "AF8", "TP10"
        public let position: SCNVector3   // head-space position, meters
        public let restY: Float           // baseline Y for theta elevation

        public init(id: String, position: SCNVector3, restY: Float) {
            self.id = id
            self.position = position
            self.restY = restY
        }
    }

    public var electrodes: [Electrode] = [] {
        didSet { rebuildScene() }
    }

    /// Camera distance from the scene center. Smaller = closer.
    public var cameraDistance: Float = 0.30 {
        didSet { updateCamera() }
    }

    /// Field of view in degrees.
    public var fieldOfView: Double = 45.0 {
        didSet { updateCamera() }
    }

    /// Updates per second. The view throttles to this rate regardless
    /// of how fast the EEG stream produces samples (default ~30 Hz).
    public var animationHz: Double = 30.0

    // MARK: - Private state

    private var scnView: SCNView!
    private var scene: SCNScene!
    private var cameraNode: SCNNode!
    private var nodeMap: [String: SCNNode] = [:]
    private var edgeMap: [String: SCNNode] = [:]  // "i-j" with i<j
    private var ringBuffer: [String: [Double]] = [:]  // per-electrode time-domain
    private let ringCapacity: Int = 256 * 2  // 2-second buffer per electrode
    private var alphaFilter: [String: Biquad1P] = [:]  // per-electrode biquad state
    private var thetaFilter: [String: Biquad1P] = [:]
    private var streamTask: Task<Void, Never>?
    private var displayLink: CVDisplayLink?
    private var lastUpdate: CFTimeInterval = 0
    private var fsmState: FSMState = .idle
    private var consumed: UInt64 = 0

    // MARK: - Classifier + embedding diagnostic state
    //
    // Both are additive to the EEG-sample-driven visualization above: the
    // view renders fine with neither bound. See `subscribeClassifier(to:)`
    // and `subscribeEmbeddings(provider:contextProvider:)`.

    private var classifierStreamTask: Task<Void, Never>?
    /// Most recent classifier confidence (0...1), or nil if never bound.
    /// Modulates overall edge-pulse intensity in `recompute()`. This is a
    /// *global* modulation, not per-edge: `IntentClass` (jaw clench / blink
    /// / rest / select) isn't localized to a specific electrode pair in a
    /// 4-channel Muse montage, so there's no honest "highest-confidence
    /// neighbor" to single out.
    private var latestClassifierConfidence: Float?

    private var embeddingTask: Task<Void, Never>?
    /// Most recent embedding vector from `TokenEmbeddingProviding`, kept
    /// around for inspection/future re-projection.
    public private(set) var latestEmbedding: [Float] = []
    /// Reduces `latestEmbedding` to a 3D point for `embeddingNode`. Default
    /// is `RandomProjectionProjector` — see that type's doc comment for why
    /// its output is a visualization convenience, not a semantically
    /// meaningful layout. Swappable (e.g. for a future `PCAProjector`)
    /// without touching anything else in this view.
    public var embeddingProjector: any EmbeddingProjecting = RandomProjectionProjector()
    /// Freestanding marker node whose position is
    /// `embeddingProjector.project(latestEmbedding)`, normalized onto a
    /// fixed-radius shell so it stays on-screen regardless of the input
    /// vector's magnitude (raw logits are unbounded). Separate from the 4
    /// electrode nodes — electrode position already encodes theta
    /// elevation, so this stays a distinct signal rather than overloading
    /// electrode placement with unrelated embedding data.
    private var embeddingNode: SCNNode!

    public enum FSMState: String {
        case idle = "Idle"
        case wake = "Wake"
        case n1 = "N1"
        case n2n3 = "N2/N3"
        case rem = "REM?"
    }

    // MARK: - Init

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        self.electrodes = Self.defaultElectrodes
        for id in ["TP9", "AF7", "AF8", "TP10"] {
            alphaFilter[id] = Biquad1P.bandpass(lowHz: 8.0, highHz: 13.0, sampleRate: 256.0)
            thetaFilter[id] = Biquad1P.bandpass(lowHz: 4.0, highHz: 8.0, sampleRate: 256.0)
        }
        buildScene()
        startDisplayLink()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        self.electrodes = Self.defaultElectrodes
        for id in ["TP9", "AF7", "AF8", "TP10"] {
            alphaFilter[id] = Biquad1P.bandpass(lowHz: 8.0, highHz: 13.0, sampleRate: 256.0)
            thetaFilter[id] = Biquad1P.bandpass(lowHz: 4.0, highHz: 8.0, sampleRate: 256.0)
        }
        buildScene()
        startDisplayLink()
    }

    deinit {
        streamTask?.cancel()
        classifierStreamTask?.cancel()
        embeddingTask?.cancel()
        // CVDisplayLink cleanup happens implicitly.
    }

    public override func layout() {
        super.layout()
        scnView?.frame = bounds
    }

    // MARK: - Scene construction

    private static let defaultElectrodes: [Electrode] = [
        // Approximate 10-20 head positions, scaled to a unit-ish "head" of radius 0.10 m.
        // TP9/TP10 are behind the ears (mastoids), at y ≈ 0.
        // AF7/AF8 are on the forehead, slightly above center.
        Electrode(id: "TP9",  position: SCNVector3(-0.09, 0.00, -0.02), restY: 0.00),
        Electrode(id: "AF7",  position: SCNVector3(-0.04, 0.05,  0.08), restY: 0.05),
        Electrode(id: "AF8",  position: SCNVector3( 0.04, 0.05,  0.08), restY: 0.05),
        Electrode(id: "TP10", position: SCNVector3( 0.09, 0.00, -0.02), restY: 0.00),
    ]

    private func buildScene() {
        let v = SCNView(frame: bounds)
        v.autoresizingMask = [.width, .height]
        v.allowsCameraControl = true   // user can pan/zoom with mouse
        v.backgroundColor = NSColor(white: 0.05, alpha: 1.0)
        v.antialiasingMode = .multisampling2X
        addSubview(v)
        scnView = v

        let s = SCNScene()
        s.background.contents = NSColor(white: 0.05, alpha: 1.0)
        v.scene = s
        scene = s

        // Ambient + key light so the spheres have visible shading.
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.color = NSColor(white: 0.4, alpha: 1.0)
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.color = NSColor(white: 0.9, alpha: 1.0)
        key.eulerAngles = SCNVector3(-0.6, 0.4, 0.0)
        scene.rootNode.addChildNode(key)

        // Camera
        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.fieldOfView = fieldOfView
        cam.camera?.zNear = 0.001
        cam.camera?.zFar = 10.0
        scene.rootNode.addChildNode(cam)
        cameraNode = cam
        updateCamera()

        // Head outline (a wireframe icosahedron) as a spatial reference.
        let head = SCNSphere(radius: 0.10)
        head.segmentCount = 32
        let headNode = SCNNode(geometry: head)
        headNode.geometry?.firstMaterial?.diffuse.contents =
            NSColor(white: 0.15, alpha: 0.3)
        headNode.geometry?.firstMaterial?.transparency = 0.5
        headNode.geometry?.firstMaterial?.fillMode = .lines   // wireframe
        headNode.geometry?.firstMaterial?.lightingModel = .constant
        scene.rootNode.addChildNode(headNode)

        // Embedding marker — a distinct small node, separate from the 4
        // electrode spheres, so embedding-driven position never overloads
        // electrode placement (which already encodes theta elevation).
        // Starts at the head center; `recompute()` moves it once an
        // embedding has actually been ingested.
        let embeddingGeometry = SCNSphere(radius: 0.008)
        embeddingGeometry.firstMaterial?.diffuse.contents = NSColor(white: 0.9, alpha: 1.0)
        embeddingGeometry.firstMaterial?.emission.contents = NSColor(red: 0.7, green: 0.5, blue: 1.0, alpha: 1.0)
        embeddingGeometry.firstMaterial?.emission.intensity = 0.6
        embeddingGeometry.firstMaterial?.lightingModel = .constant
        let embNode = SCNNode(geometry: embeddingGeometry)
        embNode.position = SCNVector3(0, 0.03, 0)
        embNode.name = "embedding"
        scene.rootNode.addChildNode(embNode)
        embeddingNode = embNode

        // The 4 electrode nodes + 4 connecting edges.
        rebuildScene()
    }

    private func rebuildScene() {
        // Remove existing nodes and edges.
        nodeMap.values.forEach { $0.removeFromParentNode() }
        edgeMap.values.forEach { $0.removeFromParentNode() }
        nodeMap.removeAll()
        edgeMap.removeAll()

        // Build per-electrode spheres.
        for e in electrodes {
            let sphere = SCNSphere(radius: 0.012)
            let node = SCNNode(geometry: sphere)
            node.position = e.position
            node.name = e.id
            let m = SCNMaterial()
            m.diffuse.contents = Self.colorForElectrode(e.id)
            m.emission.contents = NSColor(white: 0.0, alpha: 1.0)
            m.lightingModel = .physicallyBased
            sphere.firstMaterial = m
            scene.rootNode.addChildNode(node)
            nodeMap[e.id] = node
            ringBuffer[e.id] = []
        }

        // Build 4 connecting edges (the quad is TP9-AF7-AF8-TP10; we
        // also include the diagonals AF7-AF8 and TP9-TP10 for visual
        // completeness, so 6 edges total).
        let edges: [(String, String)] = [
            ("TP9", "AF7"),
            ("AF7", "AF8"),
            ("AF8", "TP10"),
            ("TP9", "TP10"),
            ("TP9", "AF8"),
            ("AF7", "TP10"),
        ]
        for (a, b) in edges {
            guard let pa = nodeMap[a]?.position, let pb = nodeMap[b]?.position else { continue }
            let edge = makeEdgeNode(from: pa, to: pb)
            let key = a < b ? "\(a)-\(b)" : "\(b)-\(a)"
            edge.name = key
            scene.rootNode.addChildNode(edge)
            edgeMap[key] = edge
        }
    }

    private func makeEdgeNode(from a: SCNVector3, to b: SCNVector3) -> SCNNode {
        // Build a thin cylinder between two points.
        let dx = Float(b.x - a.x), dy = Float(b.y - a.y), dz = Float(b.z - a.z)
        let length = sqrt(dx*dx + dy*dy + dz*dz)
        let cyl = SCNCylinder(radius: 0.0015, height: CGFloat(length))
        cyl.firstMaterial?.diffuse.contents = NSColor(white: 0.5, alpha: 0.7)
        cyl.firstMaterial?.emission.contents = NSColor(white: 0.0, alpha: 1.0)
        cyl.firstMaterial?.lightingModel = .constant
        let n = SCNNode(geometry: cyl)
        // Place at midpoint, oriented along the segment.
        n.position = SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
        // Cylinders in SceneKit are along the Y axis. Rotate to align with the segment.
        let dir = simd_float3(dx, dy, dz)
        let yAxis = simd_float3(0, 1, 0)
        let len = simd_length(dir)
        guard len > 0 else { return n }
        let normalized = dir / len
        let dot = simd_dot(yAxis, normalized)
        if abs(dot) < 0.9999 {
            let axis = simd_normalize(simd_cross(yAxis, normalized))
            let angle = acos(dot)
            n.rotation = SCNVector4(axis.x, axis.y, axis.z, angle)
        } else if dot < 0 {
            n.rotation = SCNVector4(1, 0, 0, Float.pi)
        }
        return n
    }

    private static func colorForElectrode(_ id: String) -> NSColor {
        switch id {
        case "TP9":  return NSColor(red: 0.40, green: 0.80, blue: 0.40, alpha: 1.0)
        case "AF7":  return NSColor(red: 0.40, green: 0.60, blue: 1.00, alpha: 1.0)
        case "AF8":  return NSColor(red: 1.00, green: 0.70, blue: 0.30, alpha: 1.0)
        case "TP10": return NSColor(red: 0.95, green: 0.30, blue: 0.55, alpha: 1.0)
        default:     return NSColor.white
        }
    }

    private func updateCamera() {
        guard let cam = cameraNode else { return }
        cam.camera?.fieldOfView = fieldOfView
        cam.position = SCNVector3(0, 0.03, cameraDistance)
        cam.eulerAngles = SCNVector3(-0.05, 0.0, 0.0)
        cam.look(at: SCNVector3(0, 0.03, 0))
    }

    // MARK: - Stream consumption

    /// Subscribe to an `AsyncThrowingStream<EEGSample, Error>` from
    /// `BrainFlowService.start()`. Replaces any prior subscription.
    public func subscribe<Failure: Error>(to stream: AsyncThrowingStream<EEGSample, Failure>) {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            do {
                for try await sample in stream {
                    guard let self else { return }
                    self.ingest(sample)
                }
            } catch {
                BCILog.eeg.error("NeuralWorkspace stream error: \(error)")
            }
        }
    }

    public func cancelSubscription() {
        streamTask?.cancel()
        streamTask = nil
    }

    /// Subscribe to raw classifier output, e.g. `AppViewModel.liveClassifierStream()`
    /// wrapped in the same throwing-stream adapter used for EEG samples.
    /// Diagnostic only — independent of the FSM/carousel path, so nothing
    /// here can affect composition.
    public func subscribeClassifier<Failure: Error>(to stream: AsyncThrowingStream<IntentPrediction, Failure>) {
        classifierStreamTask?.cancel()
        classifierStreamTask = Task { [weak self] in
            do {
                for try await prediction in stream {
                    guard let self else { return }
                    self.latestClassifierConfidence = prediction.confidence
                }
            } catch {
                BCILog.eeg.error("NeuralWorkspace classifier stream error: \(error)")
            }
        }
    }

    public func cancelClassifierSubscription() {
        classifierStreamTask?.cancel()
        classifierStreamTask = nil
    }

    /// Periodically pull a contextual embedding from `provider` for whatever
    /// `contextProvider()` returns at call time (e.g. the live composed
    /// text). `contextProvider` and this method must only be called on the
    /// main actor — `NeuralWorkspaceView` is `@MainActor`, and the polling
    /// loop below inherits that isolation since it isn't `.detached`.
    ///
    /// Stores the vector in `latestEmbedding`; `recompute()` reduces it via
    /// `embeddingProjector` to place `embeddingNode` each frame. See
    /// `RandomProjectionProjector`'s doc comment for why that placement is
    /// a visualization convenience and not a semantically meaningful
    /// layout, and `TokenEmbeddingProviding` for why the vector itself is
    /// currently a logit vector rather than a hidden state.
    public func subscribeEmbeddings(
        provider: any TokenEmbeddingProviding,
        contextProvider: @escaping () -> String,
        interval: TimeInterval = 1.0
    ) {
        embeddingTask?.cancel()
        embeddingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let text = contextProvider()
                if let vector = try? await provider.embedding(for: text) {
                    self.latestEmbedding = vector
                }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    public func cancelEmbeddingSubscription() {
        embeddingTask?.cancel()
        embeddingTask = nil
    }

    /// Ingest a single sample. Thread-safe only on the main actor.
    public func ingest(_ sample: EEGSample) {
        // Map EEGSample.channels to the 4 electrodes in our known order:
        //   sample.channels[0] -> TP9
        //   sample.channels[1] -> AF7
        //   sample.channels[2] -> AF8
        //   sample.channels[3] -> TP10
        let map = ["TP9": 0, "AF7": 1, "AF8": 2, "TP10": 3]
        for (id, idx) in map {
            guard idx < sample.channels.count, var buf = ringBuffer[id] else { continue }
            buf.append(Double(sample.channels[idx]))
            if buf.count > ringCapacity { buf.removeFirst() }
            ringBuffer[id] = buf
        }
        consumed &+= 1
    }

    /// Update the FSM state visualization. Called by the host.
    public func setFSMState(_ state: FSMState) {
        fsmState = state
    }

    // MARK: - Display link

    private func startDisplayLink() {
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }
        let cb: CVDisplayLinkOutputCallback = { _, _, _, _, _, ctx in
            guard let ctx else { return kCVReturnSuccess }
            let view = Unmanaged<NeuralWorkspaceView>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { view.tick() }
            return kCVReturnSuccess
        }
        CVDisplayLinkSetOutputCallback(link, cb, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(link)
        displayLink = link
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let interval = 1.0 / max(animationHz, 1.0)
        guard now - lastUpdate >= interval else { return }
        lastUpdate = now
        recompute()
    }

    private func recompute() {
        // Per-electrode alpha and theta power → drive node animations.
        for (id, buf) in ringBuffer {
            guard buf.count > 32,
                  let node = nodeMap[id],
                  let electrode = electrodes.first(where: { $0.id == id })
            else { continue }
            // Bandpass filter the entire buffer (DFT-II transposed biquad).
            // For visualization we don't need exact band power, just a
            // stable, band-limited RMS. We use a 2nd-order Butterworth
            // from BCICore's BandpassFilter.
            // Filter into alpha and theta bands using per-electrode
            // biquad state, then compute RMS as a proxy for band power.
            guard let abq0 = alphaFilter[id], let tbq0 = thetaFilter[id] else { continue }
            var abq = abq0
            var tbq = tbq0
            var alphaAcc: Double = 0
            var thetaAcc: Double = 0
            for v in buf {
                let a = abq.process(v)
                let t = tbq.process(v)
                alphaAcc += a * a
                thetaAcc += t * t
            }
            // Write the updated biquad state back to the dictionary.
            alphaFilter[id] = abq
            thetaFilter[id] = tbq
            let alpha = sqrt(alphaAcc / Double(buf.count))
            let theta = sqrt(thetaAcc / Double(buf.count))
            // Map alpha to emissive intensity (0-1). We use a log
            // compression so small changes are visible and large
            // changes don't saturate.
            let intensity = log1p(Float(alpha) * 50.0).clamped(to: 0...1)
            if let mat = node.geometry?.firstMaterial {
                mat.emission.contents = Self.colorForElectrode(id).withAlphaComponent(1.0)
                mat.emission.intensity = CGFloat(intensity)
            }
            // Map theta to Y elevation above rest.
            let elevation = Float(log1p(theta * 30.0)).clamped(to: 0...0.04)
            node.position = SCNVector3(
                electrode.position.x,
                CGFloat(electrode.restY + elevation),
                electrode.position.z
            )
        }
        // Edge "pulse" — slow oscillation by FSM state, so the user
        // can see the state visually even without looking at any UI.
        // Classifier confidence (if bound) scales the pulse amplitude
        // globally: higher confidence = a more pronounced pulse. This is
        // deliberately not per-edge — see `latestClassifierConfidence`'s
        // doc comment for why there's no honest per-electrode mapping.
        let edgePulse: Float = edgePulseForFSM()
        let clampedConfidence: Float = (latestClassifierConfidence ?? 1.0).clamped(to: 0...1)
        let confidenceScale: Float = 0.5 + 0.5 * clampedConfidence
        let radius: Float = 0.0015 + 0.0008 * edgePulse * confidenceScale
        let intensity: Float = (0.3 + 0.4 * edgePulse) * confidenceScale
        for (_, edge) in edgeMap {
            guard let cyl = edge.geometry as? SCNCylinder,
                  let mat = cyl.firstMaterial
            else { continue }
            cyl.radius = CGFloat(radius)
            mat.emission.contents = Self.fsmColor(fsmState)
            mat.emission.intensity = CGFloat(intensity)
        }

        // Embedding marker position — projected via `embeddingProjector`,
        // then normalized onto a fixed-radius shell (raw logits are
        // unbounded, so a normalized direction is what's actually stable
        // to look at; magnitude isn't discarded for any principled reason,
        // just because an unbounded value would send the marker off-screen).
        if !latestEmbedding.isEmpty {
            let projected = embeddingProjector.project(latestEmbedding)
            let norm = simd_length(projected)
            if norm > 1e-6 {
                let unit = projected / norm
                let shellRadius: Float = 0.06
                embeddingNode.position = SCNVector3(
                    CGFloat(unit.x * shellRadius),
                    CGFloat(0.03 + unit.y * shellRadius * 0.5),
                    CGFloat(unit.z * shellRadius)
                )
            }
        }
    }

    private func edgePulseForFSM() -> Float {
        // Sinusoidal pulse, phase-shifted per state.
        let t = Float(CACurrentMediaTime())
        let phase: Float
        switch fsmState {
        case .idle: phase = 0
        case .wake: phase = .pi / 4
        case .n1: phase = .pi / 2
        case .n2n3: phase = 3 * .pi / 4
        case .rem: phase = .pi
        }
        return (sin(t * 1.5 + phase) + 1) / 2
    }

    private static func fsmColor(_ state: FSMState) -> NSColor {
        switch state {
        case .idle: return NSColor(white: 0.4, alpha: 1.0)
        case .wake: return NSColor(red: 1.0, green: 0.85, blue: 0.3, alpha: 1.0)
        case .n1:   return NSColor(red: 0.4, green: 0.7, blue: 1.0, alpha: 1.0)
        case .n2n3: return NSColor(red: 0.5, green: 0.4, blue: 1.0, alpha: 1.0)
        case .rem:  return NSColor(red: 1.0, green: 0.5, blue: 0.7, alpha: 1.0)
        }
    }

    private func bandRMS(_ x: [Double]) -> Double {
        // Legacy helper kept for documentation. Real band separation
        // is done in `recompute()` using per-electrode biquad state.
        guard x.count > 32 else { return 0 }
        var sumSq = 0.0
        for i in 1..<x.count {
            let d = x[i] - x[i-1]
            sumSq += d * d
        }
        return sqrt(sumSq / Double(x.count - 1))
    }
}

// MARK: - Per-electrode 2nd-order Butterworth bandpass (single-pole cascade)
//
// A 2nd-order Butterworth bandpass implemented as a cascade of one
// 2nd-order Butterworth bandpass section. Coefficients are computed
// at construction time via the bilinear transform. The biquad has
// stateful z1/z2, so we keep one per electrode (4 total).
struct Biquad1P {
    var b0: Double
    var b1: Double
    var b2: Double
    var a1: Double
    var a2: Double
    var z1: Double = 0
    var z2: Double = 0

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    static func bandpass(lowHz: Double, highHz: Double, sampleRate: Double) -> Biquad1P {
        // Bilinear transform of a 2nd-order Butterworth bandpass.
        // Reference: Smith, "Introduction to Digital Filters", §19.5.
        let f0 = (lowHz + highHz) / 2.0
        let bw = highHz - lowHz
        let w0 = 2.0 * .pi * f0 / sampleRate
        let q  = f0 / bw
        let alpha = sin(w0) / (2.0 * q)
        let cosw0 = cos(w0)
        let b0 =  alpha
        let b1 =  0.0
        let b2 = -alpha
        let a0 =  1.0 + alpha
        let a1 = -2.0 * cosw0
        let a2 =  1.0 - alpha
        return Biquad1P(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0,
                        a1: a1 / a0, a2: a2 / a0)
    }
}

// MARK: - Helpers

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}
