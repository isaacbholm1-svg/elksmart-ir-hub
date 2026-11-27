import AVFoundation

/// Sends IR signals through the audio output for audio-type IR blasters
/// (ElkSmart / Ocrustar Lightning, USB-C audio and headphone-jack models).
///
/// Those dongles wire two IR LEDs in opposite directions across the left and
/// right channels. A sine at HALF the carrier on L and its inverse on R lights
/// an LED on every half-cycle, so a 19 kHz tone gives 38 kHz infrared.
/// This mirrors audio.js in the web app.
final class AudioBlaster {
    struct BlastError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Output ports an audio IR blaster can show up as.
    static let blasterPorts: Set<AVAudioSession.Port> = [.headphones, .usbAudio, .lineOut]
    static let wirelessPorts: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .airPlay]

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var connectedRate: Double = 0

    init() {
        engine.attach(player)
    }

    /// Puts the audio session in playback mode, which keeps sound on even with
    /// the silent switch on, and asks for 48 kHz so a 19 kHz tone fits.
    func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setPreferredSampleRate(48_000)
        try? session.setActive(true)
    }

    private func startEngine() throws -> Double {
        activateSession()
        var rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if rate <= 0 { rate = AVAudioSession.sharedInstance().sampleRate }
        if !engine.isRunning || rate != connectedRate {
            engine.stop()
            guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
                throw BlastError("Couldn't set up a \(Int(rate)) Hz stereo output.")
            }
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 1
            engine.prepare()
            try engine.start()
            connectedRate = rate
        }
        return rate
    }

    /// - Parameters:
    ///   - freq: carrier frequency in Hz (for example 38000)
    ///   - timings: alternating mark/space durations in microseconds, starting with a mark
    ///   - fullCarrier: play the carrier itself instead of half of it (needs 96 kHz output)
    /// - Returns: the tone frequency and the output sample rate used.
    func blast(freq: Double, timings: [Double], fullCarrier: Bool, repeats: Int, invert: Bool) throws -> (toneHz: Double, sampleRate: Double) {
        guard freq > 0, !timings.isEmpty else { throw BlastError("This button has no signal to send.") }
        let rate = try startEngine()
        let toneHz = fullCarrier ? freq : freq / 2
        if toneHz >= rate / 2 {
            throw BlastError("The output runs at \(Int(rate)) Hz, too slow for a \(toneHz / 1000) kHz tone. Use the half-carrier setting.")
        }

        let samples = timings.map { Int(($0 * rate / 1_000_000).rounded()) }
        let frameSamples = samples.reduce(0, +)
        let lead = Int(rate * 0.03) // short silence so the output is awake
        let repeatCount = max(1, min(repeats, 10))
        let total = lead + frameSamples * repeatCount

        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)),
              let channels = buffer.floatChannelData else {
            throw BlastError("Couldn't make the audio buffer.")
        }
        buffer.frameLength = AVAudioFrameCount(total)
        let left = channels[0], right = channels[1]
        for i in 0..<total { left[i] = 0; right[i] = 0 }

        let w = 2 * Double.pi * toneHz / rate
        let sign: Double = invert ? -1 : 1
        var pos = lead
        for _ in 0..<repeatCount {
            for (i, n) in samples.enumerated() {
                if i % 2 == 0 {
                    for k in 0..<n {
                        let v = Float(sin(w * Double(pos + k)) * sign)
                        left[pos + k] = v
                        right[pos + k] = -v
                    }
                }
                pos += n
            }
        }

        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        player.play()
        return (toneHz, rate)
    }

    /// Where audio is going right now, for the "blaster detected" panel.
    func status() -> [String: Any] {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
        let blaster = outputs.first { Self.blasterPorts.contains($0.portType) }
        let wireless = outputs.first { Self.wirelessPorts.contains($0.portType) }
        return [
            "outputs": outputs.map { ["type": $0.portType.rawValue, "name": $0.portName] },
            "blaster": blaster.map { ["type": $0.portType.rawValue, "name": $0.portName] } ?? NSNull(),
            "wireless": wireless?.portName ?? NSNull(),
            "volume": session.outputVolume,
            "sampleRate": session.sampleRate,
        ]
    }
}
