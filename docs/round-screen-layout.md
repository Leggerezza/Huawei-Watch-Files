# Round-screen layout

> Screenshots elsewhere in docs/ taken before this fix (`file-manager-*`, `text-reader-*`, `image-viewer*`) show the superseded full-width layout. Use the `circle-*` captures for the current one.

The watch framebuffer is 466x466, but the panel is a circle: only the inscribed circle is visible. Screenshots capture the whole square, so **clipping is invisible in every screenshot taken with `snapshot_display` or the emulator's `-screenshot`** - the first round-screen bug was found by photographing the watch, not by looking at a capture.

## The tool that closes the loop

`tools/Circle-Mask.ps1` blacks out everything outside the inscribed circle of a screenshot:

```powershell
powershell -File tools\Circle-Mask.ps1 -In shot.png -Out masked.png
```

Every UI screenshot in this repo should be checked through it before claiming a layout is correct. The "before" state - icons cut on the left, sizes cut on the right, `分类` and `服务` tabs invisible - is exactly what the user saw.

## Safe area

With diameter 466 the safe square is 466/√2 ≈ **330 px, i.e. x and y in 68..398**, or 165 vp. Fixed chrome (header, tab bar) must stay inside that square; a scrolling list can use a wider band around the vertical centre where the circle is widest.

| Element | Size | Position / padding |
| --- | --- | --- |
| top offset | 30 vp | everything starts below the curve |
| header | 18 vp tall | 42 vp side padding |
| list rows | 22 vp tall | 28 vp side padding, 6 vp top padding |
| tab bar | 18 vp tall, 160 vp wide | centred pill, 24 vp from the bottom |
| overlays (detail / input / copy) | 150 vp wide | centred |

Six rows of 22 vp = 132 vp; plus header 18 + paddings 30 + 24 + 6 = 210 vp of the 233 available, so the six buckets still fit without scrolling.

## Controls live outside the square

The circle has four "ears" outside the inscribed square - at mid-height the full 466 px width is visible. Buttons belong there, not in the page flow:

- reader: `A-` and `A+` are vertical pills on the left/right edge at mid-height; the body then owns the whole square
- viewer: `-` and `+` were already on the edges for the same reason

## Reader

- Root padding 26 vp top / 18 vp bottom, body 34 vp side padding (exactly the inscribed square).
- The paginator's budget is **165 x 150 vp**. The earlier 186 x 126 wasted vertical space on a footer that no longer exists, and before that the body overflowed and painted over the buttons.
- The body container also `clip(true)`s, so even a mis-paginated page can never paint over the header or the note.
- **Glyph width calibration**: the paginator models a Latin glyph as 0.68 em and a space as 0.35 em. The first estimate was 0.55, which made every modelled line wrap into about 1.15 visual lines and pushed one extra line onto every page. CJK stays at 1.0 em.

## Image viewer

- Top bar moved to 28 vp from the top with 42 vp side padding - the back arrow and the `1/4` counter were outside the circle at their original position.
- `-` / `+` stay on the left/right edges at mid-height, where the circle is full width, so they were never clipped.
- Bottom strip (prev, zoom badge, next) sits 8 vp above the bottom edge inside the circle.

## Verification

Confirmed on the hardware as well (masked `snapshot_display` captures): `circle-buckets-watch.png`, `circle-reader-watch.png`, `circle-viewer-watch.png`. The emulator captures (`circle-buckets.png`, `circle-reader.png`, `circle-viewer.png`) remain as the reference for the current pagination budget.

## Verification (emulator)

Masked captures on the emulator (466x466, same geometry as the watch):

| Screen | Result |
| --- | --- |
| bucket list + tabs | PASS - `circle-buckets.png` |
| reader (page fits, footer clear) | PASS - `circle-reader.png` |
| image viewer chrome | PASS - `circle-viewer.png` |

Not yet re-checked on the hardware: the watch dropped off the hotspot after the host BSOD, so the physical re-verification of this layout is still pending. The emulator runs the same 466x466 geometry, so the mask is a faithful proxy, but a photo of the watch is the only real proof.


