"""End-to-end tests with real ffmpeg and a fake Photos library."""

from __future__ import annotations

import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path

import pytest

from icloud_video_resize import service
from icloud_video_resize import state as st
from icloud_video_resize.config import Config, load_config
from icloud_video_resize.encoder import VerifyError, encode, probe, verify
from icloud_video_resize.library import VideoAsset
from icloud_video_resize.state import State

pytestmark = pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="ffmpeg not installed")

OLD = datetime(2020, 1, 1, tzinfo=timezone.utc)
CREATION = "2020-01-01T10:00:00+0100"


def make_video(path: Path, *, rotate: int = 0, ten_bit: bool = False, crf: int = 4) -> Path:
    """A noisy 2 second clip, encoded wastefully like a phone would."""
    raw = path.with_name("raw_" + path.name)
    cmd = ["ffmpeg", "-v", "error", "-y",
           "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=30:duration=2",
           "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
           "-c:v", "libx264", "-crf", str(crf), "-preset", "ultrafast",
           "-pix_fmt", "yuv420p10le" if ten_bit else "yuv420p",
           "-c:a", "aac", "-shortest",
           "-metadata", f"com.apple.quicktime.creationdate={CREATION}",
           "-metadata", "com.apple.quicktime.location.ISO6709=+45.4642+009.1900+120.000/",
           "-movflags", "use_metadata_tags", str(raw)]
    if ten_bit:
        cmd[cmd.index("-pix_fmt"):cmd.index("-pix_fmt")] = [
            "-color_primaries", "bt2020", "-color_trc", "arib-std-b67", "-colorspace", "bt2020nc"]
    subprocess.run(cmd, check=True)
    if rotate:
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-display_rotation", str(rotate),
                        "-i", str(raw), "-c", "copy", "-map_metadata", "0",
                        "-movflags", "use_metadata_tags", str(path)], check=True)
        raw.unlink()
    else:
        raw.rename(path)
    return path


class FakeLibrary:
    def __init__(self, assets: list[VideoAsset]):
        self.assets = assets
        self.present = {a.uuid for a in assets}
        self.imported: dict[str, Path] = {}
        self.albums: dict[str, list[str]] = {}
        self.fail_import = False

    def list_videos(self):
        return self.assets

    def fetch_original(self, asset, dest_dir):
        dest_dir.mkdir(parents=True, exist_ok=True)
        return Path(shutil.copy2(asset.path, dest_dir / asset.filename))

    def import_video(self, path, asset):
        if self.fail_import:
            raise RuntimeError("Photos is not responding")
        new_uuid = "NEW-" + asset.uuid
        self.imported[new_uuid] = path
        self.present.add(new_uuid)
        return new_uuid

    def exists(self, uuid):
        return uuid in self.present

    def add_to_album(self, uuid, album_name):
        self.albums.setdefault(album_name, []).append(uuid)

    def delete(self, uuids):
        self.present -= set(uuids)


@pytest.fixture
def cfg(tmp_path):
    return Config(data_dir=tmp_path / "data", preset="ultrafast", crf=30,
                  min_size_mb=0, nice=0)


@pytest.fixture
def state(cfg):
    s = State(cfg.state_db)
    yield s
    s.close()


def asset_for(path: Path, uuid: str = "A1", **kw) -> VideoAsset:
    return VideoAsset(uuid=uuid, filename=path.name, size=path.stat().st_size,
                      date=OLD, path=path, **kw)


def test_encode_keeps_resolution_audio_and_metadata(tmp_path, cfg):
    src = probe(make_video(tmp_path / "IMG_0001.MOV"), cfg)
    dst = encode(src, tmp_path / "out.mov", cfg)
    verify(src, dst, cfg)

    assert dst.codec == "hevc"
    assert (dst.width, dst.height) == (320, 240)
    assert dst.audio_streams == 1
    assert dst.size < src.size
    assert dst.tags["com.apple.quicktime.creationdate"] == CREATION
    assert dst.tags["com.apple.quicktime.location.iso6709"].startswith("+45.4642")


def test_rotated_video_keeps_display_size(tmp_path, cfg):
    src = probe(make_video(tmp_path / "portrait.mov", rotate=90), cfg)
    assert (src.width, src.height) == (240, 320)
    dst = encode(src, tmp_path / "out.mov", cfg)
    verify(src, dst, cfg)
    assert (dst.width, dst.height) == (240, 320)


def test_hdr_video_stays_10bit_with_colour_tags(tmp_path, cfg):
    src = probe(make_video(tmp_path / "hdr.mov", ten_bit=True), cfg)
    assert src.is_10bit
    dst = encode(src, tmp_path / "out.mov", cfg)
    verify(src, dst, cfg)
    assert dst.is_10bit
    assert (dst.color_primaries, dst.color_trc) == ("bt2020", "arib-std-b67")


def test_verify_rejects_truncated_output(tmp_path, cfg):
    src = probe(make_video(tmp_path / "a.mov"), cfg)
    short = tmp_path / "short.mov"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(src.path), "-t", "1",
                    "-c:v", "libx265", "-tag:v", "hvc1", "-c:a", "copy",
                    "-map_metadata", "0", "-movflags", "use_metadata_tags", str(short)],
                   check=True)
    with pytest.raises(VerifyError, match="duration"):
        verify(src, probe(short, cfg), cfg)


