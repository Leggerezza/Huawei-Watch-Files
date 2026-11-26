# Phase 0 - Engineering audit and test baseline

Scope: HWWatchFiles as it actually exists in `C:\Users\Lenovo\DevEcoStudioProjects\Files` at commit `6fa9c99`, on the HUAWEI WATCH 5 (`RTS-AL00`) reached over HDC.

Method: read every `.ets` file in the project, run the build, run the protocol suite against the device, query the device and the SDK. Nothing below is inferred from file names or from the earlier reports; anything not re-checked is marked as such.

## 1. Environment (verified on this machine)

| Item | Value | How it was checked |
| --- | --- | --- |
| Device | HUAWEI WATCH 5, `RTS-AL00` | `param get const.product.model` |
| OS / API | OpenHarmony 6.1.0.125, API 23, arm64-v8a | `param get const.ohos.apiversion`, `uname -a` |
| Screen | 466x466 round | screenshot 466x466 |
| HDC | 3.2.0f, TCP `192.168.137.223:<port>` (port changes on reboot) | `hdc list targets -v` |
| Build SDK | HarmonyOS 26.0.0 (api 26), `compatibleSdkVersion 6.1.0(23)` | `sdk-pck.json`, `build-profile.json5` |
| Signing | DevEco automatic signing, bundle `io.github.leggerezza.files`, debug profile bound to the watch UDID | `build-profile.json5` + successful install |
| Node / hvigor | bundled `tools/node` + `tools/hvigor` | `Build-Hap.ps1` |
| Native toolchain | `native/llvm/bin/aarch64-unknown-linux-ohos-clang.exe`, `native/build-tools/cmake/bin/{cmake,ninja}.exe`, sysroot `native/sysroot/usr/lib/aarch64-linux-ohos` | directory listing |
| Storage free | ~10 GB of 14 GB (`df -h /data`) | device shell |

Toolchain consequence: a native module is buildable (clang + cmake + ninja + arm64 sysroot all present). That only means "can compile"; it says nothing about device-side load or decode, which is the point of the FFmpeg probe.

## 2. Code inventory (what each file actually does)

| File | Lines* | Actual behaviour |
| --- | --- | --- |
| `services/FtpServer.ets` | ~950 | FTP control state machine, PASV/EPSV data path, 30+ verbs, auth with one-time credentials, login throttle, idle sweep, connection cap, optional post-upload filing |
| `services/FsStore.ets` | ~180 | path normalisation and clamping, stat/list/mkdir/remove/rename, readme seeding |
| `services/Classifier.ets` | ~260 | six buckets, extension map, magic-byte sniffing (JPEG/PNG/GIF/BMP/RIFF/PDF/ZIP/Matroska/FLAC/OGG/ID3/MPEG/ISO-BMFF), collision-safe naming |
| `services/HttpServer.ets` | ~1050 | HTTP/1.1 subset: request parsing, session cookies, CSRF, streaming upload/download, Range, form actions |
| `services/WebUi.ets` | ~330 | server-rendered browser page, login page, inline CSS/JS, no external assets |
| `services/NetInfo.ets` | ~65 | enumerates networks, prefers Wi-Fi IPv4 |
| `pages/Index.ets` | ~250 | 466x466 UI, starts/stops both servers, background continuous task |
| `Test-Ftp-Suite.ps1` | ~430 | 72 protocol checks over raw sockets |
| `Test-Http.ps1` | ~150 | HTTP checks over curl with a cookie jar |

\* approximate, post-change.

Dependency graph is a flat two-layer tree: UI -> (FtpServer, HttpServer) -> (FsStore, Classifier, NetInfo) -> `@kit.CoreFileKit` / `@kit.NetworkKit`. There is no shared server-manager object yet; `Index` owns both instances.

## 3. Feature status

Legend: **verified** = exercised on the device in this engagement; **built** = compiles and is installed but not exercised; **absent** = not implemented.

