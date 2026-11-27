import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { acquireScreen, releaseScreen } from '../services/ScreenKeeper';

/**
 * Full-screen image viewer.
 *
 * Decodes with `ImageSource` at a `desiredSize` capped to the display, so a
 * 12 MP photo never materialises a 12 MP PixelMap on a 466 px screen. Zoom and
 * pan are a transform on the decoded bitmap; previous/next come from the crown
 * or from tapping the left/right third, which is what a round screen leaves
 * reachable.
 */
@Component
export struct ImageViewer {
  @Prop @Watch('onRealPathChanged') realPath: string;
  @Prop name: string;
  @Prop fileSize: number;
  /** ordinal of this image inside the current list, 1-based */
  @Prop ordinal: number;
  @Prop total: number;
  onClose: () => void = () => {
  };
  onPrev: () => void = () => {
  };
  onNext: () => void = () => {
  };

  @State pixel: image.PixelMap | undefined = undefined;
  @State error: string = '';
  @State info: string = '';
  @State scaleValue: number = 1;
  @State dx: number = 0;
  @State dy: number = 0;
  @State showInfo: boolean = true;
  private crownAccum: number = 0;

  aboutToAppear(): void {
    const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    acquireScreen(ctx);
    this.load();
  }

  aboutToDisappear(): void {
    releaseScreen();
    this.releasePixel();
  }

  /** The same viewer instance is reused for prev/next; reload on path change. */
  onRealPathChanged(): void {
    this.load();
  }

  private releasePixel(): void {
    const p: image.PixelMap | undefined = this.pixel;
    this.pixel = undefined;
    if (p !== undefined) {
      p.release();
    }
  }

  private async load(): Promise<void> {
    // Clear the previous bitmap first: if this file fails to decode the viewer
    // must show the error, not the last image that happened to work.
    this.releasePixel();
    this.error = '';
    this.info = '';
    this.scaleValue = 1;
    this.dx = 0;
    this.dy = 0;
    let src: image.ImageSource | null = null;
    try {
      src = image.createImageSource(this.realPath);
      const meta: image.ImageInfo = await src.getImageInfo();
      const w: number = meta.size.width;
      const h: number = meta.size.height;
      // Cap the decoded bitmap to the screen: the viewer never needs more.
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
      this.pixel = pm;
      this.info = `${w}x${h}  ${meta.mimeType}`;
    } catch (e) {
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

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#000000')
        .onClick((event: ClickEvent) => {
          // event.x is in vp; the canvas is 233 vp wide, not 466.
          if (event.x < 78) {
            this.onPrev();
          } else if (event.x > 155) {
            this.onNext();
          } else {
            this.showInfo = !this.showInfo;
          }
        })

      if (this.pixel !== undefined) {
        Image(this.pixel)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
          .scale({ x: this.scaleValue, y: this.scaleValue })
          .translate({ x: this.dx, y: this.dy })
          .hitTestBehavior(HitTestMode.Transparent)
          .gesture(
            GestureGroup(GestureMode.Parallel,
              PinchGesture({ fingers: 2 })
                .onActionUpdate((event: GestureEvent) => {
                  this.scaleValue = Math.min(4, Math.max(1, event.scale));
                }),
              PanGesture({ fingers: 1, distance: 12 })
                .onActionUpdate((event: GestureEvent) => {
                  if (this.scaleValue > 1) {
                    this.dx = this.dx + event.offsetX;
                    this.dy = this.dy + event.offsetY;
                  }
                })
            )
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
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }

      if (this.showInfo) {
        Column({ space: 1 }) {
          Row() {
            Text('‹ 关闭')
              .fontSize(10)
              .fontColor('#93C5FD')
              .onClick(() => {
                this.onClose();
              })
            Text('')
              .layoutWeight(1)
            Text(`${this.ordinal}/${this.total}`)
              .fontSize(9)
              .fontColor('#9CA3AF')
          }
          .width('100%')
          Text(this.name)
            .fontSize(9)
            .fontColor('#E5E7EB')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(`${this.info}  ${(this.fileSize / 1024).toFixed(0)} KB`)
            .fontSize(7)
            .fontColor('#6B7280')
            .width('100%')
        }
        .width('100%')
        .padding({ left: 10, right: 10, top: 8 })
        .hitTestBehavior(HitTestMode.Transparent)
      }
    }
    .width('100%')
    .height('100%')
    .onDigitalCrown((event: CrownEvent) => {
      this.onCrown(event);
    })
  }
}

