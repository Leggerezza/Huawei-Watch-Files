# Architecture

State after stage 1. One HAP, no native modules, no third-party dependencies.

## Layers

```
pages/Index.ets                     UI + ability lifecycle only
        |
        +-- ServerHub.ets           transport coordinator: start/stop, one status snapshot
                    |
                    +-- FtpServer.ets     FTP protocol + passive data channel
                    +-- HttpServer.ets    HTTP/1.1 subset + sessions
                    |       +-- WebUi.ets     server-rendered HTML
                    +-- Metadata.ets      type / container / codec / playability policy
                    +-- MediaBackend.ets  system ImageSource (audio-video: stage 8)
                            |
                    +-- FsStore.ets      the only module that touches the filesystem
                    +-- NetInfo.ets      Wi-Fi IPv4 lookup
                            |
                    @kit.CoreFileKit  @kit.NetworkKit  @kit.CryptoArchitectureKit  @kit.ImageKit
```

`Index` knows one object (`ServerHub`) and one snapshot (`ServerStatus`). It does not know that two servers exist, nor how either speaks. The UI never parses a protocol and never touches a socket.

## Stage 1 changes

- **`ServerHub`** owns both transports. It also sweeps stale `.upload-*.part` files at start and runs a one-off metadata self-check so the layer is provable from `hilog` without a UI page.
- **`Metadata`** separates three things that used to be mixed: what the file *is* (extension + magic → container + codec), which bucket it belongs to, and whether this device can play it. The third is a **policy** derived from `watch-decode-capability-report.md`, named `policyPlayable` so it is never mistaken for a runtime measurement. H.264 → SYSTEM; HEVC/VP8/VP9/AV1/MJPEG/TIFF → UNSUPPORTED; ten audio codecs → SYSTEM.
- **`MediaBackend`** defines the seam and implements one real thing: image dimensions through `ImageSource`. `mediaMetadata()` returns an explicit "not implemented until stage 8" error rather than a fake result.
- **`FsStore`** is now the single place with filesystem semantics: `copy`, `move` (rename with copy fallback), `removeTree` (explicit, for the future file manager; FTP's `RMD` deliberately does *not* use it), `freeBytes`, `totalBytes`, `uniquePath`, `sweepTemp`, `readHead`. `HttpServer` now delegates MIME to `Metadata` and collision naming to `FsStore` instead of keeping copies.

## Deliberate choices

- **One sandbox root, two protocols.** A file uploaded over FTP is immediately visible in the browser and vice versa.
- **No repository or index.** The filesystem *is* the database. Six fixed buckets give the browser a stable layout without a migration path.
- **Classification is policy, not architecture.** FTP never moves a file; HTTP files root uploads. Same `Classifier`, two call sites.
- **No native code in the main app.** The device already ships H.264 hardware decode and ten software audio decoders; FFmpeg would add 10-20 MB and a licence question for capability this app does not use yet.
- **Streaming everywhere.** Uploads are written chunk by chunk to a temp file and renamed on completion; downloads are read in 64 KB blocks and awaited for backpressure. No file is fully buffered.

## Threading model

Everything runs on the UIAbility JS thread. Each socket callback is bounded work: parse a small buffer, write one chunk, send one chunk. 8 MB over FTP measures 1.5 MB/s up and 3.7 MB/s down, which is Wi-Fi, not the thread. Media decoding, when it arrives, must go to a worker or native thread, not into these callbacks.

## Lifecycle

```
aboutToAppear -> resolve IPv4 -> hub.start(root, ip) -> ask for a DATA_TRANSFER task
aboutToDisappear -> release task -> hub.stop()
```

The continuous task is currently refused by the watch (`9800005`); the UI shows that failure instead of hiding it, and the app does not claim background service.

## Known structural gaps

- `Index` still renders both transports' status inline; a second page (file manager) should introduce a shared view model rather than copy the state fields.
- No persistence: ports and credentials are per-run by design.
- `Metadata` trusts `watch-decode-capability-report.md` for playability. Stage 8 replaces that with a real probe.
