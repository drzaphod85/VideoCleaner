// VideoCleaner — Copyright (C) 2026 Lasse L
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import VideoCleanerCore

@Observable @MainActor
final class AppModel {
    var items: [VideoItem] = []
    var selection: Set<VideoItem.ID> = []

    var options: ProcessingOptions { didSet { Prefs.save(options, key: Prefs.options) } }
    var subtitleLanguagesText: String { didSet { Prefs.defaults.set(subtitleLanguagesText, forKey: Prefs.subtitleLangs) } }
    var removeAudioLanguagesText: String { didSet { Prefs.defaults.set(removeAudioLanguagesText, forKey: Prefs.removeAudioLangs) } }
    var snapToKeyframes: Bool { didSet { Prefs.defaults.set(snapToKeyframes, forKey: Prefs.snap) } }
    var skipRemovedWhilePlaying: Bool { didSet { Prefs.defaults.set(skipRemovedWhilePlaying, forKey: Prefs.skipRemoved) } }
    var toolOverrides: [String: String] { didSet { Prefs.defaults.set(toolOverrides, forKey: Prefs.toolOverrides); refreshTools() } }

    private(set) var tools: ToolPaths
    let player = PlayerController()

    var isProcessing = false
    var processingItemID: VideoItem.ID?
    private var runTask: Task<Void, Never>?
    private var keyframeTasks: [VideoItem.ID: Task<Void, Never>] = [:]

    var showLog = false
    var commandPreview: CommandPreview?
    var audioChoice: AudioChoice?

    struct CommandPreview: Identifiable {
        let id = UUID()
        let title: String
        let text: String
    }

    init() {
        let d = Prefs.defaults
        options = Prefs.load(ProcessingOptions.self, key: Prefs.options) ?? ProcessingOptions()
        subtitleLanguagesText = d.string(forKey: Prefs.subtitleLangs) ?? ""
        removeAudioLanguagesText = d.string(forKey: Prefs.removeAudioLangs) ?? ""
        snapToKeyframes = d.object(forKey: Prefs.snap) as? Bool ?? false
        skipRemovedWhilePlaying = d.object(forKey: Prefs.skipRemoved) as? Bool ?? false
        let overrides = d.dictionary(forKey: Prefs.toolOverrides) as? [String: String] ?? [:]
        toolOverrides = overrides
        tools = ToolPaths.locate(overrides: overrides)
    }

    func refreshTools() { tools = ToolPaths.locate(overrides: toolOverrides) }

    var rules: TrackRules {
        TrackRules(subtitleLanguages: Languages.parseList(subtitleLanguagesText),
                   removeAudioLanguages: Languages.parseList(removeAudioLanguagesText))
    }

    var selectedItems: [VideoItem] { items.filter { selection.contains($0.id) } }
    var selectedItem: VideoItem? { selection.count == 1 ? selectedItems.first : nil }