def test_cycle_replaces_video_then_purge_deletes_original(tmp_path, cfg, state):
    video = make_video(tmp_path / "IMG_0002.MOV")
    lib = FakeLibrary([asset_for(video)])

    counts = service.run_cycle(cfg, lib, state)

    assert counts == {st.REPLACED: 1}
    row = state.get("A1")
    assert row["new_uuid"] == "NEW-A1"
    assert row["new_size"] < row["orig_size"]
    assert lib.imported["NEW-A1"].name == "IMG_0002.MOV"  # same name in Photos
    assert lib.albums[cfg.delete_album] == ["A1"]
    assert "A1" in lib.present  # original is NOT deleted by the cycle
    assert not any(cfg.work_dir.iterdir())  # temp files cleaned

    # A second cycle does nothing.
    assert service.run_cycle(cfg, lib, state) == {}

    assert service.purge(cfg, lib, state) == (1, 0)
    assert "A1" not in lib.present and "NEW-A1" in lib.present
    assert state.get("A1")["status"] == st.DELETED


def test_purge_keeps_original_when_replacement_is_missing(tmp_path, cfg, state):
    video = make_video(tmp_path / "a.mov")
    lib = FakeLibrary([asset_for(video)])
    service.run_cycle(cfg, lib, state)
    lib.present.discard("NEW-A1")  # someone removed the new video

    assert service.purge(cfg, lib, state) == (0, 1)
    assert "A1" in lib.present
    assert state.get("A1")["status"] == st.REPLACED


def test_dry_run_changes_nothing(tmp_path, cfg, state):
    video = make_video(tmp_path / "a.mov")
    lib = FakeLibrary([asset_for(video)])
    assert service.run_cycle(cfg, lib, state, dry_run=True) == {st.REPLACED: 1}
    assert not lib.imported and not lib.albums
    assert state.get("A1") is None


def test_small_saving_keeps_original(tmp_path, cfg, state):
    cfg.min_saving_percent = 99.9
    video = make_video(tmp_path / "a.mov")
    lib = FakeLibrary([asset_for(video)])
    assert service.run_cycle(cfg, lib, state) == {st.NOT_WORTH: 1}
    assert not lib.imported


def test_already_compressed_video_is_not_encoded(tmp_path, cfg, state):
    cfg.min_bits_per_pixel = 1000
    video = make_video(tmp_path / "a.mov")
    lib = FakeLibrary([asset_for(video)])
    assert service.run_cycle(cfg, lib, state) == {st.NOT_WORTH: 1}


def test_import_failure_needs_review_and_is_not_retried(tmp_path, cfg, state):
    video = make_video(tmp_path / "a.mov")
    lib = FakeLibrary([asset_for(video)])
    lib.fail_import = True

    assert service.run_cycle(cfg, lib, state) == {st.NEEDS_REVIEW: 1}
    lib.fail_import = False
    assert service.run_cycle(cfg, lib, state) == {}
    assert "A1" in lib.present


def test_encode_failure_is_retried_up_to_max_attempts(tmp_path, cfg, state):
    broken = tmp_path / "broken.mov"
    broken.write_bytes(b"not a video" * 1000)
    lib = FakeLibrary([asset_for(broken)])
    cfg.max_attempts = 2

    assert service.run_cycle(cfg, lib, state) == {st.FAILED: 1}
    assert service.run_cycle(cfg, lib, state) == {st.FAILED: 1}
    assert service.run_cycle(cfg, lib, state) == {}
    assert state.get("A1")["attempts"] == 2


def test_classify_filters(tmp_path, cfg, state):
    video = make_video(tmp_path / "a.mov")
    cfg.min_size_mb = 0.001
    assets = [
        asset_for(video, "ok"),
        asset_for(video, "marked", keywords=[cfg.marker_keyword]),
        asset_for(video, "edited", skip_reason="edited in Photos"),
        VideoAsset(uuid="tiny", filename="t.mov", size=10, date=OLD, path=video),
        VideoAsset(uuid="recent", filename="r.mov", size=10**9,
                   date=datetime.now(timezone.utc), path=video),
    ]
    result = {c.asset.uuid: c.reason for c in service.classify(assets, cfg, state)}
    assert result["ok"] is None
    assert "already re-encoded" in result["marked"]
    assert "edited" in result["edited"]
    assert "smaller" in result["tiny"]
    assert "newer" in result["recent"]


def test_interrupted_import_is_flagged_at_startup(cfg, state):
    state.set("X", st.IMPORTING, filename="x.mov")
    assert state.recover_interrupted() == 1
    assert state.get("X")["status"] == st.NEEDS_REVIEW


def test_config_rejects_unknown_keys(tmp_path):
    path = tmp_path / "config.toml"
    path.write_text('crf = 22\nencoder = "videotoolbox"\n')
    cfg = load_config(path)
    assert (cfg.crf, cfg.encoder) == (22, "videotoolbox")

    path.write_text("cfr = 22\n")
    with pytest.raises(ValueError, match="cfr"):
        load_config(path)
