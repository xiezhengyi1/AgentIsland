import AppKit
import SwiftUI

// Looping indicators drawn with Core Animation. The render server runs these animations, so the app
// itself does no work per frame (SwiftUI's TimelineView would re-evaluate views 30 times a second).

private final class LayerView: NSView {
    override var isFlipped: Bool { false }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Three dots that bounce in sequence ("working").
struct DotsAnimation: NSViewRepresentable {
    var color: Color

    func makeNSView(context: Context) -> NSView {
        let v = LayerView()
        let c = NSColor(color).cgColor
        let period = 1.1, lag = 0.1576 // matches the SwiftUI version: sin(2πt/1.1 − 0.9·i)
        for i in 0..<3 {
            let dot = CALayer()
            dot.bounds = CGRect(x: 0, y: 0, width: 5, height: 5)
            dot.cornerRadius = 2.5
            dot.backgroundColor = c
            dot.position = CGPoint(x: 5 + CGFloat(i) * 8 + 2.5, y: 9)
            let steps = 16
            let up = (0...steps).map { k -> Double in max(0, sin(2 * .pi * Double(k) / Double(steps))) }
            let hop = CAKeyframeAnimation(keyPath: "transform.translation.y")
            hop.values = up.map { $0 * 3.5 }
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = up.map { 0.55 + 0.45 * $0 }
            let g = CAAnimationGroup()
            g.animations = [hop, fade]
            g.duration = period
            g.repeatCount = .infinity
            g.timeOffset = (period - lag * Double(i)).truncatingRemainder(dividingBy: period)
            dot.add(g, forKey: "bounce")
            v.layer?.addSublayer(dot)
        }
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? { CGSize(width: 31, height: 16) }
}

/// A spinning arc ("working" badge).
struct SpinnerAnimation: NSViewRepresentable {
    var color: Color
    var size: CGFloat

    func makeNSView(context: Context) -> NSView {
        let v = LayerView()
        let arc = CAShapeLayer()
        arc.frame = CGRect(x: 0, y: 0, width: size, height: size)
        let r = (size - 1.8) / 2
        arc.path = CGPath(ellipseIn: CGRect(x: 0.9, y: 0.9, width: 2 * r, height: 2 * r), transform: nil)
        arc.fillColor = nil
        arc.strokeColor = NSColor(color).cgColor
        arc.lineWidth = 1.8
        arc.lineCap = .round
        arc.strokeEnd = 0.7
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 0.9
        spin.repeatCount = .infinity
        arc.add(spin, forKey: "spin")
        v.layer?.addSublayer(arc)
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? { CGSize(width: size, height: size) }
}

/// A gently pulsing symbol ("needs you").
struct PulseAnimation: NSViewRepresentable {
    var symbol: String
    var color: Color

    func makeNSView(context: Context) -> NSView {
        let v = LayerView()
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return v }
        let tinted = NSImage(size: img.size, flipped: false) { rect in
            img.draw(in: rect)
            NSColor(color).set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let l = CALayer()
        l.bounds = CGRect(origin: .zero, size: img.size)
        l.position = CGPoint(x: 8, y: 8)
        l.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        l.contents = tinted
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 0.85
        pulse.toValue = 1.0
        pulse.duration = 0.6
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        l.add(pulse, forKey: "pulse")
        v.layer?.addSublayer(l)
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? { CGSize(width: 16, height: 16) }
}
