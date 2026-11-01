# Sonic for iOS — v1.3

Sonic is a native SwiftUI music client with a Spotify / Apple Music-inspired interface, personal music servers, public catalogs, Apple Music and Spotify account integrations, offline downloads, local audio imports, background playback, and a small two-deck mashup studio.

## What's new in 1.1

- **Apple Music / MusicKit:** authorize an Apple Music account, search the Apple Music catalog from Sonic Search, and play selected songs using `ApplicationMusicPlayer`.
- **Spotify account connection:** OAuth 2.0 Authorization Code with PKCE, secure token storage, profile lookup, Spotify catalog search, and playback commands through the user's Spotify Connect playback device.
- **Sonic Search:** combines Internet Archive, Audius, connected personal sources, Apple Music and Spotify results. Apple Music tracks play through MusicKit; Spotify tracks are handed to Spotify Connect.
- **Beat haptics:** optional soft haptic pulses using a user-selected BPM. This is a manual tempo guide, not automatic beat detection.
- **Sleep timer:** 15 / 30 / 45 / 60 / 90 minute presets with a short fade-out for Sonic's AVPlayer stream.
- **Mashup Studio:** play two imported/downloaded local audio files together using `AVAudioEngine`, with independent deck volume controls.
- **Appearance:** dark, light and system themes.
- **Navigation:** a dedicated Settings tab keeps account connections and advanced features out of the main playback screen.


## What's new in 1.3

- **Variable playback speed:** choose 0.5× through 2.0× from the Now Playing screen or Settings. The selection is persisted and applied to Sonic's AVPlayer streams with spectral time-pitch processing. Apple Music and Spotify remain controlled by their respective provider players.
- **End-of-track sleep timer:** stop playback after the current track finishes, in addition to the existing timed fade-out presets.
- **Honest quality display:** Now Playing no longer claims "Original source quality" when a provider has not supplied bitrate metadata. A reported bitrate is shown when available; otherwise Sonic says source metadata is unavailable.
- **Version:** 1.3.0 (build 4).

## What's new in 1.2

- **GitHub Actions CI:** shared Xcode scheme, macOS 26 runner, Xcode 26.4 selection, unsigned iOS Simulator build/test, static project validation, and diagnostic artifacts on failures.
- **Unit tests:** XCTest coverage for synchronized-lyrics timestamp parsing and malformed lyric lines.
- **Synchronized lyrics:** best-effort LRCLIB lookup, time-synced highlighting and auto-scrolling, with plain-lyrics fallback. Lyrics are optional and never block playback.
- **Smarter queue controls:** shuffle without immediately repeating the current track, repeat off/all/one, queue reordering, and swipe-to-remove.
- **Playlist organization:** create playlists, group them into named folders, add tracks from the library, and keep the main navigation flat.
- **Sleep timer fix:** fading now restores the player's prior volume if the timer is cancelled instead of leaving volume in an unexpected state.
- **Library reliability:** restore local-file URLs after relaunch and avoid duplicate downloads.
- **Updated version:** 1.2.0 (build 3).

## GitHub Actions build

The repository includes `.github/workflows/ios-ci.yml` and a shared `Sonic` scheme. Push the extracted `Sonic/` directory contents to a GitHub repository (the `.github` folder must remain at the repository root). GitHub Actions will:

1. Run on a macOS 26 hosted runner and select Xcode 26.4.
2. Validate the Info.plist, Xcode project object graph, source references and shared scheme.
3. Run Swift parser checks for every app and test source file.
4. Build and run the XCTest target on an available iPhone simulator with code signing disabled.
5. Compile a separate Release configuration for the generic iPhone device SDK without signing.
6. Upload the simulator `.app`, unsigned device `.app` build product, and `.xcresult`/logs for diagnostics.

No Apple signing certificate or paid developer account is needed for these compile checks. The device `.app` artifact is intentionally unsigned and cannot be installed directly; a signed IPA, device archive, or TestFlight upload is a separate workflow and requires Apple signing credentials and provisioning.

The CI job deliberately does not hide Xcode's exit status: `set -euo pipefail` preserves failures through `tee`, so an Xcode exit code 65 or shell exit code 1 fails the job and leaves logs/results available for diagnosis. This source package has not yet been run on a hosted GitHub runner from this environment; the first GitHub Actions run is the authoritative Xcode build verification.

## Open and build

1. Extract the ZIP and open `Sonic.xcodeproj` in Xcode on macOS.
2. Select the **Sonic** target and set your Apple development team under **Signing & Capabilities**.
3. For Apple Music, add/enable the **MusicKit** capability for the App ID and target. The app already includes `NSAppleMusicUsageDescription` and the audio background mode.
4. Select an iPhone simulator or connected iPhone and press Run.

The deployment target is iOS 17. A free Apple developer account can be used for personal device testing through Xcode's Personal Team provisioning, subject to Apple's provisioning limits and renewal period.

## Connect Apple Music