    // MARK: Adding files

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = L("Open Video Files or Folders")
        panel.prompt = L("Open")
        panel.message = L("Choose files, a folder or a folder with subfolders — every .mkv/.mp4/.m4v/.mov is added.")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        var types: [UTType] = [.mpeg4Movie, .quickTimeMovie, .movie]
        if let mkv = UTType(filenameExtension: "mkv") { types.append(mkv) }
        if let m4v = UTType(filenameExtension: "m4v") { types.append(m4v) }
        panel.allowedContentTypes = types
        if panel.runModal() == .OK { add(urls: panel.urls) }
    }

    func add(urls: [URL]) {
        Task {
            let files = await Task.detached { FileScanner.videoFiles(in: urls) }.value
            let existing = Set(items.map { $0.url.standardizedFileURL.path })
            let newItems = files.filter { !existing.contains($0.standardizedFileURL.path) }.map(VideoItem.init)
            guard !newItems.isEmpty else { return }
            items.append(contentsOf: newItems)
            if selection.isEmpty, let first = newItems.first { selection = [first.id] }
            await probe(newItems)
        }
    }

    private func probe(_ list: [VideoItem]) async {
        let tools = self.tools
        let jobs = list.map { ($0.id, $0.url) }
        let byID = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        await withTaskGroup(of: (UUID, Result<MediaInfo, Error>).self) { group in
            var iterator = jobs.makeIterator()
            func addNext() -> Bool {
                guard let (id, url) = iterator.next() else { return false }
                group.addTask {
                    do { return (id, .success(try await Probe.mediaInfo(url, tools: tools))) } catch { return (id, .failure(error)) }
                }
                return true
            }
            for _ in 0..<6 where addNext() {}
            while let (id, result) = await group.next() {
                if let item = byID[id] {
                    switch result {
                    case .success(let info): item.info = info; item.loadError = nil
                    case .failure(let e): item.loadError = e.localizedDescription
                    }
                }
                _ = addNext()
            }
        }
    }

    func reload(_ item: VideoItem) async {
        item.info = nil
        item.keyframes = []
        item.keyframesState = .idle
        item.poster = nil
        await probe([item])
    }

    func loadKeyframes(for item: VideoItem) {
        guard item.keyframesState == .idle, let info = item.info else { return }
        item.keyframesState = .loading
        let tools = self.tools
        let url = item.url
        keyframeTasks[item.id] = Task {
            do {
                let kfs = try await Probe.keyframes(url, info: info, tools: tools)
                guard item.url == url else { return }
                item.keyframes = kfs
                item.keyframesState = .loaded
            } catch {
                item.keyframesState = .failed
            }
        }
    }

    func remove(_ ids: Set<VideoItem.ID>) {
        let removable = ids.filter { $0 != processingItemID }
        for id in removable { keyframeTasks[id]?.cancel(); keyframeTasks[id] = nil }
        items.removeAll { removable.contains($0.id) }
        selection.subtract(removable)
    }

    func clearFinished() {
        remove(Set(items.filter { if case .done = $0.status { return true }; return false }.map(\.id)))
    }

    // MARK: Processing

    func runAll() {
        run(items.filter { item in
            switch item.status {
            case .done, .running: return false
            default: return item.info != nil
            }
        })
    }

    func runSelected() { run(selectedItems.filter { $0.info != nil }) }

    func run(_ list: [VideoItem]) {
        guard !isProcessing, !list.isEmpty else { return }
        player.pause()
        isProcessing = true
        runTask = Task {
            for item in list {
                if Task.isCancelled { break }
                await process(item)
            }
            isProcessing = false
            processingItemID = nil
            runTask = nil
            if items.count > 1 { NSApp.requestUserAttention(.informationalRequest) }
        }
    }

    func cancel() { runTask?.cancel() }

    var queueSummary: (done: Int, failed: Int, total: Int) {
        var done = 0, failed = 0
        for i in items {
            switch i.status {
            case .done: done += 1
            case .failed: failed += 1
            default: break
            }
        }
        return (done, failed, items.count)
    }

    private func process(_ item: VideoItem) async {
        guard let job = item.makeJob(options: options, rules: rules) else { return }
        processingItemID = item.id
        item.status = .running
        item.progress = 0
        item.log = [LogEntry(.step, L("▶ Processing: %@", item.url.path))]
        let wasShowing = player.itemID == item.id
        if wasShowing { player.unload() }

        let processor = Processor(tools: tools)
        do {
            let result = try await processor.process(job, log: { entry in
                DispatchQueue.main.async { MainActor.assumeIsolated { item.log.append(entry) } }
            }, progress: { value in
                DispatchQueue.main.async { MainActor.assumeIsolated { item.progress = value } }
            })
            await Task.yield()
            item.lastResult = result
            if let reason = result.skippedReason {
                item.status = .skipped(reason)
            } else {
                PreviewService.shared.invalidate(item.url)
                item.url = result.output
                item.resetEdits()
                item.status = .done
                item.progress = 1
                await reload(item)
            }
        } catch is CancellationError {
            item.status = .cancelled
            item.log.append(LogEntry(.warning, L("⛔ Cancelled — temporary files removed")))
        } catch {
            item.status = .failed(error.localizedDescription)
            item.log.append(LogEntry(.error, "❌ \(error.localizedDescription)"))
        }
        if wasShowing || selectedItem?.id == item.id { player.needsReload = true }
    }

    func showCommands(for item: VideoItem) {
        guard let job = item.makeJob(options: options, rules: rules) else { return }
        let processor = Processor(tools: tools)
        let box = EntryBox()
        Task {
            do {
                _ = try await processor.process(job, dryRun: true, log: { box.add($0) }, progress: { _ in })
            } catch {
                box.add(LogEntry(.error, error.localizedDescription))
            }
            let text = box.entries.map { e -> String in
                switch e.kind {
                case .command: return "$ " + e.text
                case .warning: return "⚠️ " + e.text
                case .error: return "❌ " + e.text
                default: return "# " + e.text
                }
            }.joined(separator: "\n\n")
            commandPreview = CommandPreview(title: item.name, text: text)
        }
    }

    // MARK: Added audio tracks

    /// Asks for an audio file (or a video file to take the audio from) and adds its track to the item.
    /// Files with several audio tracks get a chooser (see `audioChoice`).
    func addAudioTrack(to item: VideoItem) {
        let panel = NSOpenPanel()
        panel.title = L("Add Audio Track")
        panel.prompt = L("Add")
        panel.message = L("Choose an audio file, or a video file to take an audio track from.")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        var types: [UTType] = [.audio, .movie]
        for ext in ["mka", "mkv", "ac3", "eac3", "ec3", "dts", "thd", "flac", "opus", "ts", "m2ts"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        panel.allowedContentTypes = types
        panel.directoryURL = item.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let tools = self.tools
        Task {
            do {
                let info = try await Probe.mediaInfo(url, tools: tools)
                let streams = info.audioStreams
                if streams.isEmpty {
                    showAlert(L("No audio track found"), L("%@ has no audio track.", url.lastPathComponent))
                } else if streams.count == 1 {
                    addTrack(stream: streams[0], from: url, info: info, to: item)
                } else {
                    audioChoice = AudioChoice(item: item, url: url, info: info)
                }
            } catch {
                showAlert(L("Could not read the file"), error.localizedDescription)
            }
        }
    }

    struct AudioChoice: Identifiable {
        let id = UUID()
        let item: VideoItem
        let url: URL
        let info: MediaInfo
    }

    func addTrack(stream: StreamInfo, from url: URL, info: MediaInfo, to item: VideoItem) {
        var track = AddedAudio(source: url, stream: stream, sourceDuration: info.duration)
        if track.language == "und", let first = rules.subtitleLanguages.sorted().first { track.language = first }
        track.title = track.language == "und" ? "" : Languages.displayName(track.language)
        item.addedAudio.append(track)
        expandedAudioTrack = track.id
    }

    /// The added track whose editor is open in the inspector.
    var expandedAudioTrack: AddedAudio.ID?

    func removeTrack(_ id: AddedAudio.ID, from item: VideoItem) {
        item.addedAudio.removeAll { $0.id == id }
        item.syncStates[id] = nil
        if player.previewTrack?.id == id { player.setPreviewTrack(nil, tools: tools) }
    }

    /// Finds offset and speed against one of the file's own audio tracks and applies them.
    func synchronize(_ trackID: AddedAudio.ID, in item: VideoItem, reference: StreamInfo) {
        guard let info = item.info, let track = item.addedAudio.first(where: { $0.id == trackID }) else { return }
        item.syncStates[trackID] = .running(0)
        let tools = self.tools
        let url = item.url
        Task {
            do {
                let result = try await AudioSync.synchronize(
                    reference: url, referenceStream: reference.index, referenceDuration: info.duration,
                    candidate: track.source, candidateStream: track.streamIndex, candidateDuration: track.sourceDuration,
                    tools: tools) { p in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                if case .running = item.syncStates[trackID] { item.syncStates[trackID] = .running(p) }
                            }
                        }
                    }
                guard let i = item.addedAudio.firstIndex(where: { $0.id == trackID }) else { return }
                item.addedAudio[i].offset = result.offset
                item.addedAudio[i].stretch = result.stretch
                item.syncStates[trackID] = .done(result)
            } catch is CancellationError {
                item.syncStates[trackID] = nil
            } catch {
                item.syncStates[trackID] = .failed(error.localizedDescription)
            }
        }
    }

    func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L("Choose")
        panel.message = L("Choose the folder where cleaned files and subtitles are saved")
        if panel.runModal() == .OK, let url = panel.url { options.outputDirectory = url.path }
    }
}

private final class EntryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [LogEntry] = []
    func add(_ e: LogEntry) { lock.lock(); list.append(e); lock.unlock() }
    var entries: [LogEntry] { lock.lock(); defer { lock.unlock() }; return list }
}

enum Prefs {
    static let defaults = UserDefaults.standard
    static let options = "processingOptions"
    static let subtitleLangs = "subtitleLanguages"
    static let removeAudioLangs = "removeAudioLanguages"
    static let snap = "snapToKeyframesV2"  // default changed to off in 1.1
    static let skipRemoved = "skipRemovedWhilePlaying"
    static let toolOverrides = "toolOverrides"

    static func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
