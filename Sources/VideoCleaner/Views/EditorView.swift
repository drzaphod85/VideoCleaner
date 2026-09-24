// VideoCleaner — Copyright (C) 2026 Lasse L
// SPDX-License-Identifier: GPL-3.0-or-later

import AVKit
import SwiftUI
import VideoCleanerCore

// MARK: - Cut actions

extension AppModel {
    /// Where a kept part may start: the nearest keyframe when snapping (so no re-encoding is needed).
    func snappedKeepStart(_ t: Double, item: VideoItem) -> Double {
        guard snapToKeyframes, !item.preciseCut, let k = Cuts.nearestKeyframe(to: t, in: item.keyframes) else { return t }
        return k
    }

    func cutBefore(_ item: VideoItem) {
        let t = snappedKeepStart(player.currentTime, item: item)
        guard t > 0.01 else { NSSound.beep(); return }
        item.addRemoval(TimeRange(0, t))
        player.seek(to: t)
    }

    func cutAfter(_ item: VideoItem) {
        let t = player.currentTime
        guard t < item.duration - 0.01 else { NSSound.beep(); return }
        item.addRemoval(TimeRange(t, item.duration))
    }

    func markIn(_ item: VideoItem) {
        item.markIn = player.currentTime
    }

    func markOut(_ item: VideoItem) {
        guard let a = item.markIn else {
            item.markIn = player.currentTime
            return
        }
        let b = snappedKeepStart(player.currentTime, item: item)
        guard b > a + 0.01 else { NSSound.beep(); return }
        item.addRemoval(TimeRange(a, b))
        item.markIn = nil
        player.seek(to: b)
    }

    func removeRemoval(at t: Double, in item: VideoItem) {
        let before = item.removals.count
        item.removals.removeAll { $0.contains(t) || abs($0.end - t) < 0.001 }
        if item.removals.count == before { NSSound.beep() }
    }

    func jumpKeyframe(_ item: VideoItem, forward: Bool) {
        let t = player.currentTime
        let k = forward ? Cuts.nextKeyframe(after: t, in: item.keyframes)
                        : Cuts.previousKeyframe(before: t, in: item.keyframes)
        if let k { player.pause(); player.seek(to: k) } else { NSSound.beep() }
    }
}

// MARK: - Editor

struct EditorView: View {
    @Environment(AppModel.self) private var model
    let item: VideoItem
    @FocusState private var focused: Bool
    @State private var timeline = TimelineState()

    var body: some View {
        VStack(spacing: 0) {
            PlayerSurface(item: item)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .onTapGesture { focused = true; model.player.togglePlay() }
            TransportBar(item: item)
                .padding(.horizontal, 16)
                .padding(.top, 10)
            TimelineView(item: item, state: timeline)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .simultaneousGesture(TapGesture().onEnded { focused = true })
            CutBar(item: item, timeline: timeline)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            if model.showLog {
                LogPanel(item: item)
                    .frame(height: 190)
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.snappy, value: model.showLog)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down, action: handleKey)
        .onAppear { focused = true }
        .task(id: loadKey) {
            guard item.info != nil else { return }
            model.player.load(item: item, tools: model.tools)
            model.loadKeyframes(for: item)
        }
        .onChange(of: model.player.needsReload) { _, needs in
            if needs, item.info != nil { model.player.load(item: item, tools: model.tools); model.loadKeyframes(for: item) }
        }
        .onChange(of: item.removals, initial: true) { _, r in model.player.skipRanges = r }
        .onChange(of: model.skipRemovedWhilePlaying, initial: true) { _, v in model.player.skipRemoved = v }
    }

