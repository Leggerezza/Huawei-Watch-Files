import { fileIo as fs } from '@kit.CoreFileKit';

/** Bucket directories created at the FTP root, in listing order. */
export const BUCKETS: string[] = ['Images', 'Videos', 'Audio', 'Documents', 'Archives', 'Others'];

const IMAGE_EXT: string[] = ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'heic', 'heif', 'tif', 'tiff', 'svg', 'ico', 'raw', 'dng'];
const VIDEO_EXT: string[] = ['mp4', 'mov', 'm4v', 'mkv', 'avi', 'wmv', 'flv', 'webm', '3gp', 'ts', 'mpg', 'mpeg', 'rmvb'];
const AUDIO_EXT: string[] = ['mp3', 'wav', 'flac', 'aac', 'ogg', 'm4a', 'amr', 'ape', 'wma', 'opus', 'mid', 'midi'];
const DOC_EXT: string[] = ['pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'md', 'csv', 'json', 'xml', 'html', 'htm', 'rtf', 'epub', 'log', 'ini', 'yaml', 'yml'];
const ARCHIVE_EXT: string[] = ['zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz', 'apk', 'hap', 'jar', 'iso', 'cab'];

/**
 * Files a finished upload into a type bucket.
 *
 * Only uploads that land directly in the FTP root are moved: a client that
 * names a path explicitly keeps that path. Moving a root upload is a
 * deliberate trade — the file is easier to browse afterwards, but a client
 * that reuses the original name in the same session will not find it there,
 * so the 226 reply carries the final path.
 */
export class Classifier {
  private root: string = '';
  private ready: boolean = false;

  constructor(root: string) {
    this.root = root;
  }

  ensureBuckets(): void {
    for (let i = 0; i < BUCKETS.length; i++) {
      const dir: string = `${this.root}/${BUCKETS[i]}`;
      try {
        if (!fs.accessSync(dir)) {
          fs.mkdirSync(dir, true);
        }
      } catch (e) {
        // A read-only or partially mounted root must not break the server.
      }
    }
    this.ready = true;
  }

  /**
   * @param absPath absolute path of the just-written file
   * @param virtualPath client path, e.g. "/photo.jpg"
   * @returns the new virtual path, or '' when the file stays where it is
   */
  fileRootUpload(absPath: string, virtualPath: string): string {
    if (!virtualPath.startsWith('/')) {
      return '';
    }
    const name: string = virtualPath.substring(1);
    if (name.length === 0 || name.indexOf('/') >= 0) {
      return '';
    }
    for (let i = 0; i < BUCKETS.length; i++) {
      if (name === BUCKETS[i]) {
        return '';
      }
    }
    if (!this.ready) {
      this.ensureBuckets();
    }
    const bucket: string = this.bucketFor(name, absPath);
    const target: string = this.uniquePath(`${this.root}/${bucket}`, name);
    try {
      fs.renameSync(absPath, target);
    } catch (e) {
      return '';
    }
    const leaf: string = target.substring(target.lastIndexOf('/') + 1);
    return `/${bucket}/${leaf}`;
  }

  /** Extension first; magic bytes only when the name says nothing useful. */
  bucketFor(name: string, absPath: string): string {
    const byExt: string = Classifier.bucketOfExtension(Classifier.extensionOf(name));
    if (byExt.length > 0) {
      return byExt;
    }
    return Classifier.bucketOfMagic(absPath);
  }

  static extensionOf(name: string): string {
    const dot: number = name.lastIndexOf('.');
    if (dot <= 0 || dot === name.length - 1) {
      return '';
    }
    return name.substring(dot + 1).toLowerCase();
  }

  static bucketOfExtension(ext: string): string {
    if (ext.length === 0) {
      return '';
    }
    if (IMAGE_EXT.indexOf(ext) >= 0) {
      return 'Images';
    }
    if (VIDEO_EXT.indexOf(ext) >= 0) {
      return 'Videos';
    }
    if (AUDIO_EXT.indexOf(ext) >= 0) {
      return 'Audio';
    }
    if (DOC_EXT.indexOf(ext) >= 0) {
      return 'Documents';
    }
    if (ARCHIVE_EXT.indexOf(ext) >= 0) {
      return 'Archives';
    }
    return '';
  }

  /** Reads the first bytes and maps well-known signatures. */
  static bucketOfMagic(absPath: string): string {
    const head: number[] = Classifier.readHead(absPath);
    if (head.length < 4) {
      return 'Others';
    }
    // RIFF containers: WEBP is an image, WAVE is audio, everything else (AVI) is video.
    if (head[0] === 0x52 && head[1] === 0x49 && head[2] === 0x46 && head[3] === 0x46) {
      if (head.length >= 12) {
        const kind: string = Classifier.ascii(head, 8, 4);
        if (kind === 'WEBP') {
          return 'Images';
        }
        if (kind === 'WAVE') {
          return 'Audio';
        }
      }
      return 'Videos';
    }
    if (head[0] === 0xFF && head[1] === 0xD8 && head[2] === 0xFF) {
      return 'Images';
    }
    if (head[0] === 0x89 && head[1] === 0x50 && head[2] === 0x4E && head[3] === 0x47) {
      return 'Images';
    }
    if (head[0] === 0x47 && head[1] === 0x49 && head[2] === 0x46) {
      return 'Images';
    }
    if (head[0] === 0x42 && head[1] === 0x4D) {
      return 'Images';
    }
    if (head[0] === 0x25 && head[1] === 0x50 && head[2] === 0x44 && head[3] === 0x46) {
      return 'Documents';
    }
    if (head[0] === 0x50 && head[1] === 0x4B && head[2] === 0x03 && head[3] === 0x04) {
      return 'Archives';
    }
    if (head[0] === 0x1A && head[1] === 0x45 && head[2] === 0xDF && head[3] === 0xA3) {
      return 'Videos';
    }
    if (head[0] === 0x66 && head[1] === 0x4C && head[2] === 0x61 && head[3] === 0x43) {
      return 'Audio';
    }
    if (head[0] === 0x4F && head[1] === 0x67 && head[2] === 0x67 && head[3] === 0x53) {
      return 'Audio';
    }
    if (head[0] === 0x49 && head[1] === 0x44 && head[2] === 0x33) {
      return 'Audio';
    }
    if (head[0] === 0xFF && (head[1] === 0xFB || head[1] === 0xF3 || head[1] === 0xF2)) {
      return 'Audio';
    }
    if (head.length >= 12 && Classifier.ascii(head, 4, 4) === 'ftyp') {
      const brand: string = Classifier.ascii(head, 8, 4);
      if (brand === 'heic' || brand === 'heix' || brand === 'mif1' || brand === 'msf1') {
        return 'Images';
      }
      return 'Videos';
    }
    return 'Others';
  }

  private static readHead(absPath: string): number[] {
    const out: number[] = [];
    try {
      const file: fs.File = fs.openSync(absPath, fs.OpenMode.READ_ONLY);
      try {
        const buf: ArrayBuffer = new ArrayBuffer(32);
        const n: number = fs.readSync(file.fd, buf, { offset: 0, length: 32 });
        const bytes: Uint8Array = new Uint8Array(buf);
        for (let i = 0; i < n; i++) {
          out.push(bytes[i]);
        }
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      return out;
    }
    return out;
  }

  private static ascii(data: number[], start: number, len: number): string {
    let s: string = '';
    for (let i = start; i < start + len && i < data.length; i++) {
      s = s + String.fromCharCode(data[i]);
    }
    return s;
  }

  /** name.ext, then "name (1).ext", "name (2).ext" ... */
  private uniquePath(dir: string, name: string): string {
    const first: string = `${dir}/${name}`;
    try {
      if (!fs.accessSync(first)) {
        return first;
      }
    } catch (e) {
      return first;
    }
    const dot: number = name.lastIndexOf('.');
    const base: string = dot > 0 ? name.substring(0, dot) : name;
    const ext: string = dot > 0 ? name.substring(dot) : '';
    for (let i = 1; i < 500; i++) {
      const candidate: string = `${dir}/${base} (${i})${ext}`;
      try {
        if (!fs.accessSync(candidate)) {
          return candidate;
        }
      } catch (e) {
        return candidate;
      }
    }
    return `${dir}/${base}-${Date.now()}${ext}`;
  }
}
