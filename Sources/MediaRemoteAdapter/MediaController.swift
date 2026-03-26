import Foundation

public class MediaController {

    private var perlScriptPath: String? {
        guard let path = Bundle.module.path(forResource: "run", ofType: "pl") else {
            assertionFailure("run.pl script not found in bundle resources.")
            return nil
        }
        return path
    }

    private var listeningProcess: Process?
    private var dataBuffer = Data()
    private var playbackTimer: Timer?
    private var playbackInfo: (baseTime: TimeInterval, baseTimestamp: TimeInterval)?
    private var currentTrackIdentifier: String?
    private var isPlaying = false
    private var lastTrackInfo: TrackInfo?
    private var seekTimer: Timer?
    private var trackChangeEmitTimer: Timer?
    private var eventCount = 0
    private let restartThreshold = 100

    public var onTrackInfoReceived: ((TrackInfo?) -> Void)?
    public var onListenerTerminated: (() -> Void)?
    public var onDecodingError: ((Error, Data) -> Void)?
    public var onPlaybackTimeUpdate: ((_ elapsedTime: TimeInterval) -> Void)?
    public var bundleIdentifier: String?

    public init(bundleIdentifier: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
    }

    private var libraryPath: String? {
        let bundle = Bundle(for: MediaController.self)
        guard let path = bundle.executablePath else {
            assertionFailure("Could not locate the executable path for the MediaRemoteAdapter framework.")
            return nil
        }
        return path
    }

