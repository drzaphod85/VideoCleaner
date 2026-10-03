// VideoCleaner — Copyright (C) 2026 Lasse L
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import VideoCleanerCore

/// An audio track from another file, with its editor: language, automatic synchronization against one of the
/// film's own tracks, manual offset/speed/trim, and listening in the player.
struct AddedTrackView: View {
    @Environment(AppModel.self) private var model
    let item: VideoItem
    let info: MediaInfo
    let trackID: AddedAudio.ID
    @State private var referenceIndex: Int?

    private var index: Int? { item.addedAudio.firstIndex { $0.id == trackID } }

    var body: some View {
        if let i = index {
            let track = item.addedAudio[i]
            DisclosureGroup(isExpanded: Binding(
                get: { model.expandedAudioTrack == trackID },
                set: { model.expandedAudioTrack = $0 ? trackID : nil })) {
                editor(track)
                    .padding(.top, 4)
            } label: {
                header(track)
            }
            .onChange(of: track) { _, new in
                if model.player.previewTrack?.id == new.id { model.player.setPreviewTrack(new, tools: model.tools) }
            }
        }
    }

    /// Changes the language; the name follows along unless the user typed a name of their own.
    private func setLanguage(_ code: String, of t: AddedAudio) {
        guard let i = index else { return }
        let followsLanguage = t.title.isEmpty || t.title == Languages.displayName(t.language)
        item.addedAudio[i].language = code
        if followsLanguage { item.addedAudio[i].title = code == "und" ? "" : Languages.displayName(code) }
    }

    private func binding<T>(_ key: WritableKeyPath<AddedAudio, T>) -> Binding<T> {
        Binding(get: { item.addedAudio.first { $0.id == trackID }![keyPath: key] },
                set: { v in if let i = index { item.addedAudio[i][keyPath: key] = v } })
    }

    // MARK: Header