    private var loadKey: String { "\(item.id)|\(item.url.path)|\(item.info != nil)" }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let p = model.player
        let shift = press.modifiers.contains(.shift)
        let option = press.modifiers.contains(.option)
        if press.modifiers.contains(.command) { return .ignored }
        switch press.key {
        case .space:
            p.togglePlay(); return .handled
        case .upArrow:
            model.jumpKeyframe(item, forward: false); return .handled
        case .downArrow:
            model.jumpKeyframe(item, forward: true); return .handled
        case .leftArrow:
            if option { model.jumpKeyframe(item, forward: false) } else if shift { p.seek(to: p.currentTime - 1) } else { p.step(frames: -1) }
            return .handled
        case .rightArrow:
            if option { model.jumpKeyframe(item, forward: true) } else if shift { p.seek(to: p.currentTime + 1) } else { p.step(frames: 1) }
            return .handled
        case .home:
            p.seek(to: 0); return .handled
        case .end:
            p.seek(to: item.duration); return .handled
        case .delete, .deleteForward:
            model.removeRemoval(at: p.currentTime, in: item); return .handled
        case .escape:
            item.markIn = nil; return .handled
        default:
            break
        }
        switch press.characters.lowercased() {
        case "i": model.markIn(item)
        case "o": model.markOut(item)
        case "[": model.cutBefore(item)
        case "]": model.cutAfter(item)
        case "k": p.togglePlay()
        case "j": p.seek(to: p.currentTime - 5)
        case "l": p.seek(to: p.currentTime + 5)
        case "+", "=": timeline.zoomIn(around: p.currentTime)
        case "-": timeline.zoomOut(around: p.currentTime)
        case "0": timeline.fit()
        case "z": timeline.zoomToKeyframes(item.keyframes, around: p.currentTime)
        default: return .ignored
        }
        return .handled
    }
}

// MARK: - Player

struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        v.player = player
        v.allowsPictureInPicturePlayback = false
        return v
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}

struct PlayerSurface: View {
    @Environment(AppModel.self) private var model
    let item: VideoItem

    var body: some View {
        let p = model.player
        ZStack {
            Color.black
            AVPlayerViewRepresentable(player: p.player)
                .opacity(p.state == .ready ? 1 : 0)
            switch p.state {
            case .preparing(let progress, let label):
                ZStack {
                    if let img = item.poster {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).blur(radius: 24).opacity(0.5)
                    }
                    VStack(spacing: 10) {
                        if let progress {
                            ProgressView(value: progress).frame(width: 240)
                            Text(verbatim: "\(label) \(Int(progress * 100)) %").font(.callout).monospacedDigit()
                        } else {
                            ProgressView().controlSize(.large)
                            Text(label).font(.callout)
                        }
                        if item.url.pathExtension.lowercased() == "mkv" {
                            Text("macOS cannot play MKV directly — a temporary copy is made without re-encoding.")
                                .font(.caption).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .foregroundStyle(.white)
                }
                .clipped()
            case .failed(let message):
                VStack(spacing: 8) {
                    Image(systemName: "eye.slash").font(.largeTitle)
                    Text("No preview available").font(.headline)
                    Text(message).font(.caption).multilineTextAlignment(.center).frame(maxWidth: 420)
                    Text("You can still cut using the timeline and process the file.").font(.caption)
                }
                .foregroundStyle(.white.opacity(0.8))
            case .empty:
                if item.info == nil {
                    ProgressView().tint(.white)
                }
            case .ready:
                EmptyView()
            }
        }
        .overlay(alignment: .topLeading) { RemovedBadge(item: item) }
        .overlay(alignment: .topTrailing) {
            if p.previewMode == .transcode {
                Text("Lower-quality preview")
                    .font(.caption2).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.5), in: Capsule()).foregroundStyle(.white.opacity(0.8))
                    .padding(10)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .frame(minHeight: 220)
    }
}

/// Shows a red "removed" badge when the playhead is inside a part that will be cut away.
struct RemovedBadge: View {
    @Environment(AppModel.self) private var model
    let item: VideoItem

    var body: some View {
        let t = model.player.currentTime
        if item.removals.contains(where: { $0.contains(t) }) {
            Label("Removed", systemImage: "scissors")
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.red.opacity(0.85), in: Capsule())
                .foregroundStyle(.white)
                .padding(12)
                .transition(.opacity)
        }
    }
}

// MARK: - Transport

struct TransportBar: View {
    @Environment(AppModel.self) private var model
    let item: VideoItem
    @State private var editingTime = false
    @State private var timeText = ""

    var body: some View {
        @Bindable var model = model
        let p = model.player
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                transportButton("backward.end.alt.fill", L("Previous keyframe (⌥←)")) { model.jumpKeyframe(item, forward: false) }
                    .disabled(item.keyframes.isEmpty)
                transportButton("backward.frame.fill", L("One frame back (←)")) { p.step(frames: -1) }
                Button { p.togglePlay() } label: {
                    Image(systemName: p.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 40, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Play/pause (space)")
                .disabled(p.state != .ready)
                transportButton("forward.frame.fill", L("One frame forward (→)")) { p.step(frames: 1) }
                transportButton("forward.end.alt.fill", L("Next keyframe (⌥→)")) { model.jumpKeyframe(item, forward: true) }
                    .disabled(item.keyframes.isEmpty)
            }

            timecode(p)

            keyframeIndicator(p.currentTime)

            Spacer()

            Toggle(isOn: $model.skipRemovedWhilePlaying) {
                Label("Skip removed", systemImage: "arrowshape.bounce.right")
            }
            .toggleStyle(.button)
            .labelStyle(.titleAndIcon)
            .help("Preview the result: playback jumps over the parts that are removed")

            Toggle(isOn: $model.snapToKeyframes) {
                Label("Snap to keyframes", systemImage: "arrow.right.and.line.vertical.and.arrow.left")
            }
            .toggleStyle(.button)
            .labelStyle(.titleAndIcon)
            .help("Cuts where a kept part starts are placed on the nearest keyframe — then the video does not need re-encoding")
        }
        .labelStyle(.iconOnly)
        .controlSize(.regular)
    }

