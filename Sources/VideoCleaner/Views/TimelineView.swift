// VideoCleaner — Copyright (C) 2026 Lasse L
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Observation
import SwiftUI
import VideoCleanerCore

/// Zoom and pan state of the timeline. Only the visible window is ever drawn, so any zoom level works
/// even on very long files.
@Observable @MainActor
final class TimelineState {
    var duration: Double = 1
    var zoom: Double = 1
    var viewStart: Double = 0
    var width: CGFloat = 800

    /// Keyframes are spaced about this far apart after "Show keyframes".
    static let keyframeSpacing: CGFloat = 44
    /// Shortest visible span (seconds) at maximum zoom.
    static let minVisible: Double = 1.5

    var maxZoom: Double { max(1, duration / Self.minVisible) }
    var visibleDuration: Double { duration / zoom }
    var viewEnd: Double { viewStart + visibleDuration }
    var pxPerSec: Double { Double(width) / visibleDuration }
    var isZoomed: Bool { zoom > 1.001 }

    func x(_ t: Double) -> CGFloat { CGFloat((t - viewStart) * pxPerSec) }
    func time(_ x: CGFloat) -> Double { min(max(0, viewStart + Double(x) / pxPerSec), duration) }

    func reset(duration: Double) {
        self.duration = max(duration, 0.001)
        zoom = 1
        viewStart = 0
    }

    private func clampStart(_ s: Double) -> Double { min(max(0, s), max(0, duration - visibleDuration)) }

    /// Zooms while keeping `anchor` (a time) at the same horizontal position.
    func setZoom(_ z: Double, anchor: Double, anchorX: CGFloat? = nil) {
        let ax = anchorX ?? (anchor >= viewStart && anchor <= viewEnd ? x(anchor) : width / 2)
        zoom = min(max(1, z), maxZoom)
        viewStart = clampStart(anchor - Double(ax) / pxPerSec)
    }

    func zoomIn(around t: Double) { setZoom(zoom * 2, anchor: t) }
    func zoomOut(around t: Double) { setZoom(zoom / 2, anchor: t) }
    func fit() { zoom = 1; viewStart = 0 }

    /// Zooms so that the keyframes around `t` are clearly separated, and centres on `t`.
    func zoomToKeyframes(_ keyframes: [Double], around t: Double) {
        guard keyframes.count > 1 else { return }
        // Local spacing: median of the gaps near t (keyframe intervals can vary a lot)
        let i = Cuts.nearestKeyframeIndex(to: t, in: keyframes) ?? 0
        let lo = max(1, i - 10), hi = min(keyframes.count - 1, i + 10)
        var gaps = (lo...hi).map { keyframes[$0] - keyframes[$0 - 1] }.filter { $0 > 0.001 }.sorted()
        if gaps.isEmpty { gaps = [duration / Double(keyframes.count)] }
        let gap = gaps[gaps.count / 2]
        let visible = gap * Double(width / Self.keyframeSpacing)
        setZoom(duration / max(visible, Self.minVisible), anchor: t, anchorX: width / 2)
    }

    func pan(by seconds: Double) { viewStart = clampStart(viewStart + seconds) }

    func center(on t: Double) { viewStart = clampStart(t - visibleDuration / 2) }

    /// Keeps t visible (used while playing, stepping and jumping between keyframes).
    func follow(_ t: Double) {
        guard isZoomed, t < viewStart || t > viewEnd else { return }
        viewStart = clampStart(t - visibleDuration * 0.15)
    }
}

// MARK: - Timeline

struct TimelineView: View {
    @Environment(AppModel.self) private var model
    let item: VideoItem
    let state: TimelineState

    @State private var viewRef = ViewRef()
    @State private var monitor: Any?

    static let rulerHeight: CGFloat = 18
    static let stripHeight: CGFloat = 58
    static let laneHeight: CGFloat = 18
    static var totalHeight: CGFloat { rulerHeight + stripHeight + 3 + laneHeight }

