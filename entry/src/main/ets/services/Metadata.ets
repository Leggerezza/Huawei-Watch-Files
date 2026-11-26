/**
 * File type / media metadata layer.
 *
 * Three separate concepts, deliberately kept apart:
 *   1. what the file *is*      - extension, magic bytes, container, codec
 *   2. what bucket it belongs to - Images/Videos/... for browsing
 *   3. whether this device can actually play it - a *policy* derived from
 *      `watch-decode-capability-report.md`, not a runtime probe.
 *
 * Point 3 is static knowledge from a measured capability report. Nothing here
 * calls a decoder. A later stage can replace `playability()` with a real
 * `AVMetadataExtractor`/`OH_AVCodec_GetCapability` probe; until then the field
 * is named `policyPlayable` so nobody mistakes it for a measurement.
 */

export enum MediaKind {
  IMAGE = 0,
  AUDIO = 1,
  VIDEO = 2,
  TEXT = 3,
  ARCHIVE = 4,
  DOCUMENT = 5,
  OTHER = 6
}

export enum Playability {
  /** The device has a verified decoder for this. */
  SYSTEM = 0,
  /** Plausible but unverified on this exact device (e.g. HEIC stills). */
  MAYBE = 1,
  /** The device has no decoder; store only. */
  UNSUPPORTED = 2,
  UNKNOWN = 3
}

export class MediaInfo {
  name: string = '';
  mime: string = 'application/octet-stream';
  kind: MediaKind = MediaKind.OTHER;
  /** mp4 / mkv / avi / mp3 / flac / jpeg ... empty when unknown */
  container: string = '';
  /** avc / hevc / vp9 / av1 / mpeg / flac ... empty when unknown */
  codec: string = '';
  policyPlayable: Playability = Playability.UNKNOWN;
  reason: string = '';
  size: number = 0;
}

const MIME: Map<string, string> = new Map<string, string>();

function initMime(): void {
  const pairs: string[][] = [
    ['jpg', 'image/jpeg'], ['jpeg', 'image/jpeg'], ['png', 'image/png'], ['gif', 'image/gif'],
    ['webp', 'image/webp'], ['bmp', 'image/bmp'], ['svg', 'image/svg+xml'], ['heic', 'image/heic'],
    ['heif', 'image/heif'], ['tif', 'image/tiff'], ['tiff', 'image/tiff'],
    ['mp4', 'video/mp4'], ['m4v', 'video/mp4'], ['mov', 'video/quicktime'], ['mkv', 'video/x-matroska'],
    ['webm', 'video/webm'], ['avi', 'video/x-msvideo'], ['3gp', 'video/3gpp'], ['ts', 'video/mp2t'],
    ['mp3', 'audio/mpeg'], ['flac', 'audio/flac'], ['wav', 'audio/wav'], ['m4a', 'audio/mp4'],
    ['aac', 'audio/aac'], ['ogg', 'audio/ogg'], ['opus', 'audio/opus'], ['amr', 'audio/amr'],
    ['alac', 'audio/alac'], ['wma', 'audio/x-ms-wma'], ['ape', 'audio/ape'],
    ['txt', 'text/plain; charset=utf-8'], ['md', 'text/plain; charset=utf-8'], ['csv', 'text/csv; charset=utf-8'],
    ['json', 'application/json'], ['html', 'text/html; charset=utf-8'], ['htm', 'text/html; charset=utf-8'],
    ['xml', 'application/xml'], ['pdf', 'application/pdf'], ['epub', 'application/epub+zip'],
    ['zip', 'application/zip'], ['rar', 'application/vnd.rar'], ['7z', 'application/x-7z-compressed'],
    ['gz', 'application/gzip'], ['tar', 'application/x-tar'], ['apk', 'application/vnd.android.package-archive'],
    ['hap', 'application/octet-stream'], ['bin', 'application/octet-stream']
  ];
  for (let i = 0; i < pairs.length; i++) {
    MIME.set(pairs[i][0], pairs[i][1]);
  }
}

