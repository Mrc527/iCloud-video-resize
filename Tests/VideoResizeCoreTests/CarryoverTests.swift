import XCTest
@testable import VideoResizeCore


/// Everything of the original must be in the new file.
final class CarryoverTests: TempDirectoryTestCase {
    func testEveryPartOfADroneVideoIsInTheNewFile() async throws {
        let source = temp.appendingPathComponent("DJI_0001.MOV")
        try await Sample.makeDroneVideo(at: source)
        let info = try await Probe.info(source)
        let destination = temp.appendingPathComponent("out").appendingPathComponent("DJI_0001.MOV")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        try await Reencode.run(NativeTranscoder(), source: source, destination: destination,
                               info: info, quality: .balanced) { _ in }
        try await Verifier.verify(source: info, output: destination, original: source, fullDecode: true)

        XCTAssertEqual(try Carryover.differences(original: source, output: destination), [])
        let new = try MovieFile(url: destination)
        let udta = try XCTUnwrap(new.moov?.child("udta"))
        XCTAssertEqual(Set(udta.children.map(\.type)), ["©xyz", "©mak", "©mod"])
        XCTAssertTrue(new.topLevel.contains { $0.type == "uuid" }, "the camera box")
        let place = try XCTUnwrap(Carryover.userDataLocation(destination))
        XCTAssertEqual(place.latitude, 46.0037, accuracy: 0.0001)
        XCTAssertEqual(place.longitude, 8.9511, accuracy: 0.0001)
        // The GPS track: the same number of positions, readable by AVFoundation.
        let before = try await Sample.timedPositions(in: source)
        let after = try await Sample.timedPositions(in: destination)
        XCTAssertEqual(after, before)
        XCTAssertEqual(after.count, 2)
    }

    func testTheCheckFindsWhatAPlainEncodeLoses() async throws {
        let source = temp.appendingPathComponent("DJI_0001.MOV")
        try await Sample.makeDroneVideo(at: source)
        let info = try await Probe.info(source)
        let plain = temp.appendingPathComponent("plain.mov")
        try await NativeTranscoder().transcode(source: source, destination: plain, info: info,
                                               quality: .balanced) { _ in }

        let missing = try Carryover.differences(original: source, output: plain).joined(separator: "; ")
        XCTAssertTrue(missing.contains("user data"), missing)
        XCTAssertTrue(missing.contains("meta track"), missing)
        XCTAssertTrue(missing.contains("uuid"), missing)
        XCTAssertTrue(missing.contains("creation date"), missing)
        do {
            try await Verifier.verify(source: info, output: plain, original: source, fullDecode: false)
            XCTFail("a file that loses data must not pass the check")
        } catch MediaError.verification {}
    }

    func testUncompressedAudioBecomesAAC() async throws {
        let silent = temp.appendingPathComponent("silent.MOV")
        try await Sample.makeVideo(at: silent)
        let source = temp.appendingPathComponent("C0001.MOV")
        try await Sample.addAudio(to: silent, output: source)  // a system sound: uncompressed
        let info = try await Probe.info(source)
        XCTAssertEqual(info.aacBitrates.count, 1)
        XCTAssertGreaterThan(info.aacBitrates.first ?? 0, 0, "the sound is uncompressed")
        let destination = temp.appendingPathComponent("out.MOV")

        try await Reencode.run(NativeTranscoder(), source: source, destination: destination,
                               info: info, quality: .balanced) { _ in }
        let output = try await Verifier.verify(source: info, output: destination, original: source,
                                               fullDecode: false)

        XCTAssertEqual(output.audioTrackCount, 1)
        XCTAssertEqual(output.aacBitrates, [0], "the new audio is compressed")
    }
}

final class CameraNameTests: TempDirectoryTestCase {
    func testNamesOfCamerasThatNameTheirFilesTheirOwnWay() {
        XCTAssertEqual(CameraName.fromName("GX012716.MP4"), "GoPro (from the name)")
        XCTAssertEqual(CameraName.fromName("GOPR0001.MP4"), "GoPro (from the name)")
        XCTAssertEqual(CameraName.fromName("dji_fly_20250928_173606_0013_video.mp4"), "DJI (from the name)")
        XCTAssertEqual(CameraName.fromName("DJI_0001.MP4"), "DJI (from the name)")
        XCTAssertNil(CameraName.fromName("IMG_1234.MOV"))
        XCTAssertNil(CameraName.fromName("GXAB12.MP4"))
    }

    func testTheCameraTagsOfTheFile() async throws {
        let url = temp.appendingPathComponent("DJI_0001.MOV")
        try await Sample.makeDroneVideo(at: url)
        XCTAssertEqual(CameraName.fromFile(url), "DJI Mini 4 Pro")
        let plain = temp.appendingPathComponent("plain.MOV")
        try await Sample.makeVideo(at: plain)
        XCTAssertNil(CameraName.fromFile(plain))
    }

