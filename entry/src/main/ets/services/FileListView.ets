import { FsEntry, FsStore } from './FsStore';
import { inspect, MediaInfo, MediaKind, Playability } from './Metadata';

export enum FileViewKind {
  BUCKETS = 0,
  DIR = 1,
  RECENT = 2,
  TRANSPORT = 3
}

export class FileItem {
  name: string = '';
  /** virtual path, always starts with '/' */
  path: string = '';
  isDir: boolean = false;
  size: number = 0;
  mtime: number = 0;
  kind: MediaKind = MediaKind.OTHER;
  playable: Playability = Playability.UNKNOWN;
}

export class BucketStat {
  name: string = '';
  count: number = 0;
  bytes: number = 0;
}

/** Result of one tree walk, kept until the next refresh. */
class Scan {
  files: FileItem[] = [];
  truncated: boolean = false;
  ms: number = 0;
}

const VIEW_NAMES: string[] = ['分类', '目录', '最近', '传输'];
const BUCKETS: string[] = ['Images', 'Videos', 'Audio', 'Documents', 'Archives', 'Others'];

export function viewName(kind: FileViewKind): string {
  return VIEW_NAMES[kind];
}

export function bucketOf(kind: MediaKind): string {
  if (kind === MediaKind.IMAGE) {
    return 'Images';
  }
  if (kind === MediaKind.VIDEO) {
    return 'Videos';
  }
  if (kind === MediaKind.AUDIO) {
    return 'Audio';
  }
  if (kind === MediaKind.TEXT || kind === MediaKind.DOCUMENT) {
    return 'Documents';
  }
  if (kind === MediaKind.ARCHIVE) {
    return 'Archives';
  }
  return 'Others';
}

/** LazyForEach source: the list only materialises rows that are on screen. */
export class FileDataSource implements IDataSource {
  private items: FileItem[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): FileItem {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const idx: number = this.listeners.indexOf(listener);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }

  setItems(items: FileItem[]): void {
    this.items = items;
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataReloaded();
    }
  }

  snapshot(): FileItem[] {
    return this.items;
  }
}

/**
 * View model for the file manager. Owns every FsStore call and exposes plain
 * data plus a change callback; the page renders and forwards taps.
 *
 * The bucket view is a *filter over the whole tree*, not a listing of the
 * physical bucket folders, so a file in a custom folder still shows up there.
 * That costs a tree walk, which is time-boxed and cached.
 */
export class FileListView {
  readonly store: FsStore;
  kind: FileViewKind = FileViewKind.BUCKETS;
  /** current directory for DIR view */
  path: string = '/';
  /** active bucket filter, empty means the bucket overview */
  filter: string = '';
  data: FileDataSource = new FileDataSource();
  buckets: BucketStat[] = [];
  loading: boolean = false;
  note: string = '';
  sortKey: string = 'name';
  sortAsc: boolean = true;
  onChange: () => void = () => {
  };

  private scanCache: Scan | null = null;
  private scanAt: number = 0;
  private readonly walkBudgetMs: number = 1500;
  private readonly maxEntries: number = 5000;

  constructor(store: FsStore) {
    this.store = store;
  }

  /** Drops cached scan results; call after any mutation or on pull-to-refresh. */
  invalidate(): void {
    this.scanCache = null;
  }

  async refresh(): Promise<void> {
    this.loading = true;
    this.note = '';
    this.onChange();
    try {
      if (this.kind === FileViewKind.DIR) {
        this.data.setItems(this.renderDir());
      } else if (this.kind === FileViewKind.RECENT) {
        this.data.setItems(this.renderRecent());
      } else {
        this.data.setItems(this.renderBuckets());
      }
    } catch (e) {
      this.note = `读取失败: ${(e as Error).message}`;
    }
    this.loading = false;
    this.onChange();
  }

  async open(kind: FileViewKind, path: string, filter: string): Promise<void> {
    this.kind = kind;
    this.path = path;
    this.filter = filter;
    await this.refresh();
  }

  /** Enter a directory (DIR view) or a bucket (BUCKETS view). */
  async enter(item: FileItem): Promise<void> {
    if (item.isDir) {
      this.kind = FileViewKind.DIR;
      this.path = item.path;
      this.filter = '';
      await this.refresh();
    }
  }

  async up(): Promise<void> {
    if (this.kind !== FileViewKind.DIR || this.path === '/') {
      return;
    }
    const idx: number = this.path.lastIndexOf('/');
    this.path = idx <= 0 ? '/' : this.path.substring(0, idx);
    await this.refresh();
  }

  async openBucket(name: string): Promise<void> {
    this.filter = name;
    await this.refresh();
  }

  async backToBuckets(): Promise<void> {
    this.filter = '';
    await this.refresh();
  }

  cycleSort(): void {
    if (this.sortKey === 'name') {
      this.sortKey = 'size';
    } else if (this.sortKey === 'size') {
      this.sortKey = 'time';
    } else {
      this.sortKey = 'name';
    }
    this.sortAsc = !this.sortAsc;
    this.refresh();
  }

