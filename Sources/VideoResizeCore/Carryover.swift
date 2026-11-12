import CryptoKit
import Foundation

/// The encoders write only the video, the audio and the Apple metadata. This puts back
/// everything else the original had, so that nothing is lost:
///
/// - the extra tracks with their data: GPS and sensor tracks (GoPro GPMF, DJI), timed
///   metadata, timecode, subtitles;
/// - the user data box (GPS as ©xyz, camera make and model, GoPro and DJI tags) and the
///   Apple metadata, byte for byte;
/// - the other boxes of the file, such as camera XML or XMP;
/// - the creation dates of the movie and of its tracks.
///
/// `differences` then proves that all of it is in the new file.
public enum Carryover {
    /// Boxes that every file has, or that the encoder writes itself.
    private static let standardTopBoxes: Set<String> = ["ftyp", "moov", "mdat", "wide"]
    /// A fragmented file keeps its media index outside `moov`: not handled.
    private static let fragmentBoxes: Set<String> = ["moof", "mfra", "sidx", "ssix", "styp", "emsg", "prft"]
    private static let encodedTracks: Set<String> = ["vide", "soun"]

    /// Throws `MediaError.unsupported` for a file whose data this code cannot carry over, so
    /// that the original is kept as it is: data found through fixed positions in the file
    /// (dashcam GPS, `iloc`, `saio`) would point to the wrong place in a new file.
    public static func check(_ url: URL) throws {
        let file = try MovieFile(url: url)
        guard let moov = file.moov else { throw Boxes.damaged }
        if file.topLevel.contains(where: { fragmentBoxes.contains($0.type) }) {
            throw MediaError.unsupported("a fragmented file")
        }
        var boxes = moov.children
        var fixed: String?
        while let box = boxes.popLast(), fixed == nil {
            switch box.type {
            case "gps ": fixed = "GPS data at fixed places in the file (dashcam)"
            case "iloc", "saio": fixed = "data at fixed places in the file (\(box.type))"
            case "trak", "mdia", "minf", "stbl", "udta", "edts": boxes += box.children
            case "meta": boxes += metaChildren(box)
            default: break
            }
        }
        if let fixed { throw MediaError.unsupported(fixed) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        for box in file.topLevel where ["meta", "free", "skip"].contains(box.type) {
            try handle.seek(toOffset: box.payloadOffset)
            let start = try handle.read(upToCount: Int(min(box.payloadSize, 64 << 10))) ?? Data()
            let iloc = [start, Data(start.dropFirst(4))].contains { payload in
                Boxes.split(payload).boxes.contains { $0.type == "iloc" }
            }
            if (box.type == "meta" && iloc) || start.prefix(4) == Data("GPS ".utf8) {
                throw MediaError.unsupported("data at fixed places in the file")
            }
        }
    }

    /// The size of the header written for a top-level box with this payload.
    private static func headerSize(_ payload: UInt64) -> UInt64 {
        payload + 8 > UInt64(UInt32.max) ? 16 : 8
    }

    /// A box header, with the real size even when the original said "to the end of the file".
    private static func boxHeader(_ type: String, payload: UInt64) -> Data {
        var data = Data()
        if headerSize(payload) == 16 {
            data.append(uint32: 1); data.append(fourCC: type); data.append(uint64: payload + 16)
        } else {
            data.append(uint32: UInt32(payload + 8)); data.append(fourCC: type)
        }
        return data
    }

    /// The boxes inside a `meta` box, which in ISO files starts with version and flags.
    private static func metaChildren(_ meta: RawBox) -> [RawBox] {
        let payload = meta.payload
        let iso = payload.count >= 8 && payload.fourCC(at: 4) != "hdlr"
        return Boxes.split(iso ? payload.subdata(in: 4..<payload.count) : payload).boxes
    }

    /// The original's own top-level boxes: all but the ones every file has and empty padding.
    private static func ownTopBoxes(_ file: MovieFile, _ url: URL) throws -> [MovieFile.TopBox] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try file.topLevel.filter { box in
            guard !standardTopBoxes.contains(box.type) else { return false }
            let padding = box.type == "free" || box.type == "skip" || box.type == "\0\0\0\0"
            guard padding, box.payloadSize <= 64 << 20 else { return true }
            try handle.seek(toOffset: box.payloadOffset)
            let payload = try handle.read(upToCount: Int(box.payloadSize)) ?? Data()
            return payload.contains { $0 != 0 }  // padding that holds data is kept too
        }
    }

