import Foundation

public enum Bitrate {
    /// Target video bit rate in bits per second.
    ///
    /// Starts from the bit rate for 1080p at 30 fps and scales it. The scaling
    /// is less than linear: a 4K video has 4 times the pixels of 1080p but
    /// needs only about 2.8 times the bits for the same visual quality.
    public static func target(width: Int, height: Int, fps: Double, quality: Quality) -> Double {
        let pixels = Double(max(width * height, 1))
        let rate = min(max(fps > 0 ? fps : 30, 15), 120)
        return quality.referenceBitrate
            * pow(pixels / (1920 * 1080), 0.75)
            * pow(rate / 30, 0.5)
    }

    /// Saving we can expect, in percent. Negative when the video is already below the target.
    public static func expectedSaving(sourceBitrate: Double, width: Int, height: Int,
                                      fps: Double, quality: Quality) -> Double {
        guard sourceBitrate > 0 else { return 0 }
        let goal = target(width: width, height: height, fps: fps, quality: quality)
        return 100 * (1 - goal / sourceBitrate)
    }
}

public enum Decision: Equatable, Sendable {
    case process
    case leave(String)  // why the video is left alone
}

public enum Policy {
    public static let maxAttempts = 3

    /// Decide whether to process a video, using only what we know without downloading it.
    ///
    /// - Parameter outputs: identifiers of the videos this app created.
    public static func decide(item: VideoItem, record: Record?, settings: AppSettings,
                              outputs: Set<String>, now: Date = Date()) -> Decision {
        if outputs.contains(item.id) {
            return .leave("Re-encoded by this app")
        }
        if let record {
            switch record.status {
            case .failed where record.attempts < maxAttempts:
                break  // try again
            case .failed:
                return .leave("Failed \(record.attempts) times: \(record.detail)")
            case .replaced:
                return .leave("Replaced. The original waits for deletion")
            case .restored:
                break  // as if never processed
            case .needsReview:
                return .leave("Check Photos for a duplicate: \(record.detail)")
            case .importing, .deleted, .notWorth, .skipped:
                return .leave(record.detail)
            }
        }
        if let reason = item.skipReason {
            return .leave(reason)
        }
        if item.fileSize <= 0 {
            return .leave("File size not available")
        }
        if Double(item.fileSize) < settings.minSizeMB * 1_048_576 {
            return .leave("Smaller than \(Int(settings.minSizeMB)) MB")
        }
        if let date = item.creationDate,
           date > now.addingTimeInterval(-Double(settings.minAgeDays) * 86_400) {
            return .leave("Newer than \(settings.minAgeDays) days")
        }
        // The frame rate is not known before the download. 30 fps gives the
        // lowest target, so no video is wrongly excluded here.
        let saving = Bitrate.expectedSaving(sourceBitrate: item.estimatedBitrate,
                                            width: item.width, height: item.height,
                                            fps: 30, quality: settings.quality)
        if saving < settings.minSavingPercent {
            return .leave("Already well compressed")
        }
        return .process
    }
}
