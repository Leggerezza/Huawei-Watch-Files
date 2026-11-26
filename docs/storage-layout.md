# Storage layout and automatic filing

Question this answers: can files arriving over FTP be sorted into per-type folders inside the app sandbox, as the basis for a file browser later?

Implemented and verified on the watch. The interesting part is not whether it works, it is what it costs.

## What is implemented

Six buckets are created at the FTP root when the server starts:

```
/Images  /Videos  /Audio  /Documents  /Archives  /Others
```

A file uploaded **directly into the root** is moved into its bucket as soon as the upload finishes:

```
STOR photo.jpg      ->  226 Transfer complete (91200 bytes). Stored as /Images/photo.jpg.
```

A file uploaded to an explicit path is never touched:

```
STOR backup/photo.jpg   ->  stays at /backup/photo.jpg
STOR /Documents/x.pdf   ->  stays at /Documents/x.pdf
```

## Type detection

Two passes, extension first:

1. **Extension** — jpg/png/heic… → Images, mp4/mov/mkv… → Videos, mp3/flac/wav… → Audio, pdf/doc/xlsx/txt… → Documents, zip/rar/apk/hap… → Archives.
2. **Magic bytes** — only when the name has no usable extension. Reads 32 bytes and checks JPEG, PNG, GIF, BMP, WEBP/RIFF, PDF, ZIP, Matroska, FLAC, OGG, ID3/MPEG audio and ISO-BMFF `ftyp` (with HEIC brands going to Images, other brands to Videos).

Extension wins on purpose: a `.jpg` that is really a PNG stays in Images, which is what the person filing it expects. Anything unrecognised goes to `Others` and is never rejected.

Name collisions are resolved without overwriting: `photo.jpg`, `photo (1).jpg`, `photo (2).jpg`.

## The cost: path fidelity

FTP has no way to say "I moved it". A client that uploads `/photo.jpg` and then asks for `SIZE /photo.jpg` gets `550`, because the file is now `/Images/photo.jpg`. The 226 reply carries the new path, which FileZilla, WinSCP and most phone clients display in their transfer log, but a client that only refreshes the listing will simply show `photo.jpg` gone and an `Images` folder appearing.

That is why the feature is scoped to root uploads only:

- uploading straight to the root means "I do not care where it goes", and that is exactly the case the bucket is for
- naming a path means "I do care", so the path is respected
- `APPE` never moves anything, since appending assumes a stable path

The switch is `classifyRootUploads` in `FtpServer.ets`, default on.

## Why not the alternatives

- **Copy into a bucket, keep the original** — double the storage. The watch has ~10 GB free and videos are the point of the feature.
- **Symlink / hard link** — `fs` exposes no link creation worth relying on, and a link in the FTP root would show up as a file that cannot be opened by many clients.
- **Virtual type folders** (a listing computed by scanning the whole tree) — no data movement and no broken paths, but every path operation then needs a virtual-to-real resolver, and the directories would look writable while `STOR` into them has to be special-cased. More machinery than a rename.
- **Sort at the client** — tells the phone what it should do instead of doing it. Fine, but it leaves the watch's sandbox flat, which is the problem being solved.

A rename on the same filesystem is metadata-only: measured cost for an 8 MB upload is unchanged at 2.0 MB/s, which is the Wi-Fi limit, not the disk.

## What it gives the file browser

The next stage mostly needs a stable, cheap listing:

- one level of directories, six of them, in a fixed order — a watch screen can show that without scrolling logic
- no tag database or index to keep in sync, so no migration when the app updates
- `MLSD` already reports `type`, `size` and `modify` per entry, which is enough for a list with icons and timestamps
- `SIZE` / `MDTM` answer for any file, so a detail view needs no extra protocol

What it does *not* give you: thumbnails, taken dates, or search. Those need either a sidecar index written at upload time or a scan at startup. For a first browser, listing six folders is enough; a photo grid would want the index.

## Verified

Section 15 of `Test-Ftp-Suite.ps1`, 12 checks, all passing on the device:

- extensionless PNG filed by magic into `/Images`
- `.pdf` / `.zip` / `.mp4` / `.mp3` filed by extension
- unknown bytes filed into `/Others`
- second upload of the same name becomes `noext (1)`
- the 226 reply names the filed path
- the original root path is gone
- an upload into an explicit subdirectory is not moved
