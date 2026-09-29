import SwiftUI

@MainActor
final class RanadViewModel: ObservableObject {
    @Published var showLabels: Bool { didSet { defaults.set(showLabels, forKey: Keys.labels) } }
    @Published var thaiLabels: Bool { didSet { defaults.set(thaiLabels, forKey: Keys.thaiLabels) } }
    @Published var octaves: Bool { didSet { defaults.set(octaves, forKey: Keys.octaves) } }
    @Published var tremolo: Bool { didSet { defaults.set(tremolo, forKey: Keys.tremolo) } }
    @Published var tuning: Tuning { didSet { defaults.set(tuning.rawValue, forKey: Keys.tuning) } }

    /// Bars currently glowing: held under a finger or just struck.
    @Published private(set) var litBars: Set<Int> = []

    /// Notes for every tuning, in `Tuning.allCases` order, `barCount` per tuning.
    private let audio = RanadAudioEngine(noteFrequencies: Tuning.allCases.flatMap { tuning in
        (0..<RanadInstrument.barCount).map { RanadInstrument.frequency(ofBar: $0, tuning: tuning) }
    })
    private let defaults = UserDefaults.standard
    private var heldBars: Set<Int> = []
    private var flashingBars: Set<Int> = []
    private var flashTokens: [Int: Int] = [:]

    private enum Keys {
        static let labels = "showLabels"
        static let thaiLabels = "thaiLabels"
        static let octaves = "octaves"
        static let tremolo = "tremolo"
        static let tuning = "tuning"
    }

    init() {
        defaults.register(defaults: [Keys.labels: true, Keys.thaiLabels: true])
        showLabels = defaults.bool(forKey: Keys.labels)
        thaiLabels = defaults.bool(forKey: Keys.thaiLabels)
        octaves = defaults.bool(forKey: Keys.octaves)
        tremolo = defaults.bool(forKey: Keys.tremolo)
        tuning = Tuning(rawValue: defaults.string(forKey: Keys.tuning) ?? "") ?? .thai
    }

    func resumeAudio() {
        audio.start()
    }

    func strike(_ bar: Int, velocity: Float) {
        play(bar, velocity: velocity)
        if octaves {
            play(RanadInstrument.octavePartner(ofBar: bar), velocity: velocity * 0.85)
        }
    }

    func setHeldBars(_ bars: Set<Int>) {
        guard bars != heldBars else { return }
        heldBars = bars
        refreshLit()
    }

    func label(forBar bar: Int) -> String? {
        showLabels ? RanadInstrument.name(ofBar: bar, thai: thaiLabels) : nil
    }

    private func play(_ bar: Int, velocity: Float) {
        let tuningIndex = Tuning.allCases.firstIndex(of: tuning) ?? 0
        audio.noteOn(tuningIndex * RanadInstrument.barCount + bar, velocity: velocity)
        flash(bar)
    }

    private func flash(_ bar: Int) {
        let token = (flashTokens[bar] ?? 0) + 1
        flashTokens[bar] = token
        flashingBars.insert(bar)
        refreshLit()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard let self, self.flashTokens[bar] == token else { return }
            self.flashingBars.remove(bar)
            self.refreshLit()
        }
    }

    private func refreshLit() {
        let lit = heldBars.union(flashingBars)
        if lit != litBars { litBars = lit }
    }
}
