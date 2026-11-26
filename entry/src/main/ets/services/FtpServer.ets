import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { Classifier } from './Classifier';
import { FsEntry, FsStore } from './FsStore';

const CRLF: string = '\r\n';
const CHUNK: number = 64 * 1024;
const LIST_CHUNK: number = 32 * 1024;
const DATA_TIMEOUT_MS: number = 10000;
const UPLOAD_IDLE_TIMEOUT_MS: number = 120000;
const PORT_MIN: number = 30000;
const PORT_MAX: number = 60000;

const MONTHS: string[] = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/** Snapshot handed to the UI. */
export class FtpStatus {
  running: boolean = false;
  port: number = 0;
  clients: number = 0;
  root: string = '';
  user: string = '';
  pass: string = '';
}

/** Per control-connection state machine. */
class FtpSession {
  id: number = 0;
  conn: socket.TCPSocketConnection | null = null;
  buf: string = '';
  cwd: string = '/';
  binary: boolean = true;
  rest: number = 0;
  renameFrom: string = '';
  chain: Promise<void> = Promise.resolve();
  // authentication state
  userTried: string = '';
  authed: boolean = false;
  failCount: number = 0;
  // passive listener + the single data connection it accepts
  pasv: socket.TCPSocketServer | null = null;
  pasvPort: number = 0;
  pending: socket.TCPSocketConnection | null = null;
  waiter: ((c: socket.TCPSocketConnection | null) => void) | null = null;
  dead: boolean = false;
}

/**
 * Minimal but client-compatible FTP server:
 *   - anonymous (any USER/PASS is accepted)
 *   - passive mode only (PASV + EPSV), binary and ASCII
 *   - LIST / NLST / MLSD / RETR / STOR / APPE / DELE / MKD / RMD / RNFR / RNTO
 *     / SIZE / MDTM / PWD / CWD / CDUP / TYPE / FEAT / SYST / NOOP / QUIT
 *
 * All paths are clamped inside the sandbox root supplied to start().
 */
export class FtpServer {
  private server: socket.TCPSocketServer | null = null;
  private store: FsStore = new FsStore('');
  private classifier: Classifier = new Classifier('');
  /**
   * When true, a file uploaded straight into the FTP root is filed into a
   * type bucket (Images/, Videos/, ...). Files uploaded to an explicit path
   * are always left alone.
   */
  private classifyRootUploads: boolean = true;
  private sessions: FtpSession[] = [];
  private decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
  private encoder: util.TextEncoder = new util.TextEncoder();
  private nextId: number = 1;
  private port: number = 0;
  private localIp: string = '127.0.0.1';
  private userName: string = '';
  private password: string = '';
  private failTimes: number[] = [];
  private lockUntil: number = 0;

  onLog: (msg: string) => void = (msg: string) => {
    console.info(`[FTP] ${msg}`);
  };
  onStatus: (st: FtpStatus) => void = (st: FtpStatus) => {
  };

  isRunning(): boolean {
    return this.server !== null;
  }

  currentPort(): number {
    return this.port;
  }

  status(): FtpStatus {
    const st: FtpStatus = new FtpStatus();
    st.running = this.server !== null;
    st.port = this.port;
    st.clients = this.sessions.length;
    st.root = this.store.root;
    st.user = this.userName;
    st.pass = this.password;
    return st;
  }

  // ---------------------------------------------------------------- lifecycle

  async start(root: string, localIp: string): Promise<FtpStatus> {
    if (this.server !== null) {
      await this.stop();
    }
    this.store = new FsStore(root);
    this.store.ensureRoot();
    this.classifier = new Classifier(this.store.root);
    if (this.classifyRootUploads) {
      this.classifier.ensureBuckets();
    }
    this.localIp = localIp.length > 0 ? localIp : '127.0.0.1';
    this.probePaths();
    this.failTimes = [];
    this.lockUntil = 0;
    this.makeCreds();

    let lastError: string = '';
    for (let attempt = 0; attempt < 24; attempt++) {
      const candidate: number = this.randomPort();
      const srv: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
      try {
        await srv.listen({ address: '0.0.0.0', port: candidate, family: 1 });
      } catch (e) {
        lastError = this.errText(e);
        continue;
      }
      this.server = srv;
      this.port = candidate;
      this.bindServer(srv);
      this.log(`listening on 0.0.0.0:${candidate}, root=${root}, user=${this.userName}`);
      const st: FtpStatus = this.status();
      this.onStatus(st);
      return st;
    }
    throw new Error(`no free port found: ${lastError}`);
  }

