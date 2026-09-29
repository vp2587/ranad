import CoreGraphics
import Foundation

/// How the bars are tuned.
enum Tuning: String, CaseIterable, Identifiable {
    /// Traditional Thai tuning: the octave is split into seven (roughly) equal steps.
    case thai
    /// Western major scale, for playing along with Western instruments.
    case western

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thai: return "Thai"
        case .western: return "Western"
        }
    }
}

/// Pitch and naming for the 21 bars of a ranad ek (ระนาดเอก).
enum RanadInstrument {
    static let barCount = 21
    static let notesPerOctave = 7

    /// Pitch of the lowest (left-most) bar. The ranad ek sits well above middle C.
    static let lowestFrequency = 330.0

    static let thaiNames = ["โด", "เร", "มี", "ฟา", "ซอล", "ลา", "ที"]
    static let latinNames = ["Do", "Re", "Mi", "Fa", "Sol", "La", "Ti"]

    private static let majorScaleSemitones = [0, 2, 4, 5, 7, 9, 11]

    static func frequency(ofBar bar: Int, tuning: Tuning) -> Double {
        switch tuning {
        case .thai:
            return lowestFrequency * pow(2, Double(bar) / Double(notesPerOctave))
        case .western:
            let octave = bar / notesPerOctave
            let semitones = majorScaleSemitones[bar % notesPerOctave] + 12 * octave
            return lowestFrequency * pow(2, Double(semitones) / 12)
        }
    }

    static func name(ofBar bar: Int, thai: Bool) -> String {
        (thai ? thaiNames : latinNames)[bar % notesPerOctave]
    }

    /// The bar one octave away, used when playing in octaves (ตีคู่แปด) like a real ranad player.
    static func octavePartner(ofBar bar: Int) -> Int {
        bar >= notesPerOctave ? bar - notesPerOctave : bar + notesPerOctave
    }
}

/// Geometry of the instrument, shared by the drawing code and the touch handling
/// so that what you see is exactly what you hit.
struct RanadLayout {
    let size: CGSize
    let barRects: [CGRect]
    let slotWidth: CGFloat
    let sidePadding: CGFloat

    init(size: CGSize) {
        self.size = size
        let count = RanadInstrument.barCount
        let sidePadding: CGFloat = 12
        let slot = (size.width - sidePadding * 2) / CGFloat(count)
        let barWidth = slot * 0.86
        // Every bar is the same length and sits on the same top and bottom line.
        let top = size.height * 0.04
        let height = size.height * 0.92
        self.barRects = (0..<count).map { i in
            let midX = sidePadding + slot * (CGFloat(i) + 0.5)
            return CGRect(x: midX - barWidth / 2, y: top, width: barWidth, height: height)
        }
        self.slotWidth = slot
        self.sidePadding = sidePadding
    }

    /// The bar under a point. Each bar owns its whole column, gaps included,
    /// so fast glissandos don't drop notes.
    func barIndex(at point: CGPoint) -> Int? {
        guard slotWidth > 0 else { return nil }
        let column = Int(floor((point.x - sidePadding) / slotWidth))
        guard barRects.indices.contains(column) else { return nil }
        return point.y >= 0 && point.y <= size.height ? column : nil
    }
}
