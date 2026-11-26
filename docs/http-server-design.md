# HTTP file service design

A browser-facing file manager for the watch sandbox, built directly on `TCPSocketServer` because HarmonyOS ships no HTTP server.

## Protocol subset

Implemented:

- request line and headers, `Content-Length` bodies
- `GET`, `HEAD` (headers only), `POST`, `PUT`
- `Range: bytes=...` on downloads (single range, `206`)
- `Expect: 100-continue` answered immediately, so `curl -T` does not stall
- `Connection: close` on every response: one request per connection
- `Content-Disposition` with both an ASCII fallback and `filename*=UTF-8''`

Rejected explicitly rather than half-parsed:

| Input | Answer |
| --- | --- |
| `Transfer-Encoding: chunked` | `501` |
| headers over 16 KB | `431` |
| form body over 256 KB | `413` |
| multipart/form-data | not implemented: uploads are raw `PUT`/`POST` bodies |
| unknown method | `405` |

Keep-alive is not implemented. Browsers open several connections per page and cope fine; the cost is a TCP handshake per request on a LAN.

## Routes

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/` or `/browse?p=` | HTML browser for a virtual directory |
| GET | `/dl?p=` | download (attachment) |
| GET | `/raw?p=` | same bytes, `Content-Disposition: inline` |
| GET | `/health` | `{"ok":true}` when authorised |
| POST | `/login` | access code -> session cookie |
| POST/PUT | `/upload?p=&name=&csrf=` | raw body -> file |
| POST | `/mkdir` | form: `p`, `name`, `csrf` |
| POST | `/delete` | form: `p`, `csrf` |
| POST | `/rename` | form: `p`, `name`, `csrf` |
| POST | `/move` | form: `p`, `dst`, `csrf` |

Uploads deliberately avoid multipart: the built-in page sends the `File` object as the request body, and `curl -T` does the same. Parsing multipart across arbitrary TCP boundaries is a lot of code for zero user-visible gain here.

## Authentication

- On start, a 6-hex-character access code is generated from `cryptoFramework` and shown on the watch face only.
- `POST /login` with the right code creates a session: 128-bit `sid`, 128-bit `csrf`, both from the CSPRNG.
- Cookie is `HttpOnly; SameSite=Strict; Path=/; Max-Age=1800`; sessions expire after 30 minutes idle and are capped at 16, oldest evicted.
- Every state-changing request must carry the session's `csrf` value; wrong or missing -> `403`.
- Login failures are throttled: 10 wrong codes in 60 s locks logins for 60 s (`429`).
- If the CSPRNG is unavailable the server refuses to start instead of inventing a weak code.

This is **not** transport encryption. The access code protects against someone finding the port; it does not protect the bytes on the wire. HTTP and FTP are both plaintext and are meant for a LAN the user controls.

## Streaming and disk safety

- Upload: `Content-Length` must be known. Space is checked with `statfs` before the first byte. Body chunks are written straight to `.upload-<ts>-<id>.part` in the target directory; on completion the file is closed and renamed to its final name, adding ` (n)` on collision. Any error or disconnect deletes the temp file.
- Download: file opened once, read in 64 KB blocks, each block awaited before the next (`send` backpressure), so memory stays bounded regardless of file size.
- `HEAD` returns headers only.

## Limits

| Limit | Value | Reason |
| --- | --- | --- |
| concurrent connections | 8 | watch RAM and the single JS thread |
| header size | 16 KB | browser cookies plus a long URL |
| form body | 256 KB | nothing legitimate is bigger |
| connection idle before headers | 30 s | free the slot |
| sessions | 16 | one phone plus a few browser tabs |

## Page

`WebUi.ets` renders the page server-side: a list, a breadcrumb, a mkdir form, and an upload control that uses `XMLHttpRequest` with `upload.onprogress` for a real progress bar. All CSS is inline, there are no external fonts, scripts or CDN references, so the page works on a LAN with no internet. File names are HTML-escaped, and the path injected into the inline script is JSON-escaped with `<`/`>`/`&` neutralised so a crafted file name cannot close the `<script>` tag.

## Not implemented on purpose

- HTTPS (no certificate story on this device; see `protocol-assessment.md`)
- WebDAV (`PROPFIND`/`MKCOL` etc.) - a later stage
- multipart forms
- keep-alive
- per-IP rate limiting (single-user LAN device)
- upload resume
