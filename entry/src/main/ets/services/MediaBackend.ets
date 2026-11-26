import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * Media backend interface.
 *
 * Stage 1 defines the seam and implements exactly one thing for real: still
 * image dimensions via the system `ImageSource`, which the capability report
 * verified for JPEG/PNG/GIF/WebP/BMP/SVG. Audio and video metadata belong to
 * stage 8 and are declared here so callers can be written against the shape
 * without pretending they work.
 */

export class ImageMeta {
  width: number = 0;
  height: number = 0;
  mime: string = '';
  ok: boolean = false;
  error: string = '';
}

export class MediaMetadata {
  durationMs: number = -1;
  videoWidth: number = -1;
  videoHeight: number = -1;
  mime: string = '';
  ok: boolean = false;
  error: string = '';
}

/**
 * Reads image dimensions. Does not keep the PixelMap, so this is cheap enough
 * for a detail view; it still decodes the header, so do not call it per row of
 * a long list.
 */
export async function imageInfo(realPath: string): Promise<ImageMeta> {
  const out: ImageMeta = new ImageMeta();
  let src: image.ImageSource | null = null;
  try {
    src = image.createImageSource(realPath);
    if (src === null || src === undefined) {
      out.error = 'createImageSource returned null';
      return out;
    }
    const info: image.ImageInfo = await src.getImageInfo();
    out.width = info.size.width;
    out.height = info.size.height;
    out.mime = info.mimeType;
    out.ok = out.width > 0 && out.height > 0;
  } catch (e) {
    const be: BusinessError = e as BusinessError;
    out.error = be !== undefined && be.code !== undefined ? `code=${be.code} ${be.message}` : `${e}`;
    hilog.warn(0x0100, 'WatchMedia', 'imageInfo failed: %{public}s', out.error);
  } finally {
    if (src !== null) {
      try {
        await src.release();
      } catch (e) {
      }
    }
  }
  return out;
}

/**
 * Container/codec metadata for audio and video.
 * NOT IMPLEMENTED: stage 8. Returns an explicit error instead of a fake result
 * so callers and tests can tell the difference between "no metadata" and
 * "cannot extract yet".
 */
export async function mediaMetadata(realPath: string): Promise<MediaMetadata> {
  const out: MediaMetadata = new MediaMetadata();
  out.error = 'not implemented until stage 8 (AVMetadataExtractor)';
  return out;
}
