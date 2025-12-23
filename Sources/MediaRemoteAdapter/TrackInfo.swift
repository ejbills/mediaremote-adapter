import AppKit
import Foundation

public struct TrackInfo: Codable {
    public let payload: Payload

    public enum ShuffleMode: Int, Codable {
        case off = 0
        case songs = 1
        case albums = 2
    }

    public enum RepeatMode: Int, Codable {
        case off = 0
        case one = 1
        case all = 2
    }

    public struct Payload: Codable {
        public let title: String?
        public let artist: String?
        public let album: String?
        public let isPlaying: Bool?
        public let durationMicros: Double?
        public let elapsedTimeMicros: Double?
        public let applicationName: String?
        public let bundleIdentifier: String?
        public let artworkDataBase64: String?
        public let artworkMimeType: String?
        public let timestampEpochMicros: Double?
        public let PID: pid_t?
        public let shuffleMode: ShuffleMode?
        public let repeatMode: RepeatMode?
        public let playbackRate: Double?

        public var artwork: NSImage? {
            guard let base64String = artworkDataBase64,
                  let data = Data(base64Encoded: base64String)
            else {
                return nil
            }
            return NSImage(data: data)
        }

        public var uniqueIdentifier: String {
            return "\(title ?? "")-\(artist ?? "")-\(album ?? "")"
        }

        /// Returns the current elapsed time in seconds, accounting for playback since the last update.
        /// This computes: elapsedTime + (timeSinceUpdate * playbackRate)
        public var currentElapsedTime: TimeInterval? {
            guard let elapsedMicros = elapsedTimeMicros,
                  let timestampMicros = timestampEpochMicros else {
                return nil
            }

            let elapsedSeconds = elapsedMicros / 1_000_000
            let timestampSeconds = timestampMicros / 1_000_000
            let rate = playbackRate ?? 0.0

            let now = Date().timeIntervalSince1970
            let timeSinceUpdate = now - timestampSeconds

            return elapsedSeconds + (timeSinceUpdate * rate)
        }

        enum CodingKeys: String, CodingKey {
            case title, artist, album, isPlaying, durationMicros, elapsedTimeMicros, applicationName, bundleIdentifier, artworkDataBase64, artworkMimeType, timestampEpochMicros, PID, shuffleMode, repeatMode, playbackRate
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.title = try container.decodeIfPresent(String.self, forKey: .title)
            self.artist = try container.decodeIfPresent(String.self, forKey: .artist)
            self.album = try container.decodeIfPresent(String.self, forKey: .album)
            self.durationMicros = try container.decodeIfPresent(Double.self, forKey: .durationMicros)
            self.elapsedTimeMicros = try container.decodeIfPresent(Double.self, forKey: .elapsedTimeMicros)
            self.applicationName = try container.decodeIfPresent(String.self, forKey: .applicationName)
            self.bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
            self.artworkDataBase64 = try container.decodeIfPresent(String.self, forKey: .artworkDataBase64)
            self.artworkMimeType = try container.decodeIfPresent(String.self, forKey: .artworkMimeType)
            self.timestampEpochMicros = try container.decodeIfPresent(Double.self, forKey: .timestampEpochMicros)

            // Handle PID which may come as Int or String
            if let pidNumber = try? container.decodeIfPresent(Int32.self, forKey: .PID) {
                self.PID = pid_t(pidNumber)
            } else if let pidString = try? container.decodeIfPresent(String.self, forKey: .PID),
                      let pidNumber = Int32(pidString) {
                self.PID = pid_t(pidNumber)
            } else {
                self.PID = nil
            }

            self.shuffleMode = try? container.decodeIfPresent(ShuffleMode.self, forKey: .shuffleMode)
            self.repeatMode = try? container.decodeIfPresent(RepeatMode.self, forKey: .repeatMode)
            self.playbackRate = try container.decodeIfPresent(Double.self, forKey: .playbackRate)

            if let boolValue = try? container.decode(Bool.self, forKey: .isPlaying) {
                self.isPlaying = boolValue
            } else if let intValue = try? container.decode(Int.self, forKey: .isPlaying) {
                self.isPlaying = (intValue == 1)
            } else {
                self.isPlaying = nil
            }
        }
    }
} 