    private func transportButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    @ViewBuilder
    private func timecode(_ p: PlayerController) -> some View {
        HStack(spacing: 4) {
            if editingTime {
                TextField(text: $timeText) { Text(verbatim: "h:mm:ss,mmm") }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 130)
                    .onSubmit {
                        if let t = TimeFormat.parse(timeText) { p.seek(to: t) } else { NSSound.beep() }
                        editingTime = false
                    }
                    .onExitCommand { editingTime = false }
            } else {
                Button {
                    timeText = TimeFormat.string(p.currentTime, alwaysHours: true)
                    editingTime = true
                } label: {
                    Text(TimeFormat.string(p.currentTime, alwaysHours: true))
                        .font(.system(.title3, design: .monospaced).weight(.medium))
                        .monospacedDigit()
                }
                .buttonStyle(.plain)
                .help("Click to go to a time (e.g. 00:55,855)")
            }
            Text(verbatim: "/ \(TimeFormat.string(item.duration, alwaysHours: true))")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func keyframeIndicator(_ t: Double) -> some View {
        switch item.keyframesState {
        case .loading:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Reading keyframes…").font(.caption).foregroundStyle(.secondary)
            }
        case .loaded:
            let onKey = Cuts.isKeyframe(t, in: item.keyframes, tolerance: max(0.002, model.player.frameDuration / 2))
            let index = (Cuts.nearestKeyframeIndex(to: t, in: item.keyframes) ?? 0) + 1
            HStack(spacing: 5) {
                Image(systemName: onKey ? "diamond.fill" : "diamond")
                    .font(.system(size: 9))
                    .foregroundStyle(onKey ? Color.accentColor : Color.secondary)
                Text(onKey ? L("Keyframe %lld of %lld", index, item.keyframes.count) : L("Between keyframes"))
                    .font(.caption)
                    .foregroundStyle(onKey ? .primary : .secondary)
                    .monospacedDigit()
            }
            .help(L("%lld keyframes. Cutting on a keyframe needs no re-encoding.", item.keyframes.count))
        case .failed:
            Label("Keyframes could not be read", systemImage: "exclamationmark.triangle")
                .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.orange)
        case .idle:
            EmptyView()
        }
    }
}

// MARK: - Cut bar

