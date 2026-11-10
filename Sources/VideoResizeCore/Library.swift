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
    /// Put the original in an album, where it waits for deletion.
    func park(original id: String, albumTitle: String) async throws
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
            let assets = PHAsset.fetchAssets(with: .video, options: options)

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
                    skipReason: Self.skipReason(asset, resources)))
            }
            return items
        }.value
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
        }
        guard !created.value.isEmpty else { throw LibraryError.importFailed }
        return created.value
    }

    public func exists(_ id: String) -> Bool {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).count > 0
    }

    public func park(original id: String, albumTitle: String) async throws {
        let original = try asset(id)

        var found: PHAssetCollection?
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            .enumerateObjects { album, _, stop in
                if album.localizedTitle == albumTitle {
                    found = album
                    stop.pointee = true
                }
            }
        let existing = found

        try await PHPhotoLibrary.shared().performChanges {
            let request: PHAssetCollectionChangeRequest?
            if let existing {
                request = PHAssetCollectionChangeRequest(for: existing)
            } else {
                request = PHAssetCollectionChangeRequest
                    .creationRequestForAssetCollection(withTitle: albumTitle)
            }
            request?.addAssets([original] as NSArray)
        }
    }

    public func delete(_ ids: [String]) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
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