    var body: some View {
        VStack(spacing: 6) {
            TimelineContent(item: item, state: state)
                .frame(height: Self.totalHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ViewRefReader(ref: viewRef))
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { state.width = max(1, $0) }

            OverviewBar(item: item, state: state)
                .frame(height: 12)

            controls
        }
        .onAppear {
            state.reset(duration: item.duration)
            installMonitor()
        }
        .onDisappear(perform: removeMonitor)
        .onChange(of: item.duration) { _, d in state.reset(duration: d) }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Legend(color: .red.opacity(0.6), text: L("Removed"))
                    Legend(color: .yellow, text: L("Start mark"))
                    if item.keyframesState == .loaded {
                        Legend(color: .accentColor, text: L("Keyframes (click to snap)"), diamond: true)
                    }
                }
                if item.keyframesState == .loaded {
                    Legend(color: .accentColor, text: L("Keyframes (click to snap)"), diamond: true)
                }
                Color.clear.frame(width: 0, height: 0)
            }
            Spacer(minLength: 4)
            Text(L("Visible: %@", TimeFormat.string(state.visibleDuration, millis: state.visibleDuration < 60)))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button { state.zoomOut(around: model.player.currentTime) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom out ( − )")
            .disabled(!state.isZoomed)
            Slider(value: Binding(get: { log(state.zoom) },
                                  set: { state.setZoom(exp($0), anchor: model.player.currentTime) }),
                   in: 0...max(0.01, log(state.maxZoom)))
                .frame(width: 130)
                .controlSize(.small)
            Button { state.zoomIn(around: model.player.currentTime) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom in ( + )")
            Button { state.zoomToKeyframes(item.keyframes, around: model.player.currentTime) } label: {
                Label("Show Keyframes", systemImage: "key.viewfinder")
            }
            .help("Zoom in around the playhead so every keyframe can be seen and picked ( Z )")
            .disabled(item.keyframes.count < 2)
            Button("Fit") { state.fit() }
                .help("Show the whole file ( 0 )")
                .disabled(!state.isZoomed)
        }
        .font(.caption)
        .controlSize(.small)
        .buttonStyle(.borderless)
    }

    // Trackpad/mouse: horizontal scroll pans, pinch or ⌘/⌥ + scroll zooms around the pointer.
    private func installMonitor() {
        guard monitor == nil else { return }
        let ref = viewRef
        let state = state
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { event in
            let handled: Bool = MainActor.assumeIsolated {
                guard let view = ref.view, event.window === view.window else { return false }
                let p = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(p) else { return false }
                let anchorX = p.x
                let anchor = state.time(anchorX)
                if event.type == .magnify {
                    state.setZoom(state.zoom * (1 + event.magnification * 1.5), anchor: anchor, anchorX: anchorX)
                    return true
                }
                let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
                let dx = event.scrollingDeltaX * scale, dy = event.scrollingDeltaY * scale
                if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
                    state.setZoom(state.zoom * exp(Double(dy) * 0.02), anchor: anchor, anchorX: anchorX)
                    return true
                }
                guard state.isZoomed else { return false }
                let d = abs(dx) > abs(dy) ? dx : dy
                state.pan(by: -Double(d) / state.pxPerSec)
                return true
            }
            return handled ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Gives the event monitor access to the timeline's NSView (for hit testing scroll events).
final class ViewRef { weak var view: NSView? }

private struct ViewRefReader: NSViewRepresentable {
    let ref: ViewRef
    func makeNSView(context: Context) -> NSView {
        let v = PassthroughView()
        ref.view = v
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { ref.view = nsView }

    final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

private struct Legend: View {
    let color: Color
    let text: String
    var diamond = false
    var body: some View {
        HStack(spacing: 4) {
            if diamond {
                Image(systemName: "diamond.fill").font(.system(size: 8)).foregroundStyle(color)
            } else {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 8)
            }
            Text(text).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Content

private struct TimelineContent: View {
    @Environment(AppModel.self) private var model
    let item: VideoItem
    let state: TimelineState

    var body: some View {
        let stripTop = TimelineView.rulerHeight
        ZStack(alignment: .topLeading) {
            Ruler(state: state)
                .frame(width: state.width, height: TimelineView.rulerHeight)

            ThumbnailStrip(provider: model.player.thumbnails, state: state)
                .frame(width: state.width, height: TimelineView.stripHeight, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .offset(y: stripTop)

            ForEach(Array(item.removals.enumerated()), id: \.offset) { index, r in
                if state.x(r.end) > -12 && state.x(r.start) < state.width + 12 {
                    RemovalOverlay(item: item, index: index, range: r, state: state)
                        .offset(y: stripTop)
                }
            }

            if let a = item.markIn, state.x(a) >= -2, state.x(a) <= state.width + 2 {
                MarkInFlag()
                    .offset(x: state.x(a) - 1, y: 2)
                    .allowsHitTesting(false)
            }

            KeyframeLane(item: item, state: state)
                .frame(width: state.width, height: TimelineView.laneHeight)
                .offset(y: stripTop + TimelineView.stripHeight + 3)

            Playhead(state: state)
                .allowsHitTesting(false)
        }
        .frame(width: state.width, height: TimelineView.totalHeight, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        .coordinateSpace(.named("timeline"))
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                .onChanged { v in
                    model.player.pause()
                    model.player.seek(to: state.time(v.location.x), precise: false)
                }
                .onEnded { v in model.player.seek(to: state.time(v.location.x), precise: true) }
        )
    }
}

private struct Ruler: View {
    let state: TimelineState

    var body: some View {
        Canvas { ctx, size in
            let pps = state.pxPerSec
            let steps: [Double] = [0.04, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
            let major = steps.first { $0 * pps >= 90 } ?? 3600
            let minor = major / 5
            var t = (state.viewStart / minor).rounded(.down) * minor
            while t <= state.viewEnd + minor {
                let x = state.x(t)
                let isMajor = abs((t / major).rounded() - t / major) < 1e-6
                let h: CGFloat = isMajor ? 7 : 3.5
                ctx.fill(Path(CGRect(x: x, y: size.height - h, width: 1, height: h)),
                         with: .color(Color.secondary.opacity(isMajor ? 0.8 : 0.4)))
                if isMajor {
                    ctx.draw(Text(TimeFormat.string(t, millis: major < 1)).font(.system(size: 9.5).monospacedDigit())
                                .foregroundStyle(.secondary),
                             at: CGPoint(x: x + 3, y: 1), anchor: .topLeading)
                }
                t += minor
            }
        }
    }
}

private struct ThumbnailStrip: View {
    let provider: ThumbnailProvider?
    let state: TimelineState
    static let tileWidth: CGFloat = 104

    var body: some View {
        let tileDuration = Double(Self.tileWidth) / state.pxPerSec
        let first = max(0, Int((state.viewStart / tileDuration).rounded(.down)))
        let last = max(first, Int((min(state.duration, state.viewEnd) / tileDuration).rounded(.up)))
        let exact = tileDuration < 4
        ZStack(alignment: .topLeading) {
            Color.secondary.opacity(0.15)
            ForEach(first...last, id: \.self) { i in
                ThumbTile(provider: provider, time: min(state.duration, (Double(i) + 0.5) * tileDuration), exact: exact)
                    .offset(x: state.x(Double(i) * tileDuration))
            }
        }
    }
}

private struct ThumbTile: View {
    let provider: ThumbnailProvider?
    let time: Double
    let exact: Bool
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.12))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: ThumbnailStrip.tileWidth, height: TimelineView.stripHeight)
        .clipped()
        .overlay(alignment: .trailing) { Rectangle().fill(.black.opacity(0.25)).frame(width: 0.5) }
        .task(id: TaskKey(provider: provider.map(ObjectIdentifier.init), time: time, exact: exact)) {
            image = provider?.cached(at: time, exact: exact)
            if image == nil, let provider { image = await provider.image(at: time, exact: exact) }
        }
    }

    private struct TaskKey: Equatable {
        let provider: ObjectIdentifier?
        let time: Double
        let exact: Bool
    }
}

/// Keyframe markers: diamonds when zoomed in far enough, thin ticks otherwise. The keyframe nearest the
/// playhead is highlighted (filled when the playhead is exactly on it). Clicking or dragging here always
/// lands exactly on a keyframe.
private struct KeyframeLane: View {
    @Environment(AppModel.self) private var model
    let item: VideoItem
    let state: TimelineState

    var body: some View {
        let keyframes = item.keyframes
        let current = model.player.currentTime
        let nearest = Cuts.nearestKeyframe(to: current, in: keyframes)
        let onKey = nearest.map { abs($0 - current) <= max(0.002, model.player.frameDuration / 2) } ?? false
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4),
                     with: .color(Color.secondary.opacity(0.08)))
            guard !keyframes.isEmpty else { return }
            let range = Cuts.indexRange(of: keyframes, from: state.viewStart, to: state.viewEnd)
            let spacing = range.count > 1 ? size.width / CGFloat(range.count) : size.width
            let mid = size.height / 2
            if spacing >= 9 {
                var diamonds = Path()
                for i in range {
                    diamonds.addPath(Self.diamond(at: CGPoint(x: state.x(keyframes[i]), y: mid), r: 4))
                }
                ctx.fill(diamonds, with: .color(Color.accentColor.opacity(0.55)))
            } else {
                var ticks = Path()
                var lastX: CGFloat = -10
                for i in range {
                    let x = state.x(keyframes[i])
                    if x - lastX < 2.5 { continue }
                    ticks.addRect(CGRect(x: x, y: 3, width: 1, height: size.height - 6))
                    lastX = x
                }
                ctx.fill(ticks, with: .color(Color.accentColor.opacity(0.5)))
            }
            if let k = nearest, k >= state.viewStart, k <= state.viewEnd {
                let d = Self.diamond(at: CGPoint(x: state.x(k), y: mid), r: 6.5)
                if onKey {
                    ctx.fill(d, with: .color(.accentColor))
                } else {
                    ctx.stroke(d, with: .color(.accentColor), lineWidth: 1.5)
                }
            }
        }
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                .onChanged { v in snap(to: v.location.x, precise: false) }
                .onEnded { v in snap(to: v.location.x, precise: true) }
        )
        .help("Click or drag here to jump to the nearest keyframe")
    }

    private func snap(to x: CGFloat, precise: Bool) {
        guard let k = Cuts.nearestKeyframe(to: state.time(x), in: item.keyframes) else { return }
        model.player.pause()
        model.player.seek(to: k, precise: precise)
    }

    static func diamond(at c: CGPoint, r: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: c.y - r))
        p.addLine(to: CGPoint(x: c.x + r, y: c.y))
        p.addLine(to: CGPoint(x: c.x, y: c.y + r))
        p.addLine(to: CGPoint(x: c.x - r, y: c.y))
        p.closeSubpath()
        return p
    }
}