  async stop(): Promise<void> {
    const list: FtpSession[] = this.sessions.slice(0);
    for (let i = 0; i < list.length; i++) {
      await this.dropSession(list[i]);
    }
    this.sessions = [];
    if (this.server !== null) {
      const srv: socket.TCPSocketServer = this.server;
      this.server = null;
      try {
        srv.off('connect');
      } catch (e) {
      }
      try {
        await srv.close();
      } catch (e) {
      }
    }
    this.port = 0;
    this.log('stopped');
    this.onStatus(this.status());
  }

  private randomPort(): number {
    return PORT_MIN + Math.floor(Math.random() * (PORT_MAX - PORT_MIN));
  }

  /**
   * Short random credentials that are easy to retype on a phone:
   * 4 letters user, 6 characters password, ambiguity-free alphabet.
   * Regenerated on every start, so a leaked pair dies with the session.
   */
  private makeCreds(): void {
    const userAlphabet: string = 'abcdefghijkmnpqrstuvwxyz';
    const passAlphabet: string = 'abcdefghjkmnpqrstuvwxyz23456789';
    this.userName = this.randomFrom(userAlphabet, 4);
    this.password = this.randomFrom(passAlphabet, 6);
  }

  private randomFrom(alphabet: string, len: number): string {
    const bytes: number[] = this.randomBytes(len);
    let out: string = '';
    for (let i = 0; i < len; i++) {
      out = out + alphabet.charAt(bytes[i] % alphabet.length);
    }
    return out;
  }

  private randomBytes(count: number): number[] {
    const out: number[] = [];
    try {
      const rnd: cryptoFramework.Random = cryptoFramework.createRandom();
      const blob: cryptoFramework.DataBlob = rnd.generateRandomSync(count);
      for (let i = 0; i < blob.data.length; i++) {
        out.push(blob.data[i]);
      }
    } catch (e) {
      for (let i = 0; i < count; i++) {
        out.push(Math.floor(Math.random() * 256));
      }
    }
    return out;
  }

  private async cmdPass(s: FtpSession, arg: string): Promise<void> {
    const now: number = Date.now();
    if (now < this.lockUntil) {
      const wait: number = Math.ceil((this.lockUntil - now) / 1000);
      await this.reply(s, `421 Too many failed logins, retry in ${wait}s.`);
      await this.dropSession(s);
      return;
    }
    if (this.password.length > 0 && s.userTried === this.userName && arg === this.password) {
      s.authed = true;
      this.log(`#${s.id} login ok`);
      await this.reply(s, '230 Login successful.');
      return;
    }
    s.failCount = s.failCount + 1;
    this.noteFailure(now);
    this.log(`#${s.id} login failed (session ${s.failCount}, recent ${this.failTimes.length})`);
    if (s.failCount >= 3) {
      await this.reply(s, '421 Too many failed logins, closing connection.');
      await this.dropSession(s);
      return;
    }
    await this.reply(s, '530 Login incorrect.');
  }

  /**
   * Sliding-window throttle. Deliberately does NOT stop the server: a stranger
   * who can reach the port must not be able to shut the service down for its
   * owner. After the threshold, logins are refused for a short cooldown while
   * already authenticated sessions keep working.
   */
  private noteFailure(now: number): void {
    const windowStart: number = now - 60000;
    const kept: number[] = [];
    for (let i = 0; i < this.failTimes.length; i++) {
      if (this.failTimes[i] >= windowStart) {
        kept.push(this.failTimes[i]);
      }
    }
    kept.push(now);
    this.failTimes = kept;
    if (kept.length >= 20) {
      this.lockUntil = now + 30000;
      this.failTimes = [];
      this.log('login locked for 30s after too many failures');
    }
  }

