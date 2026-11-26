import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs, statfs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { FsEntry, FsStore } from './FsStore';
import { Classifier } from './Classifier';
import { mimeOf } from './Metadata';
import { browsePage, esc, loginPage, messagePage, PageInput, enc } from './WebUi';

const CRLF: string = '\r\n';
const CHUNK: number = 64 * 1024;
const MAX_HEADER: number = 16 * 1024;
const MAX_FORM: number = 256 * 1024;
const MAX_CONNECTIONS: number = 8;
const MAX_SESSIONS: number = 16;
const SESSION_IDLE_MS: number = 30 * 60 * 1000;
const CONN_IDLE_MS: number = 30 * 1000;
const LOGIN_WINDOW_MS: number = 60 * 1000;
const LOGIN_MAX_FAILS: number = 10;
const LOGIN_COOLDOWN_MS: number = 60 * 1000;
const PORT_MIN: number = 30000;
const PORT_MAX: number = 60000;

export class HttpStatus {
  running: boolean = false;
  port: number = 0;
  code: string = '';
}

class Session {
  sid: string = '';
  csrf: string = '';
  lastSeen: number = 0;
}

class Conn {
  id: number = 0;
  sock: socket.TCPSocketConnection | null = null;
  buf: number[] = [];
  headerDone: boolean = false;
  dead: boolean = false;
  // request
  method: string = '';
  target: string = '';
  path: string = '';
  query: Map<string, string> = new Map<string, string>();
  headers: Map<string, string> = new Map<string, string>();
  // body
  bodyMode: string = 'none';
  bodyRemaining: number = 0;
  bodyBuf: number[] = [];
  file: fs.File | null = null;
  tmpPath: string = '';
  uploadDir: string = '';
  uploadName: string = '';
  written: number = 0;
  startedAt: number = 0;
}

function hex(bytes: Uint8Array): string {
  let out: string = '';
  for (let i = 0; i < bytes.length; i++) {
    const v: number = bytes[i];
    out += (v < 16 ? '0' : '') + v.toString(16);
  }
  return out;
}

/** Cryptographically strong token. Throws: callers must not fall back to Math.random. */
function randomToken(bytes: number): string {
  const rnd: cryptoFramework.Random = cryptoFramework.createRandom();
  const blob: cryptoFramework.DataBlob = rnd.generateRandomSync(bytes);
  return hex(blob.data);
}

/**
 * Minimal HTTP/1.1 file server for the watch sandbox.
 *
 * Implemented on purpose: one request per connection (`Connection: close`),
 * Content-Length bodies only, Range for downloads, streaming both ways.
 * Not implemented, and rejected explicitly: chunked transfer encoding,
 * keep-alive, multipart/form-data.
 */
export class HttpServer {
  private server: socket.TCPSocketServer | null = null;
  private store: FsStore = new FsStore('');
  private classifier: Classifier = new Classifier('');
  private targetFor: string = '';
  private sessions: Map<string, Session> = new Map<string, Session>();
  private conns: Conn[] = [];
  private nextId: number = 1;
  private port: number = 0;
  private code: string = '';
  private decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
  private encoder: util.TextEncoder = new util.TextEncoder();
  private loginFails: number[] = [];
  private loginLockUntil: number = 0;
  onLog: (msg: string) => void = (msg: string) => {
    hilog.info(0x0100, 'WatchHttp', '%{public}s', msg);
  };
  onStatus: (st: HttpStatus) => void = (st: HttpStatus) => {
  };

  status(): HttpStatus {
    const st: HttpStatus = new HttpStatus();
    st.running = this.server !== null;
    st.port = this.port;
    st.code = this.code;
    return st;
  }

  isRunning(): boolean {
    return this.server !== null;
  }

