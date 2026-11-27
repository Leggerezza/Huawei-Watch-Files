# Regression test report

Device: HUAWEI WATCH 5 `RTS-AL00`, OpenHarmony 6.1.0.125 / API 23.
Build under test: `entry-default-signed.hap`, 436 KB, bundle `io.github.leggerezza.files`, installed 2026-11-26 22:08.
Markers: PASS / FAIL / PARTIAL / BLOCKED / NOT TESTED.

## Summary

| Area | Result | Evidence |
| --- | --- | --- |
| Build + sign | PASS | `Build-Hap.ps1`, 436 KB signed, no compile errors |
| Install + launch | PASS | `hdc install -r`, `aa start`, pid present |
| FTP protocol suite (65 checks) | PASS | 65 passed, 0 failed |
| FTP large transfer | PASS | 8 MB up 5227 ms (1.5 MB/s), down 2168 ms (3.7 MB/s), SHA-256 equal |
| FTP path policy change | PASS | root uploads stay at the client path, nothing filed |
| HTTP protocol suite (22 checks) | **PASS** | 22 passed, 0 failed |
| Stage 1 layering (hub / metadata / media) | **PASS** | metadata probe + ImageSource decode on device |
| Browser end-to-end (real Chrome, isolated context) | **PASS** | login, list, upload, download verified against the watch |
| Background continuous task | **FAIL** | `BusinessError 9800005 - Continuous task verification failed` |
| Media (audio/video playback, text reader) | NOT TESTED | not implemented in this build |
| FFmpeg probe | NOT TESTED | project not started |

## FTP suite detail

Run at 22:09-22:10 against `192.168.137.95:38609`.

```
1  greeting / pre-auth gate      5/5
2  credential checks             5/5
3  login and basic commands      6/6
4  traversal clamping            4/4
4b scratch workspace             2/2
5  unicode name round trip       4/4
6  SIZE / MDTM / MLSD            4/4
7  APPE                          3/3
8  REST resume                   2/2
9  directory semantics           7/7
10 rename                        5/5
11 NLST / MLSD listings          2/2
12 large transfer                3/3
13 concurrent clients            3/3
14 cleanup + root layout         4/4
15 client-path policy            7/7
```

Two defects were found and fixed while getting here:

1. `STOR` of a small file intermittently stored 0 bytes. Root cause: the passive data connection's `message` listener was attached in the transfer handler, so a client that wrote its payload and closed before the command was parsed lost the bytes when the socket layer closed the connection. Fix: attach a collector in the `connect` callback and drain it into the sink.
2. The suite's control socket timeout was 8 s, shorter than an 8 MB transfer, so a slow but correct transfer looked like a dropped connection. Fixed to 120 s.

## Stage 2 slice 1: file manager

Verified on the wearable emulator (466x466, API 23) with the emulator's own automation channel: `-uiLayout -i` for widget ids and bounds, `-click` to actuate, `-screenshot` for evidence.

| Check | Result |
| --- | --- |
| bucket overview shows six buckets with item counts and bytes | PASS |
| tapping `Images` opens the filtered list (3 files with sizes) | PASS |
| directory tab lists the six bucket folders | PASS |
| recent tab lists files newest-first | PASS |
| service tab shows state, IP, both ports, credentials and log lines | PASS |
| all six buckets fit without scrolling on the round screen | PASS |

Measured from the widget tree: header 26 vp, row 28 vp, tab bar 30 vp, at density 2 (1 vp = 2 px), so the layout canvas is **233x233 vp**, not 466. The first build treated 466 as vp, which made every row 80 px and left only three buckets visible; that is why the design doc's original "44 px row" figure was wrong and has been corrected.

Screenshots: [file-manager-buckets.png](file-manager-buckets.png), [file-manager-images.png](file-manager-images.png), [file-manager-dir.png](file-manager-dir.png), [file-manager-recent.png](file-manager-recent.png), [file-manager-service.png](file-manager-service.png).

Not in this slice: detail sheet, delete/rename/move/copy, thumbnails, pull-to-refresh, and the "long press for full name" behaviour - the row currently shows a toast with name, kind, size and playability instead.

## Stage 1 verification

Build 486 KB, installed 22:50, `ServerHub` owning both transports.

**Metadata layer on device** - after a real 320x240 JPEG was uploaded, the startup self-check logged:

```
WatchProbe: [Images] watch-test.jpg image/jpeg kind=IMAGE container=jpeg codec= play=SYSTEM size=320x240
```

