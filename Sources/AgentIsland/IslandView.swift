import AppKit
import IslandCore
import SwiftUI

/// The island outline. The menu-bar part spans the notch plus its side wings (which may differ in
/// width), with concave flares at the very top so it melts into the bezel. Below the menu bar an
/// optional wider body hangs down, joined by curved shoulders.
struct IslandShape: Shape {
    var topLeft: CGFloat // distance from the notch centre to the left edge of the menu-bar part
    var topRight: CGFloat
    var topHeight: CGFloat
    var flare: CGFloat
    var bodyWidth: CGFloat // 0 = no body below the menu bar
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(topLeft, topRight), AnimatablePair(bodyWidth, bottomRadius)) }
        set {
            topLeft = newValue.first.first
            topRight = newValue.first.second
            bodyWidth = newValue.second.first
            bottomRadius = newValue.second.second
        }
    }

    func path(in r: CGRect) -> Path {
        let f = flare, th = min(topHeight, r.height)
        let L = r.midX - topLeft, R = r.midX + topRight
        var p = Path()
        p.move(to: CGPoint(x: L - f, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: L, y: r.minY + f), control: CGPoint(x: L, y: r.minY))

        if bodyWidth <= 0 || r.height <= th + 0.5 {
            // Menu-bar part only.
            let b = min(bottomRadius, max(0, r.maxY - r.minY - f), (R - L) / 2)
            p.addLine(to: CGPoint(x: L, y: r.maxY - b))
            p.addQuadCurve(to: CGPoint(x: L + b, y: r.maxY), control: CGPoint(x: L, y: r.maxY))
            p.addLine(to: CGPoint(x: R - b, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: R, y: r.maxY - b), control: CGPoint(x: R, y: r.maxY))
        } else {
            let bodyL = r.midX - bodyWidth / 2, bodyR = r.midX + bodyWidth / 2
            let gl = max(0, L - bodyL), gr = max(0, bodyR - R) // how far the body sticks out
            let sl = min(10, gl / 2, max(0, th - f)), cl = min(12, max(0, gl - sl))
            let sr = min(10, gr / 2, max(0, th - f)), cr = min(12, max(0, gr - sr))
            let b = min(bottomRadius, max(0, r.maxY - th - max(cl, cr)))
            p.addLine(to: CGPoint(x: L, y: th - sl))
            p.addQuadCurve(to: CGPoint(x: L - sl, y: th), control: CGPoint(x: L, y: th))
            p.addLine(to: CGPoint(x: bodyL + cl, y: th))
            p.addQuadCurve(to: CGPoint(x: bodyL, y: th + cl), control: CGPoint(x: bodyL, y: th))
            p.addLine(to: CGPoint(x: bodyL, y: r.maxY - b))
            p.addQuadCurve(to: CGPoint(x: bodyL + b, y: r.maxY), control: CGPoint(x: bodyL, y: r.maxY))
            p.addLine(to: CGPoint(x: bodyR - b, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: bodyR, y: r.maxY - b), control: CGPoint(x: bodyR, y: r.maxY))
            p.addLine(to: CGPoint(x: bodyR, y: th + cr))
            p.addQuadCurve(to: CGPoint(x: bodyR - cr, y: th), control: CGPoint(x: bodyR, y: th))
            p.addLine(to: CGPoint(x: R + sr, y: th))
            p.addQuadCurve(to: CGPoint(x: R, y: th - sr), control: CGPoint(x: R, y: th))
        }

        p.addLine(to: CGPoint(x: R, y: r.minY + f))
        p.addQuadCurve(to: CGPoint(x: R + f, y: r.minY), control: CGPoint(x: R, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct IslandRootView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let size = model.islandSize
        let top = model.topExtent
        let shape = IslandShape(topLeft: top.left, topRight: top.right, topHeight: model.notch.height,
                                flare: IslandModel.flare,
                                bodyWidth: size.height > model.notch.height + 0.5 ? model.bodyWidth : 0,
                                bottomRadius: model.expanded ? 22 : (model.popup != nil ? 16 : 10))
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                shape.fill(Color.black)
                Group {
                    if model.expanded {
                        ExpandedView(model: model).transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    } else {
                        CollapsedView(model: model).transition(.opacity)
                    }
                }
                .padding(.horizontal, IslandModel.flare)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .shadow(color: .black.opacity(model.expanded ? 0.45 : 0), radius: 18, y: 8)
            .contentShape(shape)
            .onTapGesture { if !model.expanded { model.toggle() } }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Menu-bar row

/// The wings beside the notch: activity on the left, count on the right. When only one side has
/// room, that side shows both.
struct WingsRow: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let w = model.wings
        HStack(spacing: 0) {
            Group {
                if w.left > 0 {
                    if w.right > 0 { LeadIndicator(model: model) } else { both }
                }
            }
            .frame(width: w.left)
            Color.clear.frame(width: model.notch.hasNotch ? model.notch.width : 0)
            Group {
                if w.right > 0 {
                    if w.left > 0 { CountGlyph(model: model) } else { both }
                }
            }
            .frame(width: w.right)
        }
        .offset(x: (w.right - w.left) / 2) // keep the notch gap centred on the real notch
        .frame(height: model.notch.height)
        .frame(maxWidth: .infinity)
    }

    var both: some View {
        HStack(spacing: 5) {
            LeadIndicator(model: model)
            CountGlyph(model: model)
        }
    }
}

struct LeadIndicator: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        if let lead = model.leadEntry, lead.state == .waiting {
            PulsingIcon(symbol: "bell.fill", color: .orange)
        } else if let lead = model.leadEntry, lead.state == .working {
            BouncingDots(color: Color(hex: lead.kind.color))
        } else if let lead = model.leadEntry, lead.state == .done {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.green)
        } else {
            Image(systemName: "sparkles").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.4))
        }
    }
}

