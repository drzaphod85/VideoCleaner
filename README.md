# VideoCleaner

A native macOS app (Swift + SwiftUI) for cleaning up MKV and MP4 files **without re-encoding**:

- ✂️ **Cut** — remove the beginning, the end, or any number of parts in the middle, right in a video preview with a zoomable timeline.
  Cuts snap to **keyframes**, so the video is only remuxed, never re-encoded. Frame-exact cutting (hardware re-encode with VideoToolbox) is available as an opt-in fallback.
- 💬 **Subtitles** — pick which subtitle tracks to keep (by language or per track), save them as `.srt` next to the video, strip `<font>` and `{\an8}` tags, and re-time them automatically to match the cut video. Forced/SDH tracks can be tagged in the file name (`Movie.sv.forced.srt`).
- 🔊 **Audio tracks** — remove tracks by language (e.g. `de, ru`) or one by one. At least one track is always kept.
- 🏷️ **Languages** — set or fix track languages (tracks tagged `und` are highlighted). A "language tags only" mode changes MKV files in place in seconds.
- 📦 **Container** — convert to MKV with one checkbox, or keep the original format.
- 🗂️ **Batch** — open single files, several files, a folder, or a folder full of subfolders (drag and drop works too). Every file gets its own cuts and track choices; the rules in the sidebar apply to all of them.
- 🧪 **Dry run** — "Show Commands" lists exactly which `ffmpeg`/`mkvmerge` commands would run.

The app started as a port of a Bash script (`clean_and_extract_subs.sh`) and keeps its safety rules: work happens in temporary files, the original is only replaced when the new file is complete and non-empty, files that are still being downloaded are skipped, and converted originals go to the Trash (not deleted).

UI languages: English, Swedish, Danish, Norwegian (Bokmål), Finnish and Icelandic.

## Requirements

- macOS 15 Sequoia or later (Apple silicon or Intel)
- [ffmpeg](https://ffmpeg.org) — required
- [MKVToolNix](https://mkvtoolnix.download) — optional, gives cleaner MKV remuxing and instant in-place language changes

```bash
brew install ffmpeg mkvtoolnix
```

The app finds the tools in Homebrew (`/opt/homebrew/bin`, `/usr/local/bin`), MacPorts, `PATH` and the MKVToolNix app bundle. Custom paths can be set in **Settings**.

## Installing

Download the `.dmg` from [Releases](https://github.com/drzaphod85/VideoCleaner/releases) and drag **VideoCleaner** to Applications.

The app is ad-hoc signed, not notarized. The first time, right-click the app and choose **Open**, or run:

```bash
xattr -dr com.apple.quarantine /Applications/VideoCleaner.app
```

## Using it

1. Drop files or folders on the window (or **File › Open Files or Folders…**, ⌘O).
2. Select a file. MP4 plays directly; MKV gets a temporary preview copy (remuxed, not re-encoded) the first time.
3. Cut with the buttons under the timeline, or with the keyboard:

| Key | Action |
| --- | --- |
| Space / K | Play / pause |
| ← / → | One frame back / forward |
| ↑ / ↓ or ⌥← / ⌥→ | Previous / next keyframe |
| ⇧← / ⇧→ | One second back / forward |
| J / L | Five seconds back / forward |
| [ | Remove everything before the playhead |
| ] | Remove everything after the playhead |
| I, then O | Mark a part in the middle and remove it |
| ⌫ | Undo the cut under the playhead |
| Esc | Cancel a pending mark-in |
| + / − | Zoom the timeline in / out around the playhead |
| Z | Zoom in until every keyframe can be seen and picked |
| 0 | Show the whole file |

   The **keyframe lane** under the thumbnails shows every keyframe as a diamond when you zoom in (pinch, ⌘-scroll, the slider or **Show Keyframes**); clicking or dragging in the lane always lands exactly on a keyframe, and the keyframe nearest the playhead is highlighted. Scroll sideways to pan, or drag the window in the overview bar. **Previous/Next Keyframe** buttons sit right next to the cut buttons.

   Drag the red handles to adjust a cut. "Skip removed" previews the result by jumping over removed parts during playback.
4. Choose tracks and languages in the **Tracks** tab of the inspector, and global options in **Processing**.
5. Press **Run** (⌘R). Progress and a detailed log are shown per file.

### How cutting works

Streams are copied, so a kept part has to start on a keyframe. With **Snap to keyframes** on (default), the start of every kept part is placed on the nearest keyframe and the preview shows exactly what you get. If a cut is placed between keyframes, the app tells you and offers **Frame-exact (re-encodes video)**. Subtitles are extracted in full and shifted in Swift using the exact positions of the kept parts, so they stay in sync.

## Building from source

```bash
git clone https://github.com/drzaphod85/VideoCleaner.git
cd VideoCleaner
Scripts/test.sh                 # unit + end-to-end tests (need ffmpeg; mkvtoolnix optional)
Scripts/build-app.sh            # → build/VideoCleaner.app (universal)
Scripts/build-app.sh --dmg      # …and build/VideoCleaner-<version>.dmg
```

Requires Xcode 16 or later (Swift 6 toolchain). The project is a plain Swift package:

- `Sources/VideoCleanerCore` — UI-independent logic: probing, keyframes, the cut plan, SRT handling, and the processing pipeline (`Processor.swift`).
- `Sources/VideoCleaner` — the SwiftUI app: file list, player, timeline, inspector.
- `Tests/VideoCleanerCoreTests` — unit tests and end-to-end tests that generate real MKV/MP4 files with ffmpeg.

## Translations

All strings in the code are English; translations live in `Resources/<language>.lproj/Localizable.strings`, with the English text as the key:

```
"Remove Before" = "Ta bort före";
"%lld of %lld kept" = "%lld av %lld behålls";
```

To add a language, copy `Resources/sv.lproj` to `Resources/<code>.lproj`, translate the values (keep `%@` and `%lld` in the same order), add the code to `CFBundleLocalizations` in `Info.plist`, and run:

```bash
Scripts/extract-strings.py      # reports missing or unused strings for every language
```

Contributions and pull requests are welcome.

## License

Copyright © 2026 Lasse L (drzaphod85)

VideoCleaner is free software: you can redistribute it and/or modify it under the terms of the **GNU General Public License v3.0** or (at your option) any later version. See [LICENSE](LICENSE).

VideoCleaner runs `ffmpeg` and MKVToolNix as separate programs; they are not bundled and keep their own licenses.
