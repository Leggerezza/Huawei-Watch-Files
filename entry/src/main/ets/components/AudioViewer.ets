import { common } from '@kit.AbilityKit';
import { acquireScreen, releaseScreen } from '../services/ScreenKeeper';
import { AudioPlayer, fmtClock } from '../services/AudioPlayer';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * Audio player screen: previous / play-pause / next, a position bar and the
 * crown for seeking. Formats are whatever AVPlayer decodes; the file list only
 * offers MediaKind.AUDIO entries, so an unplayable container shows the error
 * state instead of pretending to play.
 */
@Component
export struct AudioViewer {
  @Prop @Watch('onPathChanged') realPath: string;
  @Prop name: string;
  @Prop fileSize: number;
  @Prop ordinal: number;
  @Prop total: number;
  onClose: () => void = () => {
  };
  onPrev: () => void = () => {
  };
  onNext: () => void = () => {
  };

  @State state: string = 'idle';
  @State positionMs: number = 0;
  @State durationMs: number = 0;
  @State error: string = '';
  private player: AudioPlayer = new AudioPlayer();
  private crownAccum: number = 0;

  aboutToAppear(): void {
    hilog.info(0x0100, 'WatchAudio', 'viewer appear %{public}s', this.realPath);
    const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    acquireScreen(ctx);
    this.player.onState = (state: string) => {
      this.state = state;
    };
    this.player.onTime = (position: number, duration: number) => {
      this.positionMs = position;
      this.durationMs = duration;
    };
    this.player.onError = (message: string) => {
      this.error = `无法播放 (${message})`;
      this.state = 'error';
    };
    this.player.onComplete = () => {
      this.onNext();
    };
    this.open();
    setTimeout(() => {
      try {
        this.getUIContext().getFocusController().requestFocus('audio-root');
      } catch (e) {
      }
    }, 200);
  }

  aboutToDisappear(): void {
    this.player.release();
    releaseScreen();
  }

  onPathChanged(): void {
    this.positionMs = 0;
    this.durationMs = 0;
    this.error = '';
    this.open();
  }

  private open(): void {
    if (this.realPath.length === 0) {
      return;
    }
    this.player.open(this.realPath, this.fileSize);
  }

  private pct(): number {
    if (this.durationMs <= 0) {
      return 0;
    }
    return Math.min(100, Math.max(0, (this.positionMs * 100) / this.durationMs));
  }

  private onCrown(event: CrownEvent): void {
    this.crownAccum += event.degree;
    if (this.crownAccum > 8) {
      this.crownAccum = 0;
      this.player.seekMs(this.positionMs + 10000);
    } else if (this.crownAccum < -8) {
      this.crownAccum = 0;
      this.player.seekMs(this.positionMs - 10000);
    }
  }

  build() {
    Column({ space: 2 }) {
      Row({ space: 4 }) {
        Text('‹')
          .fontSize(16)
          .fontColor('#FFFFFF')
          .width(24)
          .onClick(() => {
            this.onClose();
          })
        Text(this.name)
          .fontSize(8)
          .fontColor('#9CA3AF')
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${this.ordinal}/${this.total}`)
          .fontSize(8)
          .fontColor('#9CA3AF')
      }
      .width('100%')
      .padding({ left: 40, right: 40, top: 26 })

      Text('🎵')
        .fontSize(30)
        .margin({ top: 8 })

      Text(this.state === 'playing' ? '播放中' : (this.state === 'paused' ? '已暂停' : (this.state === 'completed' ? '已结束' : '准备中')))
        .fontSize(8)
        .fontColor('#93C5FD')

      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width('100%')
          .height(4)
          .backgroundColor('#1F2937')
          .borderRadius(2)
        Row()
          .width(`${this.pct()}%`)
          .height(4)
          .backgroundColor('#4ADE80')
          .borderRadius(2)
      }
      .width('70%')
      .height(4)
      .margin({ top: 6, bottom: 2 })

      Text(`${fmtClock(this.positionMs)} / ${fmtClock(this.durationMs)}`)
        .fontSize(7)
        .fontColor('#6B7280')

      if (this.error.length > 0) {
        Text(this.error)
          .fontSize(8)
          .fontColor('#FCA5A5')
          .maxLines(2)
          .padding({ left: 20, right: 20 })
      }

      Row({ space: 10 }) {
        Text('⏮')
          .fontSize(14)
          .fontColor('#E5E7EB')
          .width(30)
          .height(30)
          .textAlign(TextAlign.Center)
          .backgroundColor('#1B2130')
          .borderRadius(15)
          .onClick(() => {
            this.onPrev();
          })
        Text(this.state === 'playing' ? '⏸' : '▶')
          .fontSize(16)
          .fontColor('#0B0E14')
          .width(38)
          .height(38)
          .textAlign(TextAlign.Center)
          .backgroundColor('#4ADE80')
          .borderRadius(19)
          .onClick(() => {
            this.player.toggle();
          })
        Text('⏭')
          .fontSize(14)
          .fontColor('#E5E7EB')
          .width(30)
          .height(30)
          .textAlign(TextAlign.Center)
          .backgroundColor('#1B2130')
          .borderRadius(15)
          .onClick(() => {
            this.onNext();
          })
      }
      .margin({ top: 6 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#0B0E14')
    .id('audio-root')
    .focusable(true)
    .defaultFocus(true)
    .focusOnTouch(true)
    .onDigitalCrown((event: CrownEvent) => {
      this.onCrown(event);
    })
  }
}

