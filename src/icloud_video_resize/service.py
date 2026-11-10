"""The pipeline: pick videos, re-encode, verify, replace in Photos."""

from __future__ import annotations

import logging
import shutil
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from . import state as st
from .config import Config
from .encoder import encode, probe, verify
from .library import Library, VideoAsset
from .state import State

log = logging.getLogger(__name__)

MB = 1024 * 1024


@dataclass
class Candidate:
    asset: VideoAsset
    reason: str | None  # None = will be processed; text = why it is left alone


def classify(assets: list[VideoAsset], cfg: Config, state: State) -> list[Candidate]:
    """Decide for every video whether we process it, using only cheap checks."""
    newest_allowed = datetime.now(timezone.utc) - timedelta(days=cfg.min_age_days)
    out = []
    for a in assets:
        row = state.get(a.uuid)
        if cfg.marker_keyword in a.keywords:
            reason = "already re-encoded by icvr"
        elif row and row["status"] in st.FINAL:
            reason = f"already handled ({row['status']})"
        elif row and row["status"] == st.FAILED and row["attempts"] >= cfg.max_attempts:
            reason = f"failed {row['attempts']} times: {row['detail']}"
        elif a.skip_reason:
            reason = a.skip_reason
        elif a.size < cfg.min_size_mb * MB:
            reason = f"smaller than {cfg.min_size_mb:g} MB"
        elif a.date and _aware(a.date) > newest_allowed:
            reason = f"newer than {cfg.min_age_days} days"
        else:
            reason = None
        out.append(Candidate(a, reason))
    return out


def _aware(d: datetime) -> datetime:
    return d if d.tzinfo else d.astimezone()


def todo(candidates: list[Candidate]) -> list[VideoAsset]:
    """Videos to process, biggest first: they give the biggest saving."""
    return sorted((c.asset for c in candidates if c.reason is None),
                  key=lambda a: a.size, reverse=True)


def process_one(asset: VideoAsset, cfg: Config, lib: Library, state: State,
                dry_run: bool = False) -> str:
    """Process a single video. Returns the final status. Never raises."""
    work = cfg.work_dir / asset.uuid
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    try:
        status = _process(asset, cfg, lib, state, work, dry_run)
    except Exception as exc:
        log.error("%s: failed: %s", asset.filename, exc)
        if not dry_run:
            # A crash after the import started must not be retried blindly:
            # the new video may already be in Photos.
            row = state.get(asset.uuid)
            status = st.NEEDS_REVIEW if row and row["status"] == st.IMPORTING else st.FAILED
            state.set(asset.uuid, status, filename=asset.filename, detail=str(exc)[:500])
        else:
            status = st.FAILED
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return status


def _process(asset, cfg, lib, state, work, dry_run) -> str:
    def finish(status: str, detail: str, **kw) -> str:
        log.info("%s: %s (%s)", asset.filename, status, detail)
        if not dry_run:
            state.set(asset.uuid, status, filename=asset.filename, detail=detail, **kw)
        return status

    free = shutil.disk_usage(work).free
    if free < asset.size * 2.5:
        raise RuntimeError(
            f"not enough free disk space ({free // MB} MB free, video is {asset.size // MB} MB)"
        )

    src_path = lib.fetch_original(asset, work / "in")
    src = probe(src_path, cfg)

    if src.video_streams != 1:
        return finish(st.SKIPPED, "more than one video track (cinematic or spatial video)",
                      orig_size=src.size)
    if src.bits_per_pixel < cfg.min_bits_per_pixel:
        return finish(st.NOT_WORTH,
                      f"already well compressed ({src.bits_per_pixel:.3f} bits per pixel)",
                      orig_size=src.size)

    # Keep the original file name so the video looks the same in Photos.
    out_dir = work / "out"
    out_dir.mkdir()
    dst_path = out_dir / (src_path.stem + (src_path.suffix if src_path.suffix.lower() == ".mov" else ".mov"))

    log.info("%s: encoding %dx%d, %.0fs, %d MB", asset.filename, src.width, src.height,
             src.duration, src.size // MB)
    started = time.monotonic()
    dst = encode(src, dst_path, cfg)
    verify(src, dst, cfg)

    saving = 100 * (1 - dst.size / src.size)
    summary = (f"{src.size // MB} MB -> {dst.size // MB} MB, saved {saving:.0f}%, "
               f"took {time.monotonic() - started:.0f}s")
    if saving < cfg.min_saving_percent:
        return finish(st.NOT_WORTH, f"saving too small: {summary}",
                      orig_size=src.size, new_size=dst.size)
    if dry_run:
        return finish(st.REPLACED, f"dry run, Photos not changed: {summary}")

    # From here on Photos is changed. Record the intent first, for crash safety.
    state.set(asset.uuid, st.IMPORTING, filename=asset.filename,
              orig_size=src.size, new_size=dst.size)
    new_uuid = lib.import_video(dst_path, asset)
    state.set(asset.uuid, st.IMPORTING, new_uuid=new_uuid)
    if not lib.exists(new_uuid):
        raise RuntimeError("imported video not found in Photos after import")
    lib.add_to_album(asset.uuid, cfg.delete_album)
    return finish(st.REPLACED, summary, new_uuid=new_uuid)


def run_cycle(cfg: Config, lib: Library, state: State, limit: int | None = None,
              dry_run: bool = False) -> dict[str, int]:
    """One scan of the library plus processing of up to `limit` videos."""
    interrupted = state.recover_interrupted()
    if interrupted:
        log.warning("%d video(s) were interrupted during import. Run 'icvr status'.", interrupted)

    videos = todo(classify(lib.list_videos(), cfg, state))
    limit = cfg.max_videos_per_run if limit is None else limit
    log.info("%d video(s) to process, doing %d now", len(videos), min(limit, len(videos)))

    counts: dict[str, int] = {}
    for asset in videos[:limit]:
        status = process_one(asset, cfg, lib, state, dry_run=dry_run)
        counts[status] = counts.get(status, 0) + 1
    return counts


def run_forever(cfg: Config, lib: Library, state: State) -> None:
    while True:
        try:
            run_cycle(cfg, lib, state)
        except Exception:
            log.exception("Cycle failed, will retry at the next interval")
        log.info("Sleeping %d minutes", cfg.scan_interval_minutes)
        time.sleep(cfg.scan_interval_minutes * 60)


def purge(cfg: Config, lib: Library, state: State) -> tuple[int, int]:
    """Delete originals whose replacement is still in Photos.

    Returns (deleted, held_back). Originals whose replacement is missing are
    held back and never deleted.
    """
    safe, held = [], 0
    for row in state.by_status(st.REPLACED):
        if row["new_uuid"] and lib.exists(row["new_uuid"]):
            if lib.exists(row["uuid"]):
                safe.append(row["uuid"])
            else:  # the user already deleted it by hand
                state.set(row["uuid"], st.DELETED, detail="original already gone")
        else:
            held += 1
            log.warning("%s: replacement not found in Photos, original is kept", row["filename"])
    if safe:
        lib.delete(safe)
        for uuid in safe:
            state.set(uuid, st.DELETED, detail="original moved to Recently Deleted")
    return len(safe), held