  async start(root: string, localIp: string): Promise<HttpStatus> {
    if (this.server !== null) {
      await this.stop();
    }
    this.store = new FsStore(root);
    this.classifier = new Classifier(this.store.root);
    this.targetFor = localIp;
    this.sessions.clear();
    this.loginFails = [];
    this.loginLockUntil = 0;
    try {
      this.code = randomToken(3);
    } catch (e) {
      // Fail closed: no access code means no HTTP service.
      throw new Error('secure random unavailable, refusing to start HTTP');
    }

    let lastError: string = '';
    for (let attempt = 0; attempt < 24; attempt++) {
      const candidate: number = PORT_MIN + Math.floor(Math.random() * (PORT_MAX - PORT_MIN));
      const srv: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
      try {
        await srv.listen({ address: '0.0.0.0', port: candidate, family: 1 });
      } catch (e) {
        lastError = this.errText(e);
        continue;
      }
      this.server = srv;
      this.port = candidate;
      srv.on('connect', (client: socket.TCPSocketConnection) => {
        this.onClient(client);
      });
      srv.on('error', (err: BusinessError) => {
        this.log(`server error: ${this.errText(err)}`);
      });
      this.log(`listening on 0.0.0.0:${candidate}, root=${root}`);
      const st: HttpStatus = this.status();
      this.onStatus(st);
      return st;
    }
    throw new Error(`no free port: ${lastError}`);
  }

  async stop(): Promise<void> {
    const list: Conn[] = this.conns.slice(0);
    for (let i = 0; i < list.length; i++) {
      await this.closeConn(list[i]);
    }
    this.conns = [];
    this.sessions.clear();
    const srv: socket.TCPSocketServer | null = this.server;
    this.server = null;
    this.port = 0;
    this.code = '';
    if (srv !== null) {
      try {
        srv.off('connect');
      } catch (e) {
      }
      try {
        await srv.close();
      } catch (e) {
      }
    }
    this.log('stopped');
    this.onStatus(this.status());
  }

  // ------------------------------------------------------------- connection

  private onClient(client: socket.TCPSocketConnection): void {
    if (this.conns.length >= MAX_CONNECTIONS) {
      // Flush the 503 before closing, otherwise the client just sees a reset.
      this.sendRaw(client, '503 Service Unavailable', 'text/plain; charset=utf-8', 'busy, try again', '').then(() => {
        try {
          client.close();
        } catch (e) {
        }
      });
      return;
    }
    const c: Conn = new Conn();
    c.id = this.nextId;
    this.nextId = this.nextId + 1;
    c.sock = client;
    c.startedAt = Date.now();
    this.conns.push(c);
    client.on('message', (info: socket.SocketMessageInfo) => {
      this.onData(c, info);
    });
    client.on('close', () => {
      this.closeConn(c);
    });
    setTimeout(() => {
      if (!c.dead && !c.headerDone) {
        this.closeConn(c);
      }
    }, CONN_IDLE_MS);
  }

  private onData(c: Conn, info: socket.SocketMessageInfo): void {
    if (c.dead) {
      return;
    }
    try {
      this.onDataInner(c, info);
    } catch (e) {
      // An uncaught JS error here would take the whole app down, which is
      // exactly how a malformed request turned into a crash once already.
      this.log(`request failed: ${this.errText(e)}`);
      this.respondText(c, 500, 'internal error');
    }
  }

  private onDataInner(c: Conn, info: socket.SocketMessageInfo): void {
    const bytes: Uint8Array = new Uint8Array(info.message);
    if (!c.headerDone) {
      for (let i = 0; i < bytes.length; i++) {
        c.buf.push(bytes[i]);
      }
      const end: number = this.findHeaderEnd(c.buf);
      if (end < 0) {
        if (c.buf.length > MAX_HEADER) {
          this.respondText(c, 431, 'Request Header Fields Too Large');
        }
        return;
      }
      const headBytes: number[] = c.buf.slice(0, end);
      const rest: number[] = c.buf.slice(end + 4);
      c.buf = [];
      c.headerDone = true;
      this.handleHeaders(c, headBytes);
      if (!c.dead && rest.length > 0) {
        this.onBody(c, this.toBytes(rest));
      }
      return;
    }
    this.onBody(c, bytes);
  }

  private findHeaderEnd(buf: number[]): number {
    for (let i = 0; i + 3 < buf.length; i++) {
      if (buf[i] === 13 && buf[i + 1] === 10 && buf[i + 2] === 13 && buf[i + 3] === 10) {
        return i;
      }
    }
    return -1;
  }

  private toBytes(list: number[]): Uint8Array {
    const out: Uint8Array = new Uint8Array(list.length);
    for (let i = 0; i < list.length; i++) {
      out[i] = list[i];
    }
    return out;
  }