That single line exercises `FsStore.readHead`, `Metadata.inspect` (extension + magic → container, kind, policy) and `MediaBackend.imageInfo` (`ImageSource` actually decoded the file and returned 320x240). `policyPlayable=SYSTEM` matches the capability report for JPEG.

**Browser end-to-end** - Chrome in an isolated context (`watch-live`), phone viewport 390x844, against the watch at `http://192.168.137.95:47553/`:

1. unauthenticated visit shows the access-code page (server returns 401, expected);
2. typing the code and submitting navigates to the browser page - `9.94 GB / 13.55 GB`, six buckets plus `readme.txt`;
3. clicking `Images` navigates with the breadcrumb and a `..` row;
4. uploading a 300 KB `File` through the page's own `XMLHttpRequest` path reports `上传完成`, 100% progress;
5. the server log confirms `upload /browser-upload.jpg -> /Images/browser-upload.jpg (307200 bytes)`, i.e. the HTTP filing policy applied;
6. `fetch('/dl?...')` returns 200, `image/jpeg`, 307200 bytes, first bytes `FF D8 FF E0`, and `Content-Disposition: attachment; filename="..."; filename*=UTF-8''...`;
7. pressing 删 raises the confirm dialog, accepting it deletes the file and lands on the "已删除" page.

Three UI defects were found by the browser and fixed: the mkdir input had no `autocomplete` (Chrome accessibility issue), the per-row delete button had a ~28 px hit area (now ~34 px with an `aria-label`), and every page load produced a `favicon.ico` 404 (now `204`).

Artifacts: [browser-browse.png](browser-browse.png), [browser-images.png](browser-images.png).

**Regression after the refactor**: FTP 65/65 and HTTP 22/22 both re-run on this build, so the layering did not break either transport.

## HTTP suite detail

Run at 22:18 against `192.168.137.95:35922`.

```
1 authentication gate   5/5
2 traversal / errors    4/4
3 upload/download       5/5   (512 KB, SHA-256 equal, Range 206 + 100 bytes)
4 mutations             5/5   (mkdir / rename / delete / bad-csrf refused)
5 session hygiene       2/2
```

Three defects were found while getting here, all real:

1. **The app crashed on the first successful login.** `reason: JsError`, exit code 254, right after `login ok` in the log. Cause: the 302 response has an empty body, and `TextEncoder.encodeInto('')` returned nothing to read `.buffer` from, throwing inside the socket callback. An uncaught JS error kills the whole process, so the whole app went down and every later request was "connection refused". Fixed with an `encodeBody()` helper that returns an empty buffer for an empty string, plus a `try/catch` around request handling so one bad request can no longer take the app with it.
2. **`HttpServer` never wrote to hilog**, only to the UI log strip. The port could not be read from logs, which made every test cycle depend on OCR. Now every HTTP log line goes to hilog as well.
3. **The test script had a variable collision**: `$code` (a local) and `$Code` (the parameter) are the same variable in PowerShell, so the "correct access code" login actually sent the string `401`. The server's diagnostic line (`login rejected: got=3 expected=6`) is what exposed it. Locals renamed to `$st`.

Symptom of #1 in hindsight: unauthenticated requests and wrong-code logins worked (both have non-empty HTML bodies), only the successful login killed the app.

## Background execution

`startBackgroundRunning(DATA_TRANSFER)` fails on this device with `BusinessError 9800005`, which the SDK declares as **"Continuous task verification failed"**. The system refuses to grant the task; the call is not silently succeeding, it throws and is caught by the UI which shows `保活失败` on the watch.

Consequences, observed directly:

- with the display on, both servers work (everything measured above was measured that way);
- once the page is backgrounded the process can be reaped: one run lost its pid with no crash entry, and its ports answered "connection refused" afterwards;
- the earlier claim "the suite passed with the screen suspended, therefore background works" was wrong - the process simply had not been frozen yet in that window.

Recorded as FAIL. The app does not claim background service; the roadmap item is to either find the verification precondition this wearable enforces, or drop the continuous-task code and document that transfers must happen while the app is on screen.

## Environment notes

- The watch leaves Wi-Fi entirely after idle + screen off; three test attempts in this round had to wait for it to be physically woken.
- HDC address changed twice: `192.168.137.223:34041` -> `192.168.137.95:41467`. Scripts take the address as a parameter for this reason.
- Reading the on-screen credentials from a 466x466 screenshot is error-prone (`kzxryy` was first misread as `kzrry`). The test flow now crops and upscales the credential line before reading.
