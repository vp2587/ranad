import AVFoundation
import os

/// Plays ranad notes through AVAudioEngine. Every note is rendered once up front by
/// `RanadBarModel`, then mixed on the audio thread by `RanadSampler`, followed by a
/// small room reverb.
final class RanadAudioEngine {
    private let engine = AVAudioEngine()
    private let reverb = AVAudioUnitReverb()
    private let sampler: RanadSampler
    private var observers: [NSObjectProtocol] = []

    /// - Parameter noteFrequencies: every pitch the app can play; `noteOn` takes an index into it.
    init(noteFrequencies: [Double]) {
        Self.configureSession()
        let sessionRate = AVAudioSession.sharedInstance().sampleRate
        let sampleRate = sessionRate > 0 ? sessionRate : 44_100
        sampler = RanadSampler(notes: noteFrequencies.map { RanadBarModel.render(frequency: $0, sampleRate: sampleRate) },
                               sampleRate: sampleRate)

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let sampler = self.sampler
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)
            guard let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            sampler.render(into: first, frameCount: frames)
            for buffer in buffers.dropFirst() {
                buffer.mData?.assumingMemoryBound(to: Float.self).update(from: first, count: frames)
            }
            return noErr
        }
        reverb.loadFactoryPreset(.mediumRoom)
        reverb.wetDryMix = 10
        engine.attach(source)
        engine.attach(reverb)
        engine.connect(source, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: nil)
        engine.prepare()

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self?.start()
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.start()
        })
        start()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        engine.stop()
    }

    private static func configureSession() {
        let session = AVAudioSession.sharedInstance()
        // .playback so the instrument is audible even with the silent switch on.
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setPreferredIOBufferDuration(0.005)
        try? session.setActive(true)
    }

    func start() {
        guard !engine.isRunning else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        do {
            try engine.start()
        } catch {
            print("Ranad: failed to start audio engine: \(error)")
        }
    }

    func noteOn(_ note: Int, velocity: Float) {
        sampler.noteOn(note, velocity: velocity)
    }
}

/// Model of one struck ranad bar: a free wooden bar's modes excited by a hard mallet,
/// plus the dry "tok" of the strike and a hollow knock from the frame.
/// Matches the default settings of the web version's Sound panel.
enum RanadBarModel {
    private static let brightness = 0.60
    private static let ring = 0.30
    private static let knock = 0.60

    static func render(frequency: Double, sampleRate sr: Double) -> [Float] {
        // Wood is heavily damped: the tone dies quickly and the overtones die almost at once,
        // so they color the strike instead of ringing on like a bell.
        // (frequency ratio, level, decay relative to the fundamental)
        let modes: [(ratio: Double, level: Double, decay: Double)] = [
            (1.00, 1.00, 1.00),
            (2.76, 0.20 + 0.40 * brightness, 0.18),
            (5.40, 0.05 + 0.20 * brightness, 0.08),
            (8.93, 0.10 * brightness, 0.04),
        ]
        let tau0 = max(0.03, min(0.8, (0.05 + 0.45 * ring) * pow(165 / frequency, 0.6)))
        let length = Int((sr * (tau0 * 5 + 0.08)).rounded(.up))
        var out = [Double](repeating: 0, count: length)
        var generator = SystemRandomNumberGenerator()
        let noise = { Double.random(in: -1...1, using: &generator) }

        // Excitation: a half-sine mallet pulse (shorter = harder mallet) with a little
        // roughness from wood hitting wood.
        let pulseLength = max(2, Int((0.0016 + (0.0003 - 0.0016) * brightness) * sr))
        var excitation = [Double](repeating: 0, count: pulseLength + Int(0.005 * sr))
        for n in excitation.indices {
            if n < pulseLength { excitation[n] = sin(Double.pi * Double(n) / Double(pulseLength)) }
            excitation[n] += noise() * 0.3 * exp(-Double(n) / (0.0012 * sr))
        }

        // Each mode is a two-pole resonator driven by the excitation.
        var fundamentalPeak = 0.0
        for (index, mode) in modes.enumerated() {
            let f = frequency * mode.ratio
            guard f < sr * 0.45, mode.level > 0 else { continue }
            let w = 2 * Double.pi * f / sr, r = exp(-1 / (tau0 * mode.decay * sr))
            let a1 = 2 * r * cos(w), a2 = -r * r, b0 = mode.level * sin(w)
            var y1 = 0.0, y2 = 0.0
            for n in 0..<length {
                let y = b0 * (n < excitation.count ? excitation[n] : 0) + a1 * y1 + a2 * y2
                y2 = y1
                y1 = y
                out[n] += y
                if index == 0 { fundamentalPeak = max(fundamentalPeak, abs(y)) }
                if n > excitation.count && abs(y1) + abs(y2) < 1e-7 { break }
            }
        }
        let norm = 1 / (fundamentalPeak > 0 ? fundamentalPeak : 1)
        for n in out.indices { out[n] *= norm }

        // The dry "tok" of the strike and the hollow knock of the frame: short band-passed noise.
        func burst(centre: Double, q: Double, peakLevel: Double, tau: Double) {
            guard peakLevel > 0 else { return }
            let count = min(length, Int(tau * 8 * sr))
            var samples = [Double](repeating: 0, count: count)
            let w0 = 2 * Double.pi * centre / sr, r = exp(-w0 / (2 * q))
            let a1 = 2 * r * cos(w0), a2 = -r * r
            var y1 = 0.0, y2 = 0.0, peak = 0.0
            for n in 0..<count {
                let y = noise() * exp(-Double(n) / (tau * sr)) + a1 * y1 + a2 * y2
                y2 = y1
                y1 = y
                samples[n] = y
                peak = max(peak, abs(y))
            }
            for n in 0..<count { out[n] += samples[n] * peakLevel / (peak > 0 ? peak : 1) }
        }
        burst(centre: 1500 + (3800 - 1500) * brightness, q: 1.4, peakLevel: 0.9 * knock, tau: 0.0025)
        burst(centre: min(900, frequency * 1.8), q: 3, peakLevel: 0.7 * knock, tau: 0.025)

        let fade = min(length, Int(sr * 0.02))
        return out.enumerated().map { n, value in
            let tail = length - 1 - n
            let fadeGain = tail < fade ? Double(tail) / Double(fade) : 1
            return Float(value * 0.55 * fadeGain)
        }
    }
}

