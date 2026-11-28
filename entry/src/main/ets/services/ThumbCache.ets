import { image } from '@kit.ImageKit';

/**
 * Tiny LRU for list thumbnails.
 *
 * Row thumbnails are 96 px square (48 KiB each), so a few dozen cost almost
 * nothing, and scrolling back through a folder does not decode again. Like
 * PixelCache this owns the bitmaps: callers borrow and never release.
 */
class ThumbEntry {
  key: string = '';
  pixel: image.PixelMap | undefined = undefined;
  lastUsed: number = 0;
}

const MAX_THUMBS: number = 64;

export class ThumbCache {
  private static shared: ThumbCache | null = null;
  private entries: ThumbEntry[] = [];

  static instance(): ThumbCache {
    if (ThumbCache.shared === null) {
      ThumbCache.shared = new ThumbCache();
    }
    return ThumbCache.shared;
  }

  get(key: string): image.PixelMap | undefined {
    for (let i = 0; i < this.entries.length; i++) {
      if (this.entries[i].key === key) {
        const e: ThumbEntry = this.entries.splice(i, 1)[0];
        e.lastUsed = Date.now();
        this.entries.push(e);
        return e.pixel;
      }
    }
    return undefined;
  }

  put(key: string, pixel: image.PixelMap): void {
    for (let i = 0; i < this.entries.length; i++) {
      if (this.entries[i].key === key) {
        return;
      }
    }
    const e: ThumbEntry = new ThumbEntry();
    e.key = key;
    e.pixel = pixel;
    e.lastUsed = Date.now();
    this.entries.push(e);
    while (this.entries.length > MAX_THUMBS) {
      const victim: ThumbEntry = this.entries.shift() as ThumbEntry;
      try {
        if (victim.pixel !== undefined) {
          victim.pixel.release();
        }
      } catch (err) {
      }
    }
  }

  clear(): void {
    for (let i = 0; i < this.entries.length; i++) {
      try {
        if (this.entries[i].pixel !== undefined) {
          (this.entries[i].pixel as image.PixelMap).release();
        }
      } catch (err) {
      }
    }
    this.entries = [];
  }
}