export function extensionOf(name: string): string {
  const dot: number = name.lastIndexOf('.');
  if (dot <= 0 || dot === name.length - 1) {
    return '';
  }
  return name.substring(dot + 1).toLowerCase();
}

export function mimeOf(name: string): string {
  if (MIME.size === 0) {
    initMime();
  }
  const ext: string = extensionOf(name);
  if (ext.length === 0) {
    return 'application/octet-stream';
  }
  const m: string | undefined = MIME.get(ext);
  return m === undefined ? 'application/octet-stream' : m;
}

export function kindFromMime(mime: string): MediaKind {
  if (mime.startsWith('image/')) {
    return MediaKind.IMAGE;
  }
  if (mime.startsWith('audio/')) {
    return MediaKind.AUDIO;
  }
  if (mime.startsWith('video/')) {
    return MediaKind.VIDEO;
  }
  if (mime.startsWith('text/') || mime === 'application/json' || mime === 'application/xml') {
    return MediaKind.TEXT;
  }
  if (mime.indexOf('zip') >= 0 || mime.indexOf('rar') >= 0 || mime.indexOf('7z') >= 0 ||
    mime.indexOf('gzip') >= 0 || mime.indexOf('tar') >= 0 || mime === 'application/epub+zip') {
    return MediaKind.ARCHIVE;
  }
  if (mime === 'application/pdf') {
    return MediaKind.DOCUMENT;
  }
  return MediaKind.OTHER;
}

function ascii(data: number[], start: number, len: number): string {
  let s: string = '';
  for (let i = start; i < start + len && i < data.length; i++) {
    s = s + String.fromCharCode(data[i]);
  }
  return s;
}

/** Finds a byte pattern in the head buffer; returns -1 when absent. */
function findIn(data: number[], pattern: string, from: number, to: number): number {
  const n: number = pattern.length;
  const limit: number = to < 0 ? data.length : to;
  for (let i = from; i + n <= limit; i++) {
    let hit: boolean = true;
    for (let k = 0; k < n; k++) {
      if (data[i + k] !== pattern.charCodeAt(k)) {
        hit = false;
        break;
      }
    }
    if (hit) {
      return i;
    }
  }
  return -1;
}

function startsWithBytes(data: number[], expect: number[]): boolean {
  if (data.length < expect.length) {
    return false;
  }
  for (let i = 0; i < expect.length; i++) {
    if (data[i] !== expect[i]) {
      return false;
    }
  }
  return true;
}

/**
 * Policy table. Every entry traces back to the measured capability report:
 * one H.264 hardware video decoder, ten software audio decoders, ImageSource
 * for the common still formats, nothing for HEVC/VP8/VP9/AV1/MJPEG/TIFF.
 */
function policyFor(kind: MediaKind, codec: string, container: string): Playability {
  if (kind === MediaKind.IMAGE) {
    if (container === 'tiff') {
      return Playability.UNSUPPORTED;
    }
    if (container === 'heic') {
      return Playability.MAYBE;
    }
    return Playability.SYSTEM;
  }
  if (kind === MediaKind.VIDEO) {
    if (codec === 'avc') {
      return Playability.SYSTEM;
    }
    if (codec === 'hevc' || codec === 'vp8' || codec === 'vp9' || codec === 'av1' ||
      codec === 'mjpeg' || codec === 'mpeg2' || codec === 'mpeg4p2') {
      return Playability.UNSUPPORTED;
    }
    return Playability.MAYBE;
  }
  if (kind === MediaKind.AUDIO) {
    if (codec === 'mpeg' || codec === 'aac' || codec === 'flac' || codec === 'vorbis' ||
      codec === 'opus' || codec === 'pcm' || codec === 'amr-nb' || codec === 'amr-wb' ||
      codec === 'alac') {
      return Playability.SYSTEM;
    }
    if (codec === 'wma' || codec === 'ape') {
      return Playability.UNSUPPORTED;
    }
    return Playability.MAYBE;
  }
  return Playability.UNKNOWN;
}

