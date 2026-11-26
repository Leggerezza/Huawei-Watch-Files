# Huawei Watch Files

A file server that runs on the watch: FTP for clients that speak it, and a browser page for phones that do not. Watch side only.

![Watch UI](docs/watch-ui-v2.jpeg)

## Status

- Device: HUAWEI WATCH 5 (`RTS-AL00`), OpenHarmony 6.1.0.125, API 23
- Package: `io.github.leggerezza.files`
- SDK: target 26.0.0, compatible 6.1.0(23)
- Builds, signs and installs on the watch
- FTP: 65 protocol checks pass on the device
- HTTP: 22 protocol checks pass on the device
- Stage 1 layering in place: `ServerHub` (transports), `Metadata` (type/container/codec/playability), `MediaBackend` (system `ImageSource`), one `FsStore`
- Browser flow verified against the watch in a real Chrome instance (login, list, upload, download, delete)
- Background execution: **not granted** by the system (`9800005`), see below

```
FTP   wrong password rejected, 8 MB up 1.5 MB/s, down 3.7 MB/s, SHA-256 equal
HTTP  401 without session, login, upload, download + Range, mkdir/rename/delete
```

## The FTP root is the app sandbox

Wearables give third-party apps no public directory. Checked from inside the app (`hilog` tag `WatchFtp`):

| Path | Result |
| --- | --- |
| `/storage/media` | missing |
| `/storage/media/100/local/files` | missing |
| `/storage/media/100/local/files/Docs` | missing |
| `/storage/media/100/local/files/Download` | missing |
| `/mnt/share` | missing |
| `/mnt/hmdfs` | accessible, distributed FS mount, not a user directory |
| `/data/storage/el1/bundle` | accessible, own read-only install directory |
| `/data/storage/el2/base/haps/entry/files` | accessible, used as the FTP root |

The root is `context.filesDir`. Files are removed together with the app. They cannot be written to the watch's gallery or Downloads, because there is nothing to write to; that part has to happen on the phone.