    func testTheModelGoProWritesInGPMF() {
        // DEVC (nested) holding MINF, a 12-character text, as GoPro cameras write it.
        var minf = Data("MINF".utf8)
        minf.append(contentsOf: [UInt8(ascii: "c"), 1, 0, 12])
        minf.append(Data("HERO12 Black".utf8))
        var devc = Data("DEVC".utf8)
        devc.append(contentsOf: [0, 1, 0, UInt8(minf.count)])
        devc.append(minf)
        XCTAssertEqual(CameraName.gpmfString(devc, key: "MINF"), "HERO12 Black")
    }
}

/// The cases the review of Carryover found.
final class CarryoverEdgeTests: TempDirectoryTestCase {
    private func reencode(_ source: URL, name: String = "out.MOV") async throws -> URL {
        let info = try await Probe.info(source)
        let destination = temp.appendingPathComponent(name)
        try await Reencode.run(NativeTranscoder(), source: source, destination: destination,
                               info: info, quality: .balanced) { _ in }
        try await Verifier.verify(source: info, output: destination, original: source, fullDecode: false)
        return destination
    }

    private func tkhd(_ trak: RawBox) -> (id: UInt32, duration: UInt64) {
        let payload = trak.child("tkhd")!.payload
        return payload[payload.startIndex] == 1
            ? (payload.uint32(at: 20), payload.uint64(at: 28))
            : (payload.uint32(at: 12), UInt64(payload.uint32(at: 20)))
    }

    private func timescale(_ moov: RawBox) -> UInt64 {
        let mvhd = moov.child("mvhd")!.payload
        return UInt64(mvhd.uint32(at: mvhd[mvhd.startIndex] == 1 ? 20 : 12))
    }

    func testTheLanguageOfATrackIsKept() async throws {
        let source = temp.appendingPathComponent("IMG_0001.MOV")
        try await Sample.makeVideo(at: source, language: "ita")
        let output = try await reencode(source)
        let language = { (url: URL) in
            try MovieFile(url: url).moov?.children.first { $0.type == "trak" }?
                .child("mdia", "mdhd")?.payload.suffix(4).prefix(2)
        }
        XCTAssertEqual(try language(output), try language(source))

        let plain = temp.appendingPathComponent("plain.mov")
        try await NativeTranscoder().transcode(source: source, destination: plain,
                                               info: try await Probe.info(source), quality: .balanced) { _ in }
        XCTAssertTrue(try Carryover.differences(original: source, output: plain)
            .contains("the language of the vide track"))
    }