private struct MarkInFlag: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "flag.fill").font(.system(size: 10)).foregroundStyle(.yellow).offset(x: 1)
            Rectangle().fill(.yellow).frame(width: 2, height: TimelineView.stripHeight + 4)
        }
    }
}

private struct RemovalOverlay: View {
    @Environment(AppModel.self) private var model
    let item: VideoItem
    let index: Int
    let range: TimeRange
    let state: TimelineState

    var body: some View {
        let x0 = state.x(range.start), x1 = state.x(range.end)
        let cx0 = max(x0, -12), cx1 = min(x1, state.width + 12)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.red.opacity(0.42))
                .overlay(Stripes().stroke(Color.red.opacity(0.55), lineWidth: 1.5).clipped())
                .overlay(Rectangle().strokeBorder(Color.red, lineWidth: 1.5))
                .frame(width: max(2, cx1 - cx0), height: TimelineView.stripHeight)
                .offset(x: cx0)
                .contextMenu {
                    Button("Undo This Cut") { item.removals.removeAll { $0 == range } }
                    Button("Go to Start") { model.player.seek(to: range.start) }
                    Button("Go to End") { model.player.seek(to: range.end) }
                }
                .help(L("%@ → %@ is removed (right-click to undo)", TimeFormat.string(range.start), TimeFormat.string(range.end)))
            if range.start > 0.001 && x0 > -6 && x0 < state.width + 6 {
                Handle()
                    .offset(x: x0 - 5)
                    .highPriorityGesture(drag(isStart: true))
            }
            if range.end < state.duration - 0.001 && x1 > -6 && x1 < state.width + 6 {
                Handle()
                    .offset(x: x1 - 5)
                    .highPriorityGesture(drag(isStart: false))
            }
        }
        .frame(width: state.width, height: TimelineView.stripHeight, alignment: .topLeading)
    }

    private func drag(isStart: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline"))
            .onChanged { v in
                guard index < item.removals.count else { return }
                var r = item.removals[index]
                var t = state.time(v.location.x)
                let lower = index > 0 ? item.removals[index - 1].end : 0
                let upper = index + 1 < item.removals.count ? item.removals[index + 1].start : state.duration
                if isStart {
                    t = min(max(t, lower), r.end - 0.04)
                    r.start = t
                } else {
                    t = model.snappedKeepStart(t, item: item)
                    t = max(min(t, upper), r.start + 0.04)
                    r.end = t
                }
                item.removals[index] = r
                model.player.pause()
                model.player.seek(to: t, precise: false)
            }
            .onEnded { _ in
                item.setRemovals(item.removals)
                model.player.seek(to: model.player.currentTime, precise: true)
            }
    }
}