  /**
   * Diagnostic: report which well-known absolute paths this app can actually
   * touch. On a wearable these public/media roots are normally absent or
   * denied, leaving only the app sandbox usable as FTP root.
   */
  private probePaths(): void {
    const candidates: string[] = [
      '/storage/media',
      '/storage/media/100/local/files',
      '/storage/media/100/local/files/Docs',
      '/storage/media/100/local/files/Download',
      '/mnt/share',
      '/mnt/hmdfs',
      '/data/storage/el1/bundle',
      this.store.root
    ];
    for (let i = 0; i < candidates.length; i++) {
      const p: string = candidates[i];
      let ok: boolean = false;
      let why: string = 'missing';
      try {
        ok = fs.accessSync(p);
        why = ok ? 'accessible' : 'missing';
      } catch (e) {
        why = `denied (${this.errText(e)})`;
      }
      this.log(`probe ${p} => ${why}`);
    }
  }

  private bindServer(srv: socket.TCPSocketServer): void {
    srv.on('connect', (client: socket.TCPSocketConnection) => {
      this.onClient(client);
    });
    srv.on('error', (err: BusinessError) => {
      this.log(`server error: ${this.errText(err)}`);
    });
  }

  // ------------------------------------------------------------ control layer

  private onClient(client: socket.TCPSocketConnection): void {
    const s: FtpSession = new FtpSession();
    s.id = this.nextId;
    this.nextId = this.nextId + 1;
    s.conn = client;
    this.sessions.push(s);
    this.log(`#${s.id} connected`);
    this.onStatus(this.status());

    client.on('message', (info: socket.SocketMessageInfo) => {
      this.onControlData(s, info);
    });
    client.on('close', () => {
      this.dropSession(s);
    });
    this.reply(s, '220 Huawei Watch FTP ready (login required)');
  }

  private onControlData(s: FtpSession, info: socket.SocketMessageInfo): void {
    if (s.dead) {
      return;
    }
    let text: string = '';
    try {
      text = this.decoder.decodeToString(new Uint8Array(info.message));
    } catch (e) {
      return;
    }
    s.buf = s.buf + text;
    while (!s.dead) {
      let idx: number = s.buf.indexOf('\r\n');
      let skip: number = 2;
      if (idx < 0) {
        idx = s.buf.indexOf('\n');
        skip = 1;
      }
      if (idx < 0) {
        break;
      }
      const line: string = s.buf.substring(0, idx);
      s.buf = s.buf.substring(idx + skip);
      if (line.trim().length === 0) {
        continue;
      }
      // Serialise commands per session so data transfers cannot interleave.
      s.chain = s.chain.then(() => this.dispatch(s, line)).catch((e: Error) => {
        this.log(`#${s.id} command error: ${e.message}`);
      });
    }
  }

