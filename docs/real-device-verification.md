# Real device verification (HUAWEI WATCH 5, RTS-AL00)

First full run on hardware rather than the emulator. Device: HarmonyOS 6.1.0.125, API 23, 466x466 at density 2, reached over Wi-Fi with `hdc tconn`.

Everything below was driven over HDC: `uinput -T -c x y` for taps, `uinput -T -d/-u` with a 1.2 s gap for long press, `snapshot_display` + `file recv` for evidence, `hilog` for state.

## Connection note

The first attempt failed with `[F] Send isDead channelId:…` on every command even though `hdc list targets` showed `Connected`, twelve retries in a row. The fix was to restart the server:

```
hdc kill
hdc start
hdc tconn <ip>:<port>
```

After that the install succeeded first time. Worth remembering: a stale HDC server session looks exactly like a flaky watch.

## Protocol suites

| Suite | Result |
| --- | --- |
| FTP (`Test-Ftp-Suite.ps1`, 8 MB round trip) | **65 / 65 PASS** |
| HTTP (`Test-Http.ps1`, 512 KB) | **22 / 22 PASS** |

These are the same suites that pass on the emulator, now against the watch's own Wi-Fi and storage.

## UI, on the watch

| Item | Result | Evidence |
| --- | --- | --- |
| file manager opens on the bucket overview | PASS | `real-watch-files.jpeg` |
| metadata probe on a real file | PASS | `WatchProbe: watch-test.jpg image/jpeg kind=IMAGE container=jpeg play=SYSTEM size=320x240` |
| reader opens a UTF-8 file | PASS | `real-reader-resume.jpeg` |
| reader tap paging (page 1 → 3) | PASS | header went `第 1 页 · 0%` → `第 3 页 · 6%` |
| reading progress survives close/reopen | PASS | reopened at 第 5 段, `6%`, footer `来自缓存` |
| keep-screen-on around a reader | PASS | `WatchScreen: keep screen on: true` … `false` … `true` |
| image viewer opens a real JPEG | PASS | `real-viewer-zoom.jpeg`, `1/2`, `320x240 image/jpeg` |
| button zoom, two steps | PASS | badge `1.5x`, image visibly magnified |
| pixel cache hit | PASS | `WatchViewer: load …hit=no` then `hit=yes` on reopen |
| long-press detail sheet | PASS | `real-detail.jpeg`: 文件操作 / real-cover.jpg / 图片 · 6.8 KB · 可播放 |
| copy to another bucket | PASS | `real-copy-sheet.jpeg`; `/Documents/real-cover.jpg` then confirmed over HTTP and deleted again |

## Still not verified

| Item | Why | What it needs |
| --- | --- | --- |
| crown paging | HDC has no crown injection path; `uinput` only does touch and keys | one physical rotation while a reader is open |
| pinch zoom | single-touch injection only | two physical fingers (button zoom covers the need) |
| rename via the text overlay | needs typing into a `TextInput`; `uinput -K` could do it but the flow was left for a later pass | a manual run or an input-injection pass |
| delete via the UI confirm dialog | the copy path shares all the same plumbing and was exercised; delete was only done over HTTP | a manual tap on 删除 + confirm |
| 8 MB FTP throughput as a number | the suite asserts integrity, not speed | a timed run if the user cares about MB/s |

## Notes from the hardware run

- Layout numbers held: the same 26/28/30 vp header/row/tab heights that were measured on the emulator look correct on the watch, so the density assumption (2x) was right.
- The reader's `已恢复` note is overwritten by `来自缓存` when the text cache also hits; the percentage in the header is the reliable indicator.
- After resuming, the page counter restarts at `第 1 页` because pages are counted from the resume offset, not the file start. Known, documented, not fixed.