    /// Write `output`: the encoder's file `encoded`, plus what only `original` has.
    public static func apply(original: URL, encoded: URL, output: URL) throws {
        try check(original)
        let source = try MovieFile(url: original)
        let target = try MovieFile(url: encoded)
        guard let sourceMoov = source.moov, let targetMoov = target.moov else { throw Boxes.damaged }
        guard target.topLevel.last?.type == "moov" else {
            throw MediaError.encodingFailed("the new file does not end with its index")
        }

        let sourceChildren = sourceMoov.children
        let targetChildren = targetMoov.children
        let sourceTracks = sourceChildren.filter { $0.type == "trak" }
        let targetTracks = targetChildren.filter { $0.type == "trak" }

        // Track identifiers: the encoded tracks keep theirs, the copied ones get new ones.
        var ids: [UInt32: UInt32] = [:]
        for kind in encodedTracks {
            let from = sourceTracks.filter { $0.handler == kind }
            let to = targetTracks.filter { $0.handler == kind }
            guard from.count == to.count else {
                throw MediaError.encodingFailed("the new file has other \(kind) tracks")
            }
            for (old, new) in zip(from, to) { ids[trackID(old)] = trackID(new) }
        }
        let extras = sourceTracks.filter { !encodedTracks.contains($0.handler ?? "") }
        var nextID = (targetTracks.map(trackID).max() ?? 0) + 1
        for track in extras {
            ids[trackID(track)] = nextID
            nextID += 1
        }

        // Where the copied data goes: after the encoder's boxes and the original's own boxes.
        let kept = target.topLevel.dropLast()
        let extraTop = try ownTopBoxes(source, original)
        let tables = try extras.map(chunks)
        let dataSize = tables.reduce(UInt64(0)) { $0 + $1.sizes.reduce(0, +) }
        var position = kept.reduce(UInt64(0)) { $0 + $1.size }
            + extraTop.reduce(UInt64(0)) { $0 + headerSize($1.payloadSize) + $1.payloadSize }
            + headerSize(dataSize)
        var newOffsets: [[UInt64]] = []
        for table in tables {
            newOffsets.append(table.sizes.map { size in defer { position += size }; return position })
        }

        // The new index.
        let scale = (from: timescale(sourceChildren), to: timescale(targetChildren))
        var moov: [Data] = []
        guard let targetHeader = targetChildren.first(where: { $0.type == "mvhd" }),
              let sourceHeader = sourceChildren.first(where: { $0.type == "mvhd" })
        else { throw Boxes.damaged }
        var header = targetHeader.payload
        copyDates(from: sourceHeader.payload, to: &header)
        header.set(uint32: nextID, at: header.count - 4)
        moov.append(Boxes.make("mvhd", header))
        moov += targetChildren.filter { $0.type == "iods" }.map(\.bytes)
        for track in targetTracks {
            let old = ids.first { $0.value == trackID(track) }.map(\.key)
            let original = sourceTracks.first { trackID($0) == old }
            moov.append(merge(track, from: original, ids: ids))
        }
        for (index, track) in extras.enumerated() {
            moov.append(try rewrite(track, ids: ids, scale: scale, offsets: newOffsets[index]))
        }
        for type in ["udta", "meta"] {
            if let box = sourceChildren.first(where: { $0.type == type })
                ?? targetChildren.first(where: { $0.type == type }) {
                moov.append(box.bytes)
            }
        }
        let handled: Set<String> = ["mvhd", "iods", "trak", "udta", "meta"]
        moov += sourceChildren.filter { !handled.contains($0.type) }.map(\.bytes)
        let newMoov = Boxes.container("moov", moov)

        // Write the file.
        try? FileManager.default.removeItem(at: output)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let out = try FileHandle(forWritingTo: output)
        defer { try? out.close() }
        let fromEncoded = try FileHandle(forReadingFrom: encoded)
        defer { try? fromEncoded.close() }
        let fromOriginal = try FileHandle(forReadingFrom: original)
        defer { try? fromOriginal.close() }

        try copy(fromEncoded, 0, kept.reduce(UInt64(0)) { $0 + $1.size }, to: out)
        for box in extraTop {
            try out.write(contentsOf: boxHeader(box.type, payload: box.payloadSize))
            try copy(fromOriginal, box.payloadOffset, box.payloadSize, to: out)
        }
        try out.write(contentsOf: boxHeader("mdat", payload: dataSize))
        for table in tables {
            for (offset, size) in zip(table.offsets, table.sizes) {
                try copy(fromOriginal, offset, size, to: out)
            }
        }
        try out.write(contentsOf: newMoov)
    }

