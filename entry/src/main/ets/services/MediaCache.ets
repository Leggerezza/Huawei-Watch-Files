import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * Bounded caches shared by the viewer and the reader.
 *
 * Decoded PixelMaps are expensive (a 466 px bitmap is ~0.9 MB), so the cache
 * owns them and the pages only borrow. Eviction releases the bitmap; the
 * viewer never releases one itself, otherwise it would invalidate the cache.
 */
class PixelEntry {
  key: string = '';
  pixel: image.PixelMap | undefined = undefined;
  bytes: number = 0;
  lastUsed: number = 0;
}

const MAX_PIXELS: number = 6;
const MAX_BYTES: number = 40 * 1024 * 1024;

export class PixelCache {
  private static shared: PixelCache | null = null;
  private entries: PixelEntry[] = [];
  private hits: number = 0;
  private misses: number = 0;

  static instance(): PixelCache {
    if (PixelCache.shared === null) {
      PixelCache.shared = new PixelCache();
    }
    return PixelCache.shared;
  }

  stats(): string {
    return `${this.hits}/${this.hits + this.misses}`;
  }

  get(key: string): image.PixelMap | undefined {
    for (let i = 0; i < this.entries.length; i++) {
      if (this.entries[i].key === key) {
        this.entries[i].lastUsed = Date.now();
        this.hits += 1;
        // Move to the end so the LRU order stays meaningful.
        const e: PixelEntry = this.entries.splice(i, 1)[0];
        this.entries.push(e);
        return e.pixel;
      }
    }
    this.misses += 1;
    return undefined;
  }

  put(key: string, pixel: image.PixelMap, bytes: number): void {
    for (let i = 0; i < this.entries.length; i++) {
      if (this.entries[i].key === key) {
        return;
      }
    }
    const e: PixelEntry = new PixelEntry();
    e.key = key;
    e.pixel = pixel;
    e.bytes = bytes;
    e.lastUsed = Date.now();
    this.entries.push(e);
    this.evict();
  }

  /** Releases least-recently-used bitmaps until both limits hold. */
  private evict(): void {
    let totalBytes: number = 0;
    for (let i = 0; i < this.entries.length; i++) {
      totalBytes += this.entries[i].bytes;
    }
    while (this.entries.length > 1 && (this.entries.length > MAX_PIXELS || totalBytes > MAX_BYTES)) {
      const victim: PixelEntry = this.entries.shift() as PixelEntry;
      totalBytes -= victim.bytes;
      try {
        if (victim.pixel !== undefined) {
          victim.pixel.release();
        }
      } catch (e) {
      }
      hilog.info(0x0100, 'WatchCache', 'evicted %{public}s', victim.key);
    }
  }

  clear(): void {
    for (let i = 0; i < this.entries.length; i++) {
      try {
        if (this.entries[i].pixel !== undefined) {
          (this.entries[i].pixel as image.PixelMap).release();
        }
      } catch (e) {
      }
    }
    this.entries = [];
  }
}

class TextEntry {
  key: string = '';
  text: string = '';
  lastUsed: number = 0;
}

const MAX_TEXTS: number = 3;
const MAX_TEXT_BYTES: number = 6 * 1024 * 1024;

/** Decoded text for the reader, so reopening a file does not re-read and re-decode. */
export class TextCache {
  private static shared: TextCache | null = null;
  private entries: TextEntry[] = [];

  static instance(): TextCache {
    if (TextCache.shared === null) {
      TextCache.shared = new TextCache();
    }
    return TextCache.shared;
  }

  get(key: string): string | undefined {
    for (let i = 0; i < this.entries.length; i++) {
      if (this.entries[i].key === key) {
        this.entries[i].lastUsed = Date.now();
        const e: TextEntry = this.entries.splice(i, 1)[0];
        this.entries.push(e);
        return e.text;
      }
    }
    return undefined;
  }

  put(key: string, text: string): void {
    for (let i = 0; i < this.entries.length; i++) {
      if (this.entries[i].key === key) {
        return;
      }
    }
    const e: TextEntry = new TextEntry();
    e.key = key;
    e.text = text;
    e.lastUsed = Date.now();
    this.entries.push(e);
    let bytes: number = 0;
    for (let i = 0; i < this.entries.length; i++) {
      bytes += this.entries[i].text.length * 2;
    }
    while (this.entries.length > 1 && (this.entries.length > MAX_TEXTS || bytes > MAX_TEXT_BYTES)) {
      const victim: TextEntry = this.entries.shift() as TextEntry;
      bytes -= victim.text.length * 2;
    }
  }
}
