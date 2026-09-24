// VideoCleaner — Copyright (C) 2026 Lasse L
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import VideoCleanerCore

@main
struct VideoCleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("VideoCleaner", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1080, minHeight: 680)
                .onAppear { delegate.attach(model) }
        }
        .defaultSize(width: 1440, height: 900)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var pending: [URL] = []

    @MainActor func attach(_ model: AppModel) {
        self.model = model
        if !pending.isEmpty { model.add(urls: pending); pending = [] }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        PreviewService.shared.clearCache()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            if let model { model.add(urls: urls) } else { pending += urls }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let busy = MainActor.assumeIsolated { model?.isProcessing ?? false }
        guard busy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L("Processing in progress")
        alert.informativeText = L("Quitting now cancels the current file. The original is left untouched.")
        alert.addButton(withTitle: L("Quit Anyway"))
        alert.addButton(withTitle: L("Keep Processing"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.cancel() }
        PreviewService.shared.clearCache()
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Files or Folders…") { model.showOpenPanel() }
                .keyboardShortcut("o")
        }
        CommandMenu("Process") {
            Button("Run All") { model.runAll() }
                .keyboardShortcut("r")
                .disabled(model.isProcessing || model.items.isEmpty)
            Button("Run Selected") { model.runSelected() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.isProcessing || model.selection.isEmpty)
            Button("Cancel") { model.cancel() }
                .keyboardShortcut(".")
                .disabled(!model.isProcessing)
            Divider()
            Button("Show Commands for Selected File") {
                if let item = model.selectedItem { model.showCommands(for: item) }
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(model.selectedItem?.info == nil)
            Button(model.showLog ? L("Hide Log") : L("Show Log")) { model.showLog.toggle() }
                .keyboardShortcut("l", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .help) {
            Link("VideoCleaner on GitHub", destination: URL(string: "https://github.com/drzaphod85/VideoCleaner")!)
        }
    }
}
