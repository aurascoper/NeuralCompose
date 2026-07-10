import Foundation
import AppKit
import QuartzCore
import BCICore

/// 3D depth-stacked EEG plotter for the Sleep Validation Toolkit.
///
/// Renders up to N channels (default 4: TP9, AF7, AF8, TP10) as horizontally
/// scrolling traces on separate CALayers, each translated along the z-axis
/// to give a "scalp" or "tier" effect. The 3D effect is implemented with
/// `CATransform3D` perspective on a parent container layer; per-channel layers
/// then translate-z in 30-50 pt increments so the traces appear stacked in
/// depth from the viewer's perspective.
///
/// Design rationale (§21.4 of the design doc):
/// - The plotter is the first thing to build because it makes the raw signal
///   observable. Without it, every downstream debugging session is blind.
/// - "3D" is a visual aid, not a signal-processing feature. It lets the user
///   visually separate channels when 4 traces overlap.
/// - The scale property is a single knob the user can adjust in the debug
///   view: it controls both the Y amplitude (microvolts per pixel) and the
///   visual depth (z-spacing between channels). At scale=1.0 the default
///   amplitude is ~50 µV full-scale and the depth spacing is 30 pt.
///
/// The view is not user-facing. It is opened in the debug view (§21.3).
@MainActor
public final class EEGScalpPlotterView: NSView {

    // MARK: - Public configuration

    /// Channel labels in display order. Default is the Muse S layout.
    public var channelLabels: [String] = ["TP9", "AF7", "AF8", "TP10"] {
        didSet { rebuildLayers() }
    }

    /// Time window shown on the x-axis, in seconds.
    public var timeWindowSeconds: Double = 5.0 {
        didSet { resizeBuffers() }
    }

    /// Vertical scale in microvolts per pixel of layer height. Default 0.5
    /// (so a 200 pt layer shows ±50 µV full-scale, matching typical
    /// resting EEG).
    public var scaleMicrovoltsPerPixel: Double = 0.5 {
        didSet { setNeedsDisplay(bounds) }
    }

    /// Visual depth in points between channel layers. Larger = more 3D
    /// separation. Setting this to 0 collapses to a 2D overlay.
    public var layerDepthSpacing: Double = 30.0 {
        didSet { applyTransforms() }
    }

    /// Background color of the view.
    public var backgroundColor: NSColor = .black {
        didSet { layer?.backgroundColor = backgroundColor.cgColor }
    }

    /// Per-channel stroke colors. Falls back to a default palette.
    public var channelColors: [NSColor] = [
        NSColor(red: 0.40, green: 0.80, blue: 0.40, alpha: 1.0),  // green for TP9
        NSColor(red: 0.40, green: 0.60, blue: 1.00, alpha: 1.0),  // blue  for AF7
        NSColor(red: 1.00, green: 0.70, blue: 0.30, alpha: 1.0),  // amber for AF8
        NSColor(red: 0.95, green: 0.30, blue: 0.55, alpha: 1.0),  // pink  for TP10
    ]

    // MARK: - Private state

    /// Per-channel rolling sample buffers. Each buffer holds up to
    /// `timeWindowSeconds * sampleRate` floats per channel.
    private var ringBuffers: [[Float]] = []
    private let sampleRate: Double = 256.0
    private var containerLayer: CALayer?
    private var channelLayers: [CAShapeLayer] = []
    private var channelLabels_: [CATextLayer] = []
    private var consumed: UInt64 = 0
    private var displayLink: CVDisplayLink?
    private var streamTask: Task<Void, Never>?
    private var lastUpdate: CFTimeInterval = 0
    private let updateInterval: CFTimeInterval = 1.0 / 60.0  // 60 Hz refresh

