import AVFoundation
import CoreLocation
import Foundation
import Photos

/// What the pipeline needs from a photo library. The tests use a fake one.
public protocol VideoLibrary: Sendable {
    func listVideos() async throws -> [VideoItem]
    /// Write the original file into `directory`. Downloads it from iCloud if needed.
    func downloadOriginal(_ item: VideoItem, to directory: URL,
                          progress: @escaping @Sendable (Double) -> Void) async throws -> URL
    /// Add the new file to the library, with the date, place, favorite flag
    /// and albums of the original. Returns the identifier of the new video.
    func importReplacement(file: URL, for item: VideoItem) async throws -> String
    func exists(_ id: String) -> Bool
    /// True when the video is in the iCloud Shared Library. nil when unknown.
    func inSharedLibrary(_ id: String) -> Bool?
    /// Add videos to the album with this title, made when missing. Returns how many were
    /// not in it yet.
    @discardableResult
    func addToAlbum(_ ids: [String], albumTitle: String) async throws -> Int
    /// Take videos out of every album with this title.
    func removeFromAlbum(_ ids: [String], albumTitle: String) async throws
    /// Move videos to Recently Deleted. macOS asks the user to confirm.
    func delete(_ ids: [String]) async throws
}

public enum LibraryError: LocalizedError {
    case notFound
    case noVideoResource
    case importFailed

    public var errorDescription: String? {
        switch self {
        case .notFound: return "The video is no longer in the Photos library"
        case .noVideoResource: return "Photos has no original file for this video"
        case .importFailed: return "Photos did not create the new video"
        }
    }
}

/// The real Photos library, through PhotoKit.
public final class PhotoKitLibrary: VideoLibrary, @unchecked Sendable {
    public init() {}