| Capability | Status | Evidence |
| --- | --- | --- |
| FTP login, passive data, LIST/NLST/MLSD, RETR/STOR/APPE/REST, SIZE/MDTM, MKD/RMD/DELE/RNFR/RNTO | verified | `Test-Ftp-Suite.ps1` 72/72 on build `6fa9c99` |
| Path-traversal clamping | verified | suite section 4 |
| Unicode file names | verified | suite section 5 |
| 8 MB binary round trip, SHA-256 equal | verified | suite section 12, 2.0 MB/s up, 2.2 MB/s down |
| Login throttle (20 fails / 60 s -> 30 s cooldown, recovery) | verified | suite section 15 (`-TestLockout`) |
| Background continuous task keeps the server answering with the display off | verified | full suite ran with `power-shell suspend` |
| Root-upload filing (extension + magic) | verified on build `6fa9c99` | suite section 15; now default **off** for FTP |
| HTTP browser: login, list, upload, download, Range, mkdir, rename, delete, CSRF | built, not yet exercised | `Test-Http.ps1` written, device asleep when the build landed |
| Image viewer, audio player, video player, text reader | absent | - |
| FFmpeg probe project | absent | - |

## 4. Defects found and fixed in this engagement

All four were found by testing, not by reading:

1. **`RMD` deleted non-empty directories.** `fs.rmdirSync` removes recursively on this device, so `RMD deep` wiped a tree. Fixed: explicit emptiness check in `FsStore.remove`, non-empty now answers `550`.
2. **Upload data sink attached after the `150` reply.** A client that wrote and closed immediately could store 0 bytes (seen with `APPE`). Fixed: sink attached before `150`.
3. **`0.0.0.0` shown as the watch address.** `getDefaultNet()` returned a network without IPv4 when Bluetooth and Wi-Fi were both up. Fixed: walk `getAllNets()`, prefer the Wi-Fi bearer.
4. **Server killed itself after 12 bad passwords.** Guessing became a denial of service. Fixed: 60 s sliding window, 30 s cooldown, the server never stops itself.

## 5. Risks

| Risk | Impact | Mitigation in place |
| --- | --- | --- |
| Watch Wi-Fi is powered down after idle + screen off | server unreachable until the screen is woken | active transfers keep the radio up; documented, not controllable by the app |
| HDC wireless port changes on reboot | automation targets a stale `ip:port` | scripts take `-Device`; `hdc tconn` retry loop |
| Signing profile expires (2026-11-29) | installs start failing | re-run DevEco automatic signing |
| Both services share one bundle and one sandbox | a probe app would overwrite user data | probe work must use a separate bundle/profile or uninstall only with consent |
| Plaintext FTP/HTTP | credentials and content readable on the LAN | random one-time credentials, ephemeral ports, documented as LAN-only; no claim of encryption |
| HTTP server is new code with file-write reach | malformed requests could corrupt data | temp-file uploads, bounded headers/forms, path clamping, CSRF, 8-connection cap; needs the device test pass before being called done |

## 6. Baseline commands

```powershell
powershell -ExecutionPolicy Bypass -File .\Build-Hap.ps1
powershell -ExecutionPolicy Bypass -File .\Deploy-Hap.ps1 -Device <ip:port>
powershell -ExecutionPolicy Bypass -File .\Test-Ftp-Suite.ps1 -WatchIp <ip> -Port <ftp> -User <u> -Pass <p> -LargeMb 8 -TestLockout
powershell -ExecutionPolicy Bypass -File .\Test-Http.ps1 -WatchIp <ip> -Port <http> -Code <code>
```

Ports and credentials are regenerated on every start and shown on the watch face; `hilog -x | grep WatchFtp` prints the FTP port and account, the HTTP port and access code are on screen only.

## 7. Recommended order (and what this engagement actually did)

| Stage | Content | State |
| --- | --- | --- |
| 0 | audit + baseline | this document |
| 3 | FTP path consistency + hardening | done: filing off by default, fail-closed CSPRNG, 8-connection cap, 10 min idle sweep |
| 4 | HTTP file service | code complete, device test pending |
| 1 | storage/transport/media layering | partially: FsStore shared by both servers; media layer not started |
| 2 | file manager UI | absent |
| 5-9 | image / audio / video / metadata / text | absent |
| F0-F11 | FFmpeg probe | absent |

## 8. Blockers recorded

- The watch drops off Wi-Fi whenever it is idle with the screen off, so install/test windows depend on physically waking the device. This is the only recurring blocker and it is environmental, not a code defect.
- The FFmpeg probe has not been started: it needs a separate project, a cross-compile of FFmpeg 7.x against the SDK clang, and a signed install. None of that has been attempted yet, so no claim about FFmpeg on this device is made in this document.
