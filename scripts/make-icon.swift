// Draws the Agent Island app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (run from the package root)
import AppKit
import SwiftUI

struct IconView: View {
    var body: some View {
        ZStack {
            // macOS icon grid: 824pt squircle centred on a 1024 canvas.
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 1.0),
                                              Color(red: 0.62, green: 0.32, blue: 0.95),
                                              Color(red: 1.0, green: 0.52, blue: 0.42)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    // Soft light from the top, like a lit screen.
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .fill(RadialGradient(colors: [.white.opacity(0.35), .clear],
                                             center: .init(x: 0.5, y: 0.0), startRadius: 0, endRadius: 520))
                )
                .overlay(alignment: .top) {
                    // Translucent menu bar the island sits in.
                    Rectangle().fill(.white.opacity(0.22)).frame(height: 96)
                }
                .overlay(alignment: .top) { island }
                .clipShape(RoundedRectangle(cornerRadius: 185, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 3)
                )
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 14)
        }
        .frame(width: 1024, height: 1024)
    }

    /// The black island hanging from the top edge, with three agent dots mid-bounce.
    var island: some View {
        ZStack {
            IslandOutline()
                .fill(Color.black)
                .shadow(color: .black.opacity(0.45), radius: 30, y: 18)
            HStack(spacing: 26) {
                dot(Color(red: 0.85, green: 0.47, blue: 0.34), lift: 0)
                dot(Color(red: 0.50, green: 0.85, blue: 0.75), lift: 30)
                dot(Color(red: 0.30, green: 0.55, blue: 0.96), lift: 10)
            }
            .offset(y: 22)
        }
        .frame(width: 440, height: 250)
    }

    func dot(_ c: Color, lift: CGFloat) -> some View {
        Circle()
            .fill(c)
            .frame(width: 80, height: 80)
            .shadow(color: c.opacity(0.8), radius: 22)
            .offset(y: -lift)
    }
}

/// Flat top with concave flares into the edge, big rounded bottom — the notch silhouette.
struct IslandOutline: Shape {
    func path(in r: CGRect) -> Path {
        let f: CGFloat = 34, b: CGFloat = 110
        let L = r.minX + f, R = r.maxX - f
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: L, y: r.minY + f), control: CGPoint(x: L, y: r.minY))
        p.addLine(to: CGPoint(x: L, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: L + b, y: r.maxY), control: CGPoint(x: L, y: r.maxY))
        p.addLine(to: CGPoint(x: R - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: R, y: r.maxY - b), control: CGPoint(x: R, y: r.maxY))
        p.addLine(to: CGPoint(x: R, y: r.minY + f))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: R, y: r.minY))
        p.closeSubpath()
        return p
    }
}

MainActor.assumeIsolated {
    let fm = FileManager.default
    let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
    try? fm.removeItem(at: iconset)
    try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

    let renderer = ImageRenderer(content: IconView())
    renderer.scale = 1
    guard let cg = renderer.cgImage else { fatalError("render failed") }
    let master = NSBitmapImageRep(cgImage: cg)

    func write(_ px: Int, _ name: String) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        master.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
    for size in [16, 32, 128, 256, 512] {
        write(size, "icon_\(size)x\(size).png")
        write(size * 2, "icon_\(size)x\(size)@2x.png")
    }
    try! fm.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
    try! master.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Resources/AppIcon.png"))

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
    try! p.run()
    p.waitUntilExit()
    print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns and Resources/AppIcon.png" : "iconutil failed")
}
