import Foundation

public enum EncoderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case native  // Apple hardware encoder, no extra software
    case ffmpeg  // libx265, needs ffmpeg installed

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .native: return "Apple (fast)"
        case .ffmpeg: return "ffmpeg x265 (slow, smaller files)"
        }
    }
}

public enum Quality: String, Codable, CaseIterable, Identifiable, Sendable {
    case high, balanced, compact

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .high: return "High quality"
        case .balanced: return "Balanced"
        case .compact: return "Small files"
        }
    }

    /// Target video bit rate for a 1080p, 30 fps video, in bits per second.
    public var referenceBitrate: Double {
        switch self {
        case .high: return 7_000_000
        case .balanced: return 5_000_000
        case .compact: return 3_500_000
        }
    }

    /// Quality value for libx265. Lower means better quality.
    public var crf: Int {
        switch self {
        case .high: return 22
        case .balanced: return 24
        case .compact: return 27
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var encoder: EncoderKind = .native
    public var quality: Quality = .balanced
    public var minSizeMB: Double = 20
    public var minAgeDays: Int = 7
    /// Keep the new file only if it is at least this much smaller.
    public var minSavingPercent: Double = 20
    /// Decode the whole new file before trusting it.
    public var fullVerify: Bool = true
    /// Empty means "look in the usual Homebrew places".
    public var ffmpegPath: String = ""

    public init() {}

    private static let key = "settings"

    public static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

/// A video of the Photos library, with what we can know without downloading it.
public struct VideoItem: Identifiable, Equatable, Sendable {
    public let id: String  // PhotoKit local identifier
    public var filename: String
    public var creationDate: Date?
    public var duration: Double
    public var width: Int
    public var height: Int
    public var fileSize: Int64
    /// Set for kinds of video we never touch.
    public var skipReason: String?
    /// The camera or phone that shot the video, as Photos shows it. nil when unknown.
    public var device: String?

    public init(id: String, filename: String, creationDate: Date?, duration: Double,
                width: Int, height: Int, fileSize: Int64, skipReason: String? = nil,
                device: String? = nil) {
        self.id = id
        self.filename = filename
        self.creationDate = creationDate
        self.duration = duration
        self.width = width
        self.height = height
        self.fileSize = fileSize
        self.skipReason = skipReason
        self.device = device
    }

    /// Whole-file bit rate in bits per second. Close enough to the video bit rate.
    public var estimatedBitrate: Double {
        duration > 0 ? Double(fileSize) * 8 / duration : 0
    }
}

public enum Status: String, Codable, Sendable {
    case importing    // import into Photos started; seen at launch = the app stopped half way
    case replaced     // new video is in Photos, original waits for deletion
    case deleted      // original was moved to Recently Deleted
    case notWorth     // already well compressed, original kept
    case skipped      // a kind of video we do not touch
    case failed       // error, tried again later
    case needsReview  // stopped during import; a person must check for a duplicate
    case restored     // on request the new video was deleted and the original kept; may run again
}

extension Status {
    /// A smaller copy of the video was added to Photos.
    public var hasNewVideo: Bool { self == .replaced || self == .deleted }
}

public struct Record: Codable, Equatable, Sendable {
    public var status: Status
    public var filename: String
    public var originalSize: Int64?
    public var newSize: Int64?
    public var newIdentifier: String?
    public var detail: String
    public var attempts: Int
    public var updatedAt: Date

    public init(status: Status, filename: String, originalSize: Int64? = nil,
                newSize: Int64? = nil, newIdentifier: String? = nil, detail: String = "",
                attempts: Int = 0, updatedAt: Date = Date()) {
        self.status = status
        self.filename = filename
        self.originalSize = originalSize
        self.newSize = newSize
        self.newIdentifier = newIdentifier
        self.detail = detail
        self.attempts = attempts
        self.updatedAt = updatedAt
    }
}

/// A mutable value that can be shared with callbacks.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) { stored = value }

    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
