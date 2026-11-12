import Foundation

/// Camera names read from the files of the library, kept between launches: reading one
/// costs a file access. "" means the file names no camera.
public final class CameraCache: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var names: [String: String] = [:]

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            names = decoded
        }
    }

    /// nil when the file was not read yet.
    public func name(for id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return names[id]
    }

    public func merge(_ found: [String: String]) {
        guard !found.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        names.merge(found) { $1 }
        guard let data = try? JSONEncoder().encode(names) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// The cameras of the videos on a card: the files are there, so they are read.
public enum CardCameras {
    public static func read(_ videos: [SourceVideo]) -> [String: String] {
        var cameras: [String: String] = [:]
        for video in videos {
            cameras[video.id] = CameraName.fromFile(video.url) ?? CameraName.fromName(video.filename)
        }
        return cameras
    }
}

/// The camera or phone that shot a video, for the videos Photos does not know it of:
/// Photos reads only Apple's tags, which iPhones write.
public enum CameraName {
    /// From the file: the QuickTime ©mak and ©mod tags, or the model name GoPro writes in
    /// its GPMF box. nil when the file does not say it.
    public static func fromFile(_ url: URL) -> String? {
        guard let udta = (try? MovieFile(url: url))?.moov?.child("udta") else { return nil }
        let make = udta.child("©mak").flatMap(quickTimeText)
        let model = udta.child("©mod").flatMap(quickTimeText)
            ?? udta.child("GPMF").flatMap { gpmfString($0.payload, key: "MINF") }
        switch (make, model) {
        case let (make?, model?):
            return model.lowercased().hasPrefix(make.lowercased()) ? model : make + " " + model
        case let (make?, nil):
            return make
        case let (nil, model?):
            return udta.child("GPMF") != nil && !model.lowercased().hasPrefix("gopro")
                ? "GoPro " + model : model
        case (nil, nil):
            return nil
        }
    }

    /// A guess from the name of cameras that name their files in their own way.
    public static func fromName(_ filename: String) -> String? {
        let name = filename.uppercased()
        let gopro = ["GX", "GH", "GOPR", "GP"].contains { prefix in
            name.hasPrefix(prefix) && name.dropFirst(prefix.count).prefix(4).allSatisfy(\.isNumber)
        }
        if gopro { return "GoPro (from the name)" }
        if ["DJI_", "DJI_FLY_", "DJI_MIMO_"].contains(where: name.hasPrefix) {
            return "DJI (from the name)"
        }
        return nil
    }

    /// A QuickTime user data text: 2 bytes of length, 2 bytes of language, the text.
    private static func quickTimeText(_ box: RawBox) -> String? {
        let payload = box.payload
        guard payload.count > 4 else { return nil }
        let length = min(Int(payload.uint16(at: 0)), payload.count - 4)
        let text = String(data: payload.subdata(in: 4..<4 + length), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return text?.isEmpty == false ? text : nil
    }

    /// A text value in GPMF: key (4), type (1), size (1), count (2), then the data padded to 4.
    static func gpmfString(_ data: Data, key: String) -> String? {
        var offset = 0
        while offset + 8 <= data.count {
            let found = data.fourCC(at: offset)
            let type = data[data.startIndex + offset + 4]
            let size = Int(data[data.startIndex + offset + 5])
            let count = Int(data.uint16(at: offset + 6))
            let length = size * count
            let padded = (length + 3) & ~3
            guard offset + 8 + length <= data.count else { return nil }
            if found == key, type == UInt8(ascii: "c") {
                let bytes = data.subdata(in: offset + 8..<offset + 8 + length)
                let text = String(decoding: bytes, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
                return text.isEmpty ? nil : text
            }
            // Nested values (type 0) are entered, the others skipped.
            offset += type == 0 ? 8 : 8 + padded
        }
        return nil
    }
}