    /// What of `original` is missing in `output`. Empty when nothing is lost.
    public static func differences(original: URL, output: URL) throws -> [String] {
        let source = try MovieFile(url: original)
        let target = try MovieFile(url: output)
        guard let sourceMoov = source.moov, let targetMoov = target.moov else {
            return ["the movie index"]
        }
        var missing: [String] = []

        // Compared by type and content: a header may be written another way.
        let theirs = try target.topLevel.filter { !standardTopBoxes.contains($0.type) }
            .map { [Data($0.type.utf8), try digest(output, $0.payloadOffset, $0.payloadSize)] }
        for box in try ownTopBoxes(source, original) {
            if try !theirs.contains([Data(box.type.utf8), digest(original, box.payloadOffset, box.payloadSize)]) {
                missing.append("the \(box.type) box")
            }
        }

        let sourceChildren = sourceMoov.children
        let targetChildren = targetMoov.children
        for box in sourceChildren where !["mvhd", "iods", "trak"].contains(box.type) {
            if !targetChildren.contains(box) {
                missing.append(box.type == "udta"
                               ? "the user data (\(box.children.map(\.type).joined(separator: " ")))"
                               : "the \(box.type) box")
            }
        }
        if let old = sourceChildren.first(where: { $0.type == "mvhd" }),
           let new = targetChildren.first(where: { $0.type == "mvhd" }),
           dates(old.payload) != dates(new.payload) {
            missing.append("the creation date of the movie")
        }

        let sourceTracks = sourceChildren.filter { $0.type == "trak" }
        let targetTracks = targetChildren.filter { $0.type == "trak" }
        for kind in encodedTracks {
            let from = sourceTracks.filter { $0.handler == kind }
            let to = targetTracks.filter { $0.handler == kind }
            for (old, new) in zip(from, to) {
                for type in ["udta", "meta"] {
                    if let box = old.child(type), new.child(type) != box {
                        missing.append("the \(type) of the \(kind) track")
                    }
                }
                if let hdlr = old.child("mdia", "hdlr"), new.child("mdia", "hdlr") != hdlr {
                    missing.append("the handler name of the \(kind) track")
                }
                if let mdhd = old.child("mdia", "mdhd")?.payload,
                   language(mdhd) != new.child("mdia", "mdhd").flatMap({ language($0.payload) }) {
                    missing.append("the language of the \(kind) track")
                }
            }
        }
        var candidates = targetTracks.filter { !encodedTracks.contains($0.handler ?? "") }
        for track in sourceTracks where !encodedTracks.contains(track.handler ?? "") {
            let name = "the \(track.handler ?? "?") track (\(format(track)))"
            guard let index = candidates.firstIndex(where: { sameSamples($0, track) }) else {
                missing.append(name)
                continue
            }
            let copy = candidates.remove(at: index)
            if try sampleDigest(original, track) != sampleDigest(output, copy) {
                missing.append("the data of " + name)
            }
        }
        return missing
    }

    // MARK: - Location in user data

    /// The position written as ©xyz (QuickTime) or loci (3GPP) in the user data, as
    /// Android phones and some cameras and drones do. Apple's frameworks do not read it.
    public static func userDataLocation(_ url: URL) -> (latitude: Double, longitude: Double)? {
        guard let udta = (try? MovieFile(url: url))?.moov?.child("udta") else { return nil }
        for box in udta.children {
            let payload = box.payload
            if box.type == "©xyz", payload.count > 4 {
                let length = Int(payload.uint16(at: 0))
                let text = payload.subdata(in: 4..<min(payload.count, 4 + length))
                if let string = String(data: text, encoding: .utf8),
                   let place = ISO6709.parse(string) { return place }
            }
            if box.type == "loci", payload.count > 6,
               let end = payload[(payload.startIndex + 6)...].firstIndex(of: 0) {
                let at = end - payload.startIndex + 2  // after the name and the role
                guard payload.count >= at + 8 else { continue }
                let longitude = Double(Int32(bitPattern: payload.uint32(at: at))) / 65536
                let latitude = Double(Int32(bitPattern: payload.uint32(at: at + 4))) / 65536
                if abs(latitude) <= 90, abs(longitude) <= 180 { return (latitude, longitude) }
            }
        }
        return nil
    }

