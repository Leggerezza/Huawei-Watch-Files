# Security assessment

Scope: the two network services this app exposes on the LAN. Written against the code as it exists, not against intentions.

## Threat model

The watch is on a home or campus Wi-Fi. The realistic attackers are:

1. someone on the same network scanning for open ports;
2. someone who sees the URL/port and pokes at it;
3. a colleague on the same hotspot who knows the watch exists.

Not in scope: a targeted attacker with packet capture, and anyone who can physically take the watch. If traffic capture matters, no FTP/HTTP design here helps, because both are plaintext.

## Controls in place

| Control | Detail | Where |
| --- | --- | --- |
| No public exposure by default | both servers start only when the app page is opened, and stop when it closes | `Index.ets` |
| Ephemeral ports | both pick a random port in 30000-59999 on every start | `FtpServer.start`, `HttpServer.start` |
| One-time credentials | FTP: 4-letter user + 6-char password; HTTP: 6 hex access code; both regenerated per start and shown only on the watch | both servers |
| Fail-closed RNG | credentials come from `cryptoFramework`; if it throws, the service refuses to start rather than falling back to `Math.random` | `randomBytes`, `randomToken` |
| Login throttling | FTP: 3 failures per connection then `421`; 20 failures in 60 s -> 30 s cooldown. HTTP: 10 failures in 60 s -> 60 s lockout (`429`) | `cmdPass`, `handleLogin` |
| No account enumeration | FTP `USER` always answers `331`; HTTP shows the same page for any wrong code | both |
| Password never logged | only lengths and match results are logged | `handleLogin`, `cmdPass` |
| Pre-auth command gate | FTP answers `530` to everything except `USER PASS QUIT FEAT SYST NOOP` | `dispatch` |
| Session cookies | `HttpOnly`, `SameSite=Strict`, `Path=/`, 30 min idle expiry, 16 sessions max, 128-bit `sid` | `HttpServer` |
| CSRF | every mutating request needs the session's 128-bit token; uploads included | `routePost`, `beginUpload` |
| Path containment | all client paths are normalised and `..` is clamped at the virtual root before touching the filesystem | `FsStore.normalize` |
| Filename sanitisation | separators and control characters stripped, `.`/`..` rejected, 200-char cap | `safeName` |
| HTML/JS escaping | file names escaped for HTML; the path injected into the page script is JSON-escaped with `<`, `>`, `&` neutralised | `WebUi` |
| Bounded input | header 16 KB, form 256 KB, 8 concurrent connections, per-connection idle timer | `HttpServer` |
| Upload atomicity | body goes to `.upload-*.part`, renamed only on completion; any error or disconnect deletes it | `beginUpload` |
| No recursion on delete | `RMD` refuses a non-empty directory instead of wiping a tree | `FsStore.remove` |

## Out of scope by design (and stated as such)

- **No encryption.** FTP and HTTP are plaintext. The access code replaces "anyone can read my files" with "someone who knows the code can read my files"; it does not protect the bytes on the wire. FTPS/HTTPS were evaluated and rejected for this device in `protocol-assessment.md`.
- **No per-IP rate limiting.** The throttle is global; a single hostile client can lock out logins for a minute. On a personal LAN this is an acceptable trade for simplicity.
- **No audit trail beyond hilog.** Logs rotate with the system buffer.
- **No anti-CSRF for GET.** GETs only read; all mutations are POST with a token.
- **No protection against a malicious file.** Uploads are stored, never executed or parsed by the server.

## Residual risks

| Risk | Severity | Note |
| --- | --- | --- |
| Cleartext credentials on the LAN | medium | inherent to FTP/HTTP; mitigations are the one-time nature and the short lifetime |
| Brute force of the HTTP code | low | 24 bits of entropy, but 10 tries/minute -> expected years; FTP is 24^4 * 31^6 |
| Temp file left behind on a hard kill | low | `.upload-*.part` files are only removed on clean failure; a crash leaves one. They are excluded from listings by name convention? **No** - they would show up. Cleanup on next start is not implemented yet. |
| Two servers share one process | low | a crash in one stops both; there is no isolation |
| Device sleep drops the radio | low | availability, not confidentiality |

## Verification status

- FTP: the security-relevant checks in `Test-Ftp-Suite.ps1` passed on the device, 65/65 - pre-auth gate, no account enumeration, 3-strike close, 20/60 s cooldown, traversal clamping, client-path integrity.
- HTTP: `Test-Http.ps1` passed 22/22 on the device - 401 without a session, wrong code rejected, correct code issues the cookie, CSRF token required for every mutation (a forged token gets `403`), traversal lands on a missing path, chunked bodies get `501`.
- Open finding: the HTTP service is only as available as the app process. With the continuous task refused (`9800005`) the process can be reaped once backgrounded, which is an availability issue rather than a confidentiality one.
