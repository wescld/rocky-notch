import AVFoundation

/// Rocky's voice — synthesized musical chords, in homage to the Eridian
/// engineer who speaks in note sequences. Each app event is a short musical
/// "phrase" with a question/answer contour instead of a system beep.
///
/// Timbre: fundamental + soft harmonics with a bell-like exponential decay,
/// warm and quiet enough to live in the background of a workday.
@MainActor
final class RockyVoice {
    static let shared = RockyVoice()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate: Double = 44_100
    private var ready = false

    private init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.5
        do {
            try engine.start()
            player.play()
            ready = true
        } catch {
            ready = false
        }
    }

    /// "May I?" — two chords rising like a question (♪ sol–si … dó–mi ♪).
    func question() {
        play(phrase: [
            (notes: [392.00, 493.88], duration: 0.16),
            (notes: [523.25, 659.26], duration: 0.30),
        ])
    }

    /// "Done!" — a settling major triad (amaze!).
    func done() {
        play(phrase: [
            (notes: [523.25, 659.26, 783.99], duration: 0.40)
        ])
    }

    /// "You there?" — one gentle open fifth.
    func attention() {
        play(phrase: [
            (notes: [440.00, 659.26], duration: 0.25)
        ])
    }

    // MARK: - Synthesis

    private func play(phrase: [(notes: [Double], duration: Double)]) {
        guard ready else { return }
        guard let buffer = render(phrase: phrase) else { return }
        player.scheduleBuffer(buffer, at: nil, options: [])
    }

    private func render(phrase: [(notes: [Double], duration: Double)]) -> AVAudioPCMBuffer? {
        let gap = 0.02
        let tail = 0.35
        let total = phrase.reduce(0) { $0 + $1.duration + gap } + tail
        let frameCount = AVAudioFrameCount(total * sampleRate)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        guard let samples = buffer.floatChannelData?[0] else { return nil }

        var start = 0.0
        for chord in phrase {
            let attack = 0.008
            // The chord rings past its slot with a bell decay.
            let ring = chord.duration + tail
            let firstFrame = Int(start * sampleRate)
            let lastFrame = min(Int((start + ring) * sampleRate), Int(frameCount))
            for frame in firstFrame..<lastFrame {
                let t = Double(frame) / sampleRate - start
                let envelope = t < attack
                    ? t / attack
                    : exp(-3.2 * (t - attack) / ring)
                var sample = 0.0
                for note in chord.notes {
                    // Fundamental + soft 2nd/3rd harmonics = warm "voice".
                    sample += sin(2 * .pi * note * t)
                    sample += 0.35 * sin(2 * .pi * note * 2 * t)
                    sample += 0.12 * sin(2 * .pi * note * 3 * t)
                }
                sample *= envelope / Double(chord.notes.count * 2)
                samples[frame] += Float(sample)
            }
            start += chord.duration + gap
        }
        return buffer
    }
}