/**
 * Inspects a file. Reads a head buffer only; never decodes.
 * @param readHead callback returning the first N bytes of the real path
 */
export function inspect(name: string, size: number, readHead: (count: number) => number[]): MediaInfo {
  const info: MediaInfo = new MediaInfo();
  info.name = name;
  info.size = size;
  info.mime = mimeOf(name);
  info.kind = kindFromMime(info.mime);

  const head: number[] = readHead(65536);
  if (head.length >= 4) {
    // ISO BMFF: ftyp at offset 4
    if (head.length >= 12 && ascii(head, 4, 4) === 'ftyp') {
      const brand: string = ascii(head, 8, 4);
      info.container = (brand === 'qt  ') ? 'mov' : (brand === 'heic' || brand === 'heix' || brand === 'mif1') ? 'heic' : 'mp4';
      if (info.kind === MediaKind.IMAGE) {
        info.container = 'heic';
      } else {
        info.kind = MediaKind.VIDEO;
        info.mime = mimeOf(name).startsWith('video/') ? mimeOf(name) : 'video/mp4';
      }
      if (findIn(head, 'avc1', 0, 200000) >= 0 || findIn(head, 'avcC', 0, 200000) >= 0) {
        info.codec = 'avc';
      } else if (findIn(head, 'hvc1', 0, 200000) >= 0 || findIn(head, 'hev1', 0, 200000) >= 0) {
        info.codec = 'hevc';
      } else if (findIn(head, 'vp09', 0, 200000) >= 0) {
        info.codec = 'vp9';
      } else if (findIn(head, 'av01', 0, 200000) >= 0) {
        info.codec = 'av1';
      } else if (findIn(head, 'mp4v', 0, 200000) >= 0) {
        info.codec = 'mpeg4p2';
      }
    } else if (head[0] === 0x1A && head[1] === 0x45 && head[2] === 0xDF && head[3] === 0xA3) {
      info.container = 'mkv';
      info.kind = MediaKind.VIDEO;
      info.mime = 'video/x-matroska';
      if (findIn(head, 'V_MPEG4/ISO/AVC', 0, -1) >= 0) {
        info.codec = 'avc';
      } else if (findIn(head, 'V_MPEGH/ISO/HEVC', 0, -1) >= 0) {
        info.codec = 'hevc';
      } else if (findIn(head, 'V_VP9', 0, -1) >= 0) {
        info.codec = 'vp9';
      } else if (findIn(head, 'V_VP8', 0, -1) >= 0) {
        info.codec = 'vp8';
      } else if (findIn(head, 'V_AV1', 0, -1) >= 0) {
        info.codec = 'av1';
      }
    } else if (head[0] === 0x52 && head[1] === 0x49 && head[2] === 0x46 && head[3] === 0x46) {
      const riff: string = ascii(head, 8, 4);
      if (riff === 'AVI ') {
        info.container = 'avi';
        info.kind = MediaKind.VIDEO;
        info.mime = 'video/x-msvideo';
        if (findIn(head, 'MJPG', 0, -1) >= 0) {
          info.codec = 'mjpeg';
        } else if (findIn(head, 'H264', 0, -1) >= 0 || findIn(head, 'X264', 0, -1) >= 0) {
          info.codec = 'avc';
        }
      } else if (riff === 'WAVE') {
        info.container = 'wav';
        info.kind = MediaKind.AUDIO;
        info.codec = 'pcm';
      } else if (riff === 'WEBP') {
        info.container = 'webp';
        info.kind = MediaKind.IMAGE;
      }
    } else if (startsWithBytes(head, [0xFF, 0xD8, 0xFF])) {
      info.container = 'jpeg';
      info.kind = MediaKind.IMAGE;
    } else if (startsWithBytes(head, [0x89, 0x50, 0x4E, 0x47])) {
      info.container = 'png';
      info.kind = MediaKind.IMAGE;
    } else if (ascii(head, 0, 3) === 'GIF') {
      info.container = 'gif';
      info.kind = MediaKind.IMAGE;
    } else if (startsWithBytes(head, [0x49, 0x49, 0x2A, 0x00]) || startsWithBytes(head, [0x4D, 0x4D, 0x00, 0x2A])) {
      info.container = 'tiff';
      info.kind = MediaKind.IMAGE;
      info.mime = 'image/tiff';
    } else if (startsWithBytes(head, [0x25, 0x50, 0x44, 0x46])) {
      info.container = 'pdf';
      info.kind = MediaKind.DOCUMENT;
      info.mime = 'application/pdf';
    } else if (ascii(head, 0, 4) === 'fLaC') {
      info.container = 'flac';
      info.kind = MediaKind.AUDIO;
      info.codec = 'flac';
    } else if (ascii(head, 0, 4) === 'OggS') {
      info.container = 'ogg';
      info.kind = MediaKind.AUDIO;
      info.codec = findIn(head, 'OpusHead', 0, 512) >= 0 ? 'opus' : 'vorbis';
      info.mime = 'audio/ogg';
    } else if (ascii(head, 0, 3) === 'ID3' || (head[0] === 0xFF && (head[1] === 0xFB || head[1] === 0xF3))) {
      info.container = 'mp3';
      info.kind = MediaKind.AUDIO;
      info.codec = 'mpeg';
      info.mime = 'audio/mpeg';
    } else if (ascii(head, 0, 6) === '#!AMR\n') {
      info.container = 'amr';
      info.kind = MediaKind.AUDIO;
      info.codec = 'amr-nb';
    } else if (startsWithBytes(head, [0x50, 0x4B, 0x03, 0x04])) {
      info.container = info.mime === 'application/epub+zip' ? 'epub' : 'zip';
    }
  }

  if (info.codec.length === 0) {
    // Fall back to the extension's usual codec when the head said nothing.
    const ext: string = extensionOf(name);
    if (ext === 'mp3') {
      info.codec = 'mpeg';
      info.container = info.container.length > 0 ? info.container : 'mp3';
    } else if (ext === 'm4a' || ext === 'aac') {
      info.codec = 'aac';
      info.container = info.container.length > 0 ? info.container : 'm4a';
    } else if (ext === 'wma') {
      info.codec = 'wma';
    } else if (ext === 'ape') {
      info.codec = 'ape';
    } else if (ext === 'alac') {
      info.codec = 'alac';
    } else if (ext === 'mp4' || ext === 'mov' || ext === 'm4v') {
      info.container = info.container.length > 0 ? info.container : ext;
    } else if (ext === 'mkv' || ext === 'webm') {
      info.container = info.container.length > 0 ? info.container : ext;
    }
  }

  info.policyPlayable = policyFor(info.kind, info.codec, info.container);
  info.reason = describe(info);
  return info;
}

function describe(info: MediaInfo): string {
  if (info.kind === MediaKind.VIDEO) {
    if (info.codec === 'avc') {
      return 'H.264 hardware decoder verified on this device';
    }
    if (info.codec.length > 0) {
      return `no system decoder for ${info.codec}; store only`;
    }
    return 'video codec not identified';
  }
  if (info.kind === MediaKind.AUDIO) {
    return info.policyPlayable === Playability.SYSTEM
      ? `${info.codec} software decoder verified`
      : `no verified decoder for ${info.codec.length > 0 ? info.codec : 'this format'}`;
  }
  if (info.kind === MediaKind.IMAGE) {
    if (info.policyPlayable === Playability.SYSTEM) {
      return 'ImageSource verified';
    }
    return info.container === 'tiff' ? 'TIFF decode failed in the probe' : 'unverified on this device';
  }
  return '';
}
