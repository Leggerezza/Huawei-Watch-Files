# Stage 3 review: FTP service

Checklist against the brief's 13 points plus 8.1 and 8.2, with the code location and the test that covers it. Nothing here is inferred: each row names the check in `Test-Ftp-Suite.ps1` that exercises it.

| # | Requirement | Where | Test evidence |
| --- | --- | --- | --- |
| 1 | Username + password authentication | `FtpServer.cmdPass` | `USER gets 331`, `PASS gets 230`, `valid user + wrong password is rejected`, `third bad password gets 421` |
| 2 | Random control port | `FtpServer.start` (30000-59999, 24 retries) | every run reports a different port in hilog |
| 3 | PASV data channel | `cmdPasv`, `acceptData`, `endData` | all data checks; `PASV before login is 530` for the gate |
| 4 | Upload and download | `cmdStor`, `cmdRetr` | `STOR 512 KB`, `RETR 512 KB`, plus the 8 MB round trip with matching SHA-256 |
| 5 | Resume | `REST` + `cmdRetr` offset | `REST accepted with 350`, `RETR after REST 4 returns the tail` |
| 6 | Directory operations | `cmdCwd`, `cmdMkd`, `cmdRmd`, `cmdList` | `MKD creates nested path`, `CWD into it`, `CDUP went up one level`, `RMD refuses a non-empty directory` |
| 7 | Rename and delete | `cmdRnfr`, `cmdRnto`, `cmdDele` | `RNFR gets 350`, `RNTO gets 250`, `old name is gone`, `DELE on a directory is refused` |
| 8 | SIZE / MDTM / MLSD | `cmdSize`, `cmdMdtm`, `cmdList('mlsd')` | `SIZE reports 10`, `MDTM is 213 + 14 digits`, `MLSD has type/size/modify facts` |
| 9 | Error responses and connection close | `reply`, `dropSession` | `greeting is 220`, `QUIT gets 221`, `control connection closes cleanly`, `421` on lockout |
| 10 | Multiple clients | `sessions[]`, `maxSessions = 8` | `two control connections are served at once`, `both clients can open a data channel` |
| 11 | Transfer timeouts | `DATA_TIMEOUT_MS` 10 s to accept a data connection, `UPLOAD_IDLE_TIMEOUT_MS` 120 s, control idle sweep every 60 s with a 10 minute limit | not directly asserted; covered by the sweep/lockout paths and visible in code |
| 12 | Abrupt disconnect / handle release | `dropSession`, `closePasv`, `finally { fs.closeSync }` in both transfer paths | the suite disconnects mid-session repeatedly (`third bad password`, `QUIT`) without leaking; the 8 MB transfer after those still succeeds |
| 13 | 8.1 classification policy | `classifyRootUploads = false` in `FtpServer`, buckets still created in `Classifier.ensureBuckets` | `root upload does not report a different path`, `the file stays at the path the client used`, `nothing was filed into /Images` |
| 14 | 8.2 security | see below | see below |

## 8.2 security items

| Item | Implementation | Evidence |
| --- | --- | --- |
| Entropy of the random credentials | 4 letters from a 24-char alphabet + 6 chars from 31, both from `cryptoFramework.createRandom().generateRandomSync()` | ~2.9e14 combinations |
| No silent `Math.random` fallback | `randomBytes` no longer catches; the service refuses to start if the CSPRNG fails | code review; HTTP already fails closed the same way |
| Login failure limit | 3 per connection -> `421`; 20 in 60 s -> 30 s cooldown | `third bad password gets 421`, `repeated failures trigger a cooldown, not a shutdown` |
| Concurrent connection limit | `maxSessions = 8`, extra connections get `421` then close | code; the suite never exceeds it |
| Idle connection timeout | `sweepIdle` every 60 s, 10 minute limit, `421 Idle timeout.` | code |
| Data connection timeout | 10 s to accept, 120 s upload idle | code |
| Password log redaction | only lengths and a match flag are logged (`login rejected: got=… expected=… match=…`) | hilog during the HTTP work; FTP logs the account but never the password |
| Pre-auth command restriction | only `USER PASS QUIT FEAT SYST NOOP` answered before login | `SIZE before login is 530`, `LIST before login is 530`, `PASV before login is 530` |
| Sandbox path validation | `FsStore.normalize` clamps `..` at the virtual root | `CWD /../../ stays inside root`, `RETR ../../../etc/passwd is 550` |
| No recursion on delete | `FsStore.remove` refuses a non-empty directory | `RMD refuses a non-empty directory` |
| Resource release | every transfer closes its handle in `finally`; sessions clean listeners on drop | the suite runs 30+ transfers on one connection without `EMFILE` |

## Open items

- **Timeouts are implemented but not asserted**: the suite never waits 10 minutes for the idle sweep, and never stalls an upload for 120 s. Adding a short-timeout build switch would make these testable; until then they are code-only claims.
- **No per-IP throttling**: the cooldown is global, so one hostile client can lock a user out for 30 s. Accepted for a personal LAN.
- **Plaintext**: FTP sends the password in clear text. Random one-time credentials reduce the window but are not encryption; FTPS was rejected for this device in `protocol-assessment.md`.
- **Crown and long-press gaps from this round**: unrelated to FTP, recorded in `regression-test-report.md`.