    private func header(_ t: AddedAudio) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill").foregroundStyle(.green)
                Text(verbatim: "a\(info.audioStreams.count + 1 + (index ?? 0))")
                    .font(.caption.monospaced().weight(.semibold))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                LanguagePickerMenu(code: t.language) { setLanguage($0, of: t) }
                if t.isDefault { Badge(text: L("Default"), icon: "star.fill", color: .secondary) }
                if model.player.previewTrack?.id == t.id { Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint) }
            }
            Text(verbatim: "\(t.summary) · \(t.source.lastPathComponent)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Text(placementSummary(t)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func placementSummary(_ t: AddedAudio) -> String {
        var parts = [L("Offset %@", Self.signed(t.offset))]
        if t.isStretched { parts.append(AddedAudio.label(forStretch: t.stretch) ?? String(format: "×%.5f", t.stretch)) }
        if case .done(let r) = item.syncStates[t.id], abs(r.offset - t.offset) < 0.0005 { parts.append(L("synchronized")) }
        return parts.joined(separator: " · ")
    }

    static func signed(_ v: Double) -> String {
        (v < 0 ? "−" : "+") + TimeFormat.string(abs(v), millis: true)
    }

    // MARK: Editor

    @ViewBuilder
    private func editor(_ t: AddedAudio) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Name", text: binding(\.title), prompt: Text(Languages.displayName(t.language)))
                    .textFieldStyle(.roundedBorder)
                Toggle("Default track", isOn: Binding(
                    get: { t.isDefault },
                    set: { on in
                        for j in item.addedAudio.indices { item.addedAudio[j].isDefault = false }
                        if let i = index { item.addedAudio[i].isDefault = on }
                    }))
                    .toggleStyle(.checkbox)
                    .help("Plex and Jellyfin play the default track first")
            }

            syncBox(t)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        Text("Offset").frame(width: 70, alignment: .leading)
                        TextField("", value: binding(\.offset), format: .number.precision(.fractionLength(3)))
                            .textFieldStyle(.roundedBorder).frame(width: 80).multilineTextAlignment(.trailing)
                        Text(verbatim: "s").foregroundStyle(.secondary)
                        Spacer(minLength: 2)
                        ForEach([-0.1, -0.01, 0.01, 0.1], id: \.self) { step in
                            Button(String(format: "%+.0f", step * 1000)) { binding(\.offset).wrappedValue += step }
                                .controlSize(.mini)
                                .help(L("Move the sound %@ ms", String(format: "%+.0f", step * 1000)))
                        }
                    }
                    HStack(spacing: 4) {
                        Text("Speed").frame(width: 70, alignment: .leading)
                        Picker("", selection: binding(\.stretch)) {
                            ForEach(AddedAudio.knownStretches, id: \.ratio) { s in
                                Text(s.ratio == 1 ? L("Unchanged") : s.label).tag(s.ratio)
                            }
                            if AddedAudio.label(forStretch: t.stretch) == nil {
                                Text(String(format: "×%.5f", t.stretch)).tag(t.stretch)
                            }
                        }
                        .labelsHidden()
                        .help("Corrects audio from a source with another frame rate, e.g. Swedish TV (25 fps) against a 23.976 fps film. Changes the speed and pitch back to the original; the track is then re-encoded.")
                    }
                    Divider()
                    HStack(spacing: 6) {
                        Text("Starts").frame(width: 70, alignment: .leading)
                        Text(TimeFormat.string(max(0, t.movieRange.start))).monospacedDigit()
                        Spacer()
                        Button("Place Start Here") {
                            // Move the whole track so its first sound plays at the playhead
                            binding(\.offset).wrappedValue = model.player.currentTime - t.trimStart * t.stretch
                        }
                        .help("Move the track so that it starts at the playhead")
                        Button("Cut Before Here") {
                            binding(\.trimStart).wrappedValue = max(0, min(t.sourceTime(ofMovie: model.player.currentTime),
                                                                           (t.trimEnd ?? t.sourceDuration) - 1))
                        }
                        .help("Drop the track's sound before the playhead (e.g. a channel ident) without moving the rest")
                    }
                    HStack(spacing: 6) {
                        Text("Ends").frame(width: 70, alignment: .leading)
                        Text(TimeFormat.string(t.movieRange.end)).monospacedDigit()
                        Spacer()
                        Button("Cut After Here") {
                            binding(\.trimEnd).wrappedValue = min(t.sourceDuration,
                                                                  max(t.sourceTime(ofMovie: model.player.currentTime), t.trimStart + 1))
                        }
                        .help("Drop the track's sound after the playhead")
                        if t.trimStart > 0 || t.trimEnd != nil {
                            Button("Reset") {
                                binding(\.trimStart).wrappedValue = 0
                                binding(\.trimEnd).wrappedValue = nil
                            }
                        }
                    }
                }
                .controlSize(.small)
                .font(.callout)
            } label: {
                Text("Placement").font(.caption.weight(.semibold))
            }

            HStack {
                listenToggle(t)
                Spacer()
                Button(role: .destructive) { model.removeTrack(trackID, from: item) } label: {
                    Label("Remove Track", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
            }
            .controlSize(.small)
        }
    }

    // MARK: Automatic sync

    @ViewBuilder
    private func syncBox(_ t: AddedAudio) -> some View {
        let refs = info.audioStreams
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Compares music and sound effects with one of the film's own tracks and finds offset and speed.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Picker("Compare with", selection: Binding(
                        get: { referenceIndex ?? refs.first?.index ?? 0 },
                        set: { referenceIndex = $0 })) {
                        ForEach(refs) { s in
                            Text(verbatim: "a\(s.ordinal + 1) · \(Languages.displayName(s.normalizedLanguage)) · \(s.codec.uppercased())")
                                .tag(s.index)
                        }
                    }
                    .controlSize(.small)
                }
                switch item.syncStates[t.id] {
                case .running(let p):
                    HStack {
                        ProgressView(value: p).controlSize(.small)
                        Text(verbatim: "\(Int(p * 100)) %").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Text("Decoding both tracks… a full-length film takes about a minute.")
                        .font(.caption).foregroundStyle(.secondary)
                case .done(let r):
                    syncResult(r)
                    syncButton(t, refs: refs, title: L("Synchronize Again"))
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    syncButton(t, refs: refs, title: L("Try Again"))
                case nil:
                    syncButton(t, refs: refs, title: L("Synchronize Automatically"))
                }
            }
        } label: {
            Label("Automatic Synchronization", systemImage: "waveform.path.ecg").font(.caption.weight(.semibold))
        }
    }

    private func syncButton(_ t: AddedAudio, refs: [StreamInfo], title: String) -> some View {
        Button {
            let refIndex = referenceIndex ?? refs.first?.index
            if let ref = refs.first(where: { $0.index == refIndex }) { model.synchronize(t.id, in: item, reference: ref) }
        } label: {
            Label(title, systemImage: "wand.and.stars")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(refs.isEmpty)
    }

    @ViewBuilder
    private func syncResult(_ r: AudioSyncResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(L("Found: offset %@, speed %@", Self.signed(r.offset),
                    r.stretch == 1 ? L("unchanged") : (AddedAudio.label(forStretch: r.stretch) ?? String(format: "×%.5f", r.stretch))),
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(r.isReliable ? L("Certainty: high (%lld)", Int(r.confidence)) : L("Certainty: low (%lld) — listen and check", Int(r.confidence)))
                .foregroundStyle(r.isReliable ? Color.secondary : Color.orange)
            if !r.points.isEmpty {
                if r.isConsistent {
                    Text(L("Checked at %lld places in the film: all within %lld ms", r.points.count, Int((r.spread * 1000).rounded())))
                        .foregroundStyle(.secondary)
                } else {
                    Label(L("The offset changes by up to %@ s during the film — the dub probably comes from a different edit (e.g. a TV version). Check it by listening.",
                            String(format: "%.1f", r.spread)), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.caption)
    }

    // MARK: Listening

    @ViewBuilder
    private func listenToggle(_ t: AddedAudio) -> some View {
        let listening = model.player.previewTrack?.id == t.id
        HStack(spacing: 6) {
            Toggle(isOn: Binding(
                get: { listening },
                set: { on in model.player.setPreviewTrack(on ? t : nil, tools: model.tools) })) {
                Label("Listen in Player", systemImage: "headphones")
            }
            .toggleStyle(.button)
            .help("Play this track instead of the film's own sound, placed as set above — check the lip sync")
            if listening {
                switch model.player.audioPreview {
                case .preparing(let p):
                    ProgressView(value: p).frame(width: 60).controlSize(.mini)
                case .failed(let m):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(m)
                default:
                    EmptyView()
                }
            }
        }
    }
}

/// Language menu for a plain code (used by added tracks).
struct LanguagePickerMenu: View {
    let code: String
    let onSelect: (String) -> Void

    var body: some View {
        Menu {
            LanguageMenuItems(onSelect: onSelect)
            Divider()
            Button("Unknown (und)") { onSelect("und") }
        } label: {
            HStack(spacing: 3) {
                if code == "und" { Image(systemName: "questionmark.circle.fill").foregroundStyle(.yellow) }
                Text(Languages.displayName(code))
            }
            .font(.callout.weight(.medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// Lets the user pick which audio stream to take when the chosen file has several.
struct AudioChoiceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let choice: AppModel.AudioChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose Audio Track").font(.headline)
            Text(L("%@ has several audio tracks. Which one do you want to add?", choice.url.lastPathComponent))
                .foregroundStyle(.secondary)
            List(choice.info.audioStreams) { s in
                Button {
                    model.addTrack(stream: s, from: choice.url, info: choice.info, to: choice.item)
                    dismiss()
                } label: {
                    HStack {
                        Text(verbatim: "a\(s.ordinal + 1)").font(.callout.monospaced().weight(.semibold))
                        Text(Languages.displayName(s.normalizedLanguage)).font(.callout.weight(.medium))
                        Text(s.summary + (s.title.map { " · \($0)" } ?? "")).foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "plus.circle")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 160)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
