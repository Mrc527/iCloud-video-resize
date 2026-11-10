"""Command line: icvr scan | once | run | status | purge"""

from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

from . import service
from . import state as st
from .config import load_config
from .library import PhotosLibrary
from .state import State

MB = 1024 * 1024


def _library(cfg) -> PhotosLibrary:
    return PhotosLibrary(cfg.marker_keyword, cfg.export_timeout_seconds)


def cmd_scan(cfg, state, args) -> int:
    candidates = service.classify(_library(cfg).list_videos(), cfg, state)
    videos = service.todo(candidates)
    reasons: dict[str, int] = {}
    for c in candidates:
        if c.reason:
            key = c.reason.split(":")[0]
            reasons[key] = reasons.get(key, 0) + 1

    print(f"Videos in library: {len(candidates)}")
    print(f"To re-encode:      {len(videos)} ({sum(a.size for a in videos) / MB / 1024:.1f} GB)")
    for a in videos[: args.show]:
        where = "local" if a.path else "iCloud only"
        print(f"  {a.size / MB:8.0f} MB  {a.filename}  [{where}]")
    if len(videos) > args.show:
        print(f"  ... and {len(videos) - args.show} more")
    print("Left alone:")
    for reason, n in sorted(reasons.items(), key=lambda kv: -kv[1]):
        print(f"  {n:6d}  {reason}")
    return 0


def cmd_once(cfg, state, args) -> int:
    counts = service.run_cycle(cfg, _library(cfg), state, limit=args.limit, dry_run=args.dry_run)
    print("Done:", ", ".join(f"{k}={v}" for k, v in counts.items()) or "nothing to do")
    return 1 if counts.get(st.FAILED) or counts.get(st.NEEDS_REVIEW) else 0


def cmd_run(cfg, state, args) -> int:
    service.run_forever(cfg, _library(cfg), state)
    return 0


def cmd_status(cfg, state, args) -> int:
    rows = state.summary()
    if not rows:
        print("Nothing processed yet.")
        return 0
    for r in rows:
        line = f"{r['status']:13s} {r['n']:5d}"
        if r["status"] in (st.REPLACED, st.DELETED):
            line += f"   {r['orig'] / MB:.0f} MB -> {r['new'] / MB:.0f} MB"
        print(line)
    for status in (st.NEEDS_REVIEW, st.FAILED):
        for r in state.by_status(status):
            print(f"\n[{status}] {r['filename']} ({r['uuid']}): {r['detail']}")
    waiting = len(state.by_status(st.REPLACED))
    if waiting:
        print(f"\n{waiting} original(s) wait in the album '{cfg.delete_album}'. "
              "Run 'icvr purge' to delete them.")
    return 0


def cmd_purge(cfg, state, args) -> int:
    waiting = state.by_status(st.REPLACED)
    if not waiting:
        print("No originals to delete.")
        return 0
    size = sum(r["orig_size"] or 0 for r in waiting) / MB
    print(f"{len(waiting)} original video(s), {size:.0f} MB, will move to Recently Deleted.")
    print("They stay recoverable in Photos for 30 days.")
    if not args.yes and input("Continue? [y/N] ").strip().lower() != "y":
        print("Cancelled.")
        return 1
    print("macOS will now ask you to confirm the deletion.")
    deleted, held = service.purge(cfg, _library(cfg), state)
    print(f"Deleted {deleted}. Kept {held} because the replacement was not found.")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="icvr", description=__doc__)
    parser.add_argument("-c", "--config", type=Path, help="path to config.toml")
    parser.add_argument("-v", "--verbose", action="store_true")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("scan", help="show what would be re-encoded, change nothing")
    p.add_argument("--show", type=int, default=20, help="how many videos to list")
    p.set_defaults(func=cmd_scan)

    p = sub.add_parser("once", help="run one cycle and exit")
    p.add_argument("--limit", type=int, help="max videos to process")
    p.add_argument("--dry-run", action="store_true",
                   help="encode and verify, but do not change Photos")
    p.set_defaults(func=cmd_once)

    p = sub.add_parser("run", help="run forever (for launchd)")
    p.set_defaults(func=cmd_run)

    p = sub.add_parser("status", help="show what was done so far")
    p.set_defaults(func=cmd_status)

    p = sub.add_parser("purge", help="delete originals that were replaced")
    p.add_argument("--yes", action="store_true", help="do not ask in the terminal")
    p.set_defaults(func=cmd_purge)

    args = parser.parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )
    try:
        cfg = load_config(args.config)
    except (FileNotFoundError, ValueError) as exc:
        print(f"Config error: {exc}", file=sys.stderr)
        return 2
    state = State(cfg.state_db)
    try:
        return args.func(cfg, state, args)
    except RuntimeError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    finally:
        state.close()


if __name__ == "__main__":
    sys.exit(main())