    // MARK: - Tracks

    private static func trackID(_ trak: RawBox) -> UInt32 {
        guard let tkhd = trak.child("tkhd")?.payload, tkhd.count >= 24 else { return 0 }
        return tkhd.uint32(at: tkhd[tkhd.startIndex] == 1 ? 20 : 12)
    }

    private static func format(_ trak: RawBox) -> String {
        guard let stsd = trak.child("mdia", "minf", "stbl", "stsd")?.payload, stsd.count >= 16
        else { return "?" }
        return stsd.fourCC(at: 12)
    }

    private static func timescale(_ moov: [RawBox]) -> UInt32 {
        guard let mvhd = moov.first(where: { $0.type == "mvhd" })?.payload, mvhd.count >= 24
        else { return 600 }
        return mvhd.uint32(at: mvhd[mvhd.startIndex] == 1 ? 20 : 12)
    }

    /// Same descriptions, sizes and times of the samples.
    private static func sameSamples(_ a: RawBox, _ b: RawBox) -> Bool {
        ["stsd", "stts", "stsz"].allSatisfy {
            a.child("mdia", "minf", "stbl", $0) == b.child("mdia", "minf", "stbl", $0)
        }
    }

    private struct ChunkTable {
        let offsets: [UInt64]
        let sizes: [UInt64]
    }

    /// Where the data of a track is, chunk by chunk.
    private static func chunks(_ trak: RawBox) throws -> ChunkTable {
        guard let stbl = trak.child("mdia", "minf", "stbl") else { throw Boxes.damaged }
        var offsets: [UInt64] = []
        if let stco = stbl.child("stco")?.payload {
            guard stco.count >= 8 else { throw Boxes.damaged }
            let count = Int(stco.uint32(at: 4))
            guard stco.count >= 8 + 4 * count else { throw Boxes.damaged }
            offsets = (0..<count).map { UInt64(stco.uint32(at: 8 + 4 * $0)) }
        } else if let co64 = stbl.child("co64")?.payload {
            guard co64.count >= 8 else { throw Boxes.damaged }
            let count = Int(co64.uint32(at: 4))
            guard co64.count >= 8 + 8 * count else { throw Boxes.damaged }
            offsets = (0..<count).map { co64.uint64(at: 8 + 8 * $0) }
        } else if stbl.child("stsz") != nil {
            throw MediaError.unsupported("a track without chunk offsets")
        }
        guard let stsz = stbl.child("stsz")?.payload, stsz.count >= 12 else {
            if offsets.isEmpty { return ChunkTable(offsets: [], sizes: []) }
            throw MediaError.unsupported("a track with compact sample sizes")
        }
        let fixed = UInt64(stsz.uint32(at: 4))
        let sampleCount = Int(stsz.uint32(at: 8))
        guard fixed != 0 || stsz.count >= 12 + 4 * sampleCount else { throw Boxes.damaged }
        let sampleSize = { (index: Int) -> UInt64 in
            fixed != 0 ? fixed : UInt64(stsz.uint32(at: 12 + 4 * index))
        }
        guard let stsc = stbl.child("stsc")?.payload, stsc.count >= 8 else { throw Boxes.damaged }
        let runs = Int(stsc.uint32(at: 4))
        guard stsc.count >= 8 + 12 * runs else { throw Boxes.damaged }
        let firstChunks = (0..<runs).map { Int(stsc.uint32(at: 8 + 12 * $0)) }
        let perChunk = (0..<runs).map { Int(stsc.uint32(at: 12 + 12 * $0)) }

        var sizes: [UInt64] = []
        var sample = 0
        var run = 0
        for chunk in 1...max(offsets.count, 1) where !offsets.isEmpty {
            while run + 1 < runs && firstChunks[run + 1] <= chunk { run += 1 }
            let count = runs > 0 ? perChunk[run] : 0
            guard sample + count <= sampleCount else { throw Boxes.damaged }
            sizes.append((sample..<sample + count).reduce(0) { $0 + sampleSize($1) })
            sample += count
        }
        guard sample == sampleCount else { throw Boxes.damaged }
        return ChunkTable(offsets: offsets, sizes: sizes)
    }

