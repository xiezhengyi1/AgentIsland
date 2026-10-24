import AppKit
import ApplicationServices

/// Measures how much empty menu-bar space there is on each side of the notch, so the island's
/// wings never cover app menus or status icons.
///
/// Status icons aren't separate windows on recent macOS, so this reads menu bar items through the
/// Accessibility API: the frontmost app's menus plus every app's status items ("extras").
/// Without Accessibility permission it reports nil and the island keeps out of the menu bar.
enum MenuBarSpace {
    struct Free: Equatable {
        var left: CGFloat
        var right: CGFloat
    }

    /// Where the notch and menu bar are. Plain values so measuring can run off the main thread.
    struct Request {
        var notchMinX: CGFloat // global x of the notch's left edge
        var notchMaxX: CGFloat
        var screenMinX: CGFloat
        var screenMaxX: CGFloat
        var menuBarTopCG: CGFloat // global CG y (origin top-left of primary display)
        var menuBarHeight: CGFloat

        /// Whether a status item sits close enough to the notch to matter; those get re-read often.
        func isNearNotch(_ r: CGRect) -> Bool {
            r.minX < notchMaxX + 200 && r.maxX > notchMinX - 200
        }
    }

    static func request(for screen: NSScreen, notch: NotchMetrics) -> Request {
        let f = screen.frame
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? f.maxY
        return Request(notchMinX: f.midX - notch.width / 2, notchMaxX: f.midX + notch.width / 2,
                       screenMinX: f.minX, screenMaxX: f.maxX,
                       menuBarTopCG: primaryTop - f.maxY, menuBarHeight: notch.height)
    }

    /// The frontmost app's menu titles. Fast (a few ms), so it runs on every app switch.
    static func appMenuFrames(pid: pid_t) -> [CGRect] {
        itemFrames(of: AXUIElementCreateApplication(pid), attribute: kAXMenuBarAttribute)
    }

    /// Status icons of the given apps, keyed by owner. Slow across all apps (1–2 s), so callers
    /// re-read only the apps near the notch often and do a full sweep in the background.
    static func statusItemFrames(pids: [pid_t]) -> [pid_t: [CGRect]] {
        var result: [pid_t: [CGRect]] = [:]
        for pid in pids {
            let frames = itemFrames(of: AXUIElementCreateApplication(pid), attribute: "AXExtrasMenuBar")
            if !frames.isEmpty { result[pid] = frames }
        }
        return result
    }

    /// Apps that can own menu-bar items (background-only apps can't).
    static func candidatePIDs() -> [pid_t] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited }.map(\.processIdentifier)
    }

    static func free(_ req: Request, frames: [CGRect]) -> Free {
        var left = req.notchMinX - req.screenMinX
        var right = req.screenMaxX - req.notchMaxX
        let top = req.menuBarTopCG, bottom = req.menuBarTopCG + req.menuBarHeight
        for r in frames where r.width > 0 && r.minY < bottom && r.maxY > top {
            if r.maxX <= req.notchMinX + 1 {
                left = min(left, req.notchMinX - r.maxX)
            } else if r.minX >= req.notchMaxX - 1 {
                right = min(right, r.minX - req.notchMaxX)
            }
            // Items overlapping the notch are hidden by macOS; nothing to protect there.
        }
        return Free(left: max(0, left), right: max(0, right))
    }

    /// Human-readable dump of every menu-bar item found and the resulting free space (for `--measure`).
    static func report(_ req: Request, frontmostPID: pid_t?, names: [pid_t: String]) -> String {
        var lines = ["trusted: \(AXIsProcessTrusted())",
                     "notch x: \(req.notchMinX) – \(req.notchMaxX)   menu bar y: \(req.menuBarTopCG) + \(req.menuBarHeight)"]
        var frames: [CGRect] = []
        func add(_ pid: pid_t, _ attribute: String, _ tag: String) {
            for (title, f) in labeledFrames(of: AXUIElementCreateApplication(pid), attribute: attribute) {
                frames.append(f)
                lines.append("\(tag)\t\(names[pid] ?? String(pid))\t\(title)\tx \(Int(f.minX))–\(Int(f.maxX))  y \(Int(f.minY))–\(Int(f.maxY))")
            }
        }
        var t = Date()
        if let pid = frontmostPID { add(pid, kAXMenuBarAttribute, "menu") }
        lines.append("time: app menus \(Int(Date().timeIntervalSince(t) * 1000)) ms")
        let pids = candidatePIDs()
        t = Date()
        for pid in pids { add(pid, "AXExtrasMenuBar", "extra") }
        lines.append("time: status items of \(pids.count) apps \(Int(Date().timeIntervalSince(t) * 1000)) ms")
        let near = Set(statusItemFrames(pids: pids).filter { $0.value.contains(where: req.isNearNotch) }.keys)
        t = Date()
        _ = statusItemFrames(pids: Array(near))
        lines.append("time: status items of \(near.count) apps near the notch \(Int(Date().timeIntervalSince(t) * 1000)) ms")
        lines.append("free: \(free(req, frames: frames))")
        return lines.joined(separator: "\n")
    }

    private static func itemFrames(of app: AXUIElement, attribute: String) -> [CGRect] {
        labeledFrames(of: app, attribute: attribute).map(\.1)
    }

    private static func labeledFrames(of app: AXUIElement, attribute: String) -> [(String, CGRect)] {
        AXUIElementSetMessagingTimeout(app, 0.15)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, attribute as CFString, &bar) == .success,
              let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return [] }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
              let items = children as? [AXUIElement] else { return [] }
        return items.compactMap { item in
            guard let f = frame(of: item) else { return nil }
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &title)
            if (title as? String ?? "").isEmpty { AXUIElementCopyAttributeValue(item, kAXDescriptionAttribute as CFString, &title) }
            return ((title as? String) ?? "", f)
        }
    }

    private static func frame(of el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: pos, size: size)
    }
}