struct CountGlyph: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        if model.activeCount > 0 {
            Text("\(model.activeCount)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
        } else if !model.entries.isEmpty {
            HStack(spacing: -3) {
                ForEach(model.entries.prefix(3)) { e in
                    Circle().fill(Color(hex: e.kind.color)).frame(width: 7, height: 7)
                        .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                }
            }
        }
    }
}

// MARK: - Collapsed

struct CollapsedView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            WingsRow(model: model)
            if let popup = model.popup {
                let urgent = popup.entry.state == .waiting || popup.entry.state == .error
                FlashRow(entry: popup.entry, more: urgent ? model.moreAttention : 0,
                         onDismiss: urgent ? { model.dismissAttention(popup.entry) } : nil)
                    .frame(height: 40)
                    .contentShape(Rectangle())
                    .onTapGesture { model.navigate(to: popup.entry) }
                    .padding(.horizontal, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if model.showsChin {
                chin
                    .frame(width: model.bodyWidth - 20, height: IslandModel.chinHeight)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
    }

    /// Fallback when there's no free menu-bar space for wings.
    var chin: some View {
        HStack(spacing: 6) {
            LeadIndicator(model: model).frame(width: 22)
            Text(summary)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
            Spacer(minLength: 2)
            if model.activeCount > 0 {
                Text("\(model.activeCount)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }
        }
    }

    var summary: String {
        let working = model.entries.filter { $0.state == .working }.count
        if let lead = model.leadEntry, lead.state == .waiting { return "\(lead.kind.name) needs you" }
        if working > 1 { return "\(working) agents working" }
        if let lead = model.leadEntry, lead.state == .working { return lead.kind.name }
        if model.entries.isEmpty { return "No agents" }
        return model.entries.count == 1 ? "1 agent idle" : "\(model.entries.count) agents idle"
    }
}

struct FlashRow: View {
    var entry: AgentEntry
    var more = 0
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            AgentIcon(kind: entry.kind, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(headline).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                if let m = entry.message {
                    Text(m).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if more > 0 {
                Text("+\(more)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.6))
            }
            StateBadge(state: entry.state, color: Color(hex: entry.kind.color))
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
    }

    var headline: String {
        let where_ = entry.folder.map { " · \($0)" } ?? ""
        switch entry.state {
        case .waiting: return "\(entry.kind.name) needs you\(where_)"
        case .error: return "\(entry.kind.name) hit an error\(where_)"
        default: return "\(entry.kind.name) finished\(where_)"
        }
    }
}

// MARK: - Expanded

struct ExpandedView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            WingsRow(model: model)
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text("Agents").font(.system(size: 13, weight: .semibold))
                    if model.activeCount > 0 {
                        Text("\(model.activeCount) active")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                    }
                }
                .padding(.leading, 14)
                Spacer(minLength: 8)
                Button(action: model.toggle) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.trailing, 10)
                .help("Fold")
            }
            .frame(height: IslandModel.headerHeight)
            .foregroundStyle(.white)
            .contentShape(Rectangle())
            .onTapGesture { model.toggle() }

            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.horizontal, 12)

            if model.visibleEntries.isEmpty {
                VStack(spacing: 4) {
                    Text("No agents running").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                    Text("Start claude, codex, gemini … and they show up here")
                        .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity).frame(height: 70)
            } else {
                let rows = VStack(spacing: 0) {
                    ForEach(model.visibleEntries) { e in
                        AgentRow(entry: e, model: model)
                            .frame(height: IslandModel.rowHeight)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                if model.visibleEntries.count > IslandModel.maxRows {
                    ScrollView(.vertical, showsIndicators: false) { rows }
                        .frame(height: CGFloat(IslandModel.maxRows) * IslandModel.rowHeight)
                } else {
                    rows
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct AgentRow: View {
    var entry: AgentEntry
    @ObservedObject var model: IslandModel

    var hover: Bool { model.hoveredRow == entry.id }

    var body: some View {
        HStack(spacing: 10) {
            AgentIcon(kind: entry.kind, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.kind.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                    if let folder = entry.folder {
                        Text(folder).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                    }
                }
                Text(entry.message ?? defaultMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(entry.message == nil ? 0.35 : 0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(hover ? 0.75 : 0))
            VStack(alignment: .trailing, spacing: 3) {
                StateBadge(state: entry.state, color: Color(hex: entry.kind.color))
                switch entry.state {
                case .working, .waiting:
                    // Live timer only while something is actually happening.
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(Self.elapsed(from: entry.since, to: ctx.date)).modifier(TimeStyle())
                    }
                case .done, .error:
                    Text("at " + entry.since.formatted(date: .omitted, time: .shortened)).modifier(TimeStyle())
                case .idle:
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(hover ? 0.07 : 0)).padding(.horizontal, 4))
        .contentShape(Rectangle())
        .onTapGesture { model.navigate(to: entry) }
        .help(Navigator.hint(for: entry))
        .onHover { inside in
            if inside { model.hoveredRow = entry.id } else if model.hoveredRow == entry.id { model.hoveredRow = nil }
        }
        .contextMenu {
            Button("Go to Session") { model.navigate(to: entry) }
            if let cwd = entry.cwd {
                Button("Reveal Folder in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cwd, forType: .string)
                }
            }
            if let pid = entry.pid { Text("PID \(pid)") }
            if entry.fromHook { Button("Dismiss") { model.dismiss(entry) } }
        }
    }

    var defaultMessage: String {
        switch entry.state {
        case .working: return "Working…"
        case .waiting: return "Waiting for you"
        case .done: return "Finished"
        case .idle: return "Idle"
        case .error: return "Error"
        }
    }

    static func elapsed(from: Date, to: Date) -> String {
        let s = max(0, Int(to.timeIntervalSince(from)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}

// MARK: - Bits

struct TimeStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.4))
    }
}

struct AgentIcon: View {
    var kind: AgentKind
    var size: CGFloat

    var body: some View {
        let c = Color(hex: kind.color)
        ZStack {
            Circle().fill(c.opacity(0.18))
            Image(systemName: kind.symbol)
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(c)
        }
        .frame(width: size, height: size)
    }
}

struct StateBadge: View {
    var state: AgentState
    var color: Color

    var body: some View {
        HStack(spacing: 4) {
            switch state {
            case .working: Spinner(color: color, size: 9)
            case .waiting: Image(systemName: "bell.fill").font(.system(size: 8, weight: .bold))
            case .done: Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy))
            case .error: Image(systemName: "exclamationmark").font(.system(size: 8, weight: .heavy))
            case .idle: Circle().frame(width: 5, height: 5)
            }
            Text(state.label).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.16)))
    }

    var tint: Color {
        switch state {
        case .working: return color
        case .waiting: return .orange
        case .done: return .green
        case .error: return .red
        case .idle: return .white.opacity(0.5)
        }
    }
}

struct Spinner: View {
    var color: Color
    var size: CGFloat
    var body: some View { SpinnerAnimation(color: color, size: size).frame(width: size, height: size) }
}

struct BouncingDots: View {
    var color: Color
    var body: some View { DotsAnimation(color: color).frame(width: 31, height: 16) }
}

struct PulsingIcon: View {
    var symbol: String
    var color: Color
    var body: some View { PulseAnimation(symbol: symbol, color: color).frame(width: 16, height: 16) }
}