    /// An encoded track, with the user data, metadata and references of the original track.
    private static func merge(_ track: RawBox, from original: RawBox?, ids: [UInt32: UInt32]) -> Data {
        guard let original else { return track.bytes }
        // The original's boxes replace the encoder's; the encoder's stay when the original has none.
        let replaced = Set(["udta", "meta", "tref"].filter { original.child($0) != nil })
        var children = track.children.filter { !replaced.contains($0.type) }.map { box in
            switch box.type {
            case "tkhd":
                var payload = box.payload
                if let old = original.child("tkhd") { copyDates(from: old.payload, to: &payload) }
                return Boxes.make("tkhd", payload)
            case "mdia":
                return Boxes.container("mdia", box.children.map { inner in
                    switch inner.type {
                    case "mdhd":
                        guard let old = original.child("mdia", "mdhd") else { return inner.bytes }
                        var payload = inner.payload
                        copyDates(from: old.payload, to: &payload)
                        copyLanguage(from: old.payload, to: &payload)
                        return Boxes.make("mdhd", payload)
                    case "hdlr":
                        // The handler name, such as "GoPro AVC".
                        return original.child("mdia", "hdlr")?.bytes ?? inner.bytes
                    default:
                        return inner.bytes
                    }
                })
            default:
                return box.bytes
            }
        }
        if let tref = original.child("tref"), let mapped = references(tref, ids: ids) {
            children.insert(mapped, at: min(1, children.count))  // after tkhd
        }
        children += ["udta", "meta"].compactMap { original.child($0)?.bytes }
        return Boxes.container("trak", children)
    }

    /// A copied track, with its new identifier, references, durations and data offsets.
    private static func rewrite(_ box: RawBox, ids: [UInt32: UInt32], scale: (from: UInt32, to: UInt32),
                                offsets: [UInt64]) throws -> Data {
        switch box.type {
        case "trak", "mdia", "minf", "stbl", "edts":
            let (children, rest) = Boxes.split(box.payload)
            return Boxes.container(box.type, try children.compactMap { child in
                if child.type == "tref" { return references(child, ids: ids) }
                return try rewrite(child, ids: ids, scale: scale, offsets: offsets)
            }, rest: rest)
        case "tkhd":
            var payload = box.payload
            guard !payload.isEmpty else { throw Boxes.damaged }
            let long = payload[payload.startIndex] == 1
            guard payload.count >= (long ? 36 : 24) else { throw Boxes.damaged }
            let id = payload.uint32(at: long ? 20 : 12)
            payload.set(uint32: ids[id] ?? id, at: long ? 20 : 12)
            if long {
                payload.set(uint64: rescale(payload.uint64(at: 28), scale), at: 28)
            } else {
                payload.set(uint32: UInt32(clamping: rescale(UInt64(payload.uint32(at: 20)), scale)), at: 20)
            }
            return Boxes.make("tkhd", payload)
        case "elst":
            var payload = box.payload
            guard payload.count >= 8 else { throw Boxes.damaged }
            let long = payload[payload.startIndex] == 1
            let entry = long ? 20 : 12
            for index in 0..<min(Int(payload.uint32(at: 4)), (payload.count - 8) / entry) {
                let at = 8 + entry * index
                if long {
                    payload.set(uint64: rescale(payload.uint64(at: at), scale), at: at)
                } else {
                    payload.set(uint32: UInt32(clamping: rescale(UInt64(payload.uint32(at: at)), scale)), at: at)
                }
            }
            return Boxes.make("elst", payload)
        case "stco", "co64":
            var payload = Data([0, 0, 0, 0])
            payload.append(uint32: UInt32(offsets.count))
            let large = offsets.contains { $0 > UInt64(UInt32.max) }
            for offset in offsets {
                if large { payload.append(uint64: offset) } else { payload.append(uint32: UInt32(offset)) }
            }
            return Boxes.make(large ? "co64" : "stco", payload)
        default:
            return box.bytes
        }
    }

