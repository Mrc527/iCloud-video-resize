"""Configuration, loaded from a TOML file. Every field has a safe default."""

from __future__ import annotations

import tomllib
from dataclasses import dataclass, fields
from pathlib import Path

DEFAULT_CONFIG_PATH = Path("~/.config/icvr/config.toml").expanduser()


@dataclass
class Config:
    # Where the state database and temporary files live.
    data_dir: Path = Path("~/Library/Application Support/icvr").expanduser()

    # --- Encoding ---
    # "libx265": software, slow, best compression.
    # "videotoolbox": Apple hardware encoder, fast, bigger files.
    encoder: str = "libx265"
    crf: int = 24  # libx265 quality: lower = better quality, bigger file
    preset: str = "medium"  # libx265 speed preset
    vt_quality: int = 55  # videotoolbox quality (1-100, higher = better)
    nice: int = 10  # CPU priority of ffmpeg (0 = normal, 19 = lowest)
    ffmpeg: str = "ffmpeg"
    ffprobe: str = "ffprobe"

    # --- Which videos to touch ---
    min_size_mb: float = 20.0  # ignore small videos
    min_age_days: int = 7  # ignore recent videos
    # Bits per pixel per frame. Videos below this are already well compressed.
    min_bits_per_pixel: float = 0.05
    # Keep the re-encoded file only if it is at least this much smaller.
    min_saving_percent: float = 20.0

    # --- Safety ---
    full_decode_check: bool = True  # decode the whole new file before trusting it
    max_attempts: int = 3  # give up on a video after this many failures

    # --- Service loop ---
    scan_interval_minutes: int = 360
    max_videos_per_run: int = 20

    # --- Photos ---
    delete_album: str = "icvr - originals to delete"
    marker_keyword: str = "icvr-reencoded"
    export_timeout_seconds: int = 3600  # time allowed to download one video from iCloud

    @property
    def state_db(self) -> Path:
        return self.data_dir / "state.db"

    @property
    def work_dir(self) -> Path:
        return self.data_dir / "work"


def load_config(path: Path | None = None) -> Config:
    """Load the config file. A missing default file means "use defaults"."""
    explicit = path is not None
    path = path or DEFAULT_CONFIG_PATH
    if not path.exists():
        if explicit:
            raise FileNotFoundError(f"Config file not found: {path}")
        return Config()

    with path.open("rb") as fh:
        raw = tomllib.load(fh)

    known = {f.name: f for f in fields(Config)}
    unknown = sorted(set(raw) - set(known))
    if unknown:
        raise ValueError(f"Unknown config keys in {path}: {', '.join(unknown)}")

    cfg = Config()
    for key, value in raw.items():
        if key == "data_dir":
            value = Path(value).expanduser()
        setattr(cfg, key, value)

    if cfg.encoder not in ("libx265", "videotoolbox"):
        raise ValueError("encoder must be 'libx265' or 'videotoolbox'")
    return cfg