    public static func requestAccess() async -> Bool {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite) == .authorized
    }

    public func listVideos() async throws -> [VideoItem] {
        await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.includeAssetSourceTypes = [.typeUserLibrary]  // no shared albums
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            Self.fetchCameraInBatch(options)
            let assets = PHAsset.fetchAssets(with: .video, options: options)
            let parked = Self.identifiers(inAlbum: Pipeline.albumTitle)

            var items: [VideoItem] = []
            items.reserveCapacity(assets.count)
            assets.enumerateObjects { asset, _, _ in
                let resources = PHAssetResource.assetResources(for: asset)
                guard let video = resources.first(where: { $0.type == .video }) else { return }
                items.append(VideoItem(
                    id: asset.localIdentifier,
                    filename: video.originalFilename,
                    creationDate: asset.creationDate,
                    duration: asset.duration,
                    width: asset.pixelWidth,
                    height: asset.pixelHeight,
                    fileSize: Self.fileSize(video),
                    skipReason: parked.contains(asset.localIdentifier)
                        ? "Waits for deletion in the album \"\(Pipeline.albumTitle)\""
                        : Self.skipReason(asset, resources),
                    device: Self.camera(asset),
                    inSharedLibrary: Self.inSharedLibrary(asset)))
            }
            return items
        }.value
    }

    /// The album is shared through iCloud, but each device keeps its own records.
    /// Without this, another device would re-encode an original that waits for deletion.
    private static func identifiers(inAlbum title: String) -> Set<String> {
        var identifiers = Set<String>()
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            .enumerateObjects { album, _, _ in
                guard album.localizedTitle == title else { return }
                PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { asset, _, _ in
                    identifiers.insert(asset.localIdentifier)
                }
            }
        return identifiers
    }

    /// Kinds of video where a re-import would lose something.
    private static func skipReason(_ asset: PHAsset, _ resources: [PHAssetResource]) -> String? {
        let edited = resources.contains {
            $0.type == .adjustmentData || $0.type == .fullSizeVideo
                || $0.type == .adjustmentBaseVideo
        }
        if edited { return "Edited in Photos (the edits would be lost)" }
        let subtypes = asset.mediaSubtypes
        if subtypes.contains(.videoHighFrameRate) { return "Slow motion video" }
        if subtypes.contains(.videoTimelapse) { return "Time-lapse video" }
        if subtypes.contains(.videoCinematic) { return "Cinematic video" }
        if subtypes.contains(.spatialMedia) { return "Spatial video" }
        return nil
    }

    /// PhotoKit has no public way to ask for the size of the original file.
    /// This key is not documented, but it has been stable for years. If it
    /// goes away the size is 0 and the video is simply left alone.
    private static func fileSize(_ resource: PHAssetResource) -> Int64 {
        guard resource.responds(to: NSSelectorFromString("fileSize")) else { return 0 }
        return (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
    }

    // PhotoKit has no public way to ask for the camera either. These keys are not
    // documented: they hold what the Info panel of Photos shows. If they go away the
    // camera is simply unknown.
    private static let cameraKey = "photosInfoPanelExtendedProperties"

    /// Read the camera with the fetch: one query in all instead of one per video.
    private static func fetchCameraInBatch(_ options: PHFetchOptions) {
        let add = NSSelectorFromString("addFetchPropertySets:")
        guard let properties = NSClassFromString("PHAssetPhotosInfoPanelExtendedProperties") as AnyObject?,
              properties.responds(to: NSSelectorFromString("propertySetName")),
              let set = properties.value(forKey: "propertySetName") as? String,
              options.responds(to: add)
        else { return }
        _ = options.perform(add, with: [set])
    }

    private static func camera(_ asset: PHAsset) -> String? {
        guard asset.responds(to: NSSelectorFromString(cameraKey)),
              let info = asset.value(forKey: cameraKey) as? NSObject
        else { return nil }
        func text(_ key: String) -> String? {
            guard info.responds(to: NSSelectorFromString(key)),
                  let value = info.value(forKey: key) as? String
            else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let formatted = text("formattedCameraModel") { return formatted }
        let parts = [text("cameraMake"), text("cameraModel")].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // PhotoKit has no public way to tell the Shared Library from the Personal Library.
    // This key is not documented. Without it the library is unknown, and nothing is
    // held back for it.
    private static func inSharedLibrary(_ asset: PHAsset) -> Bool? {
        let key = "participatesInLibraryScope"
        guard asset.responds(to: NSSelectorFromString(key)) else { return nil }
        return (asset.value(forKey: key) as? NSNumber)?.boolValue
    }

    public func inSharedLibrary(_ id: String) -> Bool? {
        guard let asset = try? asset(id) else { return nil }
        return Self.inSharedLibrary(asset)
    }

    private static func album(titled title: String) -> PHAssetCollection? {
        var found: PHAssetCollection?
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            .enumerateObjects { album, _, stop in
                if album.localizedTitle == title {
                    found = album
                    stop.pointee = true
                }
            }
        return found
    }

    private func asset(_ id: String) throws -> PHAsset {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        else { throw LibraryError.notFound }
        return asset
    }

    public func downloadOriginal(_ item: VideoItem, to directory: URL,
                                 progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let asset = try asset(item.id)
        guard let resource = PHAssetResource.assetResources(for: asset)
            .first(where: { $0.type == .video })
        else { throw LibraryError.noVideoResource }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(resource.originalFilename)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true  // download from iCloud when needed
        options.progressHandler = { progress($0) }
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: url,
                                                             options: options)
        return url
    }

    public func importReplacement(file: URL, for item: VideoItem) async throws -> String {
        let original = try asset(item.id)

        var albums: [PHAssetCollection] = []
        PHAssetCollection.fetchAssetCollectionsContaining(original, with: .album, options: nil)
            .enumerateObjects { album, _, _ in
                if album.canPerform(.addContent) { albums.append(album) }
            }
        let targets = albums
        let created = Box("")
        // An app can only add to the Personal Library. The person moves the new video to the
        // Shared Library from this album; until then the original is not deleted.
        let toMove = Self.inSharedLibrary(original) == true
        let moveAlbum = toMove ? Self.album(titled: Pipeline.moveAlbumTitle) : nil

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = file.lastPathComponent
            request.addResource(with: .video, fileURL: file, options: options)
            request.creationDate = original.creationDate
            request.location = original.location
            request.isFavorite = original.isFavorite

            guard let placeholder = request.placeholderForCreatedAsset else { return }
            created.value = placeholder.localIdentifier
            for album in targets {
                PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
            }
            if toMove {
                let request = moveAlbum.flatMap { PHAssetCollectionChangeRequest(for: $0) }
                    ?? PHAssetCollectionChangeRequest.creationRequestForAssetCollection(
                        withTitle: Pipeline.moveAlbumTitle)
                request.addAssets([placeholder] as NSArray)
            }
        }
        guard !created.value.isEmpty else { throw LibraryError.importFailed }
        return created.value
    }

    public func exists(_ id: String) -> Bool {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).count > 0
    }

    /// The camera named in each original file, for the videos whose original is on this
    /// device; "" when the file names none. Nothing is downloaded: the others are left out.
    public func cameraNames(_ ids: [String]) async -> [String: String] {
        var assets: [PHAsset] = []
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            .enumerateObjects { asset, _, _ in assets.append(asset) }
        var names: [String: String] = [:]
        for asset in assets {
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = false
            options.version = .original
            options.deliveryMode = .highQualityFormat
            // The file is read while Photos keeps it open for us, in the handler.
            let name: String? = await withCheckedContinuation { continuation in
                PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { video, _, _ in
                    continuation.resume(returning: (video as? AVURLAsset).map {
                        CameraName.fromFile($0.url) ?? ""
                    })
                }
            }
            if let name { names[asset.localIdentifier] = name }
        }
        return names
    }

    /// For watching a video. Streams it from iCloud when the original is not on this device.
    public func playerItem(for id: String) async throws -> AVPlayerItem {
        let video = try asset(id)
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic
        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestPlayerItem(forVideo: video, options: options) { item, info in
                if let item {
                    continuation.resume(returning: item)
                } else {
                    continuation.resume(throwing: info?[PHImageErrorKey] as? Error
                                        ?? LibraryError.noVideoResource)
                }
            }
        }
    }

    @discardableResult
    public func addToAlbum(_ ids: [String], albumTitle: String) async throws -> Int {
        let existing = Self.album(titled: albumTitle)
        var inAlbum = Set<String>()
        if let existing {
            PHAsset.fetchAssets(in: existing, options: nil).enumerateObjects { asset, _, _ in
                inAlbum.insert(asset.localIdentifier)
            }
        }
        let missing = PHAsset.fetchAssets(
            withLocalIdentifiers: ids.filter { !inAlbum.contains($0) }, options: nil)
        guard missing.count > 0 else { return 0 }

        try await PHPhotoLibrary.shared().performChanges {
            let request: PHAssetCollectionChangeRequest?
            if let existing {
                request = PHAssetCollectionChangeRequest(for: existing)
            } else {
                request = PHAssetCollectionChangeRequest
                    .creationRequestForAssetCollection(withTitle: albumTitle)
            }
            request?.addAssets(missing)
        }
        return missing.count
    }

    public func removeFromAlbum(_ ids: [String], albumTitle: String) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard assets.count > 0 else { return }
        var albums: [PHAssetCollection] = []  // two devices may each have made one
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            .enumerateObjects { album, _, _ in
                if album.localizedTitle == albumTitle { albums.append(album) }
            }
        guard !albums.isEmpty else { return }
        let targets = albums
        try await PHPhotoLibrary.shared().performChanges {
            for album in targets {
                PHAssetCollectionChangeRequest(for: album)?.removeAssets(assets)
            }
        }
    }

    public func delete(_ ids: [String]) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }
}

