import { fileIo as fs } from '@kit.CoreFileKit';

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
}