private struct Handle: View {
    @State private var hovering = false
    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.red)
            .frame(width: 10, height: TimelineView.stripHeight)
            .overlay(
                VStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in Capsule().fill(.white.opacity(0.85)).frame(width: 4, height: 1.5) }
                }
            )
            .scaleEffect(x: hovering ? 1.25 : 1, y: 1)
            .onHover { h in
                hovering = h
                if h { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }
}

private struct Stripes: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        var x = -rect.height
        while x < rect.width {
            p.move(to: CGPoint(x: x, y: rect.height))
            p.addLine(to: CGPoint(x: x + rect.height, y: 0))
            x += 9
        }
        return p
    }
}

private struct Playhead: View {
    @Environment(AppModel.self) private var model
    let state: TimelineState

    var body: some View {
        let t = model.player.currentTime
        let x = state.x(t)
        VStack(spacing: 0) {
            PlayheadCap().fill(Color.accentColor).frame(width: 13, height: 10)
            Rectangle().fill(Color.accentColor).frame(width: 2, height: TimelineView.totalHeight - 10)
        }
        .shadow(color: .black.opacity(0.35), radius: 1.5)
        .offset(x: x - 6.5, y: TimelineView.rulerHeight - 10)
        .opacity(x >= -7 && x <= state.width + 7 ? 1 : 0)
        .onChange(of: t) { _, new in state.follow(new) }
    }
}

