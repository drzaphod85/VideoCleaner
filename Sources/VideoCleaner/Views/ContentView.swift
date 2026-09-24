// VideoCleaner — Copyright (C) 2026 Lasse L
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import VideoCleanerCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showInspector = true
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            FileListView()
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 440)
        } detail: {
            ZStack {
                if let item = model.selectedItem {
                    EditorView(item: item)
                        .id(item.id)
                } else if model.items.isEmpty {
                    EmptyStateView()
                } else {
                    ContentUnavailableView(model.selection.isEmpty ? L("No file selected") : L("%lld files selected", model.selection.count),
                                           systemImage: "film.stack",
                                           description: Text(model.selection.isEmpty
                                                             ? L("Select a file in the list to cut it and choose tracks.")
                                                             : L("Tracks and cuts are chosen per file. The settings on the right apply to all files.")))
                }
                if dropTargeted { DropOverlay() }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if !model.tools.hasFFmpeg { ToolsBanner() }
            }
        }
        .inspector(isPresented: $showInspector) {
            InspectorView()
                .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .navigationTitle(model.selectedItem?.name ?? "VideoCleaner")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls: urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .sheet(item: $model.commandPreview) { CommandPreviewSheet(preview: $0) }
    }

    private var subtitle: String {
        let s = model.queueSummary
        if s.total == 0 { return "" }
        if model.isProcessing { return L("Processing… %lld of %lld done", s.done, s.total) }
        var parts = [s.total == 1 ? L("1 file") : L("%lld files", s.total)]
        if s.done > 0 { parts.append(L("%lld done", s.done)) }
        if s.failed > 0 { parts.append(L("%lld failed", s.failed)) }
        return parts.joined(separator: " · ")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { model.showOpenPanel() } label: {
                Label("Add", systemImage: "plus")
            }
            .help("Open files, a folder or a folder with subfolders (⌘O)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.isProcessing {
                Button(role: .cancel) { model.cancel() } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
                .help("Cancel processing (⌘.)")
            } else {
                Menu {
                    Button(L("Run All (%lld)", model.items.filter { $0.status != .done }.count)) { model.runAll() }
                    Button(L("Run Selected (%lld)", model.selection.count)) { model.runSelected() }
                        .disabled(model.selection.isEmpty)
                } label: {
                    Label("Run", systemImage: "play.fill")
                } primaryAction: {
                    model.runAll()
                }
                .disabled(model.items.isEmpty || !model.tools.hasFFmpeg)
                .help("Process every file that is not done yet (⌘R)")
            }
            Button {
                if let item = model.selectedItem { model.showCommands(for: item) }
            } label: {
                Label("Show Commands", systemImage: "terminal")
            }
            .disabled(model.selectedItem?.info == nil)
            .help("Dry run: show exactly what would be done to the selected file")
            Toggle(isOn: Bindable(model).showLog) {
                Label("Log", systemImage: "list.bullet.rectangle")
            }
            .help("Show or hide the log for the selected file")
            Button { showInspector.toggle() } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help("Show or hide tracks and settings")
        }
    }
}

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
                    .foregroundStyle(.tertiary)
                VStack(spacing: 14) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 56, weight: .light))
                        .foregroundStyle(.tint)
                    Text("Drop video files or folders here")
                        .font(.title2.weight(.semibold))
                    Text("MKV, MP4, M4V and MOV — single files, a folder or a folder with many subfolders.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                    Button { model.showOpenPanel() } label: {
                        Label("Open Files or Folders…", systemImage: "folder")
                            .padding(.horizontal, 6)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 6)
                }
                .padding(40)
            }
            .frame(maxWidth: 560, maxHeight: 340)

            HStack(spacing: 28) {
                Feature(icon: "scissors", title: L("Cut without re-encoding"), text: L("Cuts are placed on keyframes"))
                Feature(icon: "captions.bubble", title: L("Subtitles to .srt"), text: L("Cleaned and re-timed"))
                Feature(icon: "speaker.wave.2", title: L("Audio tracks & languages"), text: L("Remove tracks, set languages"))
            }
            .frame(maxWidth: 640)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private struct Feature: View {
        let icon: String, title: String, text: String
        var body: some View {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title2).foregroundStyle(.tint)
                Text(title).font(.callout.weight(.medium))
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct DropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.accentColor.opacity(0.12))
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [12, 8]))
            .overlay {
                Label("Drop to add", systemImage: "plus.circle.fill")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            .padding(14)
            .allowsHitTesting(false)
    }
}

struct ToolsBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("ffmpeg was not found").font(.headline)
                Text("Install with Homebrew: brew install ffmpeg mkvtoolnix — or enter the path in Settings.")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            Button("Search Again") { model.refreshTools() }
            SettingsLink { Text("Settings…") }
        }
        .padding(12)
        .background(.yellow.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct CommandPreviewSheet: View {
    let preview: AppModel.CommandPreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "terminal").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("Dry Run").font(.headline)
                    Text(preview.title).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            ScrollView {
                Text(preview.text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Text("No files are changed. The commands can be copied and run in Terminal.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(preview.text, forType: .string)
                }
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 460)
    }
}
