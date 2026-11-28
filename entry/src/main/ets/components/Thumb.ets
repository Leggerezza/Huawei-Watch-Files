import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ThumbCache } from '../services/ThumbCache';

/**
 * Row thumbnail that decodes only when it scrolls into view.
 *
 * A folder can hold hundreds of photos and the list is built with ForEach, so
 * decoding every row up front would be a burst of `createPixelMap` calls. The
 * visible-area callback gates the decode instead; anything not yet decoded
 * shows the file-type icon, which is also the fallback for undecodable files.
 */
@Component
export struct Thumb {
  @Prop @Watch('onPathChanged') realPath: string;
  @Prop isImage: boolean;
  @Prop icon: string;
  @State pixel: image.PixelMap | undefined = undefined;
  private requested: boolean = false;

  onPathChanged(): void {
    this.pixel = undefined;
    this.requested = false;
  }

  private load(): void {
    if (!this.isImage || this.requested || this.realPath.length === 0) {
      return;
    }
    this.requested = true;
    const hit: image.PixelMap | undefined = ThumbCache.instance().get(this.realPath);
    if (hit !== undefined) {
      this.pixel = hit;
      return;
    }
    let src: image.ImageSource | null = null;
    const path: string = this.realPath;
    try {
      src = image.createImageSource(path);
      src.createPixelMap({
        desiredSize: { width: 96, height: 96 },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      }).then((pm: image.PixelMap) => {
        ThumbCache.instance().put(path, pm);
        this.pixel = pm;
      }).catch((err: Error) => {
        hilog.info(0x0100, 'WatchThumb', 'decode failed %{public}s', `${err.message}`);
      });
    } catch (e) {
      hilog.info(0x0100, 'WatchThumb', 'open failed %{public}s', `${(e as Error).message}`);
    } finally {
      if (src !== null) {
        try {
          src.release();
        } catch (e) {
        }
      }
    }
  }

  build() {
    Stack() {
      if (this.pixel !== undefined) {
        Image(this.pixel)
          .width(20)
          .height(20)
          .objectFit(ImageFit.Cover)
          .borderRadius(4)
      } else {
        Text(this.icon)
          .fontSize(10)
      }
    }
    .width(20)
    .height(20)
    .onVisibleAreaChange([0.0, 0.5], (isVisible: boolean, ratio: number) => {
      if (isVisible) {
        this.load();
      }
    })
  }
}
