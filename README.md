# iCloud Video Resize

A macOS app that re-encodes the videos of your iCloud Photos library to HEVC
(H.265), at the same resolution, to save iCloud space.

## How it works

The app shows all the videos of your Photos library and marks the ones worth
re-encoding. When you press **Start**, for each video, biggest first:

1. **Download.** If the original is only in iCloud, Photos downloads it.
2. **Encode** to HEVC. Same resolution, same frame rate, audio copied without
   changes, 10-bit HDR kept, capture date and GPS kept.
3. **Check** the new file: codec, resolution, duration, audio tracks, date,
   GPS, and a full decode of every frame.
4. **Check the saving.** If the new file is not at least 20% smaller, the
   original stays and nothing changes.
5. **Add** the new video to Photos, with the same date, place, favorite flag
   and albums as the original.
6. **Park** the original in the album `Video Resize: originals to delete`.

The app never deletes anything by itself. When you are happy with the result,
press **Delete originals**. The app checks again that each new video is still
in Photos, then moves the originals to Recently Deleted. macOS asks you to
confirm once for the whole batch. The originals stay recoverable for 30 days.

Note: iCloud space goes **up** a little until you delete the originals, and
it is fully free only when Recently Deleted is emptied.

## What it leaves alone

- Videos edited in Photos (the edits would be lost)
- Slow motion, time-lapse, cinematic and spatial videos
- Live Photos (they are photos, not videos)
- Hidden videos and shared albums
- Videos smaller than 20 MB or newer than 7 days
- Videos that are already well compressed

## Limits you should know

- **Titles, captions and keywords** that you added in Photos are not copied to
  the new video. Apple gives apps no way to read or write them.
- **Dolby Vision** metadata of iPhone HDR videos may not be kept. The video
  stays HDR (HLG, 10-bit).
- The app works only while it is open. It keeps the Mac awake while it works.

## Build and run

You need macOS 14 or newer and Xcode (or the Xcode command line tools).

```bash
git clone https://github.com/mrc527/icloud-video-resize.git
cd icloud-video-resize
./scripts/build-app.sh
open "build/iCloud Video Resize.app"
```

At the first start macOS asks for access to Photos. Choose full access.

Always start the app from the bundle built by the script. `swift run` does
not work: macOS gives access to Photos only to a real app bundle.

The app is signed for your Mac only. After each new build macOS may ask for
access to Photos again.

## First use

1. Open the app. It reads the library and fills the **To do** list.
2. Open **Settings** and set the minimum size very high, so that only one or
   two videos stay in the list. Press **Start**.
3. In Photos, compare the new video with the original in the album
   `Video Resize: originals to delete`.
4. If the result is good, set the minimum size back and let it run.

## Settings

| Setting | Default | Meaning |
|---|---|---|
| Encoder | Apple | Apple hardware encoder, or ffmpeg x265 |
| Quality | Balanced | High quality, Balanced, or Small files |
| Minimum size | 20 MB | Smaller videos are left alone |
| Minimum age | 7 days | Newer videos are left alone |
| Minimum saving | 20% | Below this the original is kept |
| Full decode check | On | Decode every frame of the new video before using it |

### Encoders

- **Apple** (default): fast, uses little power, needs nothing else installed.
  The target bit rate depends on resolution and frame rate. Balanced gives
  about 5 Mbit/s for 1080p at 30 fps and about 14 Mbit/s for 4K at 30 fps.
- **ffmpeg x265**: much slower, but the files are smaller for the same
  quality. Install it with `brew install ffmpeg`. The app finds it by itself.

## Where the app keeps its data

`~/Library/Application Support/iCloudVideoResize/`

- `state.json`: what was done to each video.
- `work/`: temporary files, removed after each video.

If the app stops while it is adding a video to Photos, that video is marked
"Check Photos for a duplicate" and is never retried automatically.

## Development

```bash
swift build
swift test
```

- `Sources/VideoResizeCore`: Photos access, encoding, checks, state.
- `Sources/VideoResizeApp`: the SwiftUI interface.
- `Tests`: the tests really encode short videos with the Apple encoder, and
  use a fake photo library.

A GitHub Action builds and tests every push on a macOS runner, and uploads
the built app as an artifact.
