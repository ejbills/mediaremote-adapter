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
    private var lastTrackInfo: TrackInfo?
    private var eventCount = 0
    private let restartThreshold = 100

    public var onTrackInfoReceived: ((TrackInfo?) -> Void)?
    public var onListenerTerminated: (() -> Void)?
    public var onDecodingError: ((Error, Data) -> Void)?

    public init() {}

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

        var outputBuffer = Data()
        var errorBuffer = Data()
        let lock = NSLock()

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            lock.lock()
            outputBuffer.append(data)
            lock.unlock()
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            lock.lock()
            errorBuffer.append(data)
            lock.unlock()
        }

        do {
            try process.run()
            process.waitUntilExit()

            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil

            lock.lock()
            outputBuffer.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
            errorBuffer.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
            lock.unlock()

            let output = String(data: outputBuffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let errorOutput = String(data: errorBuffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

            return (output, errorOutput, process.terminationStatus)
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            return (nil, error.localizedDescription, -1)
        }
    }

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

        getProcess.arguments = [scriptPath, libraryPath, "get"]

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

        listeningProcess?.arguments = [scriptPath, libraryPath, "loop"]

        let outputPipe = Pipe()
        listeningProcess?.standardOutput = outputPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            guard let self = self else { return }

            let incomingData = fileHandle.availableData
            if incomingData.isEmpty {
                return
            }

            self.dataBuffer.append(incomingData)

            guard let newlineData = "\n".data(using: .utf8) else { return }
            while let range = self.dataBuffer.firstRange(of: newlineData) {
                guard range.lowerBound <= self.dataBuffer.count else {
                    break
                }

                let lineData = self.dataBuffer.subdata(in: 0..<range.lowerBound)

                self.dataBuffer.removeSubrange(0..<range.upperBound)

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
                            let emitted = self.preservingArtworkIfDowngrade(trackInfo)
                            self.lastTrackInfo = emitted
                            self.onTrackInfoReceived?(emitted)

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
        listeningProcess = nil
    }

    public func play() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["play"])
        }
    }

    public func pause() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["pause"])
        }
    }

    public func togglePlayPause() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["toggle_play_pause"])
        }
    }

    public func nextTrack() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["next_track"])
        }
    }

    public func previousTrack() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["previous_track"])
        }
    }

    public func stop() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["stop"])
        }
    }

    public func setTime(seconds: Double) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["set_time", String(seconds)])
        }
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

    private func isSameTrack(_ a: TrackInfo.Payload, _ b: TrackInfo.Payload) -> Bool {
        guard a.title == b.title, a.artist == b.artist else { return false }
        let aAlbum = a.album ?? ""
        let bAlbum = b.album ?? ""
        return aAlbum == bAlbum || aAlbum.isEmpty || bAlbum.isEmpty
    }

    private func preservingArtworkIfDowngrade(_ incoming: TrackInfo) -> TrackInfo {
        guard let previous = lastTrackInfo,
              isSameTrack(previous.payload, incoming.payload) else {
            return incoming
        }

        let previousLen = previous.payload.artworkDataBase64?.count ?? 0
        let incomingLen = incoming.payload.artworkDataBase64?.count ?? 0
        guard incomingLen < previousLen else {
            return incoming
        }

        let p = incoming.payload
        let merged = TrackInfo.Payload(
            title: p.title,
            artist: p.artist,
            album: p.album,
            isPlaying: p.isPlaying,
            durationMicros: p.durationMicros,
            elapsedTimeMicros: p.elapsedTimeMicros,
            applicationName: p.applicationName,
            bundleIdentifier: p.bundleIdentifier,
            artworkDataBase64: previous.payload.artworkDataBase64,
            artworkMimeType: previous.payload.artworkMimeType,
            timestampEpochMicros: p.timestampEpochMicros,
            PID: p.PID,
            shuffleMode: p.shuffleMode,
            repeatMode: p.repeatMode,
            playbackRate: p.playbackRate,
            artwork: previous.payload.artwork
        )
        return TrackInfo(payload: merged)
    }

    private func restartListeningProcess() {
        listeningProcess?.terminate()
        listeningProcess = nil
        dataBuffer.removeAll()
        eventCount = 0

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.startListeningInternal()
        }
    }
}
