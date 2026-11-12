import Foundation

/// The top-level boxes of a QuickTime or MP4 file, and its `moov` box. The media data
/// is never loaded.
struct MovieFile {
    struct TopBox {
        let type: String
        let offset: UInt64
        let size: UInt64
        let headerSize: UInt64

        var payloadOffset: UInt64 { offset + headerSize }
        var payloadSize: UInt64 { size - headerSize }
    }

    let topLevel: [TopBox]
    /// The whole `moov` box, header included.
    let moov: RawBox?

    init(url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        var boxes: [TopBox] = []
        var moov: RawBox?
        var offset: UInt64 = 0
        while offset + 8 <= length {
            try handle.seek(toOffset: offset)
            let header = try handle.read(upToCount: 16) ?? Data()
            guard header.count >= 8 else { break }
            var size = UInt64(header.uint32(at: 0))
            var headerSize: UInt64 = 8
            if size == 1 {
                guard header.count >= 16 else { throw Boxes.damaged }
                size = header.uint64(at: 8)
                headerSize = 16
            } else if size == 0 {
                size = length - offset  // runs to the end of the file
            }
            guard size >= headerSize, size <= length - offset else { throw Boxes.damaged }
            let type = header.fourCC(at: 4)
            boxes.append(TopBox(type: type, offset: offset, size: size, headerSize: headerSize))
            if type == "moov" {
                try handle.seek(toOffset: offset)
                let bytes = try handle.read(upToCount: Int(size)) ?? Data()
                moov = RawBox(type: type, bytes: Data(bytes), header: Int(headerSize))
            }
            offset += size
        }
        topLevel = boxes
        self.moov = moov
    }
}

/// One box, held in memory. `bytes` is the whole box, header included, indexed from 0.
struct RawBox: Equatable {
    let type: String
    let bytes: Data
    let header: Int

    var payload: Data { bytes.subdata(in: header..<bytes.count) }

    /// The boxes inside, for container boxes.
    var children: [RawBox] { Boxes.split(payload).boxes }

    func child(_ path: String...) -> RawBox? {
        var current: RawBox? = self
        for type in path { current = current?.children.first { $0.type == type } }
        return current
    }

    /// The handler type of a `trak` (through `mdia`) or of a `meta` box: "vide", "soun", "mdta"…
    var handler: String? {
        if type == "trak" { return child("mdia")?.handler }
        var inner = payload
        // An ISO `meta` box starts with 4 bytes of version and flags, a QuickTime one does not.
        if type == "meta", inner.count >= 8, inner.fourCC(at: 4) != "hdlr" {
            inner = inner.subdata(in: 4..<inner.count)
        }
        guard let hdlr = Boxes.split(inner).boxes.first(where: { $0.type == "hdlr" }),
              hdlr.payload.count >= 12
        else { return nil }
        return hdlr.payload.fourCC(at: 8)
    }
}

enum Boxes {
    static let damaged = MediaError.unsupported("damaged file structure")

    /// The boxes one after the other in `data`. QuickTime ends some lists with a few zero
    /// bytes: what is too short for a box is returned as `rest`.
    static func split(_ data: Data) -> (boxes: [RawBox], rest: Data) {
        let data = Data(data)
        var boxes: [RawBox] = []
        var offset = 0
        while data.count - offset >= 8 {
            var size = Int(data.uint32(at: offset))
            var header = 8
            if size == 1 {
                guard data.count - offset >= 16 else { break }
                size = Int(clamping: data.uint64(at: offset + 8))
                header = 16
            } else if size == 0 {
                size = data.count - offset
            }
            guard size >= header, size <= data.count - offset else { break }
            boxes.append(RawBox(type: data.fourCC(at: offset + 4),
                                bytes: data.subdata(in: offset..<offset + size), header: header))
            offset += size
        }
        return (boxes, data.subdata(in: offset..<data.count))
    }

    /// A box with this type and payload.
    static func make(_ type: String, _ payload: Data) -> Data {
        var out = Data()
        if payload.count + 8 <= Int(UInt32.max) {
            out.append(uint32: UInt32(payload.count + 8))
            out.append(fourCC: type)
        } else {
            out.append(uint32: 1)
            out.append(fourCC: type)
            out.append(uint64: UInt64(payload.count + 16))
        }
        out.append(payload)
        return out
    }

    /// A container box made of these children.
    static func container(_ type: String, _ children: [Data], rest: Data = Data()) -> Data {
        make(type, children.reduce(into: Data()) { $0.append($1) } + rest)
    }
}

extension Data {
    func uint16(at offset: Int) -> UInt16 {
        let start = startIndex + offset
        return self[start..<start + 2].reduce(0) { $0 << 8 | UInt16($1) }
    }

    func uint32(at offset: Int) -> UInt32 {
        let start = startIndex + offset
        return self[start..<start + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    func uint64(at offset: Int) -> UInt64 {
        let start = startIndex + offset
        return self[start..<start + 8].reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// A box type. "©" (0xA9) is kept as is.
    func fourCC(at offset: Int) -> String {
        let start = startIndex + offset
        return String(bytes: self[start..<start + 4], encoding: .isoLatin1) ?? "????"
    }

    mutating func append(uint32 value: UInt32) {
        append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> (24 - 8 * $0)) })
    }

    mutating func append(uint64 value: UInt64) {
        append(contentsOf: (0..<8).map { UInt8(truncatingIfNeeded: value >> (56 - 8 * $0)) })
    }

    mutating func append(fourCC: String) {
        append(contentsOf: Array(fourCC.data(using: .isoLatin1) ?? Data("????".utf8)).prefix(4))
    }

    mutating func set(uint32 value: UInt32, at offset: Int) {
        for index in 0..<4 {
            self[startIndex + offset + index] = UInt8(truncatingIfNeeded: value >> (24 - 8 * index))
        }
    }

    mutating func set(uint64 value: UInt64, at offset: Int) {
        for index in 0..<8 {
            self[startIndex + offset + index] = UInt8(truncatingIfNeeded: value >> (56 - 8 * index))
        }
    }
}
