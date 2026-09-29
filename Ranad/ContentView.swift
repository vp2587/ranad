import SwiftUI

struct ContentView: View {
    @StateObject private var model = RanadViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            LinearGradient(colors: [Palette.backgroundTop, Palette.backgroundBottom],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                ControlBar(model: model)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                GeometryReader { geo in
                    let layout = RanadLayout(size: geo.size)
                    ZStack {
                        ForEach(0..<RanadInstrument.barCount, id: \.self) { bar in
                            let rect = layout.barRects[bar]
                            BarView(label: model.label(forBar: bar),
                                    lit: model.litBars.contains(bar),
                                    width: rect.width,
                                    height: rect.height)
                                .frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)
                        }

                        Cords(layout: layout)

                        TouchSurface(layout: layout,
                                     tremolo: model.tremolo,
                                     onStrike: { bar, velocity in model.strike(bar, velocity: velocity) },
                                     onHeldChange: { bars in model.setHeldBars(bars) })
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.resumeAudio() }
        }
    }
}

// MARK: - Controls

private struct ControlBar: View {
    @ObservedObject var model: RanadViewModel

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text("ระนาดเอก")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Palette.gold)
                Text("Ranad Ek")
                    .font(.caption)
                    .foregroundStyle(Palette.cream.opacity(0.7))
            }

            Spacer(minLength: 8)

            Chip(title: "Labels", systemImage: "textformat", isOn: $model.showLabels)
            if model.showLabels {
                Chip(title: model.thaiLabels ? "ไทย" : "ABC", systemImage: "character.book.closed",
                     isOn: $model.thaiLabels)
            }
            Chip(title: "Octaves", systemImage: "square.stack", isOn: $model.octaves)
            Chip(title: "Kro", systemImage: "waveform.path", isOn: $model.tremolo)

            Picker("Tuning", selection: $model.tuning) {
                ForEach(Tuning.allCases) { tuning in
                    Text(tuning.title).tag(tuning)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 170)
        }
    }
}

private struct Chip: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(isOn ? Palette.backgroundBottom : Palette.cream)
                .background(Capsule().fill(isOn ? Palette.gold : Color.white.opacity(0.08)))
                .overlay(Capsule().stroke(Palette.gold.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Instrument drawing

private struct BarView: View {
    let label: String?
    let lit: Bool
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: width * 0.3, style: .continuous)
        shape
            .fill(LinearGradient(colors: [Palette.barDark, Palette.barLight, Palette.barMid, Palette.barDark],
                                 startPoint: .leading, endPoint: .trailing))
            .overlay(shape.fill(Palette.gold.opacity(lit ? 0.45 : 0)))
            .overlay(shape.stroke(Color.black.opacity(0.5), lineWidth: 1))
            .overlay(alignment: .bottom) {
                if let label {
                    Text(label)
                        .font(.system(size: max(8, min(14, width * 0.42)), weight: .semibold))
                        .foregroundStyle(Palette.cream)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(width: width * 1.1)
                        .padding(.bottom, height * 0.2)
                }
            }
            .shadow(color: lit ? Palette.gold.opacity(0.9) : .black.opacity(0.55),
                    radius: lit ? 10 : 3, y: lit ? 0 : 3)
            .scaleEffect(lit ? 0.985 : 1)
            .animation(.easeOut(duration: 0.1), value: lit)
    }
}

/// The two cords the bars are threaded on.
private struct Cords: View {
    let layout: RanadLayout

    var body: some View {
        Canvas { context, _ in
            guard let first = layout.barRects.first, let last = layout.barRects.last else { return }
            for fraction in [0.1, 0.9] as [CGFloat] {
                var cord = Path()
                cord.move(to: CGPoint(x: first.minX - 4,
                                      y: first.minY + first.height * fraction))
                for rect in layout.barRects {
                    cord.addLine(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * fraction))
                }
                cord.addLine(to: CGPoint(x: last.maxX + 4,
                                         y: last.minY + last.height * fraction))
                context.stroke(cord, with: .color(Palette.cord), lineWidth: 2)

                for rect in layout.barRects {
                    let point = CGPoint(x: rect.midX, y: rect.minY + rect.height * fraction)
                    let knot = Path(ellipseIn: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5))
                    context.fill(knot, with: .color(Palette.cord))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Colours

enum Palette {
    static let backgroundTop = Color(hex: 0x3A0D12)
    static let backgroundBottom = Color(hex: 0x120405)
    static let gold = Color(hex: 0xE2B34A)
    static let cream = Color(hex: 0xF7EBD3)
    static let barDark = Color(hex: 0x6B3419)
    static let barMid = Color(hex: 0x9C5630)
    static let barLight = Color(hex: 0xC98552)
    static let cord = Color(hex: 0x2A1A10)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

#Preview(traits: .landscapeLeft) {
    ContentView()
}