private struct PlayheadCap: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY * 0.55))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY * 0.55))
        p.closeSubpath()
        return p
    }
}

// MARK: - Overview

/// The whole file in miniature: removed parts, the playhead and the zoomed window (draggable).
private struct OverviewBar: View {
    @Environment(AppModel.self) private var model
    let item: VideoItem
    let state: TimelineState

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let d = max(state.duration, 0.001)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                ForEach(Array(item.removals.enumerated()), id: \.offset) { _, r in
                    Rectangle().fill(Color.red.opacity(0.6))
                        .frame(width: max(1.5, CGFloat(r.length / d) * w))
                        .offset(x: CGFloat(r.start / d) * w)
                }
                if state.isZoomed {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor.opacity(0.18))
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                        .frame(width: max(8, CGFloat(state.visibleDuration / d) * w))
                        .offset(x: CGFloat(state.viewStart / d) * w)
                }
                Rectangle().fill(Color.accentColor)
                    .frame(width: 2)
                    .offset(x: CGFloat(model.player.currentTime / d) * w - 1)
            }
            .clipShape(Capsule())
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let t = Double(v.location.x / w) * d
                        if state.isZoomed {
                            state.center(on: t)
                        } else {
                            model.player.pause()
                            model.player.seek(to: t, precise: false)
                        }
                    }
            )
            .help(state.isZoomed ? L("Drag to move the zoomed window") : L("The whole file"))
        }
    }
}
