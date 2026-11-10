# iCloud video resize (icvr)

A background service for a Mac that is always on. It re-encodes the videos of
your iCloud Photos library to HEVC (H.265), at the same resolution, to save
iCloud space.

## How it works

For each video, biggest first:

1. **Fetch** the original. If it is only in iCloud, Photos downloads it.
2. **Encode** it with `ffmpeg` to HEVC. Same resolution, same frame rate,
   audio copied without changes, 10-bit HDR kept, date and GPS kept.
3. **Verify** the new file: codec, resolution, duration, audio tracks,
   date metadata, and a full decode of the file.
4. **Check the saving.** If the new file is not at least 20% smaller, the
   original stays and nothing changes.
5. **Import** the new video into Photos. Title, description, keywords,
   favorite and albums are copied from the original. The new video gets the
   keyword `icvr-reencoded`.
6. **Park the original** in the album `icvr - originals to delete`.

The service never deletes anything by itself. You run `icvr purge` when you
want. It checks again that each new video is still in Photos, then moves the
originals to Recently Deleted. macOS asks you to confirm once for the whole
batch (this dialog is a macOS rule and cannot be skipped). The originals stay
recoverable for 30 days.

Note: iCloud space goes **up** a little until you purge, and it is fully free
only when Recently Deleted is emptied.

## What it leaves alone

- Videos edited in Photos (the edit history would be lost)
- Slow motion and time-lapse videos
- Cinematic and spatial videos (more than one video track)
- Live Photos (they are photos, not videos)
- Hidden videos, shared albums, referenced files
- Videos smaller than 20 MB or newer than 7 days
- Videos that are already well compressed

Known limit: Dolby Vision metadata of iPhone HDR videos is not kept. The
video stays HDR (HLG, 10-bit), which is what most screens use anyway.

## Install

You need macOS, Python 3.11 or newer, and Homebrew.

```bash
brew install ffmpeg pipx
pipx install git+https://github.com/mrc527/icloud-video-resize.git
```

Optional: copy `config.example.toml` to `~/.config/icvr/config.toml` and edit it.

## First run

Do these steps by hand, in Terminal, before you install the service. macOS
will ask for permission to read the Photos library and to control Photos.
Say yes.

```bash
icvr scan                       # shows what would be done, changes nothing
icvr once --limit 1 --dry-run   # encodes one video, does not touch Photos
icvr once --limit 1             # really replaces one video
```

Then open Photos, look at the new video (search for `icvr-reencoded`) and
compare it with the original in the album `icvr - originals to delete`.
If you are happy:

```bash
icvr purge                      # deletes the parked originals
```

## Run as a service

```bash
./launchd/install.sh
```

The service scans the library every 6 hours and processes up to 20 videos per
cycle. Log file: `~/Library/Logs/icvr/icvr.log`.

It must run as a launchd *agent* inside your user session, because Photos
needs a logged-in user. Keep the Mac logged in.

## Commands

| Command | What it does |
|---|---|
| `icvr scan` | List what would be re-encoded and why the rest is skipped |
| `icvr once [--limit N] [--dry-run]` | Run one cycle and exit |
| `icvr run` | Run forever (used by launchd) |
| `icvr status` | Show totals, space saved, errors |
| `icvr purge` | Delete the originals that were replaced |

## Status values

| Status | Meaning |
|---|---|
| `replaced` | New video is in Photos, original waits in the delete album |
| `deleted` | Original was moved to Recently Deleted |
| `not_worth` | Already well compressed, original kept |
| `skipped` | A video type we do not touch |
| `failed` | Error. Retried up to 3 times |
| `needs_review` | Stopped in the middle of an import. Check Photos for a duplicate. Never retried automatically |

## Encoder choice

- `libx265` (default): software encoder. Slow, but gives the smallest files.
  Good for a Mac that works in the background.
- `videotoolbox`: Apple hardware encoder. Much faster, but files are bigger
  for the same quality.

## Development

```bash
pip install -e ".[dev]"
pytest
```

The tests use real `ffmpeg` and a fake Photos library, so they run on any
system.

## Test status

The encoding, verification, state and pipeline logic are covered by the test
suite. The code that talks to Photos (`library.py`, with `osxphotos`,
`photoscript` and PhotoKit) and the launchd script were written without
access to a Mac and **have not been run on a real Photos library yet**.
Follow the "First run" steps above with one video before you trust it.
