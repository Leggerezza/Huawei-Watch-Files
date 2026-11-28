import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { acquireScreen, releaseScreen } from '../services/ScreenKeeper';
import { ReadingState, loadReading, saveReading } from '../services/ReadingProgress';
import { TextCache } from '../services/MediaCache';
import { hilog } from '@kit.PerformanceAnalysisKit';

class PageSlice {
  text: string = '';
  next: number = 0;
}

/**
 * Plain-text reader.
 *
 * Only TXT for now. Reads in bounded chunks, detects UTF-8/UTF-16 BOMs and
 * falls back to GBK, paginates by a computed characters-per-page figure, and
 * turns pages with the crown (or a tap in the top/bottom quarter).
 *
 * No rich text, no images, no EPUB - those are separate stages.
 */
const MAX_BYTES: number = 2 * 1024 * 1024;
const CHUNK: number = 64 * 1024;

@Component
export struct TextReader {
  @Prop realPath: string;
  @Prop name: string;
  @Prop fileSize: number;
  onClose: () => void = () => {
  };

  @State content: string = '';
  @State pageStart: number = 0;
  @State pageIndex: number = 0;
  @State pageTextState: string = '';
  @State progress: number = 0;
  @State fontSize: number = 11;
  @State error: string = '';
  @State note: string = '';
  @State encoding: string = 'utf-8';

  private crownAccum: number = 0;
  private crownLockUntil: number = 0;
  private ctx: common.UIAbilityContext | null = null;
  private saveTimer: number = -1;
  private resumed: boolean = false;
  /** offsets of visited pages, so "previous page" is exact */
  private starts: number[] = [0];

  aboutToAppear(): void {
    const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.ctx = ctx;
    acquireScreen(ctx);
    this.load();
    // Focus after the first layout pass, otherwise the key does not resolve yet.
    setTimeout(() => {
      try {
        this.getUIContext().getFocusController().requestFocus('reader-root');
        hilog.info(0x0100, 'WatchCrown', 'focus requested');
      } catch (e) {
        hilog.warn(0x0100, 'WatchCrown', 'focus failed: %{public}s', `${(e as Error).message}`);
      }
    }, 200);
  }

  aboutToDisappear(): void {
    if (this.saveTimer >= 0) {
      clearTimeout(this.saveTimer);
      this.saveTimer = -1;
    }
    this.saveNow();
    releaseScreen();
  }

  private scheduleSave(): void {
    if (this.saveTimer >= 0) {
      clearTimeout(this.saveTimer);
    }
    this.saveTimer = setTimeout(() => {
      this.saveTimer = -1;
      this.saveNow();
    }, 600);
  }

  private saveNow(): void {
    const ctx: common.UIAbilityContext | null = this.ctx;
    if (ctx === null || this.content.length === 0) {
      return;
    }
    const st: ReadingState = new ReadingState();
    st.offset = this.pageStart;
    st.fontSize = this.fontSize;
    saveReading(ctx, this.realPath, st);
  }

