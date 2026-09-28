import AVFoundation
import os

/// Plays ranad notes through AVAudioEngine using a small real-time synthesizer.
final class RanadAudioEngine {
    private let engine = AVAudioEngine()
    private let synth: RanadSynth
    private var observers: [NSObjectProtocol] = []

    init() {
        Self.configureSession()
        let sessionRate = AVAudioSession.sharedInstance().sampleRate
        synth = RanadSynth(sampleRate: sessionRate > 0 ? sessionRate : 44_100)

        let format = AVAudioFormat(standardFormatWithSampleRate: synth.sampleRate, channels: 1)!
        let synth = self.synth
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)
            guard let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            synth.render(into: first, frameCount: frames)
            for buffer in buffers.dropFirst() {
                buffer.mData?.assumingMemoryBound(to: Float.self).update(from: first, count: frames)
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
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

    func noteOn(frequency: Double, velocity: Float) {
        synth.noteOn(frequency: Float(frequency), velocity: velocity)
    }
}

/// Modal synthesis of a struck hardwood bar: a few inharmonic, exponentially decaying
/// partials plus a short band-passed noise burst for the hard mallet "tock".
///
/// `noteOn` may be called from any thread; `render` runs on the audio thread and never
/// blocks or allocates.
final class RanadSynth {
    let sampleRate: Double

    private static let maxVoices = 24
    private static let partials = 4
    private static let queueCapacity = 64
    private static let twoPi = Float.pi * 2

    // Frequency ratios of a free–free wooden bar, with the level and relative decay of each.
    private static let ratios: [Float] = [1.0, 2.76, 5.40, 8.93]
    private static let levels: [Float] = [1.0, 0.30, 0.12, 0.05]
    private static let decayScale: [Float] = [1.0, 0.32, 0.13, 0.06]

    // Voice state (audio thread only).
    private let phase: UnsafeMutablePointer<Float>
    private let increment: UnsafeMutablePointer<Float>
    private let envelope: UnsafeMutablePointer<Float>
    private let decay: UnsafeMutablePointer<Float>
    private let noiseLevel: UnsafeMutablePointer<Float>
    private let noiseDecay: UnsafeMutablePointer<Float>
    private let noiseFast: UnsafeMutablePointer<Float>
    private let noiseSlow: UnsafeMutablePointer<Float>
    private let active: UnsafeMutablePointer<Bool>
    private let startedAt: UnsafeMutablePointer<Int>
    private var noteCounter = 0
    private var randomState: UInt32 = 0x9E37_79B9
    private let fastCoefficient: Float
    private let slowCoefficient: Float

    // Note-on queue shared between threads.
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let queuedFrequency: UnsafeMutablePointer<Float>
    private let queuedVelocity: UnsafeMutablePointer<Float>
    private var queuedCount = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        let slots = Self.maxVoices * Self.partials
        phase = .allocate(capacity: slots); phase.initialize(repeating: 0, count: slots)
        increment = .allocate(capacity: slots); increment.initialize(repeating: 0, count: slots)
        envelope = .allocate(capacity: slots); envelope.initialize(repeating: 0, count: slots)
        decay = .allocate(capacity: slots); decay.initialize(repeating: 0, count: slots)
        noiseLevel = .allocate(capacity: Self.maxVoices); noiseLevel.initialize(repeating: 0, count: Self.maxVoices)
        noiseDecay = .allocate(capacity: Self.maxVoices); noiseDecay.initialize(repeating: 0, count: Self.maxVoices)
        noiseFast = .allocate(capacity: Self.maxVoices); noiseFast.initialize(repeating: 0, count: Self.maxVoices)
        noiseSlow = .allocate(capacity: Self.maxVoices); noiseSlow.initialize(repeating: 0, count: Self.maxVoices)
        active = .allocate(capacity: Self.maxVoices); active.initialize(repeating: false, count: Self.maxVoices)
        startedAt = .allocate(capacity: Self.maxVoices); startedAt.initialize(repeating: 0, count: Self.maxVoices)
        lock = .allocate(capacity: 1); lock.initialize(to: os_unfair_lock())
        queuedFrequency = .allocate(capacity: Self.queueCapacity); queuedFrequency.initialize(repeating: 0, count: Self.queueCapacity)
        queuedVelocity = .allocate(capacity: Self.queueCapacity); queuedVelocity.initialize(repeating: 0, count: Self.queueCapacity)
        fastCoefficient = Float(1 - exp(-2 * Double.pi * 4_500 / sampleRate))
        slowCoefficient = Float(1 - exp(-2 * Double.pi * 900 / sampleRate))
    }

