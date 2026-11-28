import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { acquireScreen, releaseScreen } from '../services/ScreenKeeper';
import { PixelCache } from '../services/MediaCache';

const ZOOM_STEPS: number[] = [1, 1.25, 1.5, 2, 2.5, 3, 4];
const SCREEN_VP: number = 233;

/**
 * Full-screen image viewer with button zoom.
 *
 * The reference UI for this put +/- on the screen edges, which is where the
 * prev/next tap zones used to be - so navigation moved to a bottom strip and
 * the edges are now zoom. Buttons are the only reliable zoom on this device:
 * the emulator cannot synthesise a pinch, and a watch with a crown is easier to
 * drive with discrete steps than with a two-finger gesture.
 *
 * Decoded bitmaps are cached by PixelCache; the viewer borrows them and never
 * releases, otherwise the cache would hand out freed bitmaps.
 */
@Component
export struct ImageViewer {
  @Prop @Watch('onRealPathChanged') realPath: string;
  @Prop name: string;
  @Prop fileSize: number;
  @Prop ordinal: number;
  @Prop total: number;
  /** neighbours, pre-decoded so the next step is instant when possible */
  @Prop prevReal: string;
  @Prop nextReal: string;
  onClose: () => void = () => {
  };
  onPrev: () => void = () => {
  };
  onNext: () => void = () => {
  };

  @State pixel: image.PixelMap | undefined = undefined;
  @State error: string = '';
  @State info: string = '';
  @State zoomIndex: number = 0;
  @State dx: number = 0;
  @State dy: number = 0;
  @State showChrome: boolean = true;
  @State cacheNote: string = '';
  private crownAccum: number = 0;
  private imageW: number = 0;
  private imageH: number = 0;

  aboutToAppear(): void {
    const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    acquireScreen(ctx);
    this.load();
  }

  aboutToDisappear(): void {
    releaseScreen();
    // The cache owns the bitmap; just drop the reference.
    this.pixel = undefined;
  }

  onRealPathChanged(): void {
    this.zoomIndex = 0;
    this.dx = 0;
    this.dy = 0;
    this.load();
  }

  private cacheKey(path: string): string {
    return `${path}|${this.fileSize}`;
  }

  private load(): void {
    this.error = '';
    this.info = '';
    this.pixel = undefined;
    const key: string = this.cacheKey(this.realPath);
    const hit: image.PixelMap | undefined = PixelCache.instance().get(key);
    hilog.info(0x0100, 'WatchViewer', 'load %{public}s hit=%{public}s', key, hit !== undefined ? 'yes' : 'no');
    if (hit !== undefined) {
      this.pixel = hit;
      this.cacheNote = 'cache';
      this.info = '缓存命中';
      return;
    }
    this.cacheNote = '';
    this.decode(this.realPath, key, true);
    // Warm the neighbours without blocking the current frame.
    if (this.nextReal.length > 0) {
      this.decode(this.nextReal, this.cacheKey(this.nextReal), false);
    }
    if (this.prevReal.length > 0) {
      this.decode(this.prevReal, this.cacheKey(this.prevReal), false);
    }
  }

  private async decode(path: string, key: string, show: boolean): Promise<void> {
    let src: image.ImageSource | null = null;
    try {
      src = image.createImageSource(path);
      const meta: image.ImageInfo = await src.getImageInfo();
      const w: number = meta.size.width;
      const h: number = meta.size.height;
      // Cap the decoded bitmap to the display: a 12 MP photo is never decoded
      // at full size on a 466 px screen.
      const maxEdge: number = 466;
      let tw: number = w;
      let th: number = h;
      if (w > maxEdge || h > maxEdge) {
        const ratio: number = Math.min(maxEdge / w, maxEdge / h);
        tw = Math.max(1, Math.floor(w * ratio));
        th = Math.max(1, Math.floor(h * ratio));
      }
      const opts: image.DecodingOptions = {
        desiredSize: { width: tw, height: th },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      };
      const pm: image.PixelMap = await src.createPixelMap(opts);
      PixelCache.instance().put(key, pm, tw * th * 4);
      if (show) {
        this.pixel = pm;
        this.imageW = w;
        this.imageH = h;
        this.info = `${w}x${h}  ${meta.mimeType}`;
      }
    } catch (e) {
      if (!show) {
        return;
      }
      const be: BusinessError = e as BusinessError;
      const detail: string = be !== undefined && be !== null && be.message !== undefined
        ? `${be.code} ${be.message}` : `${e}`;
      this.error = `无法解码 (${detail})`;
    } finally {
      if (src !== null) {
        try {
          await src.release();
        } catch (e) {
        }
      }
    }
  }

  private zoomLabel(): string {
    return `${ZOOM_STEPS[this.zoomIndex].toFixed(2).replace(/0$/, '')}x`;
  }

  private clampPan(): void {
    const scale: number = ZOOM_STEPS[this.zoomIndex];
    const limitX: number = ((scale - 1) * SCREEN_VP) / 2;
    const limitY: number = ((scale - 1) * SCREEN_VP) / 2;
    this.dx = Math.min(limitX, Math.max(-limitX, this.dx));
    this.dy = Math.min(limitY, Math.max(-limitY, this.dy));
  }