  private readAll(): number[] {
    const out: number[] = [];
    let file: fs.File | null = null;
    try {
      file = fs.openSync(this.realPath, fs.OpenMode.READ_ONLY);
      let offset: number = 0;
      while (offset < MAX_BYTES) {
        const want: number = Math.min(CHUNK, MAX_BYTES - offset);
        const buf: ArrayBuffer = new ArrayBuffer(want);
        const n: number = fs.readSync(file.fd, buf, { offset: offset, length: want });
        if (n <= 0) {
          break;
        }
        const bytes: Uint8Array = new Uint8Array(buf);
        for (let i = 0; i < n; i++) {
          out.push(bytes[i]);
        }
        offset += n;
        if (n < want) {
          break;
        }
      }
    } catch (e) {
      this.error = `读取失败: ${(e as Error).message}`;
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
        }
      }
    }
    return out;
  }

  private decode(bytes: number[]): string {
    if (bytes.length === 0) {
      return '';
    }
    let enc: string = 'utf-8';
    let start: number = 0;
    if (bytes.length >= 3 && bytes[0] === 0xEF && bytes[1] === 0xBB && bytes[2] === 0xBF) {
      enc = 'utf-8';
      start = 3;
    } else if (bytes.length >= 2 && bytes[0] === 0xFF && bytes[1] === 0xFE) {
      enc = 'utf-16le';
      start = 2;
    } else if (bytes.length >= 2 && bytes[0] === 0xFE && bytes[1] === 0xFF) {
      enc = 'utf-16be';
      start = 2;
    }
    const body: Uint8Array = new Uint8Array(bytes.length - start);
    for (let i = start; i < bytes.length; i++) {
      body[i - start] = bytes[i];
    }
    this.encoding = enc;
    try {
      return util.TextDecoder.create(enc).decodeToString(body);
    } catch (e) {
      try {
        this.encoding = 'gbk';
        return util.TextDecoder.create('gbk').decodeToString(body);
      } catch (e2) {
        this.encoding = 'utf-8(强制)';
        return util.TextDecoder.create('utf-8').decodeToString(body);
      }
    }
  }

  private async load(): Promise<void> {
    const key: string = this.realPath;
    const cached: string | undefined = TextCache.instance().get(key);
    if (cached !== undefined) {
      this.content = cached;
      this.note = '来自缓存';
    } else {
      const bytes: number[] = this.readAll();
      if (this.error.length > 0) {
        return;
      }
      if (bytes.length >= MAX_BYTES) {
        this.note = '文件较大，仅显示前 2 MB';
      }
      this.content = this.decode(bytes).replace(/\r\n/g, '\n').replace(/\r/g, '\n');
      TextCache.instance().put(key, this.content);
    }
    const ctx: common.UIAbilityContext | null = this.ctx;
    let offset: number = 0;
    if (ctx !== null) {
      const st: ReadingState = await loadReading(ctx, key);
      this.fontSize = Math.min(20, Math.max(9, st.fontSize));
      offset = Math.max(0, Math.min(this.content.length, st.offset));
      this.resumed = offset > 0;
    }
    this.starts = [0];
    this.pageIndex = 0;
    this.renderFrom(offset);
    if (this.resumed && this.note.length === 0) {
      this.note = `已恢复 ${this.progress}%`;
    }
  }

  /** Characters per page for the current font size on a 233 vp canvas. */
  private computePageChars(): number {
    const bodyWidth: number = 210;
    const bodyHeight: number = 168;
    const lineHeight: number = this.fontSize * 1.55;
    const lines: number = Math.max(1, Math.floor(bodyHeight / lineHeight));
    const perLine: number = Math.max(4, Math.floor(bodyWidth / this.fontSize));
    return lines * perLine;
  }

  /** How many "column units" a character occupies: CJK 1, Latin ~0.55. */
  private unitsOf(ch: string): number {
    const code: number = ch.charCodeAt(0);
    if (code >= 0x2E80) {
      return 1;
    }
    if (ch === ' ') {
      return 0.35;
    }
    // Latin glyphs in this font are ~0.68 em wide, not the 0.55 first assumed:
    // estimating narrow made every modelled line wrap into ~1.15 visual lines.
    return 0.68;
  }

  /**
   * Lays out one page starting at `start`.
   *
   * Walks the text counting column units rather than characters, because a CJK
   * glyph is nearly twice as wide as a Latin one - the earlier character-count
   * estimate overflowed on mixed text and clipped the bottom line. When the
   * budget runs out it backs up to the last newline so a line is never cut.
   */
  private layoutPage(start: number): PageSlice {
    const out: PageSlice = new PageSlice();
    const perLineUnits: number = Math.max(4, (165 / this.fontSize) * 1.0);
    const lineHeight: number = this.fontSize * 1.55;
    // Body height measured on the device (233 vp canvas minus the header, footer
    // and padding). With the glyph widths calibrated above the model matches the
    // rendered line count, so no extra headroom is needed; clip(true) stays as a
    // safety net.
    const maxLines: number = Math.max(1, Math.floor(150 / lineHeight));
    let units: number = 0;
    let lines: number = 1;
    let i: number = start;
    let lastBreak: number = start;
    while (i < this.content.length) {
      const ch: string = this.content.charAt(i);
      if (ch === '\n') {
        lines += 1;
        units = 0;
        i += 1;
        lastBreak = i;
        if (lines > maxLines) {
          break;
        }
        continue;
      }
      const u: number = this.unitsOf(ch);
      if (units + u > perLineUnits) {
        lines += 1;
        units = 0;
        lastBreak = i;
        if (lines > maxLines) {
          break;
        }
      }
      units += u;
      i += 1;
    }
    let end: number = i;
    // Prefer ending on a line break when one is close enough to fill the page.
    if (end < this.content.length && lastBreak > start + (end - start) * 0.6) {
      end = lastBreak;
    }
    out.text = this.content.substring(start, end);
    out.next = end;
    return out;
  }

  private renderFrom(start: number): void {
    const slice: PageSlice = this.layoutPage(start);
    this.pageStart = start;
    this.pageTextState = slice.text;
    this.nextStart = slice.next;
    this.progress = this.content.length === 0 ? 0 : Math.min(100, Math.floor((start * 100) / this.content.length));
    this.scheduleSave();
  }

  private nextStart: number = 0;

  private changeFont(delta: number): void {
    const next: number = Math.min(20, Math.max(9, this.fontSize + delta));
    if (next === this.fontSize) {
      return;
    }
    this.fontSize = next;
    this.renderFrom(this.pageStart);
  }

  private turn(delta: number): void {
    if (this.content.length === 0) {
      return;
    }
    if (delta > 0) {
      if (this.nextStart >= this.content.length) {
        return;
      }
      this.starts.push(this.nextStart);
      this.pageIndex = this.starts.length - 1;
      this.renderFrom(this.nextStart);
    } else {
      if (this.pageIndex <= 0) {
        return;
      }
      this.pageIndex -= 1;
      this.starts = this.starts.slice(0, this.pageIndex + 1);
      this.renderFrom(this.starts[this.pageIndex]);
    }
  }

  // One notch of this crown reports only 0..1 degrees per event, so the page
  // threshold has to be small; 10 degrees needed several notches and read as
  // 'the crown does nothing'.
  private onCrown(event: CrownEvent): void {
    hilog.info(0x0100, 'WatchCrown', 'degree=%{public}s vel=%{public}s', `${event.degree}`, `${event.angularVelocity}`);
    this.crownAccum += event.degree;
    if (Date.now() < this.crownLockUntil) {
      return;
    }
    if (this.crownAccum > 12) {
      this.crownAccum = 0;
      this.crownLockUntil = Date.now() + 220;
      this.turn(1);
    } else if (this.crownAccum < -12) {
      this.crownAccum = 0;
      this.crownLockUntil = Date.now() + 220;
      this.turn(-1);
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        Row({ space: 4 }) {
          Text('‹ 关闭')
          .fontSize(9)
          .fontColor('#93C5FD')
          .onClick(() => {
            this.onClose();
          })
        Text(this.name)
          .fontSize(8)
          .fontColor('#9CA3AF')
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`第 ${this.pageIndex + 1} 页 · ${this.progress}%`)
          .fontSize(8)
          .fontColor('#9CA3AF')
      }
      .width('100%')
      .padding({ left: 40, right: 40, top: 2 })

      if (this.error.length > 0) {
        Column({ space: 6 }) {
          Text('📄')
            .fontSize(22)
          Text(this.error)
            .fontSize(9)
            .fontColor('#FCA5A5')
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Column() {
          Text(this.pageTextState)
            .fontSize(this.fontSize)
            .lineHeight(this.fontSize * 1.55)
            .fontColor('#E5E7EB')
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 34, right: 34, top: 2 })
        .clip(true)
        .alignItems(HorizontalAlign.Start)
        .gesture(
          PanGesture({ fingers: 1, distance: 16 })
            .onActionEnd((event: GestureEvent) => {
              if (event.offsetY < -28) {
                this.turn(1);
              } else if (event.offsetY > 28) {
                this.turn(-1);
              }
            })
        )
        .onClick((event: ClickEvent) => {
          // Top quarter goes back, bottom quarter goes forward, middle is inert.
          const y: number = event.y;
          if (y < 40) {
            this.turn(-1);
          } else if (y > 150) {
            this.turn(1);
          }
        })
      }

      Text(this.note.length > 0 ? this.note : `${this.encoding} · ${this.fontSize}vp`)
        .fontSize(6.5)
        .fontColor('#6B7280')
        .width('100%')
        .textAlign(TextAlign.Center)
        .height(10)
    }
    .width('100%')
    .height('100%')
    .padding({ top: 26, bottom: 18 })
    .backgroundColor('#0B0E14')
    // onDigitalCrown is only delivered to the focused component, and
    // defaultFocus alone does not win against the page underneath the overlay,
    // so focus is requested explicitly once the page is laid out.
    .id('reader-root')
    .focusable(true)
    .defaultFocus(true)
    .focusOnTouch(true)
    .onDigitalCrown((event: CrownEvent) => {
      this.onCrown(event);
    })

      // Controls sit in the circle's outer band, outside the inscribed square,
      // so they take no space from the page.
      Row() {
        this.sideButton('A-', () => {
          this.changeFont(-1);
        })
        this.sideButton('A+', () => {
          this.changeFont(1);
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)
      .padding({ left: 4, right: 4 })
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%')
    .height('100%')
  }

  /**
   * Side controls sit in the circle's outer band, outside the inscribed square,
   * so they cost the page no layout space at all.
   */
  @Builder
  sideButton(label: string, action: () => void) {
    Text(label)
      .fontSize(10)
      .fontColor('#93C5FD')
      .width(24)
      .height(40)
      .textAlign(TextAlign.Center)
      .backgroundColor('#1B2130CC')
      .borderRadius(12)
      .onClick(() => {
        action();
      })
  }
}















