import AVFoundation
import CoreHaptics
import UIKit

/// A soft paper sound and a light tap on each page turn (#128), both off by default.
/// The sound is made here rather than shipped as a file: a short burst of filtered noise
/// that swells and fades, like a page sliding over the one beneath. It plays in the ambient
/// category, so it follows the silent switch and the volume, and mixes with music.
@MainActor
final class PageTurnFeedback {
    static let shared = PageTurnFeedback()

    static let soundKey = "reader.pageTurnSound"
    static let hapticKey = "reader.pageTurnHaptic"

    /// Whether this device can play haptics (most iPads can't).
    static var supportsHaptics: Bool { CHHapticEngine.capabilitiesForHardware().supportsHaptics }

    private var players: [AVAudioPlayer] = []
    private var nextPlayer = 0
    private var haptic: UIImpactFeedbackGenerator?
    private var sessionReady = false

    private init() {}

    func pageTurned() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.soundKey) { playSound() }
        if defaults.bool(forKey: Self.hapticKey), Self.supportsHaptics {
            if haptic == nil { haptic = UIImpactFeedbackGenerator(style: .soft) }
            haptic?.impactOccurred(intensity: 0.55)
            haptic?.prepare()
        }
    }

    /// Plays the sound once (also for trying it in Settings).
    func playSound() {
        if !sessionReady {
            try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
            sessionReady = true
        }
        if players.isEmpty {
            // A few players, so quick turns don't cut each other off. Each is a little
            // different, which keeps it from sounding mechanical.
            players = (0..<3).compactMap { seed in
                (try? AVAudioPlayer(data: Self.paperSound(seed: UInt64(seed + 1)))).map { player in
                    player.volume = 0.5
                    player.prepareToPlay()
                    return player
                }
            }
        }
        guard !players.isEmpty else { return }
        let player = players[nextPlayer % players.count]
        nextPlayer += 1
        player.currentTime = 0
        player.play()
    }

    /// A 16-bit mono WAV of a page turning: noise, low-passed so it is soft rather than
    /// hissy, high-passed so it doesn't thump, shaped by a quick swell and a longer fade.
    static func paperSound(seed: UInt64, sampleRate: Int = 44_100) -> Data {
        let duration = 0.26
        let count = Int(Double(sampleRate) * duration)
        var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        func noise() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(Int64(bitPattern: state >> 11) % 1_000_000) / 500_000 - 1
        }
        var samples = [Int16](repeating: 0, count: count)
        var low = 0.0, lowSlow = 0.0
        let peak = 0.05 + 0.02 * Double(seed % 3)
        for i in 0..<count {
            let t = Double(i) / Double(sampleRate)
            let raw = noise()
            // Two one-pole filters: a low-pass (soft) and a slower one taken away (no thump).
            low += 0.18 * (raw - low)
            lowSlow += 0.01 * (raw - lowSlow)
            let band = low - lowSlow
            // A swell to `peak` seconds, then a fade, with a little flutter as the page moves.
            let envelope = t < peak ? pow(t / peak, 1.5) : exp(-(t - peak) * 16)
            let flutter = 0.8 + 0.2 * sin(t * 2 * .pi * (38 + Double(seed) * 7))
            let value = band * envelope * flutter * 2.2
            samples[i] = Int16(max(-1, min(1, value)) * 32_000)
        }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        let bytes = count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(bytes))
        for sample in samples { append(sample) }
        return data
    }
}