    @discardableResult
    private func runPerlCommand(arguments: [String]) -> (output: String?, error: String?, terminationStatus: Int32) {
        guard let scriptPath = perlScriptPath else {
            return (nil, "Perl script not found.", -1)
        }
        guard let libraryPath = libraryPath else {
            return (nil, "Dynamic library path not found.", -1)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptPath, libraryPath] + arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe

        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

            return (output, errorOutput, process.terminationStatus)
        } catch {
            return (nil, error.localizedDescription, -1)
        }
    }

    /// Returns the track info independently from the actual listen process.
    public func getTrackInfo(_ onReceive: @escaping (TrackInfo?) -> Void) {
        guard let scriptPath = perlScriptPath else {
            onReceive(nil)
            return
        }
        guard let libraryPath = libraryPath else {
            onReceive(nil)
            return
        }

        let getProcess = Process()
        getProcess.executableURL = URL(fileURLWithPath: "/usr/bin/perl")

        var getDataBuffer = Data()
        var callbackExecuted = false

        var arguments = [scriptPath]
        if let bundleId = bundleIdentifier {
            arguments.append("--id")
            arguments.append(bundleId)
        }
        arguments.append(contentsOf: [libraryPath, "get"])
        getProcess.arguments = arguments

        let outputPipe = Pipe()
        getProcess.standardOutput = outputPipe

        outputPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let incomingData = fileHandle.availableData
            if incomingData.isEmpty {
                return
            }

            getDataBuffer.append(incomingData)

            guard let newlineData = "\n".data(using: .utf8),
                  let range = getDataBuffer.firstRange(of: newlineData),
                  range.lowerBound <= getDataBuffer.count else {
                return
            }

            let lineData = getDataBuffer.subdata(in: 0..<range.lowerBound)
            getDataBuffer.removeSubrange(0..<range.upperBound)

            if !lineData.isEmpty && !callbackExecuted {
                callbackExecuted = true
                // Check for NIL response
                if lineData == "NIL".data(using: .utf8) {
                    DispatchQueue.main.async { onReceive(nil) }
                    return
                }
                do {
                    let trackInfo = try JSONDecoder().decode(TrackInfo.self, from: lineData)
                    DispatchQueue.main.async { onReceive(trackInfo) }
                } catch {
                    DispatchQueue.main.async { onReceive(nil) }
                }
            }
        }

        getProcess.terminationHandler = { _ in
            if !callbackExecuted {
                DispatchQueue.main.async { onReceive(nil) }
            }
        }

        do {
            try getProcess.run()
        } catch {
            onReceive(nil)
        }
    }

    public func startListening() {
        guard listeningProcess == nil else {
            return
        }

        eventCount = 0
        startListeningInternal()
    }

    private func startListeningInternal() {
        guard let scriptPath = perlScriptPath else {
            return
        }
        guard let libraryPath = libraryPath else {
            return
        }

        listeningProcess = Process()
        listeningProcess?.executableURL = URL(fileURLWithPath: "/usr/bin/perl")

        var arguments = [scriptPath]
        if let bundleId = bundleIdentifier {
            arguments.append("--id")
            arguments.append(bundleId)
        }
        arguments.append(contentsOf: [libraryPath, "loop"])
        listeningProcess?.arguments = arguments

        let outputPipe = Pipe()
        listeningProcess?.standardOutput = outputPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            guard let self = self else { return }

            let incomingData = fileHandle.availableData
            if incomingData.isEmpty {
                // This can happen when the process terminates.
                return
            }

            self.dataBuffer.append(incomingData)

            // Process all complete lines in the buffer.
            guard let newlineData = "\n".data(using: .utf8) else { return }
            while let range = self.dataBuffer.firstRange(of: newlineData) {
                // Bounds check before accessing subrange
                guard range.lowerBound <= self.dataBuffer.count else {
                    break
                }

                let lineData = self.dataBuffer.subdata(in: 0..<range.lowerBound)

                // Remove the line and the newline character from the buffer.
                self.dataBuffer.removeSubrange(0..<range.upperBound)

                // Check for NIL response indicating no media player
                if lineData == "NIL".data(using: .utf8) {
                    DispatchQueue.main.async {
                        self.onTrackInfoReceived?(nil)
                    }
                    continue
                }

                if !lineData.isEmpty {
                    self.eventCount += 1

                    do {
                        let trackInfo = try JSONDecoder().decode(TrackInfo.self, from: lineData)
                        DispatchQueue.main.async {
                            self.lastTrackInfo = trackInfo
                            self.updatePlaybackTimer(with: trackInfo)

                            let isTrackChange = trackInfo.payload.uniqueIdentifier != self.currentTrackIdentifier

                            if isTrackChange {
                                self.trackChangeEmitTimer?.invalidate()
                                self.trackChangeEmitTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                                    guard let self = self, let latest = self.lastTrackInfo else { return }
                                    self.onTrackInfoReceived?(latest)
                                }
                            } else {
                                self.onTrackInfoReceived?(trackInfo)
                            }

                            if self.eventCount >= self.restartThreshold {
                                self.restartListeningProcess()
                            }
                        }
                    } catch {
                        DispatchQueue.main.async {
                            self.onDecodingError?(error, lineData)
                        }
                    }
                }
            }
        }

        listeningProcess?.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                self?.listeningProcess = nil
                self?.playbackTimer?.invalidate()
                // Don't call onListenerTerminated if this is a planned restart
                if self?.eventCount != 0 {
                    self?.onListenerTerminated?()
                }
            }
        }

        do {
            try listeningProcess?.run()
        } catch {
            print("Failed to start listening process: \(error)")
            listeningProcess = nil
        }
    }

    public func stopListening() {
        listeningProcess?.terminate()
        playbackTimer?.invalidate()
        listeningProcess = nil
    }

    public func play() {
        applyOptimisticPlayState(playing: true)
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["play"])
        }
    }

    public func pause() {
        applyOptimisticPlayState(playing: false)
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["pause"])
        }
    }

    public func togglePlayPause() {
        applyOptimisticPlayState(playing: !isPlaying)
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["toggle_play_pause"])
        }
    }

    public func nextTrack() {
        applyOptimisticSkip()
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["next_track"])
        }
    }

    public func previousTrack() {
        applyOptimisticSkip()
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["previous_track"])
        }
    }

    private func applyOptimisticPlayState(playing: Bool) {
        guard let last = lastTrackInfo else { return }

        let now = Date().timeIntervalSince1970
        let currentPosition: Double
        if let info = playbackInfo {
            currentPosition = info.baseTime + (now - info.baseTimestamp)
        } else {
            currentPosition = (last.payload.elapsedTimeMicros ?? 0) / 1_000_000
        }

        if playing {
            self.playbackInfo = (baseTime: currentPosition, baseTimestamp: now)
            if playbackTimer == nil || !playbackTimer!.isValid {
                playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                    self?.handleTimerTick()
                }
            }
        } else {
            playbackTimer?.invalidate()
            onPlaybackTimeUpdate?(currentPosition)
        }

        self.isPlaying = playing
        let nowMicros = now * 1_000_000
        let syntheticPayload = TrackInfo.Payload(
            title: last.payload.title,
            artist: last.payload.artist,
            album: last.payload.album,
            isPlaying: playing,
            durationMicros: last.payload.durationMicros,
            elapsedTimeMicros: currentPosition * 1_000_000,
            applicationName: last.payload.applicationName,
            bundleIdentifier: last.payload.bundleIdentifier,
            artworkDataBase64: last.payload.artworkDataBase64,
            artworkMimeType: last.payload.artworkMimeType,
            timestampEpochMicros: nowMicros,
            PID: last.payload.PID,
            shuffleMode: last.payload.shuffleMode,
            repeatMode: last.payload.repeatMode,
            playbackRate: playing ? 1.0 : 0.0,
            artwork: last.payload.artwork
        )
        let syntheticTrackInfo = TrackInfo(payload: syntheticPayload)
        self.lastTrackInfo = syntheticTrackInfo
        onTrackInfoReceived?(syntheticTrackInfo)
    }

    private func applyOptimisticSkip() {
        onPlaybackTimeUpdate?(0)
        self.playbackInfo = (baseTime: 0, baseTimestamp: Date().timeIntervalSince1970)
        self.isPlaying = true

        if playbackTimer == nil || !playbackTimer!.isValid {
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.handleTimerTick()
            }
        }
    }
    
    public func stop() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["stop"])
        }
    }

    public func setTime(seconds: Double) {
        seekTimer?.invalidate()

        // Optimistically update the UI and our internal timer state.
        onPlaybackTimeUpdate?(seconds)
        self.playbackInfo = (baseTime: seconds, baseTimestamp: Date().timeIntervalSince1970)

        // If we are currently playing, ensure the timer continues to run from the new
        // optimistic position for a smooth UI experience during scrubbing.
        if isPlaying, playbackTimer == nil || !playbackTimer!.isValid {
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.handleTimerTick()
            }
        }

        // Throttle the actual seek command to avoid overwhelming the system.
        seekTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
            DispatchQueue.global(qos: .userInitiated).async {
                self?.runPerlCommand(arguments: ["set_time", String(seconds)])
            }
        }
    }
    
    private func updatePlaybackTimer(with trackInfo: TrackInfo) {
        let newTrackIdentifier = trackInfo.payload.uniqueIdentifier
        
        // When a new track is detected, reset the progress to 0.
        if newTrackIdentifier != self.currentTrackIdentifier {
            self.currentTrackIdentifier = newTrackIdentifier
            onPlaybackTimeUpdate?(0)
        }

        playbackTimer?.invalidate()

        // Update our local playing state.
        self.isPlaying = trackInfo.payload.isPlaying ?? false

        guard self.isPlaying,
              let baseTime = trackInfo.payload.elapsedTimeMicros,
              let baseTimestamp = trackInfo.payload.timestampEpochMicros
        else {
            if let lastKnownTime = trackInfo.payload.elapsedTimeMicros {
                onPlaybackTimeUpdate?(lastKnownTime / 1_000_000)
            }
            return
        }

        let incomingBaseTime = baseTime / 1_000_000
        let incomingBaseTimestamp = baseTimestamp / 1_000_000

        if let existing = self.playbackInfo {
            let now = Date().timeIntervalSince1970
            let interpolated = existing.baseTime + (now - existing.baseTimestamp)
            if abs(interpolated - incomingBaseTime) < 1.0 {
                self.playbackInfo = (baseTime: interpolated, baseTimestamp: now)
            } else {
                self.playbackInfo = (baseTime: incomingBaseTime, baseTimestamp: incomingBaseTimestamp)
            }
        } else {
            self.playbackInfo = (baseTime: incomingBaseTime, baseTimestamp: incomingBaseTimestamp)
        }

        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.handleTimerTick()
        }
    }

    @objc private func handleTimerTick() {
        guard let info = playbackInfo else { return }
        let now = Date().timeIntervalSince1970
        let timePassed = now - info.baseTimestamp
        let currentElapsedTime = info.baseTime + timePassed
        onPlaybackTimeUpdate?(currentElapsedTime)
    }

    public func toggleShuffle() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["toggle_shuffle"])
        }
    }

    public func toggleRepeat() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["toggle_repeat"])
        }
    }

    public func startForwardSeek() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["start_forward_seek"])
        }
    }

    public func endForwardSeek() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["end_forward_seek"])
        }
    }

    public func startBackwardSeek() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["start_backward_seek"])
        }
    }

    public func endBackwardSeek() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["end_backward_seek"])
        }
    }

    public func goBackFifteenSeconds() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["go_back_fifteen_seconds"])
        }
    }

    public func skipFifteenSeconds() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["skip_fifteen_seconds"])
        }
    }

    public func likeTrack() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["like_track"])
        }
    }

    public func banTrack() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["ban_track"])
        }
    }

    public func addToWishList() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["add_to_wish_list"])
        }
    }

    public func removeFromWishList() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["remove_from_wish_list"])
        }
    }

    public func setShuffleMode(_ mode: TrackInfo.ShuffleMode) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["set_shuffle_mode", String(mode.rawValue)])
        }
    }

    public func setRepeatMode(_ mode: TrackInfo.RepeatMode) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["set_repeat_mode", String(mode.rawValue)])
        }
    }

    private func restartListeningProcess() {
        // Stop current process
        listeningProcess?.terminate()
        listeningProcess = nil

        // Clear data buffer to free any accumulated data
        dataBuffer.removeAll()

        // Reset event count
        eventCount = 0

        // Wait a brief moment for cleanup, then restart
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.startListeningInternal()
        }
    }
} 