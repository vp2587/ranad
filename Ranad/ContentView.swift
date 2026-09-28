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
                        RanadStand(layout: layout)

                        ForEach(0..<RanadInstrument.barCount, id: \.self) { bar in
                            let rect = layout.barRects[bar]
                            BarView(label: model.label(forBar: bar),
                                    lit: model.litBars.contains(bar),
                                    width: rect.width)
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
                        .padding(.bottom, width * 0.9)
                }
            }
            .shadow(color: lit ? Palette.gold.opacity(0.9) : .black.opacity(0.55),
                    radius: lit ? 10 : 3, y: lit ? 0 : 3)
            .scaleEffect(lit ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: lit)
    }
}

/// The boat-shaped wooden stand (รางระนาด) with its pedestal foot.
private struct RanadStand: View {
    let layout: RanadLayout

    var body: some View {
        Canvas { context, size in
            guard let first = layout.barRects.first, let last = layout.barRects.last else { return }
            let middle = layout.barRects[layout.barRects.count / 2]
            let slot = layout.slotWidth

            let left = CGPoint(x: first.minX - slot * 1.1, y: first.midY - first.height * 0.08)
            let right = CGPoint(x: last.maxX + slot * 1.1, y: last.midY - last.height * 0.08)
            // Quadratic control point that puts the rim just below the middle bar's centre.
            let rimMid = middle.midY + middle.height * 0.12
            let rimControl = CGPoint(x: size.width / 2, y: 2 * rimMid - (left.y + right.y) / 2)

            let bottomSide = size.height * 0.84
            let bottomMid = size.height * 0.91
            let bottomLeft = CGPoint(x: left.x + slot * 1.6, y: bottomSide)
            let bottomRight = CGPoint(x: right.x - slot * 1.6, y: bottomSide)
            let bottomControl = CGPoint(x: size.width / 2, y: 2 * bottomMid - bottomSide)

            // Pedestal foot.
            var foot = Path()
            foot.move(to: CGPoint(x: size.width * 0.41, y: bottomMid - 4))
            foot.addLine(to: CGPoint(x: size.width * 0.59, y: bottomMid - 4))
            foot.addLine(to: CGPoint(x: size.width * 0.64, y: size.height * 0.995))
            foot.addLine(to: CGPoint(x: size.width * 0.36, y: size.height * 0.995))
            foot.closeSubpath()
            context.fill(foot, with: .linearGradient(Gradient(colors: [Palette.hullDark, Palette.hull]),
                                                     startPoint: CGPoint(x: 0, y: bottomMid),
                                                     endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(foot, with: .color(Palette.gold.opacity(0.8)), lineWidth: 1.5)

            // Hull.
            var hull = Path()
            hull.move(to: left)
            hull.addQuadCurve(to: right, control: rimControl)
            hull.addQuadCurve(to: bottomRight, control: CGPoint(x: right.x, y: bottomSide))
            hull.addQuadCurve(to: bottomLeft, control: bottomControl)
            hull.addQuadCurve(to: left, control: CGPoint(x: left.x, y: bottomSide))
            hull.closeSubpath()
            context.fill(hull, with: .linearGradient(Gradient(colors: [Palette.hull, Palette.hullDark]),
                                                     startPoint: CGPoint(x: 0, y: rimMid),
                                                     endPoint: CGPoint(x: 0, y: bottomMid)))
            context.stroke(hull, with: .color(.black.opacity(0.6)), lineWidth: 2)

            // Gold trim along the rim and a decorative band below it.
            var rim = Path()
            rim.move(to: left)
            rim.addQuadCurve(to: right, control: rimControl)
            context.stroke(rim, with: .color(Palette.gold), lineWidth: 3)

            let bandOffset = size.height * 0.07
            var band = Path()
            band.move(to: CGPoint(x: left.x + slot * 0.6, y: left.y + bandOffset))
            band.addQuadCurve(to: CGPoint(x: right.x - slot * 0.6, y: right.y + bandOffset),
                              control: CGPoint(x: rimControl.x, y: rimControl.y + bandOffset))
            context.stroke(band, with: .color(Palette.gold.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 2, dash: [6, 5]))

            // Raised, curled ends.
            for end in [left, right] {
                let r = slot * 0.35
                let knob = Path(ellipseIn: CGRect(x: end.x - r, y: end.y - r, width: r * 2, height: r * 2))
                context.fill(knob, with: .color(Palette.gold))
                context.stroke(knob, with: .color(Palette.hullDark), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
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
                cord.move(to: CGPoint(x: first.minX - layout.slotWidth * 0.9,
                                      y: first.minY + first.height * fraction))
                for rect in layout.barRects {
                    cord.addLine(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * fraction))
                }
                cord.addLine(to: CGPoint(x: last.maxX + layout.slotWidth * 0.9,
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
    static let hull = Color(hex: 0x6A2E14)
    static let hullDark = Color(hex: 0x2E1208)
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
