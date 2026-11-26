import { fileIo as fs, statfs } from '@kit.CoreFileKit';

/**
 * One directory entry as exposed over the FTP wire.
 */
export class FsEntry {
  name: string = '';
  isDir: boolean = false;
  size: number = 0;
  /** epoch milliseconds */
  mtime: number = 0;
}

/**
 * Sandboxed file access for the FTP server.
 *
 * Every client supplied path is first normalised into a virtual absolute path
 * ("/a/b"), then mapped under `root`. `..` segments are clamped at the virtual
 * root, so a client can never escape the sandbox directory.
 */
export class FsStore {
  readonly root: string;

  constructor(root: string) {
    let r: string = root;
    while (r.length > 1 && r.endsWith('/')) {
      r = r.substring(0, r.length - 1);
    }
    this.root = r;
  }

  /** Collapse ".", ".." and duplicate separators into a virtual absolute path. */
  normalize(input: string): string {
    let p: string = input === null || input === undefined ? '/' : input;
    if (p.length === 0) {
      p = '/';
    }
    if (!p.startsWith('/')) {
      p = '/' + p;
    }
    const parts: string[] = p.split('/');
    const stack: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      const seg: string = parts[i];
      if (seg.length === 0 || seg === '.') {
        continue;
      }
      if (seg === '..') {
        if (stack.length > 0) {
          stack.pop();
        }
        continue;
      }
      stack.push(seg);
    }
    return '/' + stack.join('/');
  }

  /** Join a virtual path onto the real sandbox root. */
  real(virtualPath: string): string {
    const v: string = this.normalize(virtualPath);
    return v === '/' ? this.root : this.root + v;
  }

  exists(realPath: string): boolean {
    try {
      return fs.accessSync(realPath);
    } catch (e) {
      return false;
    }
  }

  isDir(realPath: string): boolean {
    try {
      return fs.statSync(realPath).isDirectory();
    } catch (e) {
      return false;
    }
  }

  size(realPath: string): number {
    try {
      return fs.statSync(realPath).size;
    } catch (e) {
      return -1;
    }
  }

  /** Build an entry for one real path; name is the last segment. */
  statOf(realPath: string, name: string): FsEntry | null {
    try {
      const st: fs.Stat = fs.statSync(realPath);
      const e: FsEntry = new FsEntry();
      e.name = name;
      e.isDir = st.isDirectory();
      e.size = st.size;
      e.mtime = st.mtime * 1000;
      return e;
    } catch (e) {
      return null;
    }
  }

  list(realPath: string): FsEntry[] {
    const out: FsEntry[] = [];
    let names: string[] = [];
    try {
      names = fs.listFileSync(realPath);
    } catch (e) {
      return out;
    }
    for (let i = 0; i < names.length; i++) {
      const name: string = names[i];
      const entry: FsEntry | null = this.statOf(realPath + '/' + name, name);
      if (entry !== null) {
        out.push(entry);
      }
    }
    return out;
  }

  mkdir(realPath: string): boolean {
    try {
      fs.mkdirSync(realPath, true);
      return true;
    } catch (e) {
      return false;
    }
  }

  remove(realPath: string): boolean {
    try {
      if (this.isDir(realPath)) {
        // Never recurse on behalf of a client: FTP RMD on a non-empty
        // directory has to fail, otherwise one command can wipe a tree.
        const names: string[] = fs.listFileSync(realPath);
        if (names.length > 0) {
          return false;
        }
        fs.rmdirSync(realPath);
      } else {
        fs.unlinkSync(realPath);
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  rename(fromReal: string, toReal: string): boolean {
    try {
      fs.renameSync(fromReal, toReal);
      return true;
    } catch (e) {
      return false;
    }
  }

  /** Ensure the FTP root exists and seed a tiny readme so clients see content. */
  ensureRoot(): void {
    if (!this.exists(this.root)) {
      this.mkdir(this.root);
    }
    const readme: string = this.real('/readme.txt');
    if (!this.exists(readme)) {
      try {
        const file: fs.File = fs.openSync(readme, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        fs.writeSync(file.fd, 'Huawei Watch FTP server.\nDrop files here from your phone.\n');
        fs.closeSync(file);
      } catch (e) {
        // Non fatal: an empty directory is still a valid FTP root.
      }
    }
  }

  // ---------------------------------------------------------- stage 1 additions

  /** Recursive copy. Returns false on the first failure and leaves a partial tree. */
  copy(fromReal: string, toReal: string): boolean {
    try {
      if (this.isDir(fromReal)) {
        if (!this.mkdir(toReal)) {
          return false;
        }
        const names: string[] = fs.listFileSync(fromReal);
        for (let i = 0; i < names.length; i++) {
          if (!this.copy(`${fromReal}/${names[i]}`, `${toReal}/${names[i]}`)) {
            return false;
          }
        }
        return true;
      }
      fs.copyFileSync(fromReal, toReal);
      return true;
    } catch (e) {
      return false;
    }
  }

  /** Rename, falling back to copy + delete when the rename is refused. */
  move(fromReal: string, toReal: string): boolean {
    if (this.rename(fromReal, toReal)) {
      return true;
    }
    if (!this.copy(fromReal, toReal)) {
      return false;
    }
    return this.removeTree(fromReal);
  }

  /**
   * Explicit recursive delete, for the on-watch file manager only.
   * The FTP RMD verb deliberately does NOT use this: a client must not be able
   * to wipe a tree with one command.
   */
  removeTree(realPath: string): boolean {
    try {
      if (!this.exists(realPath)) {
        return true;
      }
      if (!this.isDir(realPath)) {
        fs.unlinkSync(realPath);
        return true;
      }
      const names: string[] = fs.listFileSync(realPath);
      for (let i = 0; i < names.length; i++) {
        if (!this.removeTree(`${realPath}/${names[i]}`)) {
          return false;
        }
      }
      fs.rmdirSync(realPath);
      return true;
    } catch (e) {
      return false;
    }
  }

  freeBytes(): number {
    try {
      return statfs.getFreeSizeSync(this.root);
    } catch (e) {
      return -1;
    }
  }

  totalBytes(): number {
    try {
      return statfs.getTotalSizeSync(this.root);
    } catch (e) {
      return -1;
    }
  }

  /** `name.ext`, then `name (1).ext`, ... so a write never clobbers a file. */
  uniquePath(dirReal: string, name: string): string {
    const first: string = `${dirReal}/${name}`;
    if (!this.exists(first)) {
      return first;
    }
    const dot: number = name.lastIndexOf('.');
    const base: string = dot > 0 ? name.substring(0, dot) : name;
    const ext: string = dot > 0 ? name.substring(dot) : '';
    for (let i = 1; i < 500; i++) {
      const candidate: string = `${dirReal}/${base} (${i})${ext}`;
      if (!this.exists(candidate)) {
        return candidate;
      }
    }
    return `${dirReal}/${base}-${Date.now()}${ext}`;
  }

  /**
   * Removes `.upload-*.part` files left behind by an interrupted HTTP upload.
   * Only files older than `olderThanMs` are touched, so an upload in progress
   * on another connection is never deleted.
   */
  sweepTemp(olderThanMs: number): number {
    let removed: number = 0;
    const dirs: string[] = [this.root];
    const buckets: string[] = ['Images', 'Videos', 'Audio', 'Documents', 'Archives', 'Others'];
    for (let i = 0; i < buckets.length; i++) {
      const d: string = `${this.root}/${buckets[i]}`;
      if (this.isDir(d)) {
        dirs.push(d);
      }
    }
    const cutoff: number = Date.now() - olderThanMs;
    for (let i = 0; i < dirs.length; i++) {
      let names: string[] = [];
      try {
        names = fs.listFileSync(dirs[i]);
      } catch (e) {
        continue;
      }
      for (let k = 0; k < names.length; k++) {
        const name: string = names[k];
        if (!name.startsWith('.upload-') || !name.endsWith('.part')) {
          continue;
        }
        const full: string = `${dirs[i]}/${name}`;
        try {
          const st: fs.Stat = fs.statSync(full);
          if (st.mtime * 1000 < cutoff) {
            fs.unlinkSync(full);
            removed += 1;
          }
        } catch (e) {
          // Ignore: another writer may have removed it first.
        }
      }
    }
    return removed;
  }

  /** First `count` bytes of a file, for signature checks. */
  readHead(realPath: string, count: number): number[] {
    const out: number[] = [];
    let file: fs.File | null = null;
    try {
      file = fs.openSync(realPath, fs.OpenMode.READ_ONLY);
      const buf: ArrayBuffer = new ArrayBuffer(count);
      const n: number = fs.readSync(file.fd, buf, { offset: 0, length: count });
      const bytes: Uint8Array = new Uint8Array(buf);
      for (let i = 0; i < n; i++) {
        out.push(bytes[i]);
      }
    } catch (e) {
      return out;
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
        }
      }
    }
    return out;
  }
}
