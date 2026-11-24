# Protocol and auth options

What can be added on top of "random port, no password", and whether FTPS, HTTP/HTTPS or WebDAV are worth the effort on a HarmonyOS wearable.

Everything below was checked against the SDK declarations installed on this machine, not recalled:

- `@ohos.net.socket.d.ts`, lines 115-124: `constructTLSSocketServerInstance()`, `@since 10`
- same file: `TLSSocketServer.listen(options: TLSConnectOptions)`; the comment states a TLS session is created and "a certificate key will be loaded and verified"
- same file: `constructTLSSocketInstance(tcpSocket)` exists from `@since 12`, but it upgrades an existing socket on the **client** side
- `@ohos.security.cert.d.ts`: `createX509Cert` (parse), `createX509CertChain`, `createCertChainValidator`. No API that generates a self-signed certificate
- `@ohos.net.*`: no HTTP or WebDAV server; `@ohos.net.http` is client only

## Comparison

| Option | Effort | Phone support | Real gain | Verdict |
| --- | --- | --- | --- | --- |
| Random short credentials | low | every FTP client | keeps scanners and visitors out, not sniffers | implemented |
| Implicit FTPS, TLS from byte 0, port 990 | high | mixed, most clients default to explicit | weak: one self-signed key shared by every install | no |
| Explicit FTPS (`AUTH TLS`) | - | - | - | impossible, no server-side TLS upgrade |
| HTTP portal | medium | any browser, nothing to install | low-medium, plain HTTP with the same credentials | next |
| WebDAV | medium-high | iOS Files native, Android needs an app | low-medium | after HTTP |
| HTTPS | high | same certificate problem as FTPS | medium | no |

FTPS on this device is not a "can it be done" question. Implicit FTPS is technically possible, but with no certificate generation API you would ship one fixed self-signed key inside every install, every client would have to trust it by hand, and most phone clients open with explicit `AUTH TLS`, which is exactly the variant the SDK cannot do.

## What is implemented

| Item | Value |
| --- | --- |
| User | 4 lowercase letters, 24-character alphabet (`i l o` removed) |
| Password | 6 characters, 31-character alphabet (`a-z` minus `i l o`, plus `2-9` minus `0 1`) |
| Key space | 24^4 * 31^6, about 2.9e14 |
| Randomness | `cryptoFramework.createRandom().generateRandomSync()`, `Math.random` only if that throws |
| Lifetime | regenerated on every start, together with the control port |
| Brute force | 3 failures per connection sends `421` and closes it; 20 failures in 60 s trigger a 30 s login cooldown |
| Availability | the server never stops itself on failures, so guessing cannot be turned into a denial of service |
| Disclosure | `USER` always answers `331`; the password is not written to the log |
| Before login | only `USER PASS QUIT FEAT SYST NOOP` are answered, everything else gets `530` |

It stops port scanners on a shared network, people who open the URL by accident, and clients that default to anonymous login. It does not stop anyone who can capture traffic, because FTP is clear text end to end. Against that threat the answer is not FTPS on a watch, it is a phone-side app with its own encrypted channel.

## What is worth building next

1. **HTTP portal** (`http://watch-ip:port`). A page with a file list, an upload form and download links. Nothing to install on the phone, works from any browser. There is no HTTP server in the SDK, so this means parsing request lines, headers and bodies on top of `TCPSocketServer`; roughly 400-600 lines, reusing `FsStore`.

2. **WebDAV** on the same HTTP engine: `PROPFIND`, `MKCOL`, `PUT`, `MOVE`, `COPY` and XML replies, another ~300 lines. iOS Files can mount it natively, Android needs a file manager that speaks WebDAV.

3. **No-typing variants**, to remove the 10 characters a user has to retype:
   - approve on the watch: when a client connects, the watch asks "allow 192.168.1.7?" and the tap allowlists that IP for the session
   - QR code on the watch containing `ftp://user:pass@ip:port`; a 466x466 screen fits a version-6 code, and a small QR encoder is around 200 lines with no dependency

## State

- Code: `entry/src/main/ets/services/{FtpServer,FsStore,NetInfo}.ets`, `pages/Index.ets`
- Builds and signs with `compatibleSdkVersion 6.1.0(23)` against the local API 26 SDK
- Installed and tested on the watch: wrong password rejected, 512 KB upload and download with matching SHA-256, rename and delete
