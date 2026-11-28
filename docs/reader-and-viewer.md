# Image viewer and text reader

Stage 5 (images) and the TXT part of stage 9, plus the answer to the "keep the screen on" question.

## Keeping the display awake

`window.setWindowKeepScreenOn(true)` is available to **normal applications** - the SDK only asks that it be used "in necessary scenarios (such as navigation, video playback, drawing, ...)". A full-screen reader or image viewer qualifies.

```ts
const win = await window.getLastWindow(ctx);
await win.setWindowKeepScreenOn(true);   // ... and false when the page closes
```

`services/ScreenKeeper.ets` reference-counts it, so overlapping pages cannot switch it off too early, and it is released on `aboutToDisappear`.

Confirmed on the device: opening the reader logs `WatchScreen: keep screen on: true`, closing it logs `false`.

**There is no API to postpone the screen-off timeout**, and none to wake a sleeping device. The choice is "stay lit while a page that needs it is open" or "let the watch sleep". A background file server cannot use this - it only applies while the app is in the foreground, which is also why continuous tasks mattered and why they are refused on this product.

## Image viewer (`components/ImageViewer.ets`)

- Decodes through `ImageSource` with `desiredSize` capped at 466 px on the long edge and `RGBA_8888`, so a 12 MP photo becomes at most a 466 px bitmap. The full-size `PixelMap` is never materialised.
- Shows dimensions and MIME from `getImageInfo()` in the header.
- Navigation: tap the left third for previous, the right third for next, the middle toggles the info bar; the crown also steps images. Thresholds are **in vp** (78 / 155 of a 233 vp canvas) - the first version used pixel values and the right third could never be hit.
- Pinch zooms 1..4x, one-finger pan moves the bitmap while zoomed.
- Failure is explicit: the previous bitmap is released before loading, then `无法解码 (...)` is shown. The first version left the last working image on screen behind the error.
- `@Watch` on `realPath` reloads when the parent steps to another image; without it the header changed but the pixels did not.

## Text reader (`components/TextReader.ets`)

- TXT only, and honest about it: no EPUB, no PDF, no images.
- Reads in 64 KB chunks up to 2 MB, then notes the truncation.
- Encoding: UTF-8 BOM, UTF-16 LE/BE BOM, otherwise UTF-8, falling back to GBK and finally forced UTF-8. The active encoding is shown in the footer.
- Font size 9..20 vp via the A- / A+ buttons, reapplied to the current page.
- Paging: crown (10 degree threshold) or a tap in the top quarter (previous) / bottom quarter (next).

### Pagination had to be rebuilt twice

1. First version estimated characters per page as `lines x charsPerLine`. Mixed Chinese/Latin text broke it: a CJK glyph is roughly twice as wide as a Latin one, so pages overflowed and the last line was clipped.
2. Second version walks the text accumulating **column units** (CJK = 1.0, Latin = 0.55, space = 0.3), starting a new line when the budget is exceeded, and stopping at the page's line budget.
3. The remaining bug was the budget itself: 168 vp of body height was too optimistic because the header and footer live inside the same 233 vp. Measured on screen, 200x138 vp is what actually fits; at 14 vp the page now ends cleanly.

The paginator still cuts mid-word at a page boundary rather than backing up to the last space; it does back up to the last newline when that is close enough. Word wrapping is a known rough edge.

## Verification matrix

| Item | Result | Evidence |
| --- | --- | --- |
| image decode + display, real JPEG 320x240 | PASS | `image-viewer.png` |
| image next/previous by tap | PASS | header `2/4` after tapping the right third |
| image decode failure state | PASS | fake-JPEG sample shows `无法解码` |
| reader opens a UTF-8 file, 31 pages at 11 vp | PASS | `text-reader-11vp.png` |
| font size A+ to 14 vp, re-paginates | PASS | `text-reader-14vp.png` |
| reader tap paging | PASS | page advanced on a bottom tap (watch: 第 1 页 → 第 3 页) |
| reading progress on hardware | PASS | resumed at 6% after close/reopen on the watch |
| keep screen on | PASS | hilog `WatchScreen: keep screen on: true` |
| crown paging (reader and viewer) | NOT TESTED | HDC has no crown injection path |
| pinch zoom / pan | NOT TESTED | emulator cannot synthesise multi-touch pinch; button zoom replaced it |
| long-press detail sheet + rename/copy/move/delete | NOT TESTED | emulator cannot synthesise a long press |
| reading progress persists across reopen | PASS | resumed at 6% with 已恢复 note |
| text cache hit | PASS | footer shows 来自缓存 |
| button zoom (2 steps to 1.5x) | PASS | image-viewer-zoom.png |
| pixel cache hit | PASS | on the watch: `WatchViewer load … hit=no` then `hit=yes` |

## Known gaps

- No reading progress persistence: reopening a file starts at page 1 (the design calls for it, the code does not do it yet).
- No word-level wrapping at page boundaries.
- The image viewer keeps one bitmap at a time; a filmstrip/thumbnail cache is stage 5's next step if the grid view is wanted.
- `ImageViewer` still allocates a full-screen `Image` node per image; a recycle pool would matter only for rapid bursts.

## Reading progress (added)

services/ReadingProgress.ets keeps a `preferences` store `watch_reading`: one JSON blob per file under `f:<path>` (offset + font size + timestamp) and a global `fontSize`. The reader loads it before the first page, renders from the saved offset, and saves debounced 600 ms after every page turn or font change, plus immediately on close.

Verified on the emulator: read to page 5, left the reader, reopened the same file → resumed at the same paragraph with `6%` in the header and `已恢复`/`来自缓存` in the footer.

Known rough edge: the header still says `第 1 页` after resuming, because page numbers count from the resume point rather than from the file start. The percentage is the honest indicator.

## Caches (added)

`services/MediaCache.ets` holds two bounded caches:

| Cache | Bound | Key | Notes |
| --- | --- | --- | --- |
| PixelCache | 6 bitmaps / 40 MB | `realPath | fileSize` | owns the PixelMaps and releases on eviction; the viewer only borrows, otherwise it would free a bitmap the cache still hands out |
| TextCache | 3 files / 6 MB | `realPath` | avoids re-reading and re-decoding a text file on reopen |

The viewer also pre-decodes the previous and next image after showing the current one, so stepping is instant when it fits in the budget.

Observed: the text cache hit is visible in the reader footer (`来自缓存`), and the viewer log shows `load ... hit=no` on first open. The **pixel cache hit path was not observed end-to-end**: driving the viewer's bottom strip through the emulator's click channel proved unreliable (clicks land but the strip does not always receive them), so only the miss path is logged evidence. The hit path is a dictionary lookup in `PixelCache.get` and is exercised by the prefetch, but should be confirmed on the watch.

## Zoom buttons (added)

The reference UI put `−` and `+` on the screen edges, which is where this viewer previously had its prev/next tap zones. The layout now is:

- edges: `−` / `+` zoom, discrete steps 1.0, 1.25, 1.5, 2.0, 2.5, 3.0, 4.0
- bottom centre: `‹` previous, a badge showing the current factor (tap resets to 1.0 and recentres), `›` next
- tap on the image toggles the whole chrome, for an unobstructed view

Buttons were chosen over gestures because the emulator cannot synthesise a pinch and a crown-only user has no pinch at all; the discrete steps also avoid the "stuck between two zoom levels" feel of a free pinch. Pan while zoomed is still one finger, clamped to `(scale-1) * screen/2` so the bitmap cannot be flung off-screen.

Verified: two `+` presses move the badge to `1.5x` and visibly magnify the image (`image-viewer-zoom.png`).