    /// A `tref` box with the new track identifiers. References to tracks that are not in
    /// the new file are dropped.
    private static func references(_ tref: RawBox, ids: [UInt32: UInt32]) -> Data? {
        let kinds = tref.children.compactMap { kind -> Data? in
            let payload = kind.payload
            let targets = (0..<payload.count / 4).compactMap { ids[payload.uint32(at: 4 * $0)] }
            guard !targets.isEmpty else { return nil }
            var mapped = Data()
            targets.forEach { mapped.append(uint32: $0) }
            return Boxes.make(kind.type, mapped)
        }
        return kinds.isEmpty ? nil : Boxes.container("tref", kinds)
    }

    private static func rescale(_ value: UInt64, _ scale: (from: UInt32, to: UInt32)) -> UInt64 {
        guard scale.from != 0, scale.from != scale.to, value != UInt64.max, value != UInt64(UInt32.max)
        else { return value }
        let scaled = (Double(value) * Double(scale.to) / Double(scale.from)).rounded()
        return scaled < Double(UInt64.max) ? UInt64(scaled) : UInt64.max
    }

    // MARK: - Language in mdhd

    /// Where the language code is in an mdhd payload: after the dates, time scale and duration.
    private static func languageOffset(_ payload: Data) -> Int? {
        guard !payload.isEmpty else { return nil }
        let offset = payload[payload.startIndex] == 1 ? 32 : 20
        return payload.count >= offset + 2 ? offset : nil
    }

    private static func language(_ payload: Data) -> UInt16? {
        languageOffset(payload).map { payload.uint16(at: $0) }
    }

    private static func copyLanguage(from source: Data, to target: inout Data) {
        guard let value = language(source), let offset = languageOffset(target) else { return }
        target[target.startIndex + offset] = UInt8(value >> 8)
        target[target.startIndex + offset + 1] = UInt8(value & 0xFF)
    }

    // MARK: - Dates in mvhd, tkhd and mdhd

    /// Creation and modification dates of a full box, in seconds since 1904.
    private static func dates(_ payload: Data) -> [UInt64] {
        guard payload.count >= 20 else { return [] }
        return payload[payload.startIndex] == 1
            ? [payload.uint64(at: 4), payload.uint64(at: 12)]
            : [UInt64(payload.uint32(at: 4)), UInt64(payload.uint32(at: 8))]
    }

    private static func copyDates(from source: Data, to target: inout Data) {
        let values = dates(source)
        guard values.count == 2, target.count >= 20 else { return }
        if target[target.startIndex] == 1 {
            target.set(uint64: values[0], at: 4)
            target.set(uint64: values[1], at: 12)
        } else if values.allSatisfy({ $0 <= UInt64(UInt32.max) }) {
            target.set(uint32: UInt32(values[0]), at: 4)
            target.set(uint32: UInt32(values[1]), at: 8)
        }
    }

    // MARK: - Files

    private static func copy(_ from: FileHandle, _ offset: UInt64, _ size: UInt64, to out: FileHandle) throws {
        try from.seek(toOffset: offset)
        var left = size
        while left > 0 {
            let block = try from.read(upToCount: Int(min(left, 4 << 20))) ?? Data()
            guard !block.isEmpty else { throw Boxes.damaged }
            try out.write(contentsOf: block)
            left -= UInt64(block.count)
        }
    }

    private static func digest(_ url: URL, _ offset: UInt64, _ size: UInt64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        try handle.seek(toOffset: offset)
        var left = size
        while left > 0 {
            let block = try handle.read(upToCount: Int(min(left, 4 << 20))) ?? Data()
            guard !block.isEmpty else { throw Boxes.damaged }
            hash.update(data: block)
            left -= UInt64(block.count)
        }
        return Data(hash.finalize())
    }

    /// One hash of all the sample data of a track, in order.
    private static func sampleDigest(_ url: URL, _ trak: RawBox) throws -> Data {
        let table = try chunks(trak)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        for (offset, size) in zip(table.offsets, table.sizes) {
            try handle.seek(toOffset: offset)
            var left = size
            while left > 0 {
                let block = try handle.read(upToCount: Int(min(left, 4 << 20))) ?? Data()
                guard !block.isEmpty else { throw Boxes.damaged }
                hash.update(data: block)
                left -= UInt64(block.count)
            }
        }
        return Data(hash.finalize())
    }
}
