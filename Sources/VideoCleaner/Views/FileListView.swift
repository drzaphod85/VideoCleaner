// VideoCleaner — Copyright (C) 2026 Lasse L
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import VideoCleanerCore

struct FileListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            ForEach(model.items) { item in
                FileRow(item: item)
                    .tag(item.id)
                    .contextMenu { menu(for: item) }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand { model.remove(model.selection) }
        .overlay {
            if model.items.isEmpty {
                Text("No files").foregroundStyle(.tertiary)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    @ViewBuilder
    private func menu(for item: VideoItem) -> some View {
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        Button("Run Only This File") { model.run([item]) }
            .disabled(model.isProcessing || item.info == nil)
        Button("Show Commands") { model.showCommands(for: item) }
            .disabled(item.info == nil)
        Divider()
        Button("Reset Cuts and Track Choices") { item.resetEdits() }
            .disabled(!item.hasEdits)
        if item.status != .pending && item.status != .running {
            Button("Mark as Not Processed") { item.status = .pending; item.progress = 0 }
        }
        Divider()
        Button("Remove from List", role: .destructive) {
            model.remove(model.selection.contains(item.id) ? model.selection : [item.id])
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Button { model.showOpenPanel() } label: { Image(systemName: "plus") }
                    .help("Add files or folders")
                Button { model.remove(model.selection) } label: { Image(systemName: "minus") }
                    .disabled(model.selection.isEmpty)
                    .help("Remove the selected files from the list (the files are not deleted)")
                Menu {
                    Button("Remove Finished from List") { model.clearFinished() }
                    Button("Clear List") { model.remove(Set(model.items.map(\.id))) }
                        .disabled(model.isProcessing)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                Spacer()
                let total = model.items.reduce(Int64(0)) { $0 + ($1.info?.size ?? 0) }
                if total > 0 {
                    Text(L("%lld files · %@", model.items.count, TimeFormat.byteCount(total)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }
}

struct FileRow: View {
    @Environment(AppModel.self) private var model
    let item: VideoItem

    var body: some View {
        HStack(spacing: 10) {
            poster
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let info = item.info {
                    Text(details(info))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    badges(info)
                } else if let error = item.loadError {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                } else {
                    Text("Reading…").font(.caption).foregroundStyle(.tertiary)
                }
                if item.status == .running {
                    ProgressView(value: item.progress)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
            statusIcon
        }
        .padding(.vertical, 4)
        .task(id: item.url) {
            guard item.poster == nil else { return }
            while item.info == nil && item.loadError == nil {
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
            }
            guard let info = item.info else { return }
            item.poster = await PosterService.shared.poster(for: item.url, duration: info.duration, tools: model.tools)
        }
    }

    private var poster: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.quaternary)
            if let img = item.poster {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "film").foregroundStyle(.tertiary)
            }
        }
        .frame(width: 64, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
    }

    private func details(_ info: MediaInfo) -> String {
        var parts = [item.url.pathExtension.uppercased(), TimeFormat.string(info.duration, millis: false)]
        if let v = info.primaryVideo, let h = v.height {
            parts.append(h >= 2000 ? "4K" : "\(h)p")
        }
        parts.append(TimeFormat.byteCount(info.size))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func badges(_ info: MediaInfo) -> some View {
        let rules = model.rules
        let removedAudio = info.audioStreams.filter { !item.keepsAudio($0, rules: rules) }.count
        let subs = info.subtitleStreams.filter { item.selectsSubtitle($0, rules: rules) && $0.isTextSubtitle }.count
        HStack(spacing: 4) {
            if !item.removals.isEmpty {
                Badge(text: "\(item.removals.count)", icon: "scissors", color: .orange)
            }
            if removedAudio > 0 {
                Badge(text: "−\(removedAudio)", icon: "speaker.wave.2", color: .red)
            }
            if !info.subtitleStreams.isEmpty {
                Badge(text: "\(subs)/\(info.subtitleStreams.count)", icon: "captions.bubble", color: .blue)
            }
            if item.tracksMissingLanguage > 0 {
                Badge(text: "und", icon: "questionmark", color: .yellow)
                    .help(L("%lld tracks have no language", item.tracksMissingLanguage))
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .pending:
            if item.hasEdits {
                Image(systemName: "pencil.circle.fill").foregroundStyle(.orange).help("Edited")
            }
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Done")
        case .failed(let msg):
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).help(msg)
        case .skipped(let msg):
            Image(systemName: "forward.fill").foregroundStyle(.secondary).help(L("Skipped: %@", msg))
        case .cancelled:
            Image(systemName: "stop.circle").foregroundStyle(.secondary).help("Cancelled")
        }
    }
}

struct Badge: View {
    let text: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 8, weight: .bold))
            Text(text).font(.system(size: 10, weight: .semibold)).monospacedDigit()
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .foregroundStyle(color)
        .background(color.opacity(0.15), in: Capsule())
    }
}