  private handleHeaders(c: Conn, headBytes: number[]): void {
    let text: string = '';
    try {
      text = this.decoder.decodeToString(this.toBytes(headBytes));
    } catch (e) {
      this.respondText(c, 400, 'Bad Request');
      return;
    }
    const lines: string[] = text.split(CRLF);
    if (lines.length === 0) {
      this.respondText(c, 400, 'Bad Request');
      return;
    }
    const first: string[] = lines[0].split(' ');
    if (first.length < 3) {
      this.respondText(c, 400, 'Bad Request');
      return;
    }
    c.method = first[0].toUpperCase();
    c.target = first[1];
    for (let i = 1; i < lines.length; i++) {
      const line: string = lines[i];
      const colon: number = line.indexOf(':');
      if (colon <= 0) {
        continue;
      }
      const key: string = line.substring(0, colon).trim().toLowerCase();
      const value: string = line.substring(colon + 1).trim();
      c.headers.set(key, value);
    }
    const q: number = c.target.indexOf('?');
    c.path = q < 0 ? c.target : c.target.substring(0, q);
    if (q >= 0) {
      this.parseQuery(c, c.target.substring(q + 1));
    }
    if (c.path.length === 0) {
      c.path = '/';
    }

    const te: string | undefined = c.headers.get('transfer-encoding');
    if (te !== undefined) {
      this.respondText(c, 501, 'chunked transfer encoding is not supported');
      return;
    }
    const expect: string | undefined = c.headers.get('expect');
    if (expect !== undefined && expect.toLowerCase() === '100-continue' && c.sock !== null) {
      c.sock.send({ data: 'HTTP/1.1 100 Continue\r\n\r\n' }).catch(() => {
      });
    }

    let length: number = 0;
    const cl: string | undefined = c.headers.get('content-length');
    if (cl !== undefined) {
      length = Number.parseInt(cl, 10);
      if (Number.isNaN(length) || length < 0) {
        this.respondText(c, 400, 'Bad Content-Length');
        return;
      }
    }
    c.bodyRemaining = length;

    if (c.method === 'GET' || c.method === 'HEAD') {
      this.routeGet(c);
      return;
    }
    if (c.method === 'POST' || c.method === 'PUT') {
      if (length === 0) {
        this.routePost(c, new Uint8Array(0));
        return;
      }
      // /login carries credentials in the body and must work without a session.
      if (c.path !== '/login' && !this.isAuthed(c)) {
        this.respondText(c, 401, 'login required');
        return;
      }
      if (c.path === '/upload' || c.path === '/put') {
        this.beginUpload(c);
        return;
      }
      if (length > MAX_FORM) {
        this.respondText(c, 413, 'form too large');
        return;
      }
      c.bodyMode = 'buffer';
      return;
    }
    this.respondText(c, 405, 'Method Not Allowed');
  }

  private parseQuery(c: Conn, raw: string): void {
    const parts: string[] = raw.split('&');
    for (let i = 0; i < parts.length; i++) {
      const kv: string[] = parts[i].split('=');
      if (kv.length === 0 || kv[0].length === 0) {
        continue;
      }
      const key: string = this.decode(kv[0]);
      const value: string = kv.length > 1 ? this.decode(kv.slice(1).join('=')) : '';
      c.query.set(key, value);
    }
  }

  private decode(s: string): string {
    try {
      return decodeURIComponent(s.replace(/\+/g, ' '));
    } catch (e) {
      return s;
    }
  }

  // ------------------------------------------------------------------- body

  private onBody(c: Conn, bytes: Uint8Array): void {
    if (c.dead) {
      return;
    }
    if (c.bodyMode === 'none') {
      return;
    }
    const take: number = Math.min(bytes.length, c.bodyRemaining);
    if (c.bodyMode === 'buffer') {
      for (let i = 0; i < take; i++) {
        c.bodyBuf.push(bytes[i]);
      }
      c.bodyRemaining -= take;
      if (c.bodyRemaining <= 0) {
        this.routePost(c, this.toBytes(c.bodyBuf));
      }
      return;
    }
    if (c.bodyMode === 'file') {
      if (c.file === null) {
        return;
      }
      if (take > 0) {
        const piece: Uint8Array = bytes.subarray(0, take);
        try {
          const n: number = fs.writeSync(c.file.fd, piece.buffer.slice(piece.byteOffset, piece.byteOffset + piece.byteLength));
          c.written += n;
        } catch (e) {
          this.log(`upload write failed: ${this.errText(e)}`);
          this.abortUpload(c, 500, 'write failed');
          return;
        }
      }
      c.bodyRemaining -= take;
      if (c.bodyRemaining <= 0) {
        this.finishUpload(c);
      }
    }
  }

