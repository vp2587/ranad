import SwiftUI
import UIKit

/// A transparent multi-touch layer over the bars. Every finger is a mallet: tap to strike,
/// slide across the bars for a glissando, and (with Kro on) hold to roll a tremolo.
struct TouchSurface: UIViewRepresentable {
    let layout: RanadLayout
    let tremolo: Bool
    let onStrike: (Int, Float) -> Void
    let onHeldChange: (Set<Int>) -> Void

    func makeUIView(context: Context) -> TouchSurfaceView {
        let view = TouchSurfaceView()
        view.isMultipleTouchEnabled = true
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: TouchSurfaceView, context: Context) {
        view.layout = layout
        view.onStrike = onStrike
        view.onHeldChange = onHeldChange
        view.tremoloEnabled = tremolo
    }
}

final class TouchSurfaceView: UIView {
    var layout: RanadLayout?
    var onStrike: ((Int, Float) -> Void)?
    var onHeldChange: ((Set<Int>) -> Void)?
    var tremoloEnabled = false {
        didSet { if tremoloEnabled != oldValue { updateTremoloTimer() } }
    }

    private var barForTouch: [UITouch: Int] = [:]
    private var tremoloTimer: Timer?

    /// Kro (กรอ) speed: strikes per second while a bar is held.
    private let tremoloRate: TimeInterval = 14

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let bar = bar(for: touch) else { continue }
            barForTouch[touch] = bar
            onStrike?(bar, Float.random(in: 0.85...1.0))
        }
        publishHeld()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        var changed = false
        for touch in touches {
            let bar = bar(for: touch)
            guard bar != barForTouch[touch] else { continue }
            barForTouch[touch] = bar
            changed = true
            if let bar {
                // Sliding onto a new bar: a lighter glissando stroke.
                onStrike?(bar, Float.random(in: 0.65...0.8))
            }
        }
        if changed { publishHeld() }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        release(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        release(touches)
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            tremoloTimer?.invalidate()
            tremoloTimer = nil
        } else {
            updateTremoloTimer()
        }
    }

    private func bar(for touch: UITouch) -> Int? {
        layout?.barIndex(at: touch.location(in: self))
    }

    private func release(_ touches: Set<UITouch>) {
        for touch in touches { barForTouch[touch] = nil }
        publishHeld()
    }

    private func publishHeld() {
        onHeldChange?(Set(barForTouch.values))
    }

    private func updateTremoloTimer() {
        tremoloTimer?.invalidate()
        tremoloTimer = nil
        guard tremoloEnabled, window != nil else { return }
        let timer = Timer(timeInterval: 1 / tremoloRate, target: self, selector: #selector(tremoloTick),
                          userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        tremoloTimer = timer
    }

    @objc private func tremoloTick() {
        for bar in Set(barForTouch.values) {
            onStrike?(bar, Float.random(in: 0.55...0.75))
        }
    }
}
