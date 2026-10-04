# VideoCleaner

**Get your movies and TV episodes ready for Plex and Jellyfin.** VideoCleaner is a native macOS app (Swift + SwiftUI) that cleans up and trims MKV and MP4 files — mostly **without re-encoding** — so your media server plays them the way you want:

- ✂️ **Cut** — remove the beginning, the end, or any number of parts in the middle, right in a video preview with a zoomable timeline.
  Cuts on **keyframes** only remux the file (no re-encoding). You can also cut anywhere: a cut between keyframes is made frame-exact by re-encoding the video with VideoToolbox, with a clear warning and a one-click "Move Cuts to Keyframes" to avoid it.
- 💬 **Subtitles** — pick which subtitle tracks to keep (by language or per track), save them as `.srt` next to the video, strip `<font>` and `{\an8}` tags, and re-time them automatically to match the cut video. Forced/SDH tracks can be tagged in the file name (`Movie.sv.forced.srt`).
- 🔊 **Audio tracks** — remove tracks by language (e.g. `de, ru`) or one by one. At least one track is always kept.
- 🏷️ **Languages** — set or fix track languages (tracks tagged `und` are highlighted). A "language tags only" mode changes MKV files in place in seconds.
- 📦 **Container** — convert to MKV with one checkbox, or keep the original format.
- 📼 **Old formats** — AVI (DivX/Xvid), WMV/ASF, FLV, MPEG/VOB, TS/M2TS, WebM, OGM, 3GP, RealMedia and DV are converted to MKV *without re-encoding* (missing timestamps rebuilt, packed DivX B-frames unpacked) — the easy way to give a media server an old collection in one modern container.
- 🎧 **Add audio tracks** — take an audio track from another file (e.g. a Swedish dub from a TV recording or another release), synchronize it automatically against the film's own sound (offset and frame-rate speed difference, found with Accelerate FFTs), adjust by hand, and listen in the player before you process. The player's audio menu (or **A**) switches between all of the film's own and added tracks; the film's other tracks are prepared in the background in one pass, so switching is instant.
- 🗂️ **Batch** — open single files, several files, a folder, or a folder full of subfolders — drag them onto the window or the app icon in the Dock. Every file gets its own cuts and track choices; the rules in the sidebar apply to all of them.
- 🧪 **Dry run** — "Show Commands" lists exactly which `ffmpeg`/`mkvmerge` commands would run.

### Made for Plex and Jellyfin

- **Subtitles as sidecar files** — `Movie.sv.srt`, `Movie.en.forced.srt` and `Movie.en.sdh.srt` follow the naming Plex, Jellyfin, Emby and Infuse look for, so the right language and flags show up in the player. Plain SRT next to the video also avoids the subtitle "burn-in" transcoding that image and styled subtitles (PGS, ASS) often trigger on TVs and streaming boxes.
- **Correct language tags** — the server picks the default audio and subtitle track by language; tracks tagged `und` are flagged so you can fix them.
- **Only the audio you need** — dropping dubs you never use makes files smaller and keeps the audio menu tidy.
- **Clean titles** — the container title is removed so the server shows its own metadata instead of a release name.
- **MKV everywhere** — one container that holds every codec and track type the servers support.
- **Trim intros, recaps, ads and trailers** without re-encoding, so quality stays untouched and processing takes seconds.

The app started as a port of a Bash script (`clean_and_extract_subs.sh`) and keeps its safety rules: work happens in temporary files, the original is only replaced when the new file is complete and non-empty, files that are still being downloaded are skipped, and converted originals go to the Trash (not deleted).

UI languages: English, Swedish, Danish, Norwegian (Bokmål), Finnish and Icelandic.

## Requirements

