"""ffprobe / ffmpeg wrappers: inspect a video, re-encode it to HEVC, verify the result."""

from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass, field
from fractions import Fraction
from pathlib import Path

from .config import Config

# Metadata tags that carry the capture date. Photos uses them to place the
# video on the timeline, so losing them is not acceptable.
DATE_TAGS = ("com.apple.quicktime.creationdate", "creation_time")


class EncodeError(RuntimeError):
    """ffmpeg / ffprobe failed."""


class VerifyError(RuntimeError):
    """The re-encoded file does not match the original closely enough."""


@dataclass
class MediaInfo:
    path: Path
    size: int
    duration: float
    width: int  # display width (rotation applied)
    height: int  # display height (rotation applied)
    codec: str
    pix_fmt: str
    bit_rate: int  # video bit rate, bits per second
    fps: float
    video_streams: int
    audio_streams: int
    color_primaries: str | None = None
    color_trc: str | None = None
    colorspace: str | None = None
    tags: dict[str, str] = field(default_factory=dict)

    @property
    def bits_per_pixel(self) -> float:
        pixels_per_second = self.width * self.height * self.fps
        return self.bit_rate / pixels_per_second if pixels_per_second else 0.0

    @property
    def is_10bit(self) -> bool:
        return "10" in self.pix_fmt


def _run(cmd: list[str]) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, errors="replace")
    except FileNotFoundError as exc:
        raise EncodeError(f"Program not found: {cmd[0]}. Is ffmpeg installed?") from exc


def _rotation(stream: dict) -> int:
    for side in stream.get("side_data_list", []):
        if "rotation" in side:
            return int(float(side["rotation"]))
    return int(float(stream.get("tags", {}).get("rotate", 0)))


def _known(value: str | None) -> str | None:
    return value if value and value != "unknown" else None


def probe(path: Path, cfg: Config) -> MediaInfo:
    proc = _run(
        [cfg.ffprobe, "-v", "error", "-print_format", "json",
         "-show_format", "-show_streams", str(path)]
    )
    if proc.returncode != 0:
        raise EncodeError(f"ffprobe failed on {path.name}: {proc.stderr.strip()[-500:]}")
    data = json.loads(proc.stdout)
    fmt = data.get("format", {})
    streams = data.get("streams", [])
    # Cover art counts as a video stream in ffprobe; ignore it.
    videos = [
        s for s in streams
        if s.get("codec_type") == "video"
        and not s.get("disposition", {}).get("attached_pic")
    ]
    audios = [s for s in streams if s.get("codec_type") == "audio"]
    if not videos:
        raise EncodeError(f"No video stream in {path.name}")

    v = videos[0]
    width, height = int(v["width"]), int(v["height"])
    if abs(_rotation(v)) % 180 == 90:
        width, height = height, width

    try:
        fps = float(Fraction(v.get("avg_frame_rate") or "0"))
    except (ValueError, ZeroDivisionError):
        fps = 0.0

    duration = float(v.get("duration") or fmt.get("duration") or 0)
    size = path.stat().st_size
    bit_rate = int(v.get("bit_rate") or fmt.get("bit_rate") or 0)
    if not bit_rate and duration:
        bit_rate = int(size * 8 / duration)

    return MediaInfo(
        path=path,
        size=size,
        duration=duration,
        width=width,
        height=height,
        codec=v.get("codec_name", ""),
        pix_fmt=v.get("pix_fmt", ""),
        bit_rate=bit_rate,
        fps=fps,
        video_streams=len(videos),
        audio_streams=len(audios),
        color_primaries=_known(v.get("color_primaries")),
        color_trc=_known(v.get("color_transfer")),
        colorspace=_known(v.get("color_space")),
        tags={k.lower(): str(val) for k, val in fmt.get("tags", {}).items()},
    )


def build_command(src: MediaInfo, dst: Path, cfg: Config) -> list[str]:
    """Build the ffmpeg command. Same resolution, HEVC video, audio copied as is."""
    cmd = [cfg.ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
           "-i", str(src.path),
           "-map", "0:v:0", "-map", "0:a?"]

    if cfg.encoder == "videotoolbox":
        cmd += ["-c:v", "hevc_videotoolbox", "-q:v", str(cfg.vt_quality),
                "-profile:v", "main10" if src.is_10bit else "main"]
    else:
        cmd += ["-c:v", "libx265", "-crf", str(cfg.crf), "-preset", cfg.preset,
                "-x265-params", "log-level=error"]

    # Keep bit depth and colour tags so HDR (HLG) videos stay HDR.
    cmd += ["-pix_fmt", "yuv420p10le" if src.is_10bit else "yuv420p"]
    for flag, value in (("-color_primaries", src.color_primaries),
                        ("-color_trc", src.color_trc),
                        ("-colorspace", src.colorspace)):
        if value:
            cmd += [flag, value]

    cmd += [
        "-tag:v", "hvc1",  # needed for Apple players
        "-c:a", "copy",
        "-map_metadata", "0",  # keep date, GPS, camera model
        "-movflags", "+faststart+use_metadata_tags",
        "-f", "mov",
        str(dst),
    ]
    if cfg.nice > 0:
        cmd = ["nice", "-n", str(cfg.nice)] + cmd
    return cmd


def encode(src: MediaInfo, dst: Path, cfg: Config) -> MediaInfo:
    proc = _run(build_command(src, dst, cfg))
    if proc.returncode != 0:
        dst.unlink(missing_ok=True)
        raise EncodeError(f"ffmpeg failed on {src.path.name}: {proc.stderr.strip()[-800:]}")
    return probe(dst, cfg)


def verify(src: MediaInfo, dst: MediaInfo, cfg: Config) -> None:
    """Raise VerifyError unless the new file is a faithful copy of the original."""
    if dst.codec != "hevc":
        raise VerifyError(f"codec is {dst.codec}, expected hevc")
    if (dst.width, dst.height) != (src.width, src.height):
        raise VerifyError(
            f"resolution changed: {src.width}x{src.height} -> {dst.width}x{dst.height}"
        )
    tolerance = max(0.5, src.duration * 0.01)
    if abs(dst.duration - src.duration) > tolerance:
        raise VerifyError(f"duration changed: {src.duration:.2f}s -> {dst.duration:.2f}s")
    if dst.audio_streams != src.audio_streams:
        raise VerifyError(
            f"audio streams changed: {src.audio_streams} -> {dst.audio_streams}"
        )
    if src.is_10bit and not dst.is_10bit:
        raise VerifyError("10-bit video became 8-bit")
    for tag in DATE_TAGS:
        if tag in src.tags and tag not in dst.tags:
            raise VerifyError(f"metadata tag lost: {tag}")

    if cfg.full_decode_check:
        proc = _run([cfg.ffmpeg, "-nostdin", "-v", "error", "-xerror",
                     "-i", str(dst.path), "-f", "null", "-"])
        if proc.returncode != 0 or proc.stderr.strip():
            raise VerifyError(f"new file does not decode cleanly: {proc.stderr.strip()[-300:]}")
