# Crown input

`onDigitalCrown` works on this watch, but only after the component it is attached to **has focus**. The SDK says it plainly and it is easy to miss:

> Called when the crown is rotated while the component has focus.

Without focus the callback never fires and the crown appears dead - which is exactly what the first hardware test looked like. The fix is three attributes on the container that handles paging:

```ts
Column() { ... }
  .focusable(true)
  .defaultFocus(true)
  .focusOnTouch(true)
  .onDigitalCrown((event: CrownEvent) => { ... })
```

After that the device logs real events:

```
WatchCrown: degree=... vel=...
```

`CrownEvent` carries `degree` (per-event rotation), `angularVelocity` (deg/s), `timestamp` (ns) and `action`. The reader accumulates `degree` and turns a page every 10 degrees, so a slow turn does not fly through the file.

## Swipe fallback

Not everyone wants to spin a crown, and a second input path costs little. The reader body also accepts a vertical pan:

- drag up more than 28 vp -> next page
- drag down more than 28 vp -> previous page
- tap the top quarter -> previous, bottom quarter -> next (unchanged)

Verified with `uinput -T -m 233 330 233 150` on the watch: `第 1 页 · 6%` -> `第 2 页 · 7%`.

## Why the images viewer uses the crown differently

The viewer pages with the crown and zooms with buttons; the reader pages with the crown and changes font with buttons. Both keep the crown for the thing you do most often.

## Status

| Item | Result |
| --- | --- |
| crown events delivered after adding focus | PASS (hilog `WatchCrown` lines on the watch) |
| crown turns a page | PARTIAL - the events arrive and share the same handler as tap/swipe, but the page change itself was not photographed |
| swipe turns a page | PASS (watch, page 1 -> 2) |
| tap turns a page | PASS (watch, page 1 -> 3) |

The remaining check is one screenshot before and after a crown turn; the watch dropped off the hotspot before that could be captured.