- macOS 15 Sequoia or later (Apple silicon or Intel)
- Nothing else: **FFmpeg is built in.** If a newer ffmpeg is installed (Homebrew, MacPorts or `PATH`), VideoCleaner uses that one automatically; a specific ffmpeg can be chosen in **Settings**.
- [MKVToolNix](https://mkvtoolnix.download) — optional, gives cleaner MKV remuxing and instant in-place language changes:

```bash
brew install mkvtoolnix
```

## Installing

Download the `.dmg` from [Releases](https://github.com/drzaphod85/VideoCleaner/releases) and drag **VideoCleaner** to Applications.

The app is signed with a Developer ID and notarized by Apple (from version 1.2.0), so it opens like any other app. Universal (Apple silicon and Intel), macOS 15 or later.

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
5. Press **Process File** at the bottom right (⌘↩), or **Process All** for the whole list (⌘R). The bar above the button says what will happen to the file; progress and a detailed log are shown per file.

### How cutting works

When every kept part starts on a keyframe, streams are copied and the file is only remuxed — fast and lossless. When a kept part starts between keyframes, stream copy can't start there, so the video is re-encoded (hardware VideoToolbox, audio still copied) and every cut lands exactly where you put it. The editor warns about this before you process and offers **Move Cuts to Keyframes**; turning on **Snap to keyframes** makes new cuts land on keyframes automatically. Subtitles are extracted in full and shifted using the exact positions of the kept parts, so they stay in sync either way.

## Building from source

```bash
git clone https://github.com/drzaphod85/VideoCleaner.git
cd VideoCleaner
Scripts/build-ffmpeg.sh         # once: builds the bundled ffmpeg/ffprobe into Vendor/ (a few minutes)
Scripts/test.sh                 # unit + end-to-end tests (need ffmpeg with libx264 etc., e.g. from Homebrew)
Scripts/build-app.sh            # → build/VideoCleaner.app (universal)
Scripts/build-app.sh --dmg      # …and build/VideoCleaner-<version>.dmg
Scripts/build-app.sh --install  # …and install to ~/Applications
```

Requires Xcode 16 or later (Swift 6 toolchain). The project is a plain Swift package:

- `Sources/VideoCleanerCore` — UI-independent logic: probing, keyframes, the cut plan, SRT handling, and the processing pipeline (`Processor.swift`).
- `Sources/VideoCleaner` — the SwiftUI app: file list, player, timeline, inspector.
- `Tests/VideoCleanerCoreTests` — unit tests and end-to-end tests that generate real MKV/MP4 files with ffmpeg.

### Signing and notarizing (maintainers)

`Scripts/build-app.sh` signs with a **Developer ID Application** certificate when one is in the keychain (hardened runtime, secure timestamp) and falls back to ad-hoc signing otherwise. `--notarize` also sends the DMG to Apple, staples the ticket to the DMG and the app, and checks both with Gatekeeper. One-time setup:

1. **Certificate** — Xcode › Settings › Accounts › your team › Manage Certificates… › **+** › **Developer ID Application** (only the Account Holder can create it). "Apple Development" and "Mac Developer Installer" certificates can't be used. If Xcode shows the certificate as invalid, delete the expired *Apple Worldwide Developer Relations Certification Authority* (expired 7 Feb 2023) from the login keychain.
2. **App-specific password** — sign in at [appleid.apple.com](https://appleid.apple.com) › Sign-In and Security › **App-Specific Passwords** › **+**, and name it e.g. "notarytool". Your normal Apple Account password does not work here.
3. **Store the credentials** in the keychain (asks for the app-specific password):

   ```bash
   xcrun notarytool store-credentials VideoCleaner --apple-id you@example.com --team-id TEAMID
   ```

   The Team ID is the 10 characters in parentheses in the certificate name, and is also shown under Membership at developer.apple.com.
   *Alternative:* an App Store Connect API key (Users and Access › Integrations › Team Keys, role Developer):
   `xcrun notarytool store-credentials VideoCleaner --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-id>`.
4. Build: `Scripts/build-app.sh --notarize` → `build/VideoCleaner-<version>.dmg`, ready to upload as a release.

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

## Third-party software

- **[FFmpeg](https://ffmpeg.org)** is bundled (`Contents/Helpers/ffmpeg` and `ffprobe`) under the **GNU LGPL 2.1 or later**. It is built from the unmodified release tarball by `Scripts/build-ffmpeg.sh` in an LGPL configuration without external libraries (VideoToolbox and AudioToolbox are used for hardware encoding). The license, source URL, checksum and configure options ship inside the app in `Contents/Resources/ThirdParty/FFmpeg/`, and are shown under Settings › Third-Party Software. FFmpeg is a trademark of Fabrice Bellard.
- **[MKVToolNix](https://mkvtoolnix.download)** (GPL 2) is *not* bundled; VideoCleaner runs `mkvmerge`, `mkvextract` and `mkvpropedit` when they are installed.

VideoCleaner runs these tools as separate programs; it does not link to them.

## License

Copyright © 2026 Lasse L (drzaphod85)

VideoCleaner is free software: you can redistribute it and/or modify it under the terms of the **GNU General Public License v3.0** or (at your option) any later version. See [LICENSE](LICENSE).

FFmpeg and MKVToolNix keep their own licenses (see above).
