import { hilog } from '@kit.PerformanceAnalysisKit';
import { FtpServer, FtpStatus } from './FtpServer';
import { HttpServer, HttpStatus } from './HttpServer';
import { FsStore } from './FsStore';
import { inspect, MediaInfo, MediaKind, Playability } from './Metadata';
import { imageInfo, ImageMeta } from './MediaBackend';

/** Everything the UI needs to render, in one snapshot. */
export class ServerStatus {
  running: boolean = false;
  ip: string = '';
  root: string = '';
  ftpPort: number = 0;
  ftpUser: string = '';
  ftpPass: string = '';
  httpPort: number = 0;
  httpCode: string = '';
  ftpClients: number = 0;
}

/**
 * Owns the transport layer. The UI starts and stops one thing and renders one
 * snapshot; it does not know that there are two servers, nor how either works.
 */
export class ServerHub {
  private ftp: FtpServer = new FtpServer();
  private http: HttpServer = new HttpServer();
  private store: FsStore = new FsStore('');
  private ip: string = '';
  private root: string = '';
  private startupProbe: string = '';

  onStatus: (st: ServerStatus) => void = (st: ServerStatus) => {
  };
  onLog: (line: string) => void = (line: string) => {
  };

  constructor() {
    this.ftp.onLog = (msg: string) => this.onLog(msg);
    this.http.onLog = (msg: string) => this.onLog(msg);
    this.ftp.onStatus = (st: FtpStatus) => this.emit();
    this.http.onStatus = (st: HttpStatus) => this.emit();
  }

  isRunning(): boolean {
    return this.ftp.isRunning() || this.http.isRunning();
  }

  status(): ServerStatus {
    const st: ServerStatus = new ServerStatus();
    st.running = this.isRunning();
    st.ip = this.ip;
    st.root = this.root;
    st.ftpPort = this.ftp.currentPort();
    st.httpPort = this.http.status().port;
    st.ftpUser = this.ftp.status().user;
    st.ftpPass = this.ftp.status().pass;
    st.httpCode = this.http.status().code;
    st.ftpClients = this.ftp.status().clients;
    return st;
  }

  /** Result of the one-off sample inspection done at start, for diagnostics. */
  probeLine(): string {
    return this.startupProbe;
  }

  async start(root: string, ip: string): Promise<void> {
    this.root = root;
    this.ip = ip;
    this.store = new FsStore(root);
    this.store.ensureRoot();
    const swept: number = this.store.sweepTemp(60 * 60 * 1000);
    if (swept > 0) {
      this.onLog(`cleaned ${swept} stale upload temp file(s)`);
    }
    try {
      await this.ftp.start(root, ip);
    } catch (e) {
      this.onLog(`FTP start failed: ${(e as Error).message}`);
    }
    try {
      await this.http.start(root, ip);
    } catch (e) {
      this.onLog(`HTTP start failed: ${(e as Error).message}`);
    }
    this.startupProbe = await this.inspectSample();
    this.emit();
  }

  async stop(): Promise<void> {
    await this.ftp.stop();
    await this.http.stop();
    this.emit();
  }

  /**
   * Stage 1 self-check: run the metadata layer over one real file in each
   * bucket and log the verdict. This is what proves the layer works on the
   * device without needing a UI page yet.
   */
  private async inspectSample(): Promise<string> {
    const buckets: string[] = ['Images', 'Videos', 'Audio', 'Documents'];
    let line: string = '';
    for (let i = 0; i < buckets.length; i++) {
      const dirReal: string = this.store.real(`/${buckets[i]}`);
      const entries = this.store.list(dirReal);
      if (entries.length === 0) {
        continue;
      }
      const first = entries[0];
      const real: string = `${dirReal}/${first.name}`;
      const info: MediaInfo = inspect(first.name, first.size, (count: number) => {
        return this.store.readHead(real, count);
      });
      line += `[${buckets[i]}] ${first.name} ${info.mime} kind=${MediaKind[info.kind]} `;
      line += `container=${info.container} codec=${info.codec} play=${Playability[info.policyPlayable]}`;
      if (info.kind === MediaKind.IMAGE) {
        const meta: ImageMeta = await imageInfo(real);
        line += meta.ok ? ` size=${meta.width}x${meta.height}` : ` size=ERR(${meta.error})`;
      }
      hilog.info(0x0100, 'WatchProbe', '%{public}s', line);
      line += '\n';
      break;
    }
    if (line.length === 0) {
      hilog.info(0x0100, 'WatchProbe', '%{public}s', 'no sample files in buckets yet');
      return 'no sample';
    }
    return line.trim();
  }

  private emit(): void {
    this.onStatus(this.status());
  }
}