  private async dispatch(s: FtpSession, line: string): Promise<void> {
    const sp: number = line.indexOf(' ');
    const verb: string = (sp < 0 ? line : line.substring(0, sp)).toUpperCase();
    const arg: string = sp < 0 ? '' : line.substring(sp + 1).trim();
    this.log(`#${s.id} > ${line}`);

    // Only the login handshake and a few harmless verbs are available pre-auth.
    const open: boolean = verb === 'USER' || verb === 'PASS' || verb === 'QUIT' || verb === 'FEAT' ||
      verb === 'SYST' || verb === 'NOOP';
    if (!s.authed && !open) {
      await this.reply(s, '530 Please login with USER and PASS.');
      return;
    }

    switch (verb) {
      case 'USER':
        // Never reveal whether the name is the real one: always ask for a password.
        s.userTried = arg;
        s.authed = false;
        await this.reply(s, `331 Password required for ${arg.length > 0 ? arg : 'ftp'}.`);
        return;
      case 'PASS':
        await this.cmdPass(s, arg);
        return;
      case 'SYST':
        await this.reply(s, '215 UNIX Type: L8');
        return;
      case 'FEAT':
        await this.reply(s, '211-Features:');
        await this.reply(s, ' UTF8');
        await this.reply(s, ' EPSV');
        await this.reply(s, ' PASV');
        await this.reply(s, ' SIZE');
        await this.reply(s, ' MDTM');
        await this.reply(s, ' MLST type*;size*;modify*;');
        await this.reply(s, '211 End');
        return;
      case 'OPTS':
        await this.reply(s, '200 UTF8 mode enabled.');
        return;
      case 'PWD':
      case 'XPWD':
        await this.reply(s, `257 "${s.cwd.replace(/"/g, '""')}" is the current directory.`);
        return;
      case 'CWD':
        await this.cmdCwd(s, arg);
        return;
      case 'CDUP':
        await this.cmdCwd(s, '..');
        return;
      case 'TYPE':
        s.binary = !arg.toUpperCase().startsWith('A');
        await this.reply(s, `200 Type set to ${s.binary ? 'I' : 'A'}.`);
        return;
      case 'MODE':
        await this.reply(s, '200 Mode set to S.');
        return;
      case 'STRU':
        await this.reply(s, '200 Structure set to F.');
        return;
      case 'PASV':
        await this.cmdPasv(s, false);
        return;
      case 'EPSV':
        await this.cmdPasv(s, true);
        return;
      case 'PORT':
      case 'EPRT':
        await this.reply(s, '502 Active mode not supported, use PASV.');
        return;
      case 'LIST':
        await this.cmdList(s, arg, 'list');
        return;
      case 'NLST':
        await this.cmdList(s, arg, 'nlst');
        return;
      case 'MLSD':
        await this.cmdList(s, arg, 'mlsd');
        return;
      case 'MLST':
        await this.cmdMlst(s, arg);
        return;
      case 'RETR':
        await this.cmdRetr(s, arg);
        return;
      case 'STOR':
        await this.cmdStor(s, arg, false);
        return;
      case 'APPE':
        await this.cmdStor(s, arg, true);
        return;
      case 'REST':
        s.rest = this.parseInt(arg, 0);
        await this.reply(s, '350 Restarting at requested offset.');
        return;
      case 'SIZE':
        await this.cmdSize(s, arg);
        return;
      case 'MDTM':
        await this.cmdMdtm(s, arg);
        return;
      case 'DELE':
        await this.cmdDele(s, arg);
        return;
      case 'MKD':
      case 'XMKD':
        await this.cmdMkd(s, arg);
        return;
      case 'RMD':
      case 'XRMD':
        await this.cmdRmd(s, arg);
        return;
      case 'RNFR':
        await this.cmdRnfr(s, arg);
        return;
      case 'RNTO':
        await this.cmdRnto(s, arg);
        return;
      case 'NOOP':
        await this.reply(s, '200 NOOP ok.');
        return;
      case 'ABOR':
        await this.reply(s, '226 ABOR ok.');
        return;
      case 'STAT':
        await this.reply(s, '211 FTP server status ok.');
        return;
      case 'ALLO':
        await this.reply(s, '202 ALLO not needed.');
        return;
      case 'QUIT':
        await this.reply(s, '221 Goodbye.');
        await this.dropSession(s);
        return;
      default:
        await this.reply(s, '502 Command not implemented.');
        return;
    }
  }

  // -------------------------------------------------------------- filesystem

  private virtualOf(s: FtpSession, arg: string): string {
    if (arg.length === 0) {
      return s.cwd;
    }
    if (arg.startsWith('/')) {
      return this.store.normalize(arg);
    }
    return this.store.normalize(`${s.cwd}/${arg}`);
  }