1. Open **Settings → Connected music services → Apple Music**.
2. Tap **Connect Apple Music** and grant permission.
3. An active Apple Music subscription is required for full catalog playback.
4. Search Apple Music from the main **Search** tab. Apple Music tracks play through MusicKit's `ApplicationMusicPlayer`, not by extracting protected audio into Sonic's own player.

Apple Music playback is subject to MusicKit authorization, storefront availability, subscription status, and Apple's service rules. The MusicKit player is separate from Sonic's AVPlayer queue; controls and haptics for the two playback engines are not yet unified.

## Connect Spotify

1. Create an app in the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard).
2. Add this exact Redirect URI to the app settings: `sonic://spotify-callback`.
3. Copy the Spotify **Client ID**.
4. Open **Sonic → Settings → Connected music services → Spotify**, paste the Client ID and tap **Connect Spotify**.
5. Approve the requested account permissions in Spotify.

Sonic uses PKCE authorization and stores access / refresh tokens in the iOS Keychain. It can search Spotify's catalog and send supported playback commands to the user's Spotify Connect playback device. Spotify audio itself remains in Spotify's own service/player; Sonic does not download, proxy, capture, or remix Spotify streams. On-demand playback is subject to Spotify account eligibility (typically Premium), an active playback device, developer-app access and Spotify platform rules. Spotify API access and rate limits are controlled by Spotify.

The current integration uses Spotify Web API remote playback commands. It does not embed Spotify's proprietary audio decoder or extract Spotify's protected audio stream.

## Personal music servers and public catalogs

- **Internet Archive:** public audio search and direct file playback/download when the item metadata exposes a permitted file.
- **Audius:** independent-artist catalog search and streaming; download availability follows the provider's track metadata.
- **Subsonic / OpenSubsonic:** compatible servers such as Navidrome.
- **Jellyfin:** audio search, stream, artwork and download endpoints.
- **Direct streams:** HTTP/HTTPS audio URLs.
- **Local files:** import through the iOS document picker.

Add personal servers from **Sources → Add a music source**. Prefer HTTPS outside a trusted local network.

## Mashup Studio

Mashup Studio is available from **Settings → Sonic Studio**. It mixes two local/imported/downloaded audio files with independent deck levels. It intentionally does not capture or remix Apple Music or Spotify-protected content. The initial mixer starts both files together; it does not yet provide BPM detection, beat-grid alignment, key matching, effects, stems or export/render-to-file.

## Playback and audio quality

- Sonic's own streams use AVFoundation / AVPlayer with an iOS `.playback` audio session and Lock Screen / Control Center metadata and transport commands.
- MusicKit playback is handled by Apple's `ApplicationMusicPlayer`.
- The app requests the provider's available stream and does not intentionally transcode it. Actual format, bitrate, sample rate, bit depth and output quality depend on the source, iOS decoder, and audio route.
- This build does not bundle FFmpeg or a general codec pack. Common iOS-supported formats work through AVFoundation; OGG/Opus/APE/DSD and other formats are not guaranteed. A properly licensed FFmpeg/VLC decoder module remains a separate future integration.
- Lossless playback is possible only when the source provides a lossless file and the device/output path supports it. Sonic does not upsample lossy audio or falsely label it lossless. Bluetooth output can apply its own codec limitations.

## Important limitations

- Spotify and Apple Music are account integrations, not sources Sonic can freely rehost. Their subscriptions, terms, API limits and platform restrictions apply.
- Spotify playback control requires an eligible Spotify Connect device. Spotify may return errors when no active device is available or the account is not eligible for on-demand playback.
- Apple Music playback is currently separate from Sonic's AVPlayer queue. The mini-player, queue, sleep timer and beat haptics currently control Sonic's native AVPlayer, not the separate MusicKit player.
- Beat haptics use a manually selected BPM; they are not audio-analysis-based beat detection.
- Sleep timer fade-out currently applies to Sonic's AVPlayer session.
- Mashup Studio supports local files only and is an initial two-deck mixer.
- Background playback is configured. The existing downloads still use foreground async URLSession transfers rather than a durable background download queue.
- The Jellyfin integration expects an API key and user ID; interactive server sign-in/discovery remains future work.

## Project structure

- `Sonic/App` — application entry point and shared state
- `Sonic/Models` — track and source models
- `Sonic/Services` — playback, catalog/server APIs, account integrations, downloads, Keychain and mixer
- `Sonic/Views` — Home, Search, Library, Sources, Settings, Now Playing and Mashup Studio

## Validation performed for this package

- All app and XCTest Swift files passed `swiftc -frontend -parse` in the available environment.
- `Info.plist` and `project.pbxproj` passed property-list validation.
- The project object graph was checked: targets, build phases, group children, build-file references, and source-root paths resolve.
- The shared Xcode scheme XML was parsed successfully.
- `scripts/ci-validate.sh` passed locally.
- **Not verified here:** Apple's iOS SDK type-check/build, XCTest simulator execution, signing, and live provider integrations. This environment has Swift 6.2 on Linux but no Xcode or iOS SDK. The GitHub Actions workflow performs the missing Xcode build and simulator tests after you push the project to GitHub.
