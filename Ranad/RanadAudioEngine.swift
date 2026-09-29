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
        reverb.wetDryMix = 22
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

/// Physical model of one struck ranad bar: the bar's resonant modes excited by a hard
/// mallet, the wooden "tak" of the strike, and a knock from the boat-shaped body.
enum RanadBarModel {
    /// (frequency ratio, level, decay relative to the fundamental)
    private static let modes: [(ratio: Double, level: Double, decay: Double)] = [
        (1.000, 1.00, 1.00),
        (1.004, 0.30, 0.85),  // a near-twin mode: the slight shimmer of a hand-tuned bar
        (2.920, 0.62, 0.38),  // the strong, bright first overtone
        (3.050, 0.16, 0.30),
        (5.830, 0.30, 0.16),
        (9.200, 0.12, 0.08),
    ]

    static func render(frequency: Double, sampleRate sr: Double) -> [Float] {
        let tau0 = max(0.10, min(0.55, 0.5 * pow(330 / frequency, 0.75)))
        let length = Int((sr * (tau0 * 5 + 0.1)).rounded(.up))
        var out = [Double](repeating: 0, count: length)
        let contact = 0.00045 // seconds a hard mallet stays on the bar
        let rise = 0.00015 * sr

        for mode in modes {
            let f = frequency * mode.ratio
            guard f < sr * 0.45 else { continue }
            // Spectrum of a short half-sine mallet pulse: harder mallets excite higher modes.
            let x = 2 * f * contact
            let mallet = abs(abs(x) - 1) < 0.001 ? Double.pi / 4 : abs(cos(Double.pi * f * contact) / (1 - x * x))
            let w = 2 * Double.pi * f / sr
            let d = exp(-1 / (tau0 * mode.decay * sr))
            var env = mode.level * mallet
            for n in 0..<length {
                out[n] += env * sin(w * Double(n)) * (1 - exp(-Double(n) / rise))
                env *= d
                if env < 1e-5 { break }
            }
        }

        // The "tak" of wood on wood: noise through a resonant band-pass.
        let fc = min(4200, 2200 + frequency), q = 1.2
        let w0 = 2 * Double.pi * fc / sr, r = exp(-w0 / (2 * q))
        let a1 = 2 * r * cos(w0), a2 = -r * r
        var y1 = 0.0, y2 = 0.0, clickEnv = 0.45
        let clickDecay = exp(-1 / (0.0035 * sr))
        var generator = SystemRandomNumberGenerator()
        for n in 0..<min(length, Int(sr * 0.03)) {
            let y = (1 - r) * Double.random(in: -1...1, using: &generator) + a1 * y1 + a2 * y2
            y2 = y1
            y1 = y
            out[n] += y * clickEnv * 3
            clickEnv *= clickDecay
        }

        // Hollow knock of the wooden body.
        let bodyW = 2 * Double.pi * 190 / sr, bodyDecay = exp(-1 / (0.05 * sr))
        var bodyEnv = 0.14
        for n in 0..<length where bodyEnv > 1e-5 {
            out[n] += bodyEnv * sin(bodyW * Double(n))
            bodyEnv *= bodyDecay
        }

        let peak = out.reduce(0) { max($0, abs($1)) }
        let norm = 0.8 / (peak > 0 ? peak : 1)
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
                             gain: powf(velocity, 1.3) * 0.6,
                             fadeStep: 0,
                             toneCoefficient: Float(1 - exp(-2 * Double.pi * cutoff / sampleRate)),
                             toneState: 0)
    }
}
