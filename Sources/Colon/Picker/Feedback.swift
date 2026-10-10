import AppKit
import ColonCore

/// Sound and haptics for the picker. Both are opt-out/opt-in per `AppSettings` and cost nothing
/// when off: the click is synthesized on first use, never at launch.
@MainActor
enum Feedback {
    /// After an emoji lands in the target app (`playsInsertSound`).
    static func inserted(_ settings: AppSettings) {
        guard settings.playsInsertSound else { return }
        InsertClick.shared.play()
    }

    /// When the highlight moves by keyboard or hover (`hapticFeedback`). Only felt with a finger
    /// resting on a Force Touch trackpad; a no-op elsewhere.
    static func selectionChanged(_ settings: AppSettings) {
        guard settings.hapticFeedback else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// Settings preview, regardless of the toggles.
    static func previewClick() {
        InsertClick.shared.play()
    }

    static func previewHaptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

/// The insert click: a short, soft "tock" built in memory (the executable target has no
/// resources), played through a small round-robin of `NSSound`s so rapid ⌘↩ inserts overlap
/// instead of cutting each other off.
@MainActor
private final class InsertClick {
    static let shared = InsertClick()

    private lazy var voices: [NSSound] = {
        let data = ClickSynth.wav()
        return (0..<3).compactMap { _ in
            let sound = NSSound(data: data)
            sound?.volume = 0.55
            return sound
        }
    }()
    private var next = 0

    func play() {
        guard !voices.isEmpty else { return }
        let voice = voices[next]
        next = (next + 1) % voices.count
        voice.stop()
        voice.play()
    }
}

/// Synthesizes the click as 16-bit mono PCM WAV data. Pure and deterministic.
///
/// The sound is three layers, all under ~35 ms: a damped 1.7 kHz "tick" for definition, a damped
/// 520 Hz body so it reads as a soft key rather than a beep, and a whisper of low-passed noise for
/// texture. A 1.5 ms raised-cosine attack keeps the onset from popping; peak level is about −14 dBFS.
enum ClickSynth {
    static let sampleRate = 44_100
    static let duration = 0.035
    static let peak = 0.2

    static func samples(sampleRate: Int = sampleRate) -> [Int16] {
        let count = Int(Double(sampleRate) * duration)
        let rate = Double(sampleRate)
        let attack = 0.0015
        var noiseState: UInt32 = 0x9E37_79B9
        var lowpassed = 0.0
        var raw = [Double](repeating: 0, count: count)

        for i in 0..<count {
            let t = Double(i) / rate
            let onset = t < attack ? 0.5 - 0.5 * cos(.pi * t / attack) : 1
            let tick = sin(2 * .pi * 1_700 * t) * exp(-t / 0.0035)
            let body = sin(2 * .pi * 520 * t) * exp(-t / 0.007)
            // xorshift noise, one-pole low-passed so it is a soft brush, not a hiss.
            noiseState ^= noiseState << 13
            noiseState ^= noiseState >> 17
            noiseState ^= noiseState << 5
            let white = Double(noiseState) / Double(UInt32.max) * 2 - 1
            lowpassed += 0.18 * (white - lowpassed)
            let noise = lowpassed * exp(-t / 0.004)
            raw[i] = onset * (0.55 * tick + 0.6 * body + 0.35 * noise)
        }

        // Fade the last 4 ms to true silence so the buffer never ends on a click of its own.
        let fade = min(count, Int(rate * 0.004))
        for k in 0..<fade {
            raw[count - 1 - k] *= Double(k) / Double(fade)
        }

        let maxAbs = raw.map(abs).max() ?? 0
        let gain = maxAbs > 0 ? peak / maxAbs : 0
        return raw.map { Int16(($0 * gain * Double(Int16.max)).rounded()) }
    }

    static func wav(sampleRate: Int = sampleRate) -> Data {
        let pcm = samples(sampleRate: sampleRate)
        let dataBytes = UInt32(pcm.count * 2)
        var data = Data()
        data.reserveCapacity(44 + Int(dataBytes))
        func append(_ string: String) { data.append(contentsOf: Array(string.utf8)) }
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append("RIFF")
        append(UInt32(36) + dataBytes)
        append("WAVE")
        append("fmt ")
        append(UInt32(16))                 // PCM chunk size
        append(UInt16(1))                  // PCM
        append(UInt16(1))                  // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))     // byte rate
        append(UInt16(2))                  // block align
        append(UInt16(16))                 // bits per sample
        append("data")
        append(dataBytes)
        for sample in pcm { append(sample) }
        return data
    }
}
