# MediaRemoteAdapter

A Swift package for macOS that provides a modern interface for controlling media playback and receiving track information from the private `MediaRemote.framework`.

## Installation

Add `MediaRemoteAdapter` to your project using Swift Package Manager.

1. In Xcode: **File > Add Packages...**
2. Enter: `https://github.com/ejbills/mediaremote-adapter.git`
3. Add `MediaRemoteAdapter` to your target.

### Embedding the Framework

After adding the package, ensure the framework is correctly embedded:

1. Select your project, then your main application target.
2. Go to the **General** tab.
3. In **"Frameworks, Libraries, and Embedded Content"**, set `MediaRemoteAdapter.framework` to **"Embed & Sign"**.

## Usage

```swift
import MediaRemoteAdapter

class YourAppController {
    let mediaController = MediaController()

    init() {
        // Handle incoming track data (nil when no media player is active)
        mediaController.onTrackInfoReceived = { trackInfo in
            guard let trackInfo = trackInfo else {
                print("No media playing")
                return
            }
            print("Now Playing: \(trackInfo.payload.title ?? "N/A")")
        }

        // Handle listener termination
        mediaController.onListenerTerminated = {
            print("Listener terminated")
        }
    }

    func start() {
        mediaController.startListening()
    }

    // Playback controls
    func play() { mediaController.play() }
    func pause() { mediaController.pause() }
    func togglePlayPause() { mediaController.togglePlayPause() }
    func nextTrack() { mediaController.nextTrack() }
    func previousTrack() { mediaController.previousTrack() }
    func stop() { mediaController.stop() }
    func seek(to seconds: Double) { mediaController.setTime(seconds: seconds) }

    // Shuffle and repeat
    func setShuffle(_ mode: TrackInfo.ShuffleMode) { mediaController.setShuffleMode(mode) }
    func setRepeat(_ mode: TrackInfo.RepeatMode) { mediaController.setRepeatMode(mode) }
}
```

### One-Shot Track Info

Get current track info without starting a listener:

```swift
mediaController.getTrackInfo { trackInfo in
    guard let trackInfo = trackInfo else { return }
    print("Currently playing: \(trackInfo.payload.title ?? "Unknown")")
}
```

### Filtering by Application (this doesn't work)

```swift
let musicController = MediaController(bundleIdentifier: "com.apple.Music")
let spotifyController = MediaController(bundleIdentifier: "com.spotify.client")
```

## API

### Callbacks

| Callback | Description |
|----------|-------------|
| `onTrackInfoReceived: ((TrackInfo?) -> Void)?` | Called with track info, or `nil` when no media is playing |
| `onPlaybackTimeUpdate: ((TimeInterval) -> Void)?` | Elapsed time updates (polling-based, use sparingly) |
| `onDecodingError: ((Error, Data) -> Void)?` | JSON decode errors |
| `onListenerTerminated: (() -> Void)?` | Listener process terminated |

### Methods

| Method | Description |
|--------|-------------|
| `startListening()` | Start background listener |
| `stopListening()` | Stop listener |
| `getTrackInfo(_:)` | One-shot track info fetch |
| `play()`, `pause()`, `togglePlayPause()` | Playback control |
| `nextTrack()`, `previousTrack()`, `stop()` | Track navigation |
| `setTime(seconds:)` | Seek to position |
| `setShuffleMode(_:)` | Set shuffle (`.off`, `.songs`, `.albums`) |
| `setRepeatMode(_:)` | Set repeat (`.off`, `.one`, `.all`) |

### TrackInfo.Payload

| Property | Type | Description |
|----------|------|-------------|
| `title`, `artist`, `album`, `applicationName`, `bundleIdentifier` | `String?` | |
| `isPlaying` | `Bool?` | |
| `durationMicros`, `elapsedTimeMicros`, `timestampEpochMicros` | `Double?` | |
| `playbackRate` | `Double?` | 1.0 = playing, 0.0 = paused |
| `currentElapsedTime` | `TimeInterval?` | **Computed** - real-time position in seconds |
| `artwork` | `NSImage?` | Computed from base64 data |
| `PID` | `pid_t?` | |
| `shuffleMode` | `ShuffleMode?` | |
| `repeatMode` | `RepeatMode?` | |

> **Note:** `elapsedTimeMicros` is stale (captured at last state change). Use `currentElapsedTime` for accurate position.

## Acknowledgements

This project was originally inspired by [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter). The core technique of using Perl to access the private framework was pioneered there.
