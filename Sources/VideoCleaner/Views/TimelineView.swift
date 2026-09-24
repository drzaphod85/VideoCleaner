// VideoCleaner — Copyright (C) 2026 Lasse L
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import VideoCleanerCore

/// Zoomable timeline: ruler, thumbnail strip, keyframe ticks, removed parts with drag handles and the playhead.
struct TimelineView: View {
    @Environment(AppModel.self) private var model
    let item: VideoItem

    @State private var zoom: Double = 1
    @State private var scrollPosition = ScrollPosition(edge: .leading)
    @State private var scrollOffset: CGFloat = 0
    @State private var visibleWidth: CGFloat = 800
    @State private var magnifyBase: Double?

    static let rulerHeight: CGFloat = 18
    static let stripHeight: CGFloat = 58
    static let tickHeight: CGFloat = 7
    static var totalHeight: CGFloat { rulerHeight + stripHeight + tickHeight + 4 }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let total = max(geo.size.width, geo.size.width * zoom)
                ScrollView(.horizontal, showsIndicators: zoom > 1.01) {
                    TimelineContent(item: item, width: total, follow: follow)
                        .frame(width: total, height: Self.totalHeight)
                }
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in scrollOffset = x }
                .onAppear { visibleWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, w in visibleWidth = w }
                .onChange(of: zoom) { _, z in
                    let newTotal = max(visibleWidth, visibleWidth * z)
                    let x = item.duration > 0 ? model.player.currentTime / item.duration * newTotal : 0
                    scrollPosition.scrollTo(x: max(0, min(newTotal - visibleWidth, x - visibleWidth / 2)))
                }
            }
            .frame(height: Self.totalHeight + (zoom > 1.01 ? 10 : 0))
            .gesture(
                MagnifyGesture()
                    .onChanged { v in
                        if magnifyBase == nil { magnifyBase = zoom }
                        zoom = min(maxZoom, max(1, (magnifyBase ?? 1) * v.magnification))
                    }
                    .onEnded { _ in magnifyBase = nil }
            )

            HStack(spacing: 8) {
                Legend(color: .red.opacity(0.6), text: L("Removed"))
                Legend(color: .yellow, text: L("Start mark"))
                if item.keyframesState == .loaded { Legend(color: .secondary, text: L("Keyframes"), tick: true) }
                Spacer()
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: $zoom, in: 1...maxZoom)
                    .frame(width: 140)
                    .controlSize(.small)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                Button("Fit") { zoom = 1 }
                    .controlSize(.small)
                    .disabled(zoom <= 1.01)
            }
            .font(.caption)
        }
    }

    private var maxZoom: Double { max(2, min(400, item.duration / 8)) }

    /// Keeps the playhead visible while playing when zoomed in.
    private func follow(_ x: CGFloat) {
        guard zoom > 1.01 else { return }
        if x < scrollOffset || x > scrollOffset + visibleWidth - 20 {
            scrollPosition.scrollTo(x: max(0, x - visibleWidth * 0.15))
        }
    }
}

private struct Legend: View {
    let color: Color
    let text: String
    var tick = false
    var body: some View {
        HStack(spacing: 4) {
            if tick {
                Rectangle().fill(color).frame(width: 1.5, height: 9)
            } else {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 8)
            }
            Text(text).foregroundStyle(.secondary)
        }
    }
}

private struct TimelineContent: View {
    @Environment(AppModel.self) private var model
    let item: VideoItem
    let width: CGFloat
    let follow: (CGFloat) -> Void

    private var duration: Double { max(item.duration, 0.001) }
    private func x(_ t: Double) -> CGFloat { CGFloat(t / duration) * width }
    private func time(_ x: CGFloat) -> Double { min(max(0, Double(x / width) * duration), duration) }

    var body: some View {
        let stripTop = TimelineView.rulerHeight
        ZStack(alignment: .topLeading) {
            Ruler(duration: duration, width: width)
                .frame(width: width, height: TimelineView.rulerHeight)

            ThumbnailStrip(provider: model.player.thumbnails, duration: duration, width: width)
                .frame(width: width, height: TimelineView.stripHeight)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .offset(y: stripTop)

            if item.keyframesState == .loaded {
                KeyframeTicks(keyframes: item.keyframes, duration: duration, width: width)
                    .frame(width: width, height: TimelineView.tickHeight)
                    .offset(y: stripTop + TimelineView.stripHeight + 2)
                    .allowsHitTesting(false)
            }

            ForEach(Array(item.removals.enumerated()), id: \.offset) { index, r in
                RemovalOverlay(item: item, index: index, range: r, width: width, duration: duration)
                    .offset(y: stripTop)
            }

            if let a = item.markIn {
                MarkInFlag()
                    .offset(x: x(a) - 1, y: 2)
                    .allowsHitTesting(false)
            }

            Playhead(width: width, duration: duration, follow: follow)
                .allowsHitTesting(false)
        }
        .frame(width: width, height: TimelineView.totalHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .coordinateSpace(.named("timeline"))
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                .onChanged { v in
                    model.player.pause()
                    model.player.seek(to: time(v.location.x), precise: false)
                }
                .onEnded { v in model.player.seek(to: time(v.location.x), precise: true) }
        )
    }
}

