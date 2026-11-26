# Architecture

Current shape of the app after stage 3 and stage 4. Deliberately flat: one HAP, no native modules, no external dependencies.

## Layers

```
pages/Index.ets                UI, lifecycle, background task
        |
        +-- FtpServer.ets      FTP control + passive data channel
        +-- HttpServer.ets     HTTP/1.1 subset + session auth
                    |
                    +-- FsStore.ets      path clamping, stat/list/mkdir/remove/rename
                    +-- Classifier.ets   buckets, extension + magic detection
                    +-- WebUi.ets        server-rendered HTML (HTTP only)
                    +-- NetInfo.ets      Wi-Fi IPv4 lookup
                            |
                    @kit.CoreFileKit  @kit.NetworkKit  @kit.CryptoArchitectureKit
```

`Index` owns both servers, starts them together and stops them together. Each server owns its own listener, credential and connection set; they share only `FsStore` and the sandbox root (`context.filesDir`), so the same files are visible over both protocols.

## Deliberate choices

- **One sandbox root, two protocols.** No separate HTTP storage tree, no database. A file uploaded over FTP is immediately visible in the browser and vice versa.
- **No server-manager abstraction (yet).** With two servers and one page, an extra indirection layer would be ceremony. If a third transport appears (WebDAV), introduce a `ServerHub` then, not now.
- **Classification is policy, not architecture.** `Classifier` is a pure function of (name, first 32 bytes). FTP leaves it off, HTTP applies it to root uploads. Moving it between layers is a one-line call site change.
- **No native code in the main app.** The device already ships H.264 hardware decode and ten software audio decoders (see `watch-decode-capability-report.md`); adding FFmpeg here would add 10-20 MB and a GPL/LGPL question for no capability the app currently uses.
- **Streaming everywhere.** Uploads are written chunk by chunk to a temp file and renamed on completion; downloads are read in 64 KB blocks. No file is ever fully buffered, because a watch has ~10 GB of storage but far less RAM headroom.

## Threading model

Everything runs on the JS thread of the UIAbility. Each socket callback is bounded work: parse a small buffer, write one chunk, send one chunk. The 8 MB FTP transfer measured 2.0 MB/s under this model, so a worker thread is not justified yet. If media decoding is added, that work must go to a worker or native thread, not into these callbacks.

## Lifecycle

```
aboutToAppear -> getLocalIpv4 -> start FTP -> start HTTP -> acquire DATA_TRANSFER task
aboutToDisappear -> release task -> stop both
```

Both `start()` calls are independent: if HTTP fails to start (for example no CSPRNG), FTP keeps serving and the UI shows the failure in its log strip.

## Known structural gaps

- `Index` holds UI state and server lifecycle together. A file-manager page would want a shared state object; that refactor should happen when the browser page is added, not before.
- No persistence: credentials and ports are per-run by design. A future "remember my last port" feature needs a preferences store.
- No media layer at all yet; see `development-roadmap.md`.
