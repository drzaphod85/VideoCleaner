// VideoCleaner — Copyright (C) 2026 Lasse L
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import VideoCleanerCore

struct InspectorView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: Tab = .tracks

    enum Tab: String, CaseIterable { case tracks = "Tracks", options = "Processing" }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            switch tab {
            case .tracks:
                if let item = model.selectedItem, let info = item.info {
                    TracksPanel(item: item, info: info)
                } else {
                    ContentUnavailableView("No file selected", systemImage: "list.bullet.below.rectangle",
                                           description: Text("Select a file to see and choose audio and subtitle tracks."))
                }
            case .options:
                OptionsPanel()
            }
        }
    }
}

// MARK: - Tracks

struct TracksPanel: View {
    @Environment(AppModel.self) private var model
    let item: VideoItem
    let info: MediaInfo

    var body: some View {
        let rules = model.rules
        Form {
            Section("File") {
                LabeledContent("Format", value: "\(item.url.pathExtension.uppercased()) · \(TimeFormat.byteCount(info.size))")
                LabeledContent("Duration", value: TimeFormat.string(info.duration))
                if !item.removals.isEmpty {
                    LabeledContent("After cuts", value: TimeFormat.string(item.cutPlan().outputDuration))
                }
                LabeledContent("Folder") {
                    Button(item.url.deletingLastPathComponent().lastPathComponent as String) {
                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                    }
                    .buttonStyle(.link)
                    .lineLimit(1)
                }
            }

            if !info.videoStreams.isEmpty {
                Section("Video") {
                    ForEach(info.videoStreams) { v in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(v.summary).font(.callout)
                            if let t = v.title, !t.isEmpty { Text(t).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    if info.videoStreams.count > 1 {
                        Text("Only the first video track is kept.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                if info.audioStreams.isEmpty {
                    Text("No audio tracks").foregroundStyle(.secondary)
                }
                ForEach(info.audioStreams) { a in
                    TrackRow(item: item, stream: a, prefix: "a",
                             isOn: Binding(get: { item.keepsAudio(a, rules: rules) },
                                           set: { item.audioOverrides[a.index] = $0 }),
                             help: L("Keep this audio track"))
                }
            } header: {
                HStack {
                    Text("Audio")
                    Spacer()
                    let kept = info.audioStreams.filter { item.keepsAudio($0, rules: rules) }.count
                    Text(L("%lld of %lld kept", kept, info.audioStreams.count)).foregroundStyle(.secondary)
                }
            } footer: {
                if item.removesAllAudio(rules: rules) {
                    Label("All audio tracks are deselected — then all are kept (safety).", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.caption)
                }
            }

            Section {
                if info.subtitleStreams.isEmpty {
                    Text("No subtitles").foregroundStyle(.secondary)
                }
                ForEach(info.subtitleStreams) { s in
                    TrackRow(item: item, stream: s, prefix: "s",
                             isOn: Binding(get: { item.selectsSubtitle(s, rules: rules) },
                                           set: { item.subtitleOverrides[s.index] = $0 }),
                             help: L("Select this subtitle"))
                }
            } header: {
                HStack {
                    Text("Subtitles")
                    Spacer()
                    let n = info.subtitleStreams.filter { item.selectsSubtitle($0, rules: rules) }.count
                    Text(L("%lld of %lld selected", n, info.subtitleStreams.count)).foregroundStyle(.secondary)
                }
            } footer: {
                Text(subtitleFooter).font(.caption).foregroundStyle(.secondary)
            }

            if !item.audioOverrides.isEmpty || !item.subtitleOverrides.isEmpty || !item.languageOverrides.isEmpty {
                Section {
                    Button("Reset Tracks and Languages to the Rules") {
                        item.audioOverrides = [:]
                        item.subtitleOverrides = [:]
                        item.languageOverrides = [:]
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var subtitleFooter: String {
        let o = model.options
        if o.languageOnly { return L("Only language tags are changed — subtitles stay in the file.") }
        var parts: [String] = []
        if o.extractSubtitles { parts.append(L("Selected text subtitles are saved as .srt next to the video.")) }
        parts.append(o.removeSubtitlesFromVideo ? L("All subtitles are removed from the video file.")
                                                : L("Selected subtitles are kept in the video file, the rest are removed."))
        return parts.joined(separator: " ")
    }
}

struct TrackRow: View {
    let item: VideoItem
    let stream: StreamInfo
    let prefix: String
    @Binding var isOn: Bool
    let help: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(help)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: "\(prefix)\(stream.ordinal + 1)")
                        .font(.caption.monospaced().weight(.semibold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                    LanguageMenu(item: item, stream: stream)
                    if stream.isDefault { Badge(text: L("Default"), icon: "star.fill", color: .secondary) }
                    if stream.isForced { Badge(text: L("Forced"), icon: "exclamationmark", color: .purple) }
                    if stream.isHearingImpaired { Badge(text: L("SDH"), icon: "ear", color: .teal) }
                }
                Text(stream.summary + (stream.title.map { " · \($0)" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .opacity(isOn ? 1 : 0.45)
            .strikethrough(!isOn && prefix == "a")
        }
    }
}

struct LanguageMenu: View {
    let item: VideoItem
    let stream: StreamInfo

    var body: some View {
        let current = item.language(of: stream)
        let overridden = item.languageOverrides[stream.index] != nil
        Menu {
            ForEach(Languages.all.prefix(Languages.commonCount)) { lang in
                Button(Languages.displayName(lang.code3)) { item.setLanguage(lang.code3, for: stream) }
            }
            Menu("More Languages") {
                ForEach(Languages.all.dropFirst(Languages.commonCount).sorted { Languages.displayName($0.code3) < Languages.displayName($1.code3) }) { lang in
                    Button(Languages.displayName(lang.code3)) { item.setLanguage(lang.code3, for: stream) }
                }
            }
            Divider()
            Button("Unknown (und)") { item.setLanguage("und", for: stream) }
            if overridden {
                Button(L("Reset (%@)", Languages.displayName(stream.normalizedLanguage))) {
                    item.setLanguage(nil, for: stream)
                }
            }
        } label: {
            HStack(spacing: 3) {
                if current == "und" { Image(systemName: "questionmark.circle.fill").foregroundStyle(.yellow) }
                Text(Languages.displayName(current))
                if overridden { Image(systemName: "pencil").font(.caption2) }
            }
            .font(.callout.weight(.medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(current == "und" ? L("The track has no language — choose one") : L("Change language (%@)", current))
    }
}

// MARK: - Options

struct OptionsPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Change language tags only", isOn: $model.options.languageOnly)
                Text(model.options.languageOnly
                     ? L("Nothing else is touched — no cutting, extraction or cleaning. MKV files are changed in place in seconds.")
                     : L("Full processing: subtitles, audio tracks, cutting and languages."))
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Label("Mode", systemImage: "slider.horizontal.3") }

            Section {
                Toggle("Convert to MKV", isOn: $model.options.convertToMKV)
                    .help("Off: the file keeps its original format (MP4 stays MP4)")
                Toggle("Move the original to the Trash after converting", isOn: $model.options.trashOriginalAfterConversion)
                    .disabled(!model.options.convertToMKV)
                Text(model.options.convertToMKV
                     ? L("MP4/MOV is remuxed to .mkv without re-encoding. MKV is rewritten in place.")
                     : L("Files keep their format and are rewritten in place."))
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Label("Format", systemImage: "shippingbox") }
            .disabled(model.options.languageOnly)

            Section {
                Toggle("Save selected subtitles as .srt", isOn: $model.options.extractSubtitles)
                Toggle("Remove all subtitles from the video file", isOn: $model.options.removeSubtitlesFromVideo)
                    .help("Off: the selected subtitles stay embedded")
                Toggle("Remove font and position tags", isOn: $model.options.cleanSubtitleTags)
                    .disabled(!model.options.extractSubtitles)
                Toggle("Mark forced/SDH in the file name", isOn: $model.options.tagForcedAndSDH)
                    .disabled(!model.options.extractSubtitles)
                    .help("E.g. Movie.sv.forced.srt — understood by Plex, Jellyfin, Infuse and others")
                LabeledContent("Select languages") {
                    TextField("all", text: $model.subtitleLanguagesText, prompt: Text("all"))
                        .multilineTextAlignment(.trailing)
                }
                Text(languageHint(model.rules.subtitleLanguages, empty: L("Empty = all subtitles are selected.")))
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Label("Subtitles", systemImage: "captions.bubble") }
            .disabled(model.options.languageOnly)

            Section {
                LabeledContent("Remove languages") {
                    TextField("none", text: $model.removeAudioLanguagesText, prompt: Text("e.g. de, ru"))
                        .multilineTextAlignment(.trailing)
                }
                Text(languageHint(model.rules.removeAudioLanguages, empty: L("Empty = all audio tracks are kept."))
                     + " " + L("At least one audio track is always kept."))
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Label("Audio Tracks", systemImage: "speaker.wave.2") }
            .disabled(model.options.languageOnly)

            Section {
                Picker("Save to", selection: Binding(
                    get: { model.options.outputDirectory == nil ? 0 : 1 },
                    set: { v in
                        if v == 0 { model.options.outputDirectory = nil } else { model.chooseOutputDirectory() }
                    })) {
                    Text("Same folder as the source").tag(0)
                    Text(model.options.outputDirectory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? L("Choose Folder…")).tag(1)
                }
                if let dir = model.options.outputDirectory {
                    HStack {
                        Text(dir).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                        Spacer()
                        Button("Change…") { model.chooseOutputDirectory() }.controlSize(.small)
                    }
                }
            } header: { Label("Output", systemImage: "folder") }
            .disabled(model.options.languageOnly)

            Section {
                ToolStatus(name: "ffmpeg / ffprobe", ok: model.tools.hasFFmpeg, path: model.tools.ffmpeg?.path,
                           hint: "brew install ffmpeg")
                ToolStatus(name: "mkvtoolnix", ok: model.tools.hasMKVToolNix, path: model.tools.mkvmerge?.path,
                           hint: L("brew install mkvtoolnix (optional)"))
                Toggle("Use mkvtoolnix for MKV files", isOn: $model.options.useMKVToolNix)
                    .disabled(!model.tools.hasMKVToolNix)
                    .help("mkvmerge/mkvextract/mkvpropedit give cleaner Matroska remuxing and fast in-place language changes")
            } header: { Label("Tools", systemImage: "wrench.and.screwdriver") }
        }
        .formStyle(.grouped)
    }

    private func languageHint(_ set: Set<String>, empty: String) -> String {
        guard !set.isEmpty else { return empty }
        return set.map { Languages.displayName($0) }.sorted().joined(separator: ", ") + "."
    }
}

struct ToolStatus: View {
    let name: String
    let ok: Bool
    let path: String?
    let hint: String

    var body: some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(ok ? (path ?? "") : hint).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var cacheSize: Int64 = 0

    var body: some View {
        Form {
            Section("Tools (leave empty to search automatically)") {
                ForEach(["ffmpeg", "ffprobe", "mkvmerge", "mkvextract", "mkvpropedit"], id: \.self) { tool in
                    LabeledContent(tool) {
                        TextField("automatic", text: Binding(
                            get: { model.toolOverrides[tool] ?? "" },
                            set: { model.toolOverrides[tool] = $0.isEmpty ? nil : $0 }))
                    }
                }
                HStack {
                    Spacer()
                    Button("Search Again") { model.refreshTools() }
                }
            }
            Section("Preview") {
                LabeledContent("Cache", value: TimeFormat.byteCount(cacheSize))
                Text("MKV files are copied (without re-encoding) to a temporary MP4 so they can be shown. The cache is emptied when the app quits.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Empty Cache Now") {
                        model.player.unload()
                        PreviewService.shared.clearCache()
                        cacheSize = PreviewService.shared.cacheSize()
                        model.player.needsReload = true
                    }
                }
            }
            Section("About") {
                LabeledContent("License", value: L("GNU GPL v3.0 or later"))
                Link(destination: URL(string: "https://github.com/drzaphod85/VideoCleaner")!) { Text(verbatim: "github.com/drzaphod85/VideoCleaner") }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear { cacheSize = PreviewService.shared.cacheSize() }
    }
}