struct CutBar: View {
    @Environment(AppModel.self) private var model
    let item: VideoItem
    let timeline: TimelineState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    cutButtons.labelStyle(.titleAndIcon)
                    cutButtons.labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)

                if let a = item.markIn {
                    HStack(spacing: 4) {
                        Image(systemName: "flag.fill").foregroundStyle(.yellow)
                        Text(L("In at %@ — go to the end and press O", TimeFormat.string(a)))
                            .font(.caption)
                        Button { item.markIn = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if !item.removals.isEmpty {
                    let plan = item.cutPlan()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(L("New length %@", TimeFormat.string(plan.outputDuration, millis: false)))
                            .font(.callout.weight(.medium)).monospacedDigit()
                        Text(verbatim: "−\(TimeFormat.string(item.duration - plan.outputDuration, millis: false))")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Button("Clear Cuts") { item.removals = []; item.markIn = nil; item.preciseCut = false }
                }
            }

            if !item.removals.isEmpty {
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(item.removals.enumerated()), id: \.offset) { _, r in
                                RemovalChip(range: r, duration: item.duration) {
                                    model.player.seek(to: r.start > 0 ? r.start : r.end)
                                } onDelete: {
                                    item.removals.removeAll { $0 == r }
                                }
                            }
                        }
                    }
                    precisionNote
                }
            }
        }
    }

    private var cutButtons: some View {
        HStack(spacing: 6) {
            Button { model.jumpKeyframe(item, forward: false) } label: {
                Label("Previous Keyframe", systemImage: "backward.end.fill")
            }
            .help("Jump to the previous keyframe ( ↑ or ⌥← )")
            .disabled(item.keyframes.isEmpty)
            Button { model.jumpKeyframe(item, forward: true) } label: {
                Label("Next Keyframe", systemImage: "forward.end.fill")
            }
            .help("Jump to the next keyframe ( ↓ or ⌥→ )")
            .disabled(item.keyframes.isEmpty)
            Divider().frame(height: 18)
            Button { model.cutBefore(item) } label: {
                Label("Remove Before", systemImage: "arrow.left.to.line")
            }
            .help("Remove everything before the playhead ( [ )")
            Button { model.markIn(item) } label: {
                Label("Mark In", systemImage: "chevron.left.to.line")
            }
            .help("Mark the start of a middle part to remove ( I )")
            Button { model.markOut(item) } label: {
                Label("Mark Out", systemImage: "chevron.right.to.line")
            }
            .help("Mark the end of the part and remove it ( O )")
            .disabled(item.markIn == nil)
            Button { model.cutAfter(item) } label: {
                Label("Remove After", systemImage: "arrow.right.to.line")
            }
            .help("Remove everything after the playhead ( ] )")
        }
        .fixedSize()
    }

    @ViewBuilder
    private var precisionNote: some View {
        let misaligned = CutPlan(removals: item.removals, duration: item.duration, keyframes: item.keyframes,
                                 precise: false).misalignedSegments
        if !misaligned.isEmpty && item.keyframesState == .loaded {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(misaligned.count == 1 ? L("1 cut is between keyframes") : L("%lld cuts are between keyframes", misaligned.count))
                    .font(.caption)
                Toggle("Frame-exact (re-encodes video)", isOn: Bindable(item).preciseCut)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .help("Off: the part starts at the nearest keyframe before the cut (no re-encoding).\nOn: the video is re-encoded with VideoToolbox so the cut is exact — takes longer.")
            }
            .fixedSize()
        } else if item.preciseCut {
            Toggle("Frame-exact (re-encodes video)", isOn: Bindable(item).preciseCut).toggleStyle(.checkbox).font(.caption).fixedSize()
        } else if item.keyframesState == .loaded {
            Label("All cuts on keyframes — no re-encoding", systemImage: "checkmark.seal.fill")
                .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.green).fixedSize()
        }
    }
}

struct RemovalChip: View {
    let range: TimeRange
    let duration: Double
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption2)
            Text(label).font(.caption).monospacedDigit()
            Button(action: onDelete) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.borderless)
                .help("Undo this cut")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.red.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.red.opacity(0.35)))
        .foregroundStyle(.red)
        .contentShape(Capsule())
        .onTapGesture(perform: onSelect)
    }

    private var icon: String {
        if range.start < 0.001 { return "arrow.left.to.line" }
        if range.end > duration - 0.001 { return "arrow.right.to.line" }
        return "scissors"
    }

    private var label: String {
        if range.start < 0.001 { return L("Start → %@", TimeFormat.string(range.end)) }
        if range.end > duration - 0.001 { return L("%@ → end", TimeFormat.string(range.start)) }
        return "\(TimeFormat.string(range.start)) → \(TimeFormat.string(range.end))"
    }
}

// MARK: - Log

struct LogPanel: View {
    let item: VideoItem

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Label("Log", systemImage: "list.bullet.rectangle").font(.caption.weight(.semibold))
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.log.map(\.text).joined(separator: "\n"), forType: .string)
                }
                .buttonStyle(.borderless).font(.caption)
                .disabled(item.log.isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if item.log.isEmpty {
                            Text("No log yet — run the file to see what happens.")
                                .foregroundStyle(.tertiary)
                        }
                        ForEach(item.log) { e in
                            LogLine(entry: e).id(e.id)
                        }
                    }
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 8)
                }
                .onChange(of: item.log.count) {
                    if let last = item.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .background(.background.secondary)
    }
}

struct LogLine: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 14)
            Text(entry.text)
                .foregroundStyle(entry.kind == .command ? .secondary : .primary)
        }
    }

    private var icon: String {
        switch entry.kind {
        case .step: return "arrow.right"
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        case .success: return "checkmark.circle"
        case .command: return "terminal"
        }
    }

    private var color: Color {
        switch entry.kind {
        case .step: return .accentColor
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        case .success: return .green
        case .command: return .secondary
        }
    }
}
