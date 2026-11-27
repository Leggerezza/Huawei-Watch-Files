# File manager design (stage 2)

A local file manager on a 466x466 round screen, over the same `FsStore` the servers use. No second storage model.

## What exists to build on

- `FsStore`: list, stat, copy, move, removeTree, mkdir, freeBytes/totalBytes, `uniquePath`, `sweepTemp`.
- `Metadata`: kind/container/codec/MIME and a playability policy.
- `Classifier`: the six buckets and the rule that keeps them where a phone can see them.

Stage 2 is UI plus a view model. No new filesystem code is expected beyond what stage 1 added.

## Information architecture

Two axes, both first-class, because the bucket view alone loses custom folders:

```
Home (round 466)
├─ 分类视图    Images · Videos · Audio · Documents · Archives · Others
├─ 目录视图    /  (whole sandbox, including user-made folders)
├─ 最近        files touched in the last 7 days, newest first
└─ 传输        FTP/HTTP status, ports, credentials (moved from the current page)
```

Switching between 分类 and 目录 must not lose position. A file in a custom folder is reachable in both views: the bucket view is a *filter over the whole tree* (by `Metadata.kind`), not a listing of `/Images`. That is the one design decision that prevents "my file vanished because it is not in a bucket".

Consequence: the bucket view scans. On 10 GB of files that is a full tree walk, so it must be cached and time-boxed:

- first entry to a bucket view: walk with a 1.5 s budget, render what was found, show "仍在扫描…" and continue in the background;
- cache the result keyed by directory mtime; invalidate on any write operation the app performs;
- never block the first frame on the walk.

## Screen metrics (measured, not assumed)

The watch reports **466x466 px at density 2**, so the ArkUI canvas is **233x233 vp**. Treating 466 as vp - the first thing this design did - doubles every row and only three buckets fit. The numbers below are what actually shipped and were verified with a screenshot plus the emulator's widget tree:

| Element | vp | px |
| --- | --- | --- |
| header | 26 | 52 |
| list row | 28 | 56 |
| tab bar | 30 | 60 |
| body font | 10 | ~20 |
| meta font | 7 | ~14 |

Six bucket rows (168 vp) + header (26) + tabs (30) = 224 vp, which fits 233 with 9 vp left over. The circle still clips the extreme corners, which is why the list keeps a 4 vp top/bottom inset and no row text sits in the outer 20 vp.

## Layout

```
┌ 233x233 vp round ─────────────┐
│ ‹  分类            名称↑       │  header 26 vp: back, title, sort
│  🖼  Images     3 · 429.7 KB  │  row 28 vp
│  🎬  Videos     1 · 878.9 KB  │
│  🎵  Audio      1 · 293.0 KB  │
│  📄  Documents  3 · 44.1 KB   │
│  🗜  Archives   1 · 14.6 KB   │
│  📦  Others     1 · 4.9 KB    │
│  分类   目录   最近   服务      │  tab bar 30 vp
└───────────────────────────────┘
```

Rules taken from the round screen:

- **Safe area**: content stays inside the square inscribed in the circle; the outer ring is never used for text.
- **One row = one touch target** (28 vp ≈ 56 px ≈ 4.7 mm); tapping anywhere in the row opens the file.
- **Name ellipsis at 12 characters**, the full name appears in the detail toast/sheet.
- **No nested menus**: row → detail sheet → actions, at most two levels.
- **List virtualisation**: ArkUI `List` + `LazyForEach` over an `IDataSource`; never a `Column` of every file.
- **Scrolling**: the list scrolls only when it has to; the bucket overview fits without scrolling by design.

## Interactions

| Gesture | Effect |
| --- | --- |
| tap row | open: image viewer / audio player / video player / text reader, or "no viewer" sheet for anything else |
| long press row | detail sheet: size, modified, MIME, container, codec, playability, path; actions 重命名 / 移动 / 复制 / 删除 / 详情 |
| swipe row left | 删除 (with confirm), matching the platform convention |
| crown rotate | scroll the list; if no crown events arrive, fall back to drag (see open question) |

Destructive actions always confirm; the confirm names the item and its size.

## View model

`FileListView` (ArkTS class, not a component):

```
state: { view, path, entries, loading, scanning, error, selection }
methods: open(view), enter(dir), up(), refresh(), sortBy(key), remove(entry), rename(entry, name),
         move(entry, dst), copy(entry, dst), stats()
```

It owns the `FsStore` calls and exposes plain data; the component renders and forwards taps. This is what keeps the UI free of filesystem logic and makes the manager testable without a screen.

Sorting: name / size / modified / kind, ascending/descending, remembered per view in memory (no persistence file in stage 2).

## Costs and risks

| Risk | Mitigation |
| --- | --- |
| Bucket view scan on a large tree stalls the UI | time-boxed walk, incremental render, cache by mtime |
| `ImageSource` per row for thumbnails | stage 2 does **not** show thumbnails, only type icons; thumbnails are stage 5 with `desiredSize` and a bounded cache |
| Deleting a file that is currently open in a player | operations refuse while a viewer holds the file, with a clear message |
| Round-screen text clipping | fixed safe-area gutter + ellipsis + full-name sheet |
| Crown input unknown on this device | probe `onRotate` in a throwaway page first; if no events, drag only |
| Background task refused (`9800005`) | the manager is foreground-only by design; transfers started here must finish before leaving the page |

## Stages inside stage 2

1. **List + navigation** (分类/目录/最近), lazy rows, breadcrumb, sort menu. Verify in the emulator: 200+ generated files, scroll, open a folder, back.
2. **Detail sheet + open routing**: read `Metadata` for the file, route by `MediaKind` to a "not implemented yet" placeholder for now.
3. **Mutations**: mkdir, rename, delete, move, copy with conflict handling via `FsStore.uniquePath`.
4. **传输 tab**: move the current servers page into it, so the app has one home.

Each step ends with an emulator screenshot and a log line rather than "it compiles".

## Open questions

- **Crown events**: does this watch deliver rotate events to a third-party page? Needs a 20-line probe page. If not, the design drops crown support without losing anything else.
- **Bucket semantics**: filter-over-tree (proposed) versus literal bucket directories. The filter costs a walk but never hides a file; the literal listing is cheap but shows only what HTTP filed. Proposal: filter, with a "只显示已归档" toggle for people who like the physical layout.
- **Where do transfers live**: separate tab (proposed) versus a status chip on every screen. The tab is simpler on a 466 px screen.
