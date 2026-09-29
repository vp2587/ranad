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
        reverb.wetDryMix = 15
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
/// plus the wooden "tak" of the strike and a hollow knock from the frame.
/// Matches the default settings of the web version's Sound panel.
enum RanadBarModel {
    private static let brightness = 0.70
    private static let ring = 0.35
    private static let knock = 0.45

    static func render(frequency: Double, sampleRate sr: Double) -> [Float] {
        // (frequency ratio, level, decay relative to the fundamental)
        let modes: [(ratio: Double, level: Double, decay: Double)] = [
            (1.00, 1.00, 1.00),
            (2.76, 0.25 + 0.45 * brightness, 0.30),
            (5.40, 0.05 + 0.25 * brightness, 0.12),
            (8.93, 0.12 * brightness, 0.06),
        ]
        let tau0 = max(0.04, min(1.6, (0.10 + 0.80 * ring) * pow(330 / frequency, 0.7)))
        let length = Int((sr * (tau0 * 5 + 0.08)).rounded(.up))
        var out = [Double](repeating: 0, count: length)
        let contact = 0.0012 + (0.00022 - 0.0012) * brightness // seconds the mallet stays on the bar
        let rise = 0.00012 * sr
        var fundamentalAmp = 1.0

        for (index, mode) in modes.enumerated() {
            let f = frequency * mode.ratio
            guard f < sr * 0.45, mode.level > 0 else { continue }
            // Spectrum of a short half-sine mallet pulse: harder mallets excite higher modes.
            let x = 2 * f * contact
            let mallet = abs(abs(x) - 1) < 0.001 ? Double.pi / 4 : abs(cos(Double.pi * f * contact) / (1 - x * x))
            let amp = mode.level * mallet
            if index == 0 { fundamentalAmp = amp > 0 ? amp : 1 }
            let w = 2 * Double.pi * f / sr
            let d = exp(-1 / (tau0 * mode.decay * sr))
            var env = amp
            var n = 0
            while n < length && env > 1e-5 {
                out[n] += env * sin(w * Double(n)) * (1 - exp(-Double(n) / rise))
                env *= d
                n += 1
            }
        }

        // Short band-passed noise bursts.
        var generator = SystemRandomNumberGenerator()
        func burst(centre: Double, q: Double, level: Double, tau: Double) {
            let w0 = 2 * Double.pi * centre / sr, r = exp(-w0 / (2 * q))
            let a1 = 2 * r * cos(w0), a2 = -r * r
            let d = exp(-1 / (tau * sr))
            var y1 = 0.0, y2 = 0.0, env = level
            var n = 0
            while n < length && env > 1e-5 {
                let y = (1 - r) * Double.random(in: -1...1, using: &generator) + a1 * y1 + a2 * y2
                y2 = y1
                y1 = y
                out[n] += y * env
                env *= d
                n += 1
            }
        }
        burst(centre: 1800 + (4500 - 1800) * brightness, q: 0.9, level: 1.6 * knock * fundamentalAmp, tau: 0.003)
        burst(centre: 520, q: 4, level: 1.4 * knock * fundamentalAmp, tau: 0.02)

        let norm = 0.5 / fundamentalAmp
        let fade = min(length, Int(sr * 0.02))
        return out.enumerated().map { n, value in
            let tail = length - 1 - n
            let fadeGain = tail < fade ? Double(tail) / Double(fade) : 1
            return Float(value * norm * fadeGain)
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
