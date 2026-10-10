import CoreGraphics

/// The input layer's per-capture state: the focus probe result, the picker anchor and the Jev
/// context belong to one `TriggerEngine` capture and must never leak into the next one, or a later
/// trigger skips the probe, opens at the old trigger's position and sends the old context.
///
/// The input layer calls `restart(for:)` whenever `follows(_:)` is false after a key (the engine
/// ended the capture, even silently as with `:D `, or started a new one) and whenever it ends a
/// capture itself. Async work carries `id` and is dropped once it no longer matches.
public struct CaptureSession: Sendable {
    /// Changes on every restart; probes and timers started for an older capture compare against it.
    public private(set) var id = 0
    /// The engine capture (`TriggerEngine.capture`) this state belongs to; nil when none is open.
    public private(set) var engineCapture: Int?
    /// A focus probe for this capture is running (or waiting to retry).
    public private(set) var probeInFlight = false
    /// This capture's focus probe found a readable, non-secure text element.
    public private(set) var focusUsable = false
    /// Where the picker opens (Cocoa screen coordinates), from the probe.
    public private(set) var anchor: CGRect?
    public private(set) var context = PredictionContext()
    /// The query the picker should show next.
    public var latestQuery = ""
    /// The bare-trigger strip may show (its delay passed without another key).
    public var stripDelayElapsed = false

    public init() {}

    /// Whether this state still belongs to the engine's current capture.
    public func follows(_ engine: TriggerEngine) -> Bool {
        engineCapture == engine.capture
    }

    /// Forgets everything per-capture and adopts the engine's current capture (nil when it is not
    /// tracking). Stale probe results are ignored from now on.
    public mutating func restart(for engine: TriggerEngine) {
        id &+= 1
        engineCapture = engine.capture
        probeInFlight = false
        focusUsable = false
        anchor = nil
        context = PredictionContext()
        latestQuery = ""
        stripDelayElapsed = false
    }

    /// A capture is open and nobody has found (or is looking for) its text field yet.
    public var needsProbe: Bool {
        engineCapture != nil && !focusUsable && !probeInFlight
    }

    public func isCurrent(_ captureID: Int) -> Bool {
        captureID == id
    }

    /// Marks a probe as running and returns the id its result must carry.
    public mutating func startProbe() -> Int {
        probeInFlight = true
        return id
    }

    /// Records a usable probe result. Returns false (and changes nothing) for an older capture's.
    @discardableResult
    public mutating func probeSucceeded(captureID: Int, anchor: CGRect?, context: PredictionContext) -> Bool {
        guard isCurrent(captureID), engineCapture != nil else { return false }
        probeInFlight = false
        focusUsable = true
        self.anchor = anchor
        self.context = context
        return true
    }

    /// A probe gave up or was abandoned; a later key may probe again.
    public mutating func probeEnded(captureID: Int) {
        if isCurrent(captureID) { probeInFlight = false }
    }
}
