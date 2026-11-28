# Audio playback

Stage 6, first slice: local audio with transport controls.

## Engine

`services/AudioPlayer.ets` wraps `media.AVPlayer`:

- the file is opened with `fileIo.openSync` and handed over as `fdSrc = { fd, offset: 0, length }`; the fd is owned by the wrapper and closed on release, otherwise the player keeps reading a closed descriptor
- state is driven by the `stateChange` event: `initialized -> prepare()`, `prepared -> play()`, and `completed -> onComplete`
- `timeUpdate` feeds the position; `durationUpdate` fixes the duration once the container is parsed
- errors surface as `onError` with the numeric code, which the UI shows verbatim instead of a generic "failed"

## Constraints that shaped it

- **Foreground only.** This device refuses every continuous-task mode (`9800005 The bgMode is invalid`), so playback stops with the app. There is no pretend background audio and no notification to control it.
- A file that AVPlayer cannot parse must say so: the fake MP3 used in testing produces `5400106 Unsupported Format`, which the screen prints under the progress bar.
- Keep-screen-on is held while the player is open, same as the reader and viewer.

## Screen

`components/AudioViewer.ets`, all inside the inscribed square:

```
        ‹   tone.wav   1/2
              🎵
           播放中
   ▓▓▓▓▓▓▓░░░░░░░░░░░░
        0:01 / 0:03
    ⏮      ▶/⏸      ⏭
```

- previous / play-pause / next, with the list built from all `MediaKind.AUDIO` files in the current view
- finishing a track advances to the next one automatically
- the crown seeks by 10 seconds per 8 degrees (it is a media transport here, not a page turner)

## Verified

| Item | Result |
| --- | --- |
| real WAV plays, progress bar moves, duration 0:03 | PASS (`audio-player.png`) |
| auto-advance at end of track | PASS - tone.wav handed over to the next entry |
| unplayable container reports the code | PASS - `无法播放 (5400106)` |
| crown seek | NOT TESTED - no crown injection path on the emulator |

Open: no playlist screen, no "resume where you left off" for audio, no audio-focus handling when another app starts playing.