private struct Ruler: View {
    let duration: Double
    let width: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let pxPerSec = Double(width) / duration
            let steps: [Double] = [0.04, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
            let major = steps.first { $0 * pxPerSec >= 90 } ?? 3600
            let minor = major / 5
            var t = 0.0
            let color = Color.secondary
            while t <= duration {
                let xpos = CGFloat(t * pxPerSec)
                let isMajor = abs((t / major).rounded() - t / major) < 1e-6
                let h: CGFloat = isMajor ? 7 : 3.5
                ctx.fill(Path(CGRect(x: xpos, y: size.height - h, width: 1, height: h)),
                         with: .color(color.opacity(isMajor ? 0.8 : 0.4)))
                if isMajor {
                    let label = TimeFormat.string(t, millis: major < 1)
                    ctx.draw(Text(label).font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.secondary),
                             at: CGPoint(x: xpos + 3, y: 1), anchor: .topLeading)
                }
                t += minor
            }
        }
    }
}

private struct ThumbnailStrip: View {
    let provider: ThumbnailProvider?
    let duration: Double
    let width: CGFloat
    static let tileWidth: CGFloat = 104

    var body: some View {
        let count = max(1, Int((width / Self.tileWidth).rounded(.up)))
        let tile = width / CGFloat(count)
        LazyHStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                ThumbTile(provider: provider, time: (Double(i) + 0.5) / Double(count) * duration)
                    .frame(width: tile, height: TimelineView.stripHeight)
            }
        }
        .background(Color.secondary.opacity(0.15))
    }
}

private struct ThumbTile: View {
    let provider: ThumbnailProvider?
    let time: Double
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.12))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .clipped()
        .overlay(alignment: .trailing) { Rectangle().fill(.black.opacity(0.25)).frame(width: 0.5) }
        .task(id: TaskKey(provider: provider.map(ObjectIdentifier.init), time: time)) {
            image = provider?.cached(at: time)
            if image == nil, let provider { image = await provider.image(at: time) }
        }
    }

    private struct TaskKey: Equatable {
        let provider: ObjectIdentifier?
        let time: Double
    }
}

private struct KeyframeTicks: View {
    let keyframes: [Double]
    let duration: Double
    let width: CGFloat

    var body: some View {
        Canvas { ctx, size in
            var lastX: CGFloat = -10
            var path = Path()
            for k in keyframes {
                let xpos = CGFloat(k / duration) * width
                if xpos - lastX < 2.5 { continue }
                path.addRect(CGRect(x: xpos, y: 0, width: 1, height: size.height))
                lastX = xpos
            }
            ctx.fill(path, with: .color(.secondary.opacity(0.7)))
        }
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
    let width: CGFloat
    let duration: Double

    private func x(_ t: Double) -> CGFloat { CGFloat(t / duration) * width }
    private func time(_ x: CGFloat) -> Double { min(max(0, Double(x / width) * duration), duration) }

    var body: some View {
        let x0 = x(range.start), x1 = x(range.end)
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.red.opacity(0.42))
                .overlay(Stripes().stroke(Color.red.opacity(0.55), lineWidth: 1.5).clipped())
                .overlay(Rectangle().strokeBorder(Color.red, lineWidth: 1.5))
                .frame(width: max(2, x1 - x0), height: TimelineView.stripHeight)
                .contextMenu {
                    Button("Undo This Cut") { item.removals.removeAll { $0 == range } }
                    Button("Go to Start") { model.player.seek(to: range.start) }
                    Button("Go to End") { model.player.seek(to: range.end) }
                }
                .help(L("%@ → %@ is removed (right-click to undo)", TimeFormat.string(range.start), TimeFormat.string(range.end)))
            if range.start > 0.001 {
                Handle()
                    .offset(x: -5)
                    .highPriorityGesture(drag(isStart: true))
            }
            if range.end < duration - 0.001 {
                Handle()
                    .offset(x: x1 - x0 - 5)
                    .highPriorityGesture(drag(isStart: false))
            }
        }
        .offset(x: x0)
    }

    private func drag(isStart: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline"))
            .onChanged { v in
                guard index < item.removals.count else { return }
                var r = item.removals[index]
                var t = time(v.location.x)
                let lower = index > 0 ? item.removals[index - 1].end : 0
                let upper = index + 1 < item.removals.count ? item.removals[index + 1].start : duration
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
    let width: CGFloat
    let duration: Double
    let follow: (CGFloat) -> Void

    var body: some View {
        let x = CGFloat(model.player.currentTime / duration) * width
        VStack(spacing: 0) {
            PlayheadCap().fill(Color.accentColor).frame(width: 13, height: 10)
            Rectangle().fill(Color.accentColor).frame(width: 2, height: TimelineView.totalHeight - 10)
        }
        .shadow(color: .black.opacity(0.35), radius: 1.5)
        .offset(x: x - 6.5, y: TimelineView.rulerHeight - 10)
        .onChange(of: model.player.currentTime) { _, t in
            if model.player.isPlaying { follow(CGFloat(t / duration) * width) }
        }
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
