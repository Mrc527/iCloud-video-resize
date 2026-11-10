"""Access to the macOS Photos library (and so to iCloud Photos).

Reading uses osxphotos (reads the Photos database directly, fast).
Writing uses photoscript (drives Photos.app with AppleScript).
Deleting uses PhotoKit, because AppleScript cannot delete photos.

The Mac-only modules are imported lazily, so the rest of the code can be
tested on any system with a fake library.
"""

from __future__ import annotations

import logging
import shutil
import threading
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Protocol

log = logging.getLogger(__name__)

VIDEO_SUFFIXES = {".mov", ".mp4", ".m4v"}


@dataclass
class VideoAsset:
    uuid: str
    filename: str
    size: int
    date: datetime | None = None
    path: Path | None = None  # None when the original is only in iCloud
    title: str | None = None
    description: str | None = None
    keywords: list[str] = field(default_factory=list)
    favorite: bool = False
    album_uuids: list[str] = field(default_factory=list)
    location: tuple[float, float] | None = None
    skip_reason: str | None = None  # set for video types we never touch


class Library(Protocol):
    def list_videos(self) -> list[VideoAsset]: ...
    def fetch_original(self, asset: VideoAsset, dest_dir: Path) -> Path: ...
    def import_video(self, path: Path, asset: VideoAsset) -> str: ...
    def exists(self, uuid: str) -> bool: ...
    def add_to_album(self, uuid: str, album_name: str) -> None: ...
    def delete(self, uuids: list[str]) -> None: ...


def _skip_reason(photo) -> str | None:
    """Video types where a re-import would lose something."""
    checks = (
        ("hasadjustments", "edited in Photos (edit history would be lost)"),
        ("slow_mo", "slow motion video"),
        ("time_lapse", "time-lapse video"),
        ("shared", "in a shared album or shared library"),
        ("hidden", "hidden video"),
        ("isreference", "referenced file, not stored in the library"),
    )
    for attr, reason in checks:
        if getattr(photo, attr, False):
            return reason
    return None


class PhotosLibrary:
    """The real library. Works only on macOS, inside a logged-in user session."""

    def __init__(self, marker_keyword: str, export_timeout: int = 3600):
        self.marker_keyword = marker_keyword
        self.export_timeout = export_timeout
        try:
            import osxphotos
            import photoscript
        except ImportError as exc:
            raise RuntimeError(
                "osxphotos and photoscript are required and work only on macOS."
            ) from exc
        self._osxphotos = osxphotos
        self._ps = photoscript

    def list_videos(self) -> list[VideoAsset]:
        db = self._osxphotos.PhotosDB()
        assets = []
        for p in db.photos(images=False, movies=True):
            lat, lon = p.location if p.location else (None, None)
            path = Path(p.path) if p.path else None
            assets.append(VideoAsset(
                uuid=p.uuid,
                filename=p.original_filename,
                size=p.original_filesize or 0,
                date=p.date,
                path=path,
                title=p.title,
                description=p.description,
                keywords=list(p.keywords or []),
                favorite=bool(p.favorite),
                album_uuids=[a.uuid for a in p.album_info],
                location=(lat, lon) if lat is not None and lon is not None else None,
                skip_reason=_skip_reason(p),
            ))
        return assets

    def fetch_original(self, asset: VideoAsset, dest_dir: Path) -> Path:
        dest_dir.mkdir(parents=True, exist_ok=True)
        if asset.path and asset.path.exists():
            dest = dest_dir / asset.filename
            shutil.copy2(asset.path, dest)
            return dest

        # The original is only in iCloud: ask Photos to download and export it.
        log.info("Downloading %s from iCloud", asset.filename)
        exported = self._ps.Photo(asset.uuid).export(
            str(dest_dir), original=True, overwrite=True, timeout=self.export_timeout
        )
        for name in exported:
            candidate = dest_dir / Path(name).name
            if candidate.suffix.lower() in VIDEO_SUFFIXES and candidate.exists():
                return candidate
        raise RuntimeError(f"Photos did not export a video for {asset.filename}")

    def import_video(self, path: Path, asset: VideoAsset) -> str:
        lib = self._ps.PhotosLibrary()
        imported = lib.import_photos([str(path)], skip_duplicate_check=True)
        if len(imported) != 1:
            raise RuntimeError(f"Photos imported {len(imported)} items, expected 1")
        new = imported[0]

        # The marker keyword goes first: it stops us from re-encoding our own output.
        new.keywords = sorted(set(asset.keywords) | {self.marker_keyword})
        if asset.title:
            new.title = asset.title
        if asset.description:
            new.description = asset.description
        if asset.favorite:
            new.favorite = True

        # Date and GPS come from the file metadata. Fix them only if Photos got them wrong.
        if asset.date:
            wanted = asset.date.astimezone().replace(tzinfo=None)
            got = new.date
            if got is None or abs((got.replace(tzinfo=None) - wanted).total_seconds()) > 60:
                new.date = wanted
        if asset.location and new.location in (None, (None, None)):
            new.location = asset.location

        for album_uuid in asset.album_uuids:
            try:
                lib.album(uuid=album_uuid).add([new])
            except Exception as exc:  # an album we cannot write to (smart, shared...)
                log.warning("Could not add %s to album %s: %s", asset.filename, album_uuid, exc)
        return new.uuid

    def exists(self, uuid: str) -> bool:
        try:
            self._ps.Photo(uuid)
            return True
        except Exception:
            return False

    def add_to_album(self, uuid: str, album_name: str) -> None:
        lib = self._ps.PhotosLibrary()
        album = lib.album(album_name) or lib.create_album(album_name)
        album.add([self._ps.Photo(uuid)])

    def delete(self, uuids: list[str]) -> None:
        """Move assets to Recently Deleted. macOS shows one confirmation dialog."""
        import Photos  # pyobjc-framework-Photos, installed with osxphotos

        ids = [f"{u}/L0/001" for u in uuids]
        result = Photos.PHAsset.fetchAssetsWithLocalIdentifiers_options_(ids, None)
        if result.count() != len(ids):
            raise RuntimeError(
                f"PhotoKit found {result.count()} of {len(ids)} videos. "
                "Check that this program has full access to Photos in "
                "System Settings > Privacy & Security > Photos."
            )
        assets = [result.objectAtIndex_(i) for i in range(result.count())]
        done = threading.Event()
        outcome: dict = {}

        def change():
            Photos.PHAssetChangeRequest.deleteAssets_(assets)

        def completion(success, error):
            outcome["success"], outcome["error"] = success, error
            done.set()

        Photos.PHPhotoLibrary.sharedPhotoLibrary().performChanges_completionHandler_(
            change, completion
        )
        done.wait()
        if not outcome.get("success"):
            raise RuntimeError(f"Photos refused to delete: {outcome.get('error')}")