  private zoom(delta: number): void {
    const next: number = Math.min(ZOOM_STEPS.length - 1, Math.max(0, this.zoomIndex + delta));
    if (next === this.zoomIndex) {
      return;
    }
    this.zoomIndex = next;
    if (next === 0) {
      this.dx = 0;
      this.dy = 0;
    }
    this.clampPan();
  }

  private resetZoom(): void {
    this.zoomIndex = 0;
    this.dx = 0;
    this.dy = 0;
  }

  private onCrown(event: CrownEvent): void {
    this.crownAccum += event.degree;
    if (this.crownAccum > 12) {
      this.crownAccum = 0;
      this.onNext();
    } else if (this.crownAccum < -12) {
      this.crownAccum = 0;
      this.onPrev();
    }
  }

  @Builder
  roundButton(label: string, size: number, action: () => void) {
    Text(label)
      .fontSize(14)
      .fontColor('#FFFFFF')
      .width(size)
      .height(size)
      .textAlign(TextAlign.Center)
      .backgroundColor('#1F2937E6')
      .borderRadius(size / 2)
      .border({ width: 1, color: '#374151' })
      .onClick(() => {
        action();
      })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#000000')
        .onClick(() => {
          this.showChrome = !this.showChrome;
        })

      if (this.pixel !== undefined) {
        Image(this.pixel)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
          .scale({ x: ZOOM_STEPS[this.zoomIndex], y: ZOOM_STEPS[this.zoomIndex] })
          .translate({ x: this.dx, y: this.dy })
          .hitTestBehavior(HitTestMode.Transparent)
          .gesture(
            PanGesture({ fingers: 1, distance: 8 })
              .onActionUpdate((event: GestureEvent) => {
                if (this.zoomIndex > 0) {
                  this.dx = this.dx + event.offsetX;
                  this.dy = this.dy + event.offsetY;
                  this.clampPan();
                }
              })
          )
      }

      if (this.error.length > 0) {
        Column({ space: 6 }) {
          Text('🖼')
            .fontSize(24)
          Text(this.error)
            .fontSize(9)
            .fontColor('#FCA5A5')
            .textAlign(TextAlign.Center)
            .padding({ left: 24, right: 24 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }

      if (this.showChrome) {
        Row() {
          Text('‹')
            .fontSize(16)
            .fontColor('#FFFFFF')
            .width(26)
            .onClick(() => {
              this.onClose();
            })
          Text(this.name)
            .fontSize(9)
            .fontColor('#E5E7EB')
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`${this.ordinal}/${this.total}`)
            .fontSize(8)
            .fontColor('#9CA3AF')
        }
        .width('100%')
        .height(24)
        .margin({ top: 28 })
        .padding({ left: 42, right: 42 })

        // Zoom on the edges, exactly where the reference UI put it.
        Column() {
          this.roundButton('−', 26, () => {
            this.zoom(-1);
          })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 2 })
        .hitTestBehavior(HitTestMode.Transparent)

        Column() {
          this.roundButton('+', 26, () => {
            this.zoom(1);
          })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.End)
        .padding({ right: 2 })
        .hitTestBehavior(HitTestMode.Transparent)

        // Bottom strip: prev, zoom badge (tap to reset), next.
        Column() {
          Row({ space: 8 }) {
            Text('‹')
              .fontSize(15)
              .fontColor('#FFFFFF')
              .width(26)
              .height(22)
              .textAlign(TextAlign.Center)
              .backgroundColor('#1F2937E6')
              .borderRadius(11)
              .onClick(() => {
                this.onPrev();
              })
            Text(this.zoomLabel())
              .fontSize(9)
              .fontColor(this.zoomIndex > 0 ? '#FDE68A' : '#9CA3AF')
              .height(22)
              .padding({ left: 8, right: 8 })
              .backgroundColor('#1F2937E6')
              .borderRadius(11)
              .onClick(() => {
                this.resetZoom();
              })
            Text('›')
              .fontSize(15)
              .fontColor('#FFFFFF')
              .width(26)
              .height(22)
              .textAlign(TextAlign.Center)
              .backgroundColor('#1F2937E6')
              .borderRadius(11)
              .onClick(() => {
                this.onNext();
              })
          }
          .justifyContent(FlexAlign.Center)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .padding({ bottom: 8 })
        .hitTestBehavior(HitTestMode.Transparent)

        Text(this.info.length > 0 ? `${this.info}${this.cacheNote.length > 0 ? ' · 缓存命中' : ''}` : '')
          .fontSize(8)
          .fontColor('#93C5FD')
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 54 })
          .hitTestBehavior(HitTestMode.Transparent)
      }
    }
    .width('100%')
    .height('100%')
    .focusable(true)
    .defaultFocus(true)
    .focusOnTouch(true)
    .onDigitalCrown((event: CrownEvent) => {
      this.onCrown(event);
    })
  }
}