  private async cmdCwd(s: FtpSession, arg: string): Promise<void> {
    const v: string = this.virtualOf(s, arg);
    if (!this.store.isDir(this.store.real(v))) {
      await this.reply(s, '550 Failed to change directory.');
      return;
    }
    s.cwd = v;
    await this.reply(s, `250 Directory changed to ${v}.`);
  }

  private async cmdList(s: FtpSession, arg: string, mode: string): Promise<void> {
    const v: string = this.virtualOf(s, arg);
    const real: string = this.store.real(v);
    if (!this.store.exists(real)) {
      await this.reply(s, '550 No such file or directory.');
      return;
    }
    const data: socket.TCPSocketConnection | null = await this.acceptData(s);
    if (data === null) {
      await this.reply(s, '425 Can not open data connection.');
      return;
    }
    await this.reply(s, '150 Here comes the directory listing.');

    let body: string = '';
    if (this.store.isDir(real)) {
      const entries: FsEntry[] = this.store.list(real);
      for (let i = 0; i < entries.length; i++) {
        body = body + this.entryLine(entries[i], mode);
      }
    } else {
      const entry: FsEntry | null = this.store.statOf(real, this.baseName(v));
      if (entry !== null) {
        body = body + this.entryLine(entry, mode);
      }
    }
    await this.sendText(data, body);
    await this.endData(s, data);
    await this.reply(s, '226 Directory send OK.');
  }

  private async cmdMlst(s: FtpSession, arg: string): Promise<void> {
    const v: string = this.virtualOf(s, arg);
    const real: string = this.store.real(v);
    const entry: FsEntry | null = this.store.statOf(real, this.baseName(v));
    if (entry === null) {
      await this.reply(s, '550 No such file or directory.');
      return;
    }
    await this.reply(s, '250-Listing');
    await this.reply(s, ` ${this.mlsdFacts(entry)} ${entry.name}`);
    await this.reply(s, '250 End');
  }

  private async cmdSize(s: FtpSession, arg: string): Promise<void> {
    const real: string = this.store.real(this.virtualOf(s, arg));
    if (!this.store.exists(real) || this.store.isDir(real)) {
      await this.reply(s, '550 Could not get file size.');
      return;
    }
    await this.reply(s, `213 ${this.store.size(real)}`);
  }

  private async cmdMdtm(s: FtpSession, arg: string): Promise<void> {
    const real: string = this.store.real(this.virtualOf(s, arg));
    const entry: FsEntry | null = this.store.statOf(real, this.baseName(real));
    if (entry === null) {
      await this.reply(s, '550 Could not get modification time.');
      return;
    }
    await this.reply(s, `213 ${this.mdtm(entry.mtime)}`);
  }

  private async cmdDele(s: FtpSession, arg: string): Promise<void> {
    if (arg.length === 0) {
      await this.reply(s, '501 Missing file name.');
      return;
    }
    const real: string = this.store.real(this.virtualOf(s, arg));
    if (!this.store.exists(real) || this.store.isDir(real)) {
      await this.reply(s, '550 Delete failed.');
      return;
    }
    await this.reply(s, this.store.remove(real) ? '250 Delete ok.' : '550 Delete failed.');
  }

  private async cmdMkd(s: FtpSession, arg: string): Promise<void> {
    if (arg.length === 0) {
      await this.reply(s, '501 Missing directory name.');
      return;
    }
    const v: string = this.virtualOf(s, arg);
    await this.reply(s, this.store.mkdir(this.store.real(v)) ? `257 "${v}" created.` : '550 Create failed.');
  }

  private async cmdRmd(s: FtpSession, arg: string): Promise<void> {
    const real: string = this.store.real(this.virtualOf(s, arg));
    if (!this.store.isDir(real)) {
      await this.reply(s, '550 Remove failed.');
      return;
    }
    await this.reply(s, this.store.remove(real) ? '250 Remove ok.' : '550 Remove failed.');
  }