  private beginUpload(c: Conn): void {
    const s: Session | null = this.session(c);
    const csrf: string = c.query.get('csrf') === undefined ? '' : `${c.query.get('csrf')}`;
    if (s === null || csrf !== s.csrf) {
      this.respondText(c, 403, 'bad csrf token');
      return;
    }
    const dir: string = this.store.normalize(c.query.get('p') === undefined ? '/' : `${c.query.get('p')}`);
    const rawName: string = c.query.get('name') === undefined ? '' : `${c.query.get('name')}`;
    const name: string = this.safeName(rawName);
    if (name.length === 0) {
      this.respondText(c, 400, 'missing or invalid name');
      return;
    }
    if (!this.store.isDir(this.store.real(dir))) {
      this.respondText(c, 409, 'target directory does not exist');
      return;
    }
    try {
      const free: number = this.freeBytes();
      if (c.bodyRemaining > 0 && c.bodyRemaining + 1024 * 1024 > free) {
        this.respondText(c, 507, 'not enough space');
        return;
      }
    } catch (e) {
    }
    const tmp: string = this.store.real(`${dir === '/' ? '' : dir}/.upload-${Date.now()}-${c.id}.part`);
    try {
      c.file = fs.openSync(tmp, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    } catch (e) {
      this.respondText(c, 500, 'cannot create temp file');
      return;
    }
    c.tmpPath = tmp;
    c.uploadDir = dir;
    c.uploadName = name;
    c.bodyMode = 'file';
    c.written = 0;
    if (c.bodyRemaining === 0) {
      this.finishUpload(c);
    }
  }

  private abortUpload(c: Conn, status: number, msg: string): void {
    if (c.file !== null) {
      try {
        fs.closeSync(c.file);
      } catch (e) {
      }
      c.file = null;
    }
    if (c.tmpPath.length > 0) {
      try {
        fs.unlinkSync(c.tmpPath);
      } catch (e) {
      }
    }
    c.bodyMode = 'none';
    this.respondText(c, status, msg);
  }

  private finishUpload(c: Conn): void {
    if (c.file === null) {
      return;
    }
    try {
      fs.closeSync(c.file);
    } catch (e) {
    }
    c.file = null;
    const finalVirtual: string = `${c.uploadDir === '/' ? '' : c.uploadDir}/${c.uploadName}`;
    const finalReal: string = this.uniqueReal(this.store.real(finalVirtual));
    try {
      fs.renameSync(c.tmpPath, finalReal);
    } catch (e) {
      this.log(`rename failed: ${this.errText(e)}`);
      this.abortUpload(c, 500, 'cannot commit upload');
      return;
    }
    c.tmpPath = '';
    let filed: string = '';
    const leaf: string = finalReal.substring(finalReal.lastIndexOf('/') + 1);
    const bucket: string = this.classifier.fileRootUpload(finalReal, c.uploadDir === '/' ? `/${leaf}` : '');
    if (bucket.length > 0) {
      filed = bucket;
    }
    this.log(`upload ${finalVirtual} -> ${filed.length > 0 ? filed : finalVirtual} (${c.written} bytes)`);
    const body: string = `{"ok":true,"bytes":${c.written},"path":"${filed.length > 0 ? filed : finalVirtual}"}`;
    this.respond(c, 200, 'OK', 'application/json; charset=utf-8', body, '');
  }

  private uniqueReal(realPath: string): string {
    const slash: number = realPath.lastIndexOf('/');
    const dir: string = realPath.substring(0, slash);
    const name: string = realPath.substring(slash + 1);
    return this.store.uniquePath(dir, name);
  }

  /** Rejects separators, control characters and dot-only names. */
  private safeName(raw: string): string {
    let name: string = raw.trim();
    if (name.length === 0 || name === '.' || name === '..') {
      return '';
    }
    let out: string = '';
    for (let i = 0; i < name.length; i++) {
      const ch: string = name.charAt(i);
      const code: number = name.charCodeAt(i);
      if (ch === '/' || ch === '\\' || code < 32) {
        continue;
      }
      out += ch;
    }
    if (out.length > 200) {
      out = out.substring(0, 200);
    }
    if (out === '.' || out === '..') {
      return '';
    }
    return out;
  }

  // ----------------------------------------------------------------- routes

  private isAuthed(c: Conn): boolean {
    const sid: string = this.cookie(c, 'sid');
    if (sid.length === 0) {
      return false;
    }
    const s: Session | undefined = this.sessions.get(sid);
    if (s === undefined) {
      return false;
    }
    const now: number = Date.now();
    if (now - s.lastSeen > SESSION_IDLE_MS) {
      this.sessions.delete(sid);
      return false;
    }
    s.lastSeen = now;
    return true;
  }

  private session(c: Conn): Session | null {
    const sid: string = this.cookie(c, 'sid');
    const s: Session | undefined = this.sessions.get(sid);
    return s === undefined ? null : s;
  }

  private cookie(c: Conn, key: string): string {
    const raw: string | undefined = c.headers.get('cookie');
    if (raw === undefined) {
      return '';
    }
    const parts: string[] = raw.split(';');
    for (let i = 0; i < parts.length; i++) {
      const kv: string[] = parts[i].trim().split('=');
      if (kv.length === 2 && kv[0] === key) {
        return kv[1];
      }
    }
    return '';
  }

  private routeGet(c: Conn): void {
    if (c.path === '/favicon.ico') {
      // Browsers ask for it unprompted; answer 204 so the console stays clean.
      this.respond(c, 204, 'No Content', 'text/plain; charset=utf-8', '', '');
      return;
    }
    if (c.path === '/login') {
      this.respondHtml(c, 200, loginPage(''));
      return;
    }
    if (!this.isAuthed(c)) {
      this.respondHtml(c, 401, loginPage(''));
      return;
    }
    if (c.path === '/' || c.path === '/browse') {
      this.renderBrowse(c);
      return;
    }
    if (c.path === '/dl' || c.path === '/raw') {
      this.serveFile(c, c.path === '/raw');
      return;
    }
    if (c.path === '/health') {
      this.respond(c, 200, 'OK', 'application/json; charset=utf-8', '{"ok":true}', '');
      return;
    }
    this.respondHtml(c, 404, messagePage('404', '页面不存在', '/'));
  }

  private routePost(c: Conn, body: Uint8Array): void {
    if (c.path === '/login') {
      this.handleLogin(c, body);
      return;
    }
    if (!this.isAuthed(c)) {
      this.respondText(c, 401, 'login required');
      return;
    }
    const form: Map<string, string> = this.parseForm(body);
    const s: Session | null = this.session(c);
    if (s === null) {
      this.respondText(c, 401, 'login required');
      return;
    }
    const csrf: string = form.get('csrf') === undefined ? `${c.query.get('csrf')}` : `${form.get('csrf')}`;
    if (csrf !== s.csrf) {
      this.respondText(c, 403, 'bad csrf token');
      return;
    }
    const p: string = form.get('p') === undefined ? '/' : `${form.get('p')}`;
    const target: string = this.store.real(this.store.normalize(p));

    if (c.path === '/mkdir') {
      const name: string = this.safeName(form.get('name') === undefined ? '' : `${form.get('name')}`);
      if (name.length === 0) {
        this.respondHtml(c, 400, messagePage('创建失败', '名称无效', `/?p=${enc(p)}`));
        return;
      }
      const dir: string = `${this.store.normalize(p) === '/' ? '' : this.store.normalize(p)}/${name}`;
      const ok: boolean = this.store.mkdir(this.store.real(dir));
      this.redirect(c, ok ? `/?p=${enc(this.store.normalize(p))}` : `/?p=${enc(p)}`);
      return;
    }
    if (c.path === '/delete') {
      if (!this.store.exists(target)) {
        this.respondHtml(c, 404, messagePage('删除失败', '文件不存在', `/?p=${enc(p)}`));
        return;
      }
      const ok: boolean = this.store.remove(target);
      this.respondHtml(c, ok ? 200 : 409,
        messagePage(ok ? '已删除' : '删除失败',
          ok ? '文件已从手表删除。' : '目录非空或没有权限，未删除。', `/?p=${enc(this.parentOf(p))}`));
      return;
    }
    if (c.path === '/rename') {
      const name: string = this.safeName(form.get('name') === undefined ? '' : `${form.get('name')}`);
      if (name.length === 0) {
        this.respondHtml(c, 400, messagePage('重命名失败', '名称无效', `/?p=${enc(p)}`));
        return;
      }
      const dir: string = this.parentOf(p);
      const dst: string = `${dir === '/' ? '' : dir}/${name}`;
      const ok: boolean = this.store.rename(target, this.store.real(dst));
      this.respondHtml(c, ok ? 200 : 409,
        messagePage(ok ? '已重命名' : '重命名失败', ok ? `新名称：${name}` : '目标已存在或没有权限。', `/?p=${enc(dir)}`));
      return;
    }
    if (c.path === '/move') {
      const dstDir: string = this.store.normalize(form.get('dst') === undefined ? '/' : `${form.get('dst')}`);
      const leaf: string = p.substring(p.lastIndexOf('/') + 1);
      const dst: string = `${dstDir === '/' ? '' : dstDir}/${leaf}`;
      const ok: boolean = this.store.rename(target, this.store.real(dst));
      this.respondHtml(c, ok ? 200 : 409,
        messagePage(ok ? '已移动' : '移动失败', ok ? `新位置：${dst}` : '目标冲突或没有权限。', `/?p=${enc(dstDir)}`));
      return;
    }
    this.respondText(c, 404, 'not found');
  }

  private handleLogin(c: Conn, body: Uint8Array): void {
    const now: number = Date.now();
    if (now < this.loginLockUntil) {
      this.respondHtml(c, 429, loginPage('尝试过于频繁，请稍后再试'));
      return;
    }
    const form: Map<string, string> = this.parseForm(body);
    const code: string = form.get('code') === undefined ? '' : `${form.get('code')}`.trim();
    if (code === this.code && this.code.length > 0) {
      this.loginFails = [];
      const s: Session = new Session();
      try {
        s.sid = randomToken(16);
        s.csrf = randomToken(16);
      } catch (e) {
        this.respondHtml(c, 500, loginPage('安全随机数不可用，无法创建会话'));
        return;
      }
      s.lastSeen = now;
      if (this.sessions.size >= MAX_SESSIONS) {
        const oldestKey: string = this.sessions.keys().next().value as string;
        this.sessions.delete(oldestKey);
      }
      this.sessions.set(s.sid, s);
      this.log(`login ok, active sessions ${this.sessions.size}`);
      const cookieHeader: string = `sid=${s.sid}; HttpOnly; SameSite=Strict; Path=/; Max-Age=1800`;
      this.respond(c, 302, 'Found', 'text/html; charset=utf-8', '',
        `Set-Cookie: ${cookieHeader}${CRLF}Location: /${CRLF}`);
      return;
    }
    this.loginFails.push(now);
    this.log(`login rejected: got=${code.length} expected=${this.code.length} match=${code === this.code}`);
    const kept: number[] = [];
    for (let i = 0; i < this.loginFails.length; i++) {
      if (this.loginFails[i] > now - LOGIN_WINDOW_MS) {
        kept.push(this.loginFails[i]);
      }
    }
    this.loginFails = kept;
    if (kept.length >= LOGIN_MAX_FAILS) {
      this.loginLockUntil = now + LOGIN_COOLDOWN_MS;
      this.loginFails = [];
      this.log('login locked for 60s');
    }
    this.respondHtml(c, 401, loginPage('访问码不正确'));
  }

  private renderBrowse(c: Conn): void {
    const p: string = c.query.get('p') === undefined ? '/' : `${c.query.get('p')}`;
    const dir: string = this.store.normalize(p);
    const real: string = this.store.real(dir);
    if (!this.store.isDir(real)) {
      this.respondHtml(c, 404, messagePage('404', '目录不存在', '/'));
      return;
    }
    const s: Session | null = this.session(c);
    const csrf: string = s === null ? '' : s.csrf;
    let free: number = 0;
    let total: number = 0;
    try {
      free = this.freeBytes();
      total = this.totalBytes();
    } catch (e) {
    }
    const input: PageInput = {
      path: dir,
      entries: this.store.list(real),
      free: free,
      total: total,
      csrf: csrf,
      classify: true
    };
    this.respondHtml(c, 200, browsePage(input));
  }

  private serveFile(c: Conn, inline: boolean): void {
    const p: string = c.query.get('p') === undefined ? '' : `${c.query.get('p')}`;
    const real: string = this.store.real(this.store.normalize(p));
    if (!this.store.exists(real) || this.store.isDir(real)) {
      this.respondText(c, 404, 'file not found');
      return;
    }
    const size: number = this.store.size(real);
    const name: string = p.substring(p.lastIndexOf('/') + 1);
    const type: string = mimeOf(name);
    let start: number = 0;
    let end: number = size - 1;
    let status: number = 200;
    let extra: string = '';
    const range: string | undefined = c.headers.get('range');
    if (range !== undefined && range.startsWith('bytes=')) {
      const spec: string = range.substring(6);
      const dash: number = spec.indexOf('-');
      if (dash >= 0) {
        const s1: string = spec.substring(0, dash).trim();
        const s2: string = spec.substring(dash + 1).trim();
        if (s1.length === 0 && s2.length > 0) {
          start = Math.max(0, size - Number.parseInt(s2, 10));
        } else if (s1.length > 0) {
          start = Number.parseInt(s1, 10);
          if (s2.length > 0) {
            end = Math.min(size - 1, Number.parseInt(s2, 10));
          }
        }
        if (Number.isNaN(start) || start < 0) {
          start = 0;
        }
        if (Number.isNaN(end) || end >= size) {
          end = size - 1;
        }
        if (start <= end) {
          status = 206;
          extra = `Content-Range: bytes ${start}-${end}/${size}${CRLF}Accept-Ranges: bytes${CRLF}`;
        } else {
          this.respondText(c, 416, 'range not satisfiable');
          return;
        }
      }
    } else {
      extra = `Accept-Ranges: bytes${CRLF}`;
    }
    const length: number = end - start + 1;
    const disposition: string = inline ? 'inline' : 'attachment';
    const asciiName: string = name.replace(/[^\x20-\x7e]/g, '_');
    const head: string = `HTTP/1.1 ${status} ${status === 206 ? 'Partial Content' : 'OK'}${CRLF}`
      + `Content-Type: ${type}${CRLF}`
      + `Content-Length: ${length}${CRLF}`
      + `Content-Disposition: ${disposition}; filename="${asciiName}"; filename*=UTF-8''${encodeURIComponent(name)}${CRLF}`
      + `Cache-Control: no-store${CRLF}${extra}`
      + `Connection: close${CRLF}${CRLF}`;
    if (c.sock === null) {
      return;
    }
    const sock: socket.TCPSocketConnection = c.sock;
    this.streamFile(c, sock, head, real, start, length);
  }

  private async streamFile(c: Conn, sock: socket.TCPSocketConnection, head: string, real: string, start: number, length: number): Promise<void> {
    try {
      await sock.send({ data: head });
    } catch (e) {
      this.closeConn(c);
      return;
    }
    let file: fs.File | null = null;
    try {
      file = fs.openSync(real, fs.OpenMode.READ_ONLY);
      let offset: number = start;
      let left: number = length;
      while (left > 0 && !c.dead) {
        const want: number = Math.min(CHUNK, left);
        const buf: ArrayBuffer = new ArrayBuffer(want);
        const n: number = fs.readSync(file.fd, buf, { offset: offset, length: want });
        if (n <= 0) {
          break;
        }
        const piece: ArrayBuffer = n === want ? buf : buf.slice(0, n);
        await sock.send({ data: piece });
        offset += n;
        left -= n;
      }
    } catch (e) {
      this.log(`download failed: ${this.errText(e)}`);
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
        }
      }
      this.closeConn(c);
    }
  }

  // --------------------------------------------------------------- responses

  private respondHtml(c: Conn, status: number, html: string): void {
    this.respond(c, status, this.reason(status), 'text/html; charset=utf-8', html, '');
  }

  private respondText(c: Conn, status: number, text: string): void {
    this.respond(c, status, this.reason(status), 'text/plain; charset=utf-8', text, '');
  }

  /** UTF-8 bytes of `body` as an exact ArrayBuffer; empty stays empty. */
  private encodeBody(body: string): ArrayBuffer {
    if (body.length === 0) {
      return new ArrayBuffer(0);
    }
    const bytes: Uint8Array = this.encoder.encodeInto(body);
    if (bytes === undefined || bytes === null) {
      return new ArrayBuffer(0);
    }
    return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
  }

  private respond(c: Conn, status: number, reason: string, type: string, body: string, extra: string): void {
    if (c.dead || c.sock === null) {
      return;
    }
    const exact: ArrayBuffer = this.encodeBody(body);
    // `extra` must either be empty or end with CRLF; it is appended as headers.
    const head: string = `HTTP/1.1 ${status} ${reason}${CRLF}`
      + `Content-Type: ${type}${CRLF}`
      + `Content-Length: ${exact.byteLength}${CRLF}`
      + `Cache-Control: no-store${CRLF}`
      + extra
      + `Connection: close${CRLF}${CRLF}`;
    const sock: socket.TCPSocketConnection = c.sock;
    this.sendBoth(c, sock, head, exact);
  }

  private async sendBoth(c: Conn, sock: socket.TCPSocketConnection, head: string, body: ArrayBuffer): Promise<void> {
    try {
      await sock.send({ data: head });
      if (body.byteLength > 0) {
        await sock.send({ data: body });
      }
    } catch (e) {
    }
    this.closeConn(c);
  }

  private async sendRaw(sock: socket.TCPSocketConnection, status: string, type: string, body: string, extra: string): Promise<void> {
    const exact: ArrayBuffer = this.encodeBody(body);
    const head: string = `HTTP/1.1 ${status}${CRLF}Content-Type: ${type}${CRLF}Content-Length: ${exact.byteLength}${CRLF}`
      + extra + `Connection: close${CRLF}${CRLF}`;
    try {
      await sock.send({ data: head });
      await sock.send({ data: exact });
    } catch (e) {
    }
  }

  private redirect(c: Conn, location: string): void {
    this.respond(c, 303, 'See Other', 'text/html; charset=utf-8', '', `Location: ${location}${CRLF}`);
  }

  private async closeConn(c: Conn): Promise<void> {
    if (c.dead) {
      return;
    }
    c.dead = true;
    const idx: number = this.conns.indexOf(c);
    if (idx >= 0) {
      this.conns.splice(idx, 1);
    }
    if (c.file !== null) {
      try {
        fs.closeSync(c.file);
      } catch (e) {
      }
      c.file = null;
    }
    if (c.tmpPath.length > 0) {
      try {
        fs.unlinkSync(c.tmpPath);
      } catch (e) {
      }
    }
    const sock: socket.TCPSocketConnection | null = c.sock;
    c.sock = null;
    if (sock !== null) {
      try {
        sock.off('message');
      } catch (e) {
      }
      try {
        await sock.close();
      } catch (e) {
      }
    }
  }

  // ------------------------------------------------------------------ misc

  private parseForm(body: Uint8Array): Map<string, string> {
    const out: Map<string, string> = new Map<string, string>();
    if (body.length === 0) {
      return out;
    }
    let text: string = '';
    try {
      text = this.decoder.decodeToString(body);
    } catch (e) {
      return out;
    }
    const parts: string[] = text.split('&');
    for (let i = 0; i < parts.length; i++) {
      const kv: string[] = parts[i].split('=');
      if (kv.length === 0 || kv[0].length === 0) {
        continue;
      }
      out.set(this.decode(kv[0]), kv.length > 1 ? this.decode(kv.slice(1).join('=')) : '');
    }
    return out;
  }

  private parentOf(p: string): string {
    const norm: string = this.store.normalize(p);
    const slash: number = norm.lastIndexOf('/');
    return slash <= 0 ? '/' : norm.substring(0, slash);
  }

  private freeBytes(): number {
    return statfs.getFreeSizeSync(this.store.root);
  }

  private totalBytes(): number {
    return statfs.getTotalSizeSync(this.store.root);
  }

  private reason(status: number): string {
    if (status === 200) {
      return 'OK';
    }
    if (status === 303) {
      return 'See Other';
    }
    if (status === 400) {
      return 'Bad Request';
    }
    if (status === 401) {
      return 'Unauthorized';
    }
    if (status === 403) {
      return 'Forbidden';
    }
    if (status === 404) {
      return 'Not Found';
    }
    if (status === 409) {
      return 'Conflict';
    }
    if (status === 413) {
      return 'Payload Too Large';
    }
    if (status === 429) {
      return 'Too Many Requests';
    }
    if (status === 431) {
      return 'Request Header Fields Too Large';
    }
    if (status === 500) {
      return 'Internal Server Error';
    }
    if (status === 501) {
      return 'Not Implemented';
    }
    if (status === 503) {
      return 'Service Unavailable';
    }
    if (status === 507) {
      return 'Insufficient Storage';
    }
    return 'Error';
  }

  private errText(e: Object): string {
    const be: BusinessError = e as BusinessError;
    if (be !== null && be !== undefined && be.code !== undefined) {
      return `code=${be.code} ${be.message}`;
    }
    return `${e}`;
  }

  private log(msg: string): void {
    hilog.info(0x0100, 'WatchHttp', '%{public}s', msg);
    this.onLog(msg);
  }
}
