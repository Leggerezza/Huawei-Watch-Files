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

## Screen layout

```
┌ 466x466 round ────────────────┐
│  Images            12 项  ⚙   │  header: current view, count, (settings)
│  ────────────────────────────  │
│  🖼  假期照片.jpg        470 KB │  row: icon, name (ellipsised), meta
│  🖼  screenshot-01.png   1.2 MB│
│      …                        │
│  ────────────────────────────  │
│  [分类] [目录] [最近] [传输]     │  bottom tabs, 4 items max
└───────────────────────────────┘
```

Rules taken from the round screen:

- **Safe area**: content is a square inscribed in the circle; the top and bottom 40 px are reserved for tabs/status, never for row text. Rows are clipped with a fade at the extremes.
- **Row height 44 px minimum**, one row = one touch target; the whole row opens the file.
- **Name ellipsis at 18 characters**, long-press shows the full name in a small sheet with size, mtime, MIME, container, codec, playability.
- **No nested menus**: row → detail sheet → action buttons in the sheet, at most two levels.
- **List virtualisation**: ArkUI `List` + `LazyForEach` with an `IDataSource`; never build a `Column` of 500 rows.
- **Scrolling**: `List` with `edgeEffect: Spring`; the round screen makes the first/last item partially visible, so add 24 px top/bottom padding inside the list.

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
