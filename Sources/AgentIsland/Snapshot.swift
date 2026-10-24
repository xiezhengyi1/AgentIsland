import AppKit
import SwiftUI

/// `AgentIsland --snapshot <dir>`: render the island offscreen (collapsed, flash, expanded) with
/// live data to PNGs. Handy for checking the UI without screen-recording permission.
@MainActor
enum Snapshot {
    static func run(to dir: String) {
        let model = IslandModel()
        if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first {
            model.notch = NotchMetrics.of(screen)
            model.screenGeometry = MenuBarSpace.request(for: screen, notch: model.notch)
        }
        IslandModel.maxRows = 20 // ImageRenderer can't draw ScrollView content
        model.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            for e in model.entries {
                print(e.kind.name, e.state.rawValue, e.pid.map(String.init) ?? "-", e.folder ?? "-", e.message ?? "", Navigator.hint(for: e), separator: "\t")
            }
            render(model, "collapsed-live", dir) // real measurement (needs Accessibility)
            model.screenGeometry = nil // keep the scenarios below from being re-measured
            for (name, free) in [("roomy", MenuBarSpace.Free(left: 90, right: 70)),
                                 ("tight-right", MenuBarSpace.Free(left: 60, right: 14)),
                                 ("no-permission", nil)] as [(String, MenuBarSpace.Free?)] {
                model.free = free
                render(model, "collapsed-\(name)", dir)
            }
            model.free = MenuBarSpace.Free(left: 90, right: 70)
            if let e = model.entries.first {
                model.debugAttention(AgentEntry(id: e.id, kind: e.kind, state: .waiting, message: "Claude needs your permission to use Bash",
                                                cwd: e.cwd, pid: e.pid, since: Date(), fromHook: true))
                render(model, "attention", dir)
                model.debugAttention(nil)
                model.debugFlash(AgentEntry(id: e.id, kind: e.kind, state: .done, message: "Refactored the scanner and all tests pass",
                                            cwd: e.cwd, pid: e.pid, since: Date(), fromHook: true))
            }
            render(model, "flash", dir)
            model.debugFlash(nil)
            model.expanded = true
            render(model, "expanded", dir)
            exit(0)
        }
    }

    static func render(_ model: IslandModel, _ name: String, _ dir: String) {
        let size = model.islandSize
        let view = ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.62), Color(red: 0.62, green: 0.46, blue: 0.58)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // Fake menu bar: items end exactly where the measured free space ends.
            ZStack {
                Rectangle().fill(Color.white.opacity(0.25))
                let free = model.free ?? .init(left: 12, right: 12)
                HStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Spacer()
                        Text("Window  Help").font(.system(size: 13, weight: .medium)).padding(.trailing, free.left)
                    }
                    .frame(maxWidth: .infinity)
                    UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9)
                        .fill(Color.black).frame(width: model.notch.width)
                    HStack(spacing: 0) {
                        Image(systemName: "wifi").padding(.leading, free.right)
                        Text(" 100%").font(.system(size: 13, weight: .medium))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: model.notch.height)
            IslandRootView(model: model)
        }
        .frame(width: max(size.width + 80, 560), height: size.height + 40)
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
}