extension PhotoKitLibrary: IdentifierMapping {
    public func cloudIdentifiers(for localIdentifiers: [String]) -> [String: String] {
        guard !localIdentifiers.isEmpty else { return [:] }
        return PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: localIdentifiers)
            .compactMapValues { try? $0.get().stringValue }
    }

    public func localIdentifiers(for cloudIdentifiers: [String]) -> [String: String] {
        guard !cloudIdentifiers.isEmpty else { return [:] }
        var result: [String: String] = [:]
        let mappings = PHPhotoLibrary.shared().localIdentifierMappings(
            for: cloudIdentifiers.map(PHCloudIdentifier.init(stringValue:)))
        for (cloud, local) in mappings {
            if let local = try? local.get() { result[cloud.stringValue] = local }
        }
        return result
    }
}

// MARK: - Adding new videos (used by the iPad app)

/// Something that can receive a finished video. The tests use a fake one.
public protocol PhotoSink: Sendable {
    /// Add a video file to the photo library. The file is moved, not copied.
    func add(file: URL, creationDate: Date?, latitude: Double?,
             longitude: Double?) async throws -> String
}

/// Adds videos to Photos. Needs only the "add" permission: the app cannot
/// see or change the photos that are already in the library.
public final class PhotoKitSink: PhotoSink, @unchecked Sendable {
    public init() {}

    public static func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }

    public func add(file: URL, creationDate: Date?, latitude: Double?,
                    longitude: Double?) async throws -> String {
        let created = Box("")
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = file.lastPathComponent
            options.shouldMoveFile = true
            request.addResource(with: .video, fileURL: file, options: options)
            if let creationDate {
                request.creationDate = creationDate
            }
            if let latitude, let longitude {
                request.location = CLLocation(latitude: latitude, longitude: longitude)
            }
            created.value = request.placeholderForCreatedAsset?.localIdentifier ?? ""
        }
        guard !created.value.isEmpty else { throw LibraryError.importFailed }
        return created.value
    }
}