  private async cmdRnfr(s: FtpSession, arg: string): Promise<void> {
    const real: string = this.store.real(this.virtualOf(s, arg));
    if (!this.store.exists(real)) {
      await this.reply(s, '550 File not found.');
      return;
    }
    s.renameFrom = real;
    await this.reply(s, '350 Ready for RNTO.');
  }

  private async cmdRnto(s: FtpSession, arg: string): Promise<void> {
    if (s.renameFrom.length === 0) {
      await this.reply(s, '503 RNFR required first.');
      return;
    }
    const target: string = this.store.real(this.virtualOf(s, arg));
    const ok: boolean = this.store.rename(s.renameFrom, target);
    s.renameFrom = '';
    await this.reply(s, ok ? '250 Rename ok.' : '550 Rename failed.');
  }

  // ----------------------------------------------------------- file transfer

  private async cmdRetr(s: FtpSession, arg: string): Promise<void> {
    if (arg.length === 0) {
      await this.reply(s, '501 Missing file name.');
      return;
    }
    const real: string = this.store.real(this.virtualOf(s, arg));
    if (!this.store.exists(real) || this.store.isDir(real)) {
      await this.reply(s, '550 No such file.');
      return;
    }
    const size: number = this.store.size(real);
    const data: socket.TCPSocketConnection | null = await this.acceptData(s);
    if (data === null) {
      await this.reply(s, '425 Can not open data connection.');
      return;
    }
    await this.reply(s, `150 Opening data connection (${size} bytes).`);

    const start: number = s.rest > 0 && s.rest < size ? s.rest : 0;
    s.rest = 0;
    let sent: number = 0;
    let file: fs.File | null = null;
    try {
      file = fs.openSync(real, fs.OpenMode.READ_ONLY);
      let offset: number = start;
      while (true) {
        const buf: ArrayBuffer = new ArrayBuffer(CHUNK);
        const n: number = fs.readSync(file.fd, buf, { offset: offset, length: CHUNK });
        if (n <= 0) {
          break;
        }
        const piece: ArrayBuffer = n === CHUNK ? buf : buf.slice(0, n);
        await data.send({ data: piece });
        sent = sent + n;
        offset = offset + n;
        if (n < CHUNK) {
          break;
        }
      }
    } catch (e) {
      this.log(`#${s.id} RETR failed: ${this.errText(e)}`);
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
        }
      }
    }
    await this.endData(s, data);
    await this.reply(s, `226 Transfer complete (${sent} bytes).`);
  }

  private async cmdStor(s: FtpSession, arg: string, append: boolean): Promise<void> {
    if (arg.length === 0) {
      await this.reply(s, '501 Missing file name.');
      return;
    }
    const v: string = this.virtualOf(s, arg);
    const real: string = this.store.real(v);
    const data: socket.TCPSocketConnection | null = await this.acceptData(s);
    if (data === null) {
      await this.reply(s, '425 Can not open data connection.');
      return;
    }

    let flags: number = fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC;
    if (append && this.store.exists(real)) {
      flags = fs.OpenMode.READ_WRITE | fs.OpenMode.APPEND;
    }
    let opened: fs.File | null = null;
    try {
      opened = fs.openSync(real, flags);
    } catch (e) {
      this.log(`#${s.id} STOR open failed: ${this.errText(e)}`);
      await this.reply(s, '550 Cannot create file.');
      await this.endData(s, data);
      return;
    }
    const file: fs.File = opened;

    // Attach the sink before answering 150: a client is free to write and
    // close the moment it sees 150, and anything that arrives before the
    // listener exists is lost (observed as an APPE that stored 0 bytes).
    let total: number = 0;
    let failed: boolean = false;
    data.on('message', (info: socket.SocketMessageInfo) => {
      try {
        const n: number = fs.writeSync(file.fd, info.message);
        total = total + n;
      } catch (e) {
        failed = true;
        this.log(`#${s.id} STOR write failed: ${this.errText(e)}`);
      }
    });

    const closed: Promise<void> = new Promise<void>((resolve: () => void) => {
      let settled: boolean = false;
      const finish: () => void = () => {
        if (!settled) {
          settled = true;
          resolve();
        }
      };
      data.on('close', () => {
        finish();
      });
      setTimeout(() => {
        finish();
      }, UPLOAD_IDLE_TIMEOUT_MS);
    });

    await this.reply(s, '150 Ok to send data.');
    await closed;

    try {
      data.off('message');
    } catch (e) {
    }
    try {
      fs.closeSync(file);
    } catch (e) {
    }
    await this.endData(s, data);
    let note: string = '';
    if (!failed && !append && this.classifyRootUploads) {
      const moved: string = this.classifier.fileRootUpload(real, v);
      if (moved.length > 0) {
        note = ` Stored as ${moved}.`;
        this.log(`#${s.id} filed ${v} -> ${moved}`);
      }
    }
    this.log(`#${s.id} STOR ${v} ${total} bytes`);
    await this.reply(s, failed ? '451 Transfer aborted, write error.' : `226 Transfer complete (${total} bytes).${note}`);
  }

  // ------------------------------------------------------- passive data path

  private async cmdPasv(s: FtpSession, extended: boolean): Promise<void> {
    await this.closePasv(s);
    let port: number = 0;
    let srv: socket.TCPSocketServer | null = null;
    for (let attempt = 0; attempt < 24; attempt++) {
      const candidate: number = this.randomPort();
      const candidateSrv: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
      try {
        await candidateSrv.listen({ address: '0.0.0.0', port: candidate, family: 1 });
        port = candidate;
        srv = candidateSrv;
        break;
      } catch (e) {
        continue;
      }
    }
    if (srv === null) {
      await this.reply(s, '425 Can not open passive port.');
      return;
    }

    srv.on('connect', (client: socket.TCPSocketConnection) => {
      s.pending = client;
      const waiter: ((c: socket.TCPSocketConnection | null) => void) | null = s.waiter;
      if (waiter !== null) {
        s.waiter = null;
        waiter(client);
      }
    });
    s.pasv = srv;
    s.pasvPort = port;

    if (extended) {
      await this.reply(s, `229 Entering Extended Passive Mode (|||${port}|).`);
    } else {
      await this.reply(s, `227 Entering Passive Mode (${this.ipOctets()},${Math.floor(port / 256)},${port % 256}).`);
    }
  }

  private async closePasv(s: FtpSession): Promise<void> {
    const srv: socket.TCPSocketServer | null = s.pasv;
    s.pasv = null;
    s.pasvPort = 0;
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
    s.pending = null;
    if (s.waiter !== null) {
      const waiter: (c: socket.TCPSocketConnection | null) => void = s.waiter;
      s.waiter = null;
      waiter(null);
    }
  }

  private acceptData(s: FtpSession): Promise<socket.TCPSocketConnection | null> {
    if (s.pending !== null) {
      const ready: socket.TCPSocketConnection = s.pending;
      s.pending = null;
      return Promise.resolve(ready);
    }
    if (s.pasv === null) {
      return Promise.resolve(null);
    }
    return new Promise<socket.TCPSocketConnection | null>((resolve: (c: socket.TCPSocketConnection | null) => void) => {
      let settled: boolean = false;
      const finish: (c: socket.TCPSocketConnection | null) => void = (c: socket.TCPSocketConnection | null) => {
        if (!settled) {
          settled = true;
          resolve(c);
        }
      };
      s.waiter = finish;
      setTimeout(() => {
        if (!settled) {
          s.waiter = null;
          finish(null);
        }
      }, DATA_TIMEOUT_MS);
    });
  }

  private async endData(s: FtpSession, data: socket.TCPSocketConnection | null): Promise<void> {
    if (data !== null) {
      try {
        await data.close();
      } catch (e) {
      }
    }
    await this.closePasv(s);
  }

  private async sendText(data: socket.TCPSocketConnection, text: string): Promise<void> {
    if (text.length === 0) {
      return;
    }
    const bytes: Uint8Array = this.encoder.encodeInto(text);
    const exact: ArrayBuffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
    let offset: number = 0;
    while (offset < exact.byteLength) {
      const end: number = Math.min(offset + LIST_CHUNK, exact.byteLength);
      const piece: ArrayBuffer = exact.slice(offset, end);
      try {
        await data.send({ data: piece });
      } catch (e) {
        return;
      }
      offset = end;
    }
  }

  // ------------------------------------------------------------------ helpers

  private async dropSession(s: FtpSession): Promise<void> {
    if (s.dead) {
      return;
    }
    s.dead = true;
    const idx: number = this.sessions.indexOf(s);
    if (idx >= 0) {
      this.sessions.splice(idx, 1);
    }
    await this.closePasv(s);
    if (s.conn !== null) {
      const conn: socket.TCPSocketConnection = s.conn;
      s.conn = null;
      try {
        conn.off('message');
      } catch (e) {
      }
      try {
        await conn.close();
      } catch (e) {
      }
    }
    this.log(`#${s.id} disconnected`);
    this.onStatus(this.status());
  }

  private async reply(s: FtpSession, line: string): Promise<void> {
    if (s.conn === null || s.dead) {
      return;
    }
    try {
      await s.conn.send({ data: `${line}${CRLF}` });
    } catch (e) {
      this.log(`#${s.id} reply failed: ${this.errText(e)}`);
    }
  }

  private entryLine(e: FsEntry, mode: string): string {
    if (mode === 'nlst') {
      return `${e.name}${CRLF}`;
    }
    if (mode === 'mlsd') {
      return `${this.mlsdFacts(e)} ${e.name}${CRLF}`;
    }
    const perm: string = e.isDir ? 'drwxr-xr-x' : '-rw-r--r--';
    const when: Date = new Date(e.mtime);
    const day: string = `${when.getDate()}`.padStart(2, '0');
    const stamp: string = `${MONTHS[when.getMonth()]} ${day} ${this.hhmm(when)}`;
    return `${perm}    1 ftp      ftp      ${`${e.size}`.padStart(8, ' ')} ${stamp} ${e.name}${CRLF}`;
  }

  private mlsdFacts(e: FsEntry): string {
    const kind: string = e.isDir ? 'dir' : 'file';
    return `type=${kind};size=${e.size};modify=${this.mdtm(e.mtime)};`;
  }

  private mdtm(ms: number): string {
    const d: Date = new Date(ms);
    const pad: (n: number) => string = (n: number) => `${n}`.padStart(2, '0');
    return `${d.getUTCFullYear()}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}${pad(d.getUTCHours())}${pad(d.getUTCMinutes())}${pad(d.getUTCSeconds())}`;
  }

  private hhmm(d: Date): string {
    const hh: string = `${d.getHours()}`.padStart(2, '0');
    const mm: string = `${d.getMinutes()}`.padStart(2, '0');
    return `${hh}:${mm}`;
  }

  private baseName(path: string): string {
    const idx: number = path.lastIndexOf('/');
    return idx < 0 ? path : path.substring(idx + 1);
  }

  private ipOctets(): string {
    const parts: string[] = this.localIp.split('.');
    if (parts.length !== 4) {
      return '127,0,0,1';
    }
    for (let i = 0; i < parts.length; i++) {
      const n: number = this.parseInt(parts[i], -1);
      if (n < 0 || n > 255) {
        return '127,0,0,1';
      }
    }
    return parts.join(',');
  }

  private parseInt(text: string, fallback: number): number {
    const n: number = Number.parseInt(text, 10);
    return Number.isNaN(n) ? fallback : n;
  }

  private errText(e: Object): string {
    const be: BusinessError = e as BusinessError;
    if (be !== null && be !== undefined && be.code !== undefined) {
      return `code=${be.code} ${be.message}`;
    }
    return `${e}`;
  }

  private log(msg: string): void {
    hilog.info(0x0100, 'WatchFtp', '%{public}s', msg);
    this.onLog(msg);
  }
}