/// Mixes pre-rendered notes. `noteOn` may be called from any thread; `render` runs on
/// the audio thread and never blocks or allocates.
final class RanadSampler {
    private struct Voice {
        var note = -1
        var position = 0
        var gain: Float = 0
        var fadeStep: Float = 0     // > 0 while being damped by a new strike on the same bar
        var toneCoefficient: Float = 1
        var toneState: Float = 0
    }

    private static let maxVoices = 32
    private static let queueCapacity = 64

    private let samples: [UnsafeMutableBufferPointer<Float>]
    private let sampleRate: Double
    private let voices: UnsafeMutablePointer<Voice>

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let queuedNote: UnsafeMutablePointer<Int>
    private let queuedVelocity: UnsafeMutablePointer<Float>
    private var queuedCount = 0

    init(notes: [[Float]], sampleRate: Double) {
        self.sampleRate = sampleRate
        samples = notes.map { note in
            let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: note.count)
            _ = buffer.initialize(from: note)
            return buffer
        }
        voices = .allocate(capacity: Self.maxVoices)
        voices.initialize(repeating: Voice(), count: Self.maxVoices)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        queuedNote = .allocate(capacity: Self.queueCapacity)
        queuedNote.initialize(repeating: 0, count: Self.queueCapacity)
        queuedVelocity = .allocate(capacity: Self.queueCapacity)
        queuedVelocity.initialize(repeating: 0, count: Self.queueCapacity)
    }

    deinit {
        samples.forEach { $0.deallocate() }
        voices.deallocate()
        lock.deallocate()
        queuedNote.deallocate()
        queuedVelocity.deallocate()
    }

    func noteOn(_ note: Int, velocity: Float) {
        guard samples.indices.contains(note) else { return }
        os_unfair_lock_lock(lock)
        if queuedCount < Self.queueCapacity {
            queuedNote[queuedCount] = note
            queuedVelocity[queuedCount] = max(0, min(1, velocity))
            queuedCount += 1
        }
        os_unfair_lock_unlock(lock)
    }

    func render(into output: UnsafeMutablePointer<Float>, frameCount: Int) {
        // Never block the audio thread: if the UI thread holds the lock, pick the notes up next buffer.
        if os_unfair_lock_trylock(lock) {
            for i in 0..<queuedCount {
                start(note: queuedNote[i], velocity: queuedVelocity[i])
            }
            queuedCount = 0
            os_unfair_lock_unlock(lock)
        }

        output.update(repeating: 0, count: frameCount)
        for v in 0..<Self.maxVoices where voices[v].note >= 0 {
            var voice = voices[v]
            let sample = samples[voice.note]
            let count = min(frameCount, sample.count - voice.position)
            for n in 0..<count {
                voice.toneState += voice.toneCoefficient * (sample[voice.position + n] - voice.toneState)
                output[n] += voice.toneState * voice.gain
                if voice.fadeStep > 0 {
                    voice.gain = max(0, voice.gain - voice.fadeStep)
                }
            }
            voice.position += count
            if voice.position >= sample.count || (voice.fadeStep > 0 && voice.gain <= 0) {
                voice.note = -1
            }
            voices[v] = voice
        }

        for n in 0..<frameCount {
            output[n] = tanhf(output[n] * 0.7)
        }
    }

    private func start(note: Int, velocity: Float) {
        // A struck bar doesn't keep adding up: damp what is still ringing on this bar.
        let fadeStep = Float(1 / (0.015 * sampleRate))
        for v in 0..<Self.maxVoices where voices[v].note == note && voices[v].fadeStep == 0 {
            voices[v].fadeStep = voices[v].gain * fadeStep
        }
        // Take a free voice, or steal the one that has played longest.
        var slot = 0
        var oldestPosition = -1
        for v in 0..<Self.maxVoices {
            if voices[v].note < 0 { slot = v; break }
            if voices[v].position > oldestPosition {
                oldestPosition = voices[v].position
                slot = v
            }
        }
        // Softer hits sound duller.
        let cutoff = 1800 + 14000 * Double(velocity * velocity)
        voices[slot] = Voice(note: note,
                             position: 0,
                             gain: powf(velocity, 1.3) * 0.9,
                             fadeStep: 0,
                             toneCoefficient: Float(1 - exp(-2 * Double.pi * cutoff / sampleRate)),
                             toneState: 0)
    }
}