  sortLabel(): string {
    const key: string = this.sortKey === 'name' ? '名称' : (this.sortKey === 'size' ? '大小' : '时间');
    return `${key}${this.sortAsc ? '↑' : '↓'}`;
  }

  // ---------------------------------------------------------------- rendering

  private renderDir(): FileItem[] {
    const real: string = this.store.real(this.path);
    const entries: FsEntry[] = this.store.list(real);
    const out: FileItem[] = [];
    for (let i = 0; i < entries.length; i++) {
      const e: FsEntry = entries[i];
      if (e.name.startsWith('.')) {
        continue;
      }
      const item: FileItem = new FileItem();
      item.name = e.name;
      item.path = this.path === '/' ? `/${e.name}` : `${this.path}/${e.name}`;
      item.isDir = e.isDir;
      item.size = e.size;
      item.mtime = e.mtime;
      if (!e.isDir) {
        const info: MediaInfo = inspect(e.name, e.size, (count: number) => this.store.readHead(this.store.real(item.path), count));
        item.kind = info.kind;
        item.playable = info.policyPlayable;
      }
      out.push(item);
    }
    return this.sortItems(out, true);
  }

  private renderBuckets(): FileItem[] {
    const scan: Scan = this.ensureScan();
    this.buckets = this.countBuckets(scan.files);
    if (this.filter.length === 0) {
      // Overview: one row per bucket, rendered from buckets[] elsewhere.
      return [];
    }
    const filtered: FileItem[] = [];
    for (let i = 0; i < scan.files.length; i++) {
      const f: FileItem = scan.files[i];
      if (bucketOf(f.kind) === this.filter) {
        filtered.push(f);
      }
    }
    return this.sortItems(filtered, false);
  }

  private renderRecent(): FileItem[] {
    const scan: Scan = this.ensureScan();
    const files: FileItem[] = scan.files.slice(0);
    files.sort((a: FileItem, b: FileItem) => b.mtime - a.mtime);
    return files.slice(0, 60);
  }

  private ensureScan(): Scan {
    const now: number = Date.now();
    if (this.scanCache !== null && now - this.scanAt < 30000) {
      return this.scanCache;
    }
    const started: number = now;
    const deadline: number = now + this.walkBudgetMs;
    const scan: Scan = new Scan();
    this.walk('/', deadline, scan);
    scan.ms = Date.now() - started;
    this.scanCache = scan;
    this.scanAt = now;
    if (scan.truncated) {
      this.note = `扫描超时，仅显示前 ${scan.files.length} 项`;
    }
    return scan;
  }

  private walk(dirPath: string, deadline: number, scan: Scan): void {
    if (Date.now() > deadline || scan.files.length >= this.maxEntries) {
      scan.truncated = true;
      return;
    }
    const real: string = this.store.real(dirPath);
    const entries: FsEntry[] = this.store.list(real);
    for (let i = 0; i < entries.length; i++) {
      if (Date.now() > deadline || scan.files.length >= this.maxEntries) {
        scan.truncated = true;
        return;
      }
      const e: FsEntry = entries[i];
      if (e.name.startsWith('.')) {
        continue;
      }
      const childPath: string = dirPath === '/' ? `/${e.name}` : `${dirPath}/${e.name}`;
      if (e.isDir) {
        this.walk(childPath, deadline, scan);
        continue;
      }
      const item: FileItem = new FileItem();
      item.name = e.name;
      item.path = childPath;
      item.isDir = false;
      item.size = e.size;
      item.mtime = e.mtime;
      const info: MediaInfo = inspect(e.name, e.size, (count: number) => this.store.readHead(this.store.real(childPath), count));
      item.kind = info.kind;
      item.playable = info.policyPlayable;
      scan.files.push(item);
    }
  }

  private countBuckets(files: FileItem[]): BucketStat[] {
    const stats: BucketStat[] = [];
    for (let b = 0; b < BUCKETS.length; b++) {
      const s: BucketStat = new BucketStat();
      s.name = BUCKETS[b];
      stats.push(s);
    }
    for (let i = 0; i < files.length; i++) {
      const name: string = bucketOf(files[i].kind);
      for (let b = 0; b < stats.length; b++) {
        if (stats[b].name === name) {
          stats[b].count += 1;
          stats[b].bytes += files[i].size;
          break;
        }
      }
    }
    return stats;
  }

  private sortItems(items: FileItem[], dirsFirst: boolean): FileItem[] {
    const out: FileItem[] = items.slice(0);
    out.sort((a: FileItem, b: FileItem) => {
      if (dirsFirst && a.isDir !== b.isDir) {
        return a.isDir ? -1 : 1;
      }
      let cmp: number = 0;
      if (this.sortKey === 'size') {
        cmp = a.size - b.size;
      } else if (this.sortKey === 'time') {
        cmp = a.mtime - b.mtime;
      } else {
        cmp = a.name.localeCompare(b.name, 'zh-CN');
      }
      return this.sortAsc ? cmp : -cmp;
    });
    return out;
  }
}