    deinit {
        [phase, increment, envelope, decay, noiseLevel, noiseDecay, noiseFast, noiseSlow,
         queuedFrequency, queuedVelocity].forEach { $0.deallocate() }
        active.deallocate()
        startedAt.deallocate()
        lock.deallocate()
    }

    func noteOn(frequency: Float, velocity: Float) {
        os_unfair_lock_lock(lock)
        if queuedCount < Self.queueCapacity {
            queuedFrequency[queuedCount] = frequency
            queuedVelocity[queuedCount] = max(0, min(1, velocity))
            queuedCount += 1
        }
        os_unfair_lock_unlock(lock)
    }

    func render(into output: UnsafeMutablePointer<Float>, frameCount: Int) {
        // Never block the audio thread: if the UI thread holds the lock, pick the notes up next buffer.
        if os_unfair_lock_trylock(lock) {
            for i in 0..<queuedCount {
                startVoice(frequency: queuedFrequency[i], velocity: queuedVelocity[i])
            }
            queuedCount = 0
            os_unfair_lock_unlock(lock)
        }

        output.update(repeating: 0, count: frameCount)
        let partials = Self.partials
        let twoPi = Self.twoPi

        for v in 0..<Self.maxVoices where active[v] {
            var loudness: Float = 0
            for p in 0..<partials {
                let slot = v * partials + p
                var env = envelope[slot]
                guard env > 1e-5 else { continue }
                var ph = phase[slot]
                let inc = increment[slot]
                let d = decay[slot]
                for n in 0..<frameCount {
                    output[n] += sinf(ph) * env
                    ph += inc
                    if ph >= twoPi { ph -= twoPi }
                    env *= d
                }
                phase[slot] = ph
                envelope[slot] = env
                loudness += env
            }

            var level = noiseLevel[v]
            if level > 1e-5 {
                var fast = noiseFast[v]
                var slow = noiseSlow[v]
                let nd = noiseDecay[v]
                for n in 0..<frameCount {
                    let white = nextRandom()
                    fast += fastCoefficient * (white - fast)
                    slow += slowCoefficient * (white - slow)
                    output[n] += (fast - slow) * level
                    level *= nd
                }
                noiseFast[v] = fast
                noiseSlow[v] = slow
                noiseLevel[v] = level
                loudness += level
            }

            if loudness < 1e-4 { active[v] = false }
        }

        for n in 0..<frameCount {
            output[n] = tanhf(output[n] * 0.45)
        }
    }

    private func startVoice(frequency: Float, velocity: Float) {
        // Take a free voice, or steal the oldest one.
        var voice = 0
        var oldest = Int.max
        for v in 0..<Self.maxVoices {
            if !active[v] { voice = v; break }
            if startedAt[v] < oldest { oldest = startedAt[v]; voice = v }
        }
        noteCounter += 1
        startedAt[voice] = noteCounter
        active[voice] = true

        let sr = Float(sampleRate)
        // Short bars ring for less time than long ones.
        let baseDecay = max(0.18, min(1.3, 0.95 * powf(262 / frequency, 0.6)))
        // Harder hits bring out more of the upper partials.
        let brightness = 0.55 + 0.45 * velocity

        for p in 0..<Self.partials {
            let slot = voice * Self.partials + p
            let partialFrequency = frequency * Self.ratios[p]
            phase[slot] = 0
            guard partialFrequency < sr * 0.45 else {
                envelope[slot] = 0
                continue
            }
            increment[slot] = Self.twoPi * partialFrequency / sr
            let tone = p == 0 ? 1 : brightness
            envelope[slot] = Self.levels[p] * velocity * tone
            let seconds = baseDecay * Self.decayScale[p]
            decay[slot] = expf(-1 / (seconds * sr))
        }

        noiseLevel[voice] = 0.9 * velocity * velocity
        noiseDecay[voice] = expf(-1 / (0.010 * sr))
        noiseFast[voice] = 0
        noiseSlow[voice] = 0
    }

    private func nextRandom() -> Float {
        randomState ^= randomState << 13
        randomState ^= randomState >> 17
        randomState ^= randomState << 5
        return Float(randomState) / Float(UInt32.max) * 2 - 1
    }
}
