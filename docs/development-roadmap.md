# Development roadmap

State after this round. Status words are the ones the brief asked for: PASS / FAIL / PARTIAL / BLOCKED / NOT TESTED.

## Main project

| Stage | Content | Status | Notes |
| --- | --- | --- | --- |
| 0 | audit + baseline | PASS | `audit-phase0.md`; baseline suite re-run |
| 1 | storage / transport / media layering | PASS | `ServerHub`, `Metadata`, `MediaBackend`, `FsStore` additions; verified on device (see below) |
| 2 | file manager UI | PARTIAL | circle-safe layout (330 px square, 42/28 vp insets, 160 vp tab pill), detail sheet, rename/copy/move/delete, mkdir; no thumbnails |
| 3 | FTP consistency + hardening | PASS | `stage3-ftp-review.md` maps every requirement to code and a test; suite 65/65. Timeouts are implemented but not yet asserted by a test |
| 4 | HTTP file service | PARTIAL | implementation complete; device login flow still failing, see regression report |
| 5 | image viewer + thumbnails | PARTIAL | full-screen viewer, desiredSize decode, button zoom, prev/next strip, pixel cache with prefetch; list rows now decode 96 px thumbnails on visibility (ThumbCache, 64 entries); no dedicated grid screen yet |
| 6 | audio player | NOT STARTED | `AVPlayer` + `fdSrc`; nine formats verified by the earlier probe |
| 7 | H.264 video player | NOT STARTED | XComponent surface, `surfaceId` only after `initialized` |
| 8 | media metadata + playability | NOT STARTED | `AVMetadataExtractor`; capability cache keyed by path+size+mtime |
| 9 | TXT reader | PARTIAL | chunked read, BOM/GBK detection, paginator on the full inscribed square, font 9-20 vp via edge buttons, crown (focus + 12 deg + 220 ms debounce) + swipe + tap paging, progress persisted, text cache; no EPUB/PDF |
| 10 | regression + performance pass | NOT STARTED | - |

## FFmpeg probe

| Stage | Content | Status |
| --- | --- | --- |
| F0 | toolchain, platform, licence research | PARTIAL: toolchain located and verified; licence and source selection not yet written up |
| F1 | minimal cross compile | NOT STARTED |
| F2 | .so packaging + device load | NOT STARTED |
| F3 | NAPI bridge + metadata | NOT STARTED |
| F4 | single frame / continuous decode | NOT STARTED |
| F5 | codec matrix | NOT STARTED |
| F6 | native render + PCM out | NOT STARTED |
| F7 | experimental player | NOT STARTED |
| F8 | power/thermal/soak | NOT STARTED |
| F9 | optimisation + comparison | NOT STARTED |
| F10 | decision report | NOT STARTED |

Nothing above has been claimed as working. The earlier capability report (`watch-decode-capability-report.md`) established only which system decoders exist; it did not build or run FFmpeg.

## Next steps, in order

1. Fix the HTTP login rejection and finish `Test-Http.ps1` (device is intermittently asleep; this is the only blocker). **Done in the previous round: 22/22.**
2. Add the watch-side file manager page (stage 2) - design in `file-manager-design.md`; start with the list + navigation slice.
3. Image viewer (stage 5) - smallest user-visible win, and `ImageSource` is already proven on this device.
4. Audio player (stage 6) - `AVPlayer` + `fdSrc`, plus a `AUDIO_PLAYBACK` continuous task; verify background and screen-off behaviour.
5. H.264 video (stage 7) with the exact state machine from the probe report.
6. Only then start the FFmpeg probe project, in its own directory and its own bundle.

## Test environment

The physical watch is not always reachable, so two substitutes are in place and both are now proven:

- **Chrome (chrome-devtools MCP, isolated context)** for everything web-facing: the served page, its layout, console and network. Used for the login/upload/download/delete pass.
- **Wearable emulator** for on-device behaviour. Instance `watch_dev`, image `HarmonyOS 6.1.0(23)`, 466x466 - the same device type and API as the watch. The debug-signed HAP installs directly, and `hdc fport` exposes the servers to the PC. Both suites pass against it (FTP 65/65, HTTP 22/22). Setup, port-forwarding details and the automation channel are in `emulator-workflow.md`.

What the emulator cannot answer: real performance, real power/thermal behaviour, and the continuous-task question - the emulator rejects every mode with `9800005 ... The bgMode is invalid`, exactly like the watch.

## Known debt

- `Index.ets` mixes UI and server lifecycle; split when a second page exists.
- Temp upload files are not swept at startup.
- The FTP suite and HTTP suite are PowerShell scripts; a single runner that also captures device logs would make regressions one command.
- No unit tests: the only tests are end-to-end against hardware, which is why every regression needs the watch awake.