    func testHandlerNamesAreKept() async throws {
        guard let ffmpeg = FFmpegTranscoder.locate() else { throw XCTSkip("ffmpeg is not installed") }
        let source = temp.appendingPathComponent("GX010001.MP4")
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30",
                             "-f", "lavfi", "-i", "sine", "-t", "2", "-c:v", "libx264", "-b:v", "8M",
                             "-c:a", "aac", "-metadata:s:v:0", "handler_name=GoPro AVC",
                             "-metadata:s:a:0", "handler_name=GoPro AAC", source.path]
        try process.run()
        process.waitUntilExit()
        let output = try await reencode(source, name: "GX010001.MP4")
        let names = try MovieFile(url: output).moov!.children.filter { $0.type == "trak" }
            .compactMap { $0.child("mdia", "hdlr")?.payload }
        XCTAssertTrue(names.contains { $0.range(of: Data("GoPro AVC".utf8)) != nil })
        XCTAssertTrue(names.contains { $0.range(of: Data("GoPro AAC".utf8)) != nil })
    }

    func testZerosAtTheEndOfTheFileAreNoProblem() async throws {
        let source = temp.appendingPathComponent("C0001.MOV")
        try await Sample.makeVideo(at: source)
        let handle = try FileHandle(forWritingTo: source)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0, count: 4096))
        try handle.close()
        _ = try await reencode(source)
    }

    func testAFreeBoxThatHoldsDataIsKept() async throws {
        let source = temp.appendingPathComponent("C0001.MOV")
        try await Sample.makeVideo(at: source)
        let handle = try FileHandle(forWritingTo: source)
        try handle.seekToEnd()
        try handle.write(contentsOf: Boxes.make("free", Data("camera notes".utf8)))
        try handle.close()
        let output = try await reencode(source)
        XCTAssertNotNil(try Data(contentsOf: output).range(of: Data("camera notes".utf8)))
    }

    func testDataAtFixedPlacesKeepsTheOriginalAsItIs() async throws {
        let source = temp.appendingPathComponent("NVT_0001.MOV")
        try await Sample.makeVideo(at: source)
        // A dashcam's table of GPS blocks, found by their place in the file.
        try Sample.editMoov(source) { $0.map(\.bytes) + [Boxes.make("gps ", Data(count: 16))] }
        XCTAssertThrowsError(try Carryover.check(source)) { error in
            guard case MediaError.unsupported = error else { return XCTFail("\(error)") }
        }

        let sink = FakeSink()
        let importer = Importer(sink: sink, log: ImportLog(url: temp.appendingPathComponent("log.json")),
                                workDirectory: temp.appendingPathComponent("work"))
        let video = SourceVideo(url: source, filename: "NVT_0001.MOV",
                                fileSize: Int64(try Data(contentsOf: source).count), modified: nil)
        let entry = await importer.importVideo(video, settings: AppSettings()) { _, _ in }
        XCTAssertEqual(entry?.outcome, .original, entry?.detail ?? "")
        XCTAssertTrue(entry?.detail.contains("could not carry") ?? false, entry?.detail ?? "")
        XCTAssertEqual(sink.added.first?.size, video.fileSize, "the original file, unchanged")
    }

    func testOtherDataAtFixedPlacesIsFound() async throws {
        func refused(_ box: Data) async throws -> Bool {
            let url = temp.appendingPathComponent(UUID().uuidString + ".MOV")
            try await Sample.makeVideo(at: url)
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: box)
            try handle.close()
            do { try Carryover.check(url) } catch MediaError.unsupported { return true }
            return false
        }
        // A dashcam's GPS block, an item table with file offsets, a fragment.
        let gpsBlock = try await refused(Boxes.make("free", Data("GPS ".utf8) + Data(count: 32)))
        XCTAssertTrue(gpsBlock)
        var meta = Data(count: 4)
        meta.append(Boxes.make("iloc", Data(count: 8)))
        let itemTable = try await refused(Boxes.make("meta", meta))
        XCTAssertTrue(itemTable)
        let fragment = try await refused(Boxes.make("moof", Data(count: 8)))
        XCTAssertTrue(fragment)
        let camera = try await refused(Boxes.make("free", Data("camera notes".utf8)))
        XCTAssertFalse(camera, "an ordinary box with data is carried, not refused")
    }

    func testABrokenTrackFailsWithoutACrash() async throws {
        let source = temp.appendingPathComponent("DJI_0001.MOV")
        try await Sample.makeDroneVideo(at: source)
        // An edit list too short to hold its entry count, in the GPS track.
        try Sample.editMoov(source) { children in
            children.map { box in
                guard box.type == "trak", box.handler == "meta" else { return box.bytes }
                return Boxes.container("trak", box.children.map(\.bytes)
                    + [Boxes.container("edts", [Boxes.make("elst", Data(count: 4))])])
            }
        }
        do {
            _ = try await reencode(source)
            XCTFail("a broken track must not pass")
        } catch is MediaError {}
    }

    func testTrackNumbersAndTimeScaleAreRewritten() async throws {
        let source = temp.appendingPathComponent("DJI_0001.MOV")
        // GPS track first (number 1), movie time scale 1000: both differ in the new file.
        try await Sample.makeDroneVideo(at: source, movieTimeScale: 1000, positionTrackFirst: true)
        let output = try await reencode(source)

        let old = try XCTUnwrap(try MovieFile(url: source).moov)
        let new = try XCTUnwrap(try MovieFile(url: output).moov)
        let oldGPS = try XCTUnwrap(old.children.first { $0.type == "trak" && $0.handler == "meta" })
        let newGPS = try XCTUnwrap(new.children.first { $0.type == "trak" && $0.handler == "meta" })
        let newVideo = try XCTUnwrap(new.children.first { $0.type == "trak" && $0.handler == "vide" })
        XCTAssertEqual(tkhd(oldGPS).id, 1)
        XCTAssertNotEqual(timescale(old), timescale(new))

        // The GPS track still describes the video track, under its new number.
        let reference = try XCTUnwrap(newGPS.child("tref", "cdsc")?.payload)
        XCTAssertEqual(reference.uint32(at: 0), tkhd(newVideo).id)
        XCTAssertNotEqual(tkhd(newGPS).id, tkhd(newVideo).id)
        // Its length, in the time scale of the new movie.
        let expected = Double(tkhd(oldGPS).duration) * Double(timescale(new)) / Double(timescale(old))
        XCTAssertEqual(Double(tkhd(newGPS).duration), expected.rounded(), accuracy: 1)
        let before = try await Sample.timedPositions(in: source)
        let after = try await Sample.timedPositions(in: output)
        XCTAssertEqual(after, before)
    }
}