    // MARK: - Init

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = backgroundColor.cgColor
        rebuildLayers()
        startDisplayLink()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = backgroundColor.cgColor
        rebuildLayers()
        startDisplayLink()
    }

    deinit {
        // Note: displayLink cleanup happens implicitly when the view is
        // deallocated. We can't access displayLink here because CVDisplayLink
        // is not Sendable and this class is @MainActor.
        streamTask?.cancel()
    }

    public override func layout() {
        super.layout()
        applyTransforms()
    }

    // MARK: - Layer management

    private func rebuildLayers() {
        guard let parent = layer else { return }
        // Remove old layers.
        channelLayers.forEach { $0.removeFromSuperlayer() }
        channelLabels_.forEach { $0.removeFromSuperlayer() }
        containerLayer?.removeFromSuperlayer()
        channelLayers.removeAll()
        channelLabels_.removeAll()

        // Build a single container that holds the perspective transform.
        let container = CALayer()
        container.frame = parent.bounds
        container.sublayerTransform = CATransform3DMakePerspective(800.0)
        parent.addSublayer(container)
        containerLayer = container

        // One CAShapeLayer per channel.
        for i in channelLabels.indices {
            let shape = CAShapeLayer()
            shape.frame = parent.bounds
            shape.strokeColor = (i < channelColors.count ? channelColors[i] : .white).cgColor
            shape.fillColor = NSColor.clear.cgColor
            shape.lineWidth = 1.0
            shape.lineCap = .round
            shape.lineJoin = .round
            container.addSublayer(shape)
            channelLayers.append(shape)
        }

        // Channel labels (sit on the parent layer, not the perspective container,
        // so the text doesn't get foreshortened).
        for i in channelLabels.indices {
            let text = CATextLayer()
            text.string = channelLabels[i]
            text.fontSize = 11.0
            text.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
            text.foregroundColor = (i < channelColors.count ? channelColors[i] : .white).cgColor
            text.backgroundColor = NSColor(white: 0.0, alpha: 0.5).cgColor
            text.alignmentMode = .left
            text.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
            text.frame = CGRect(x: 8, y: 4 + CGFloat(i) * 16, width: 80, height: 14)
            text.isWrapped = true
            parent.addSublayer(text)
            channelLabels_.append(text)
        }

        applyTransforms()
        resizeBuffers()
    }
    private func applyTransforms() {
        guard let container = containerLayer else { return }
        let count = channelLayers.count
        guard count > 0 else { return }
        for (i, shape) in channelLayers.enumerated() {
            // Center each channel layer vertically, then translate-z by -i*spacing.
            let bounds = container.bounds
            let perChannelHeight = bounds.height / CGFloat(count)
            shape.frame = CGRect(
                x: 0,
                y: CGFloat(count - 1 - i) * perChannelHeight,
                width: bounds.width,
                height: perChannelHeight
            )
            let midY = shape.frame.midY
            // Reset transform: translate to layer origin then apply z-shift.
            var t = CATransform3DIdentity
            t.m34 = 1.0 / 800.0
            t = CATransform3DTranslate(t, 0, midY - container.bounds.midY, -CGFloat(i) * CGFloat(layerDepthSpacing))
            shape.transform = t
        }
    }

    private func resizeBuffers() {
        let cap = Int(timeWindowSeconds * sampleRate)
        let n = channelLabels.count
        if ringBuffers.count != n {
            ringBuffers = Array(repeating: [Float](repeating: 0, count: cap), count: n)
        } else {
            for i in 0..<n {
                ringBuffers[i] = [Float](repeating: 0, count: cap)
            }
        }
        consumed = 0
    }

    // MARK: - Stream consumption

    /// Subscribe the plotter to an `AsyncThrowingStream<EEGSample, Error>`
    /// from `BrainFlowService.start()`. Replaces any prior subscription.
    public func subscribe<Failure: Error>(to stream: AsyncThrowingStream<EEGSample, Failure>) {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            do {
                for try await sample in stream {
                    guard let self else { return }
                    self.ingest(sample)
                }
            } catch {
                BCILog.eeg.error("Plotter stream error: \(error)")
            }
        }
    }

    /// Cancel any active stream subscription. The plotter continues to
    /// display the last-ingested data until a new subscription is set.
    public func cancelSubscription() {
        streamTask?.cancel()
        streamTask = nil
    }

    /// Ingest a single sample. Thread-safe only on the main actor.
    public func ingest(_ sample: EEGSample) {
        guard !ringBuffers.isEmpty else { return }
        for (i, value) in sample.channels.enumerated() where i < ringBuffers.count {
            var buf = ringBuffers[i]
            // Ring buffer drop-oldest.
            if buf.count > 0 {
                buf.removeFirst()
                buf.append(value)
            }
            ringBuffers[i] = buf
        }
        consumed &+= 1
    }

    // MARK: - Display link

    private func startDisplayLink() {
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }
        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, context in
            guard let context else { return kCVReturnSuccess }
            let view = Unmanaged<EEGScalpPlotterView>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                view.tick()
            }
            return kCVReturnSuccess
        }
        CVDisplayLinkSetOutputCallback(link, callback, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(link)
        displayLink = link
    }

    private func tick() {
        let now = CACurrentMediaTime()
        guard now - lastUpdate >= updateInterval else { return }
        lastUpdate = now
        redraw()
    }

    private func redraw() {
        guard !channelLayers.isEmpty, let container = containerLayer else { return }
        let bounds = container.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let count = channelLayers.count
        let perChannelHeight = bounds.height / CGFloat(count)
        let bufLen = ringBuffers.first?.count ?? 0
        guard bufLen > 1 else { return }
        let xStep = bounds.width / CGFloat(bufLen - 1)

        for (i, shape) in channelLayers.enumerated() {
            guard i < ringBuffers.count else { continue }
            let buffer = ringBuffers[i]
            let path = CGMutablePath()
            for j in 0..<buffer.count {
                let x = CGFloat(j) * xStep
                let midY = perChannelHeight / 2
                // Amplitude scaling: scaleMicrovoltsPerPixel µV per pixel.
                // Convert value (µV) to pixel offset from center.
                let yOffset = CGFloat(buffer[j]) / CGFloat(scaleMicrovoltsPerPixel)
                let y = midY - yOffset
                if j == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            shape.path = path
        }
    }
}

/// Build a transform with perspective from a single m34 value.
private func CATransform3DMakePerspective(_ perspective: CGFloat) -> CATransform3D {
    var t = CATransform3DIdentity
    t.m34 = -1.0 / perspective
    return t
}