Background: [app sandbox](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/app-sandbox-directory), [getUserDownloadDir is PC/2in1 only](https://developer.huawei.com/consumer/cn/doc/doccenter-references/api/js-apis-file-environment).

## Credentials

Generated on every start and shown on the watch face.

- user: 4 lowercase letters, alphabet skips `i l o`
- password: 6 characters, `a-z` without `i l o` plus `2-9` without `0 1`
- control port is random too, 30000-59999, new one on every start
- 3 wrong `PASS` on one connection: `421` and the connection closes
- 20 wrong `PASS` within 60 seconds, from any address: logins refused for 30 seconds
- the server never shuts itself down, so a stranger cannot kill it by guessing
- `USER` always gets `331`, so it does not confirm the account name
- the password is never logged
- before login only `USER PASS QUIT FEAT SYST NOOP` are answered

Key space is 24^4 * 31^6, about 2.9e14. That keeps port scanners and people who stumble onto the URL out. It does not stop packet capture, because FTP sends credentials in clear text. If that is the threat you care about, FTP is the wrong protocol.

Why not FTPS, HTTPS or WebDAV: [docs/protocol-assessment.md](docs/protocol-assessment.md).

## Web browser

Both servers start together. The watch face shows two lines:

```
FTP  52934  account qanx  password 3hhp2k
web  40964  access code e50a8f
```

Open `http://<watch-ip>:<web-port>/` on any phone, tablet or PC on the same network, enter the access code once, and you get a file browser: list, upload with a progress bar, download, create folder, rename, delete. Nothing to install, and the page has no external assets so it works on a LAN with no internet.

Details and the protocol subset: [docs/http-server-design.md](docs/http-server-design.md).

## FTP commands

`USER PASS SYST FEAT OPTS PWD CWD CDUP TYPE MODE STRU PASV EPSV LIST NLST MLSD MLST RETR STOR APPE REST SIZE MDTM DELE MKD RMD RNFR RNTO NOOP ABOR STAT ALLO QUIT`

- passive mode only: `PASV` (227) and `EPSV` (229); `PORT` and `EPRT` get `502`
- client paths are normalised and `..` is clamped at the virtual root
- commands on one connection run in order, so a transfer cannot interleave with the next command

## Tests

Two end-to-end suites, both run against the real device.

`Test-Ftp-Suite.ps1` speaks FTP over a raw control connection and hand-built passive data channels: 65 checks covering the pre-auth gate, credential handling, traversal clamping, unicode names, SIZE/MDTM/MLSD, APPE, REST resume, directory semantics, rename, an 8 MB transfer compared by SHA-256, two concurrent clients, and the client-path policy.

`Test-Http.ps1` drives the browser service with curl and a cookie jar: 22 checks covering the 401 gate, login, CSRF (a forged token must get 403), upload/download with SHA-256, Range, mkdir/rename/delete, traversal and chunked-body rejection.

The web page is also exercised in a real browser (Chrome, isolated context, 390x844 viewport) against the watch: login, bucket navigation, upload through the page's own XHR path, download with `Content-Disposition`, and delete with its confirm dialog. `tools/preview-page.js` renders the same markup to `preview/index.html` so layout can be reviewed without a device.

```powershell
powershell -ExecutionPolicy Bypass -File .\Test-Ftp-Suite.ps1 -WatchIp <ip> -Port <ftp> -User <u> -Pass <p> -LargeMb 8
powershell -ExecutionPolicy Bypass -File .\Test-Http.ps1 -WatchIp <ip> -Port <http> -Code <code>
# add -TestLockout to the FTP suite to drive the 30 s cooldown (takes ~35 s longer)
```

Last run: FTP 65/65, HTTP 22/22. 8 MB over FTP: 1.5 MB/s up, 3.7 MB/s down, SHA-256 equal.

## Storage layout

Six buckets live at the root: `Images`, `Videos`, `Audio`, `Documents`, `Archives`, `Others`. They always exist, so the browser has a stable layout.

Filing is a policy, not a filesystem rule:

- **HTTP** uploads that land directly in the root are moved into their bucket, and the JSON reply names the final path.
- **FTP** uploads are never moved. A client that names a path must be able to find the file at that path afterwards; silently relocating it breaks `SIZE`, `RETR` and resume. The switch is `classifyRootUploads` in `FtpServer.ets`.

Type detection is extension first, magic bytes only when the name has no useful extension. Details: [docs/storage-layout.md](docs/storage-layout.md).

## Background execution: not granted

The app asks for a `DATA_TRANSFER` continuous task when it starts serving. On this watch the request fails with `BusinessError 9800005 - Continuous task verification failed`, so the app does **not** have background protection. Practical consequence: transfers work while the page is on screen, and the process can be reaped after it is backgrounded.

An earlier version of this README claimed the suite had passed with the display suspended, and treated that as proof. It was not: the process simply had not been frozen yet.

Deep sleep is a separate matter: once the screen is off and there is no traffic, the watch drops off Wi-Fi entirely (no ping) until it is woken. That is a radio power policy and is not controllable from the app.

## Build, install, test

```powershell
powershell -ExecutionPolicy Bypass -File .\Build-Hap.ps1
powershell -ExecutionPolicy Bypass -File .\Deploy-Hap.ps1 -Device <ip:port>
powershell -ExecutionPolicy Bypass -File .\Test-Ftp-Suite.ps1 -WatchIp <ip> -Port <ftp> -User <u> -Pass <p>
powershell -ExecutionPolicy Bypass -File .\Test-Http.ps1 -WatchIp <ip> -Port <http> -Code <code>
```

Ports and credentials change on every start. Both are printed by hilog, except the HTTP access code which is on the watch face only:

```powershell
hdc -t <serial> shell "hilog -x | grep -E 'WatchFtp|WatchHttp' | grep listening"
```

Signing uses DevEco automatic signing. `build-profile.json5` holds the resulting config with encrypted, machine-bound passwords; on another machine, turn automatic signing on again.

## Layout

```
entry/src/main/ets/services/FtpServer.ets     FTP protocol, passive data channel
entry/src/main/ets/services/HttpServer.ets    HTTP/1.1 subset, sessions, streaming
entry/src/main/ets/services/WebUi.ets         server-rendered browser page
entry/src/main/ets/services/FsStore.ets       sandbox file access, path clamping
entry/src/main/ets/services/Classifier.ets    type buckets, extension + magic sniffing
entry/src/main/ets/services/NetInfo.ets       picks the Wi-Fi IPv4 for display
entry/src/main/ets/pages/Index.ets            466x466 UI, service lifecycle
Build-Hap.ps1 Deploy-Hap.ps1 Test-Ftp-Suite.ps1 Test-Http.ps1
docs/                                         audit, architecture, designs, reports
tools/Start-Hotspot.ps1                       revives the Windows mobile hotspot
```

## Not done

- No watch-side file manager, image viewer, audio player, video player or text reader yet. See [docs/development-roadmap.md](docs/development-roadmap.md).
- No FFmpeg probe project yet. Nothing in this repo includes or claims FFmpeg.
- No WebDAV, no HTTPS/FTPS.
- UI strings are Chinese.

## Windows note

Windows 11 turns the mobile hotspot off when no device has been connected for a while. The watch then sleeps, cannot rejoin, and hdc stays offline until the hotspot is back. `tools/Start-Hotspot.ps1` starts it through the WinRT tethering API.
