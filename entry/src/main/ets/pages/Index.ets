import { common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { promptAction } from '@kit.ArkUI';
import { ServerHub, ServerStatus } from '../services/ServerHub';
import { FsStore } from '../services/FsStore';
import { FileItem, FileListView, FileViewKind, BucketStat } from '../services/FileListView';
import { MediaKind, Playability } from '../services/Metadata';
import { getLocalIpv4 } from '../services/NetInfo';
import { probeBackgroundModes } from '../services/BackgroundProbe';

// The watch reports 466x466 px at density 2, so the usable layout is ~233 vp
// square. Every size below is in vp: a 28 vp row is ~56 px, six buckets plus
// header and tabs fit without scrolling.
const ROW_VP: number = 28;
const TAB_VP: number = 30;
const HEADER_VP: number = 26;

function two(n: number): string {
  return `${n}`.padStart(2, '0');
}

function fmtSize(bytes: number): string {
  if (bytes < 1024) {
    return `${bytes} B`;
  }
  if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(1)} KB`;
  }
  if (bytes < 1024 * 1024 * 1024) {
    return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  }
  return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} GB`;
}

function iconOf(item: FileItem): string {
  if (item.isDir) {
    return '📁';
  }
  if (item.kind === MediaKind.IMAGE) {
    return '🖼';
  }
  if (item.kind === MediaKind.VIDEO) {
    return '🎬';
  }
  if (item.kind === MediaKind.AUDIO) {
    return '🎵';
  }
  if (item.kind === MediaKind.TEXT || item.kind === MediaKind.DOCUMENT) {
    return '📄';
  }
  if (item.kind === MediaKind.ARCHIVE) {
    return '🗜';
  }
  return '📦';
}

function bucketIcon(name: string): string {
  if (name === 'Images') {
    return '🖼';
  }
  if (name === 'Videos') {
    return '🎬';
  }
  if (name === 'Audio') {
    return '🎵';
  }
  if (name === 'Documents') {
    return '📄';
  }
  if (name === 'Archives') {
    return '🗜';
  }
  return '📦';
}

function shortName(name: string, max: number): string {
  return name.length <= max ? name : `${name.substring(0, max - 2)}…`;
}

@Entry
@Component
struct Index {
  @State tab: number = 0;
  @State tick: number = 0;
  @State buckets: BucketStat[] = [];
  @State filter: string = '';
  @State title: string = '分类';
  @State loading: boolean = false;
  @State note: string = '';
  // transport state
  @State running: boolean = false;
  @State busy: boolean = false;
  @State ip: string = '0.0.0.0';
  @State ftpPort: number = 0;
  @State ftpUser: string = '';
  @State ftpPass: string = '';
  @State httpPort: number = 0;
  @State httpCode: string = '';
  @State clients: number = 0;
  @State logLines: string[] = [];

  private vm: FileListView | null = null;
  private store: FsStore | null = null;
  private hub: ServerHub | null = null;
  private started: boolean = false;
  private placeholder: FileDataPlaceholder = new FileDataPlaceholder();

  aboutToAppear(): void {
    const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const store: FsStore = new FsStore(ctx.filesDir);
    store.ensureRoot();
    this.store = store;
    const vm: FileListView = new FileListView(store);
    vm.onChange = () => {
      this.tick = this.tick + 1;
      this.buckets = vm.buckets;
      this.loading = vm.loading;
      this.note = vm.note;
      this.filter = vm.filter;
    };
    this.vm = vm;
    vm.open(FileViewKind.BUCKETS, '/', '');

    const hub: ServerHub = new ServerHub();
    hub.onStatus = (st: ServerStatus) => {
      this.running = st.running;
      this.ftpPort = st.ftpPort;
      this.ftpUser = st.ftpUser;
      this.ftpPass = st.ftpPass;
      this.httpPort = st.httpPort;
      this.httpCode = st.httpCode;
      this.clients = st.ftpClients;
      if (st.ip.length > 0) {
        this.ip = st.ip;
      }
    };
    hub.onLog = (msg: string) => this.pushLog(msg);
    this.hub = hub;
    this.autoStart();
  }

  aboutToDisappear(): void {
    const hub: ServerHub | null = this.hub;
    this.hub = null;
    if (hub !== null) {
      hub.stop();
    }
  }

  private pushLog(line: string): void {
    const now: Date = new Date();
    const next: string[] = this.logLines.slice(0);
    next.push(`${two(now.getHours())}:${two(now.getMinutes())}:${two(now.getSeconds())} ${line}`);
    while (next.length > 3) {
      next.shift();
    }
    this.logLines = next;
  }

  private async autoStart(): Promise<void> {
    const hub: ServerHub | null = this.hub;
    if (hub === null || this.started) {
      return;
    }
    this.started = true;
    const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.ip = await getLocalIpv4();
    await hub.start(ctx.filesDir, this.ip);
    probeBackgroundModes(ctx);
    await this.acquireKeepAlive();
  }

  private async acquireKeepAlive(): Promise<void> {
    try {
      const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const info: wantAgent.WantAgentInfo = {
        wants: [{ bundleName: ctx.abilityInfo.bundleName, abilityName: ctx.abilityInfo.name }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(ctx, backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent);
      this.pushLog('后台保活已开启');
    } catch (e) {
      this.pushLog('保活不可用（设备不支持连续任务）');
    }
  }

  private async toggleServer(): Promise<void> {
    const hub: ServerHub | null = this.hub;
    if (hub === null || this.busy) {
      return;
    }
    this.busy = true;
    try {
      if (this.running) {
        await hub.stop();
      } else {
        const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
        await hub.start(ctx.filesDir, this.ip);
      }
    } catch (e) {
      this.pushLog(`失败: ${(e as Error).message}`);
    } finally {
      this.busy = false;
    }
  }

  private async switchTab(index: number): Promise<void> {
    this.tab = index;
    const vm: FileListView | null = this.vm;
    if (vm === null) {
      return;
    }
    if (index === 0) {
      this.title = '分类';
      await vm.open(FileViewKind.BUCKETS, '/', '');
    } else if (index === 1) {
      this.title = '目录';
      await vm.open(FileViewKind.DIR, '/', '');
    } else if (index === 2) {
      this.title = '最近';
      await vm.open(FileViewKind.RECENT, '/', '');
    }
  }

  private async onRowTap(item: FileItem): Promise<void> {
    const vm: FileListView | null = this.vm;
    if (vm === null) {
      return;
    }
    if (item.isDir) {
      this.title = item.path;
      await vm.enter(item);
      return;
    }
    const kind: string = item.kind === MediaKind.IMAGE ? '图片' :
      (item.kind === MediaKind.VIDEO ? '视频' : (item.kind === MediaKind.AUDIO ? '音频' : '文件'));
    const play: string = item.playable === Playability.SYSTEM ? '可播放' :
      (item.playable === Playability.UNSUPPORTED ? '仅存储' : '未验证');
    promptAction.showToast({
      message: `${item.name}  ${kind} · ${fmtSize(item.size)} · ${play}`,
      duration: 2000
    });
  }

  @Builder
  tabItem(index: number, label: string) {
    Column() {
      Text(label)
        .fontSize(this.tab === index ? 11 : 10)
        .fontWeight(this.tab === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.tab === index ? '#FFFFFF' : '#6B7280')
    }
    .width('25%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.switchTab(index);
    })
  }

  @Builder
  header() {
    Row() {
      if (this.tab === 0 && this.filter.length > 0) {
        Text('‹')
          .fontSize(13)
          .fontColor('#93C5FD')
          .width(20)
          .onClick(async () => {
            const vm: FileListView | null = this.vm;
            if (vm !== null) {
              await vm.backToBuckets();
              this.title = '分类';
            }
          })
      } else if (this.tab === 1 && this.vm !== null && this.vm.path !== '/') {
        Text('‹')
          .fontSize(13)
          .fontColor('#93C5FD')
          .width(20)
          .onClick(async () => {
            const vm: FileListView | null = this.vm;
            if (vm !== null) {
              await vm.up();
              this.title = vm.path;
            }
          })
      } else {
        Text('')
          .fontSize(10)
          .width(20)
      }
      Text(shortName(this.title, 14))
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor('#E5E7EB')
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
        .maxLines(1)
      Text(this.tab === 3 ? '' : (this.vm === null ? '' : this.vm.sortLabel()))
        .fontSize(9)
        .fontColor('#93C5FD')
        .width(30)
        .textAlign(TextAlign.End)
        .onClick(() => {
          const vm: FileListView | null = this.vm;
          if (vm !== null) {
            vm.cycleSort();
          }
        })
    }
    .width('100%')
    .height(HEADER_VP)
    .padding({ left: 4, right: 4 })
  }

  @Builder
  fileRow(item: FileItem) {
    Row({ space: 4 }) {
      Text(iconOf(item))
        .fontSize(11)
        .width(16)
        .textAlign(TextAlign.Center)
      Column({ space: 0 }) {
        Text(shortName(item.name, 12))
          .fontSize(10)
          .fontColor('#E5E7EB')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(item.isDir ? '目录' : fmtSize(item.size))
          .fontSize(7)
          .fontColor('#6B7280')
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height(ROW_VP)
    .padding({ left: 6, right: 6 })
    .onClick(() => {
      this.onRowTap(item);
    })
  }

  @Builder
  bucketRow(stat: BucketStat) {
    Row({ space: 4 }) {
      Text(bucketIcon(stat.name))
        .fontSize(11)
        .width(16)
        .textAlign(TextAlign.Center)
      Text(stat.name)
        .fontSize(10)
        .fontColor('#E5E7EB')
        .layoutWeight(1)
        .maxLines(1)
      Text(stat.count > 0 ? `${stat.count} · ${fmtSize(stat.bytes)}` : '空')
        .fontSize(7)
        .fontColor('#6B7280')
    }
    .width('100%')
    .height(ROW_VP)
    .padding({ left: 6, right: 6 })
    .onClick(async () => {
      const vm: FileListView | null = this.vm;
      if (vm !== null) {
        this.title = stat.name;
        await vm.openBucket(stat.name);
      }
    })
  }

  @Builder
  filesPane() {
    Column() {
      this.header()
      if (this.tab === 0 && this.filter.length === 0) {
        List() {
          ForEach(this.buckets, (stat: BucketStat) => {
            ListItem() {
              this.bucketRow(stat)
            }
            .height(ROW_VP)
          }, (stat: BucketStat) => stat.name)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .padding({ top: 4, bottom: 4 })
      } else {
        List() {
          LazyForEach(this.vm === null ? this.placeholder : this.vm.data, (item: FileItem) => {
            ListItem() {
              this.fileRow(item)
            }
            .height(ROW_VP)
          }, (item: FileItem) => item.path)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .padding({ top: 4, bottom: 4 })
      }
      if (this.note.length > 0) {
        Text(this.note)
          .fontSize(7)
          .fontColor('#FCA5A5')
          .height(10)
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  transportPane() {
    Column({ space: 3 }) {
      Text(this.running ? '服务运行中' : '服务已停止')
        .fontSize(11)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.running ? '#4ADE80' : '#9CA3AF')
      Text(this.ip)
        .fontSize(12)
        .fontColor('#FFFFFF')
      Text(this.ftpPort > 0 ? `FTP ${this.ftpPort} ${this.ftpUser}/${this.ftpPass}` : 'FTP 未启动')
        .fontSize(8)
        .fontColor('#93C5FD')
      Text(this.httpPort > 0 ? `网页 ${this.httpPort} 码 ${this.httpCode}` : '网页未启动')
        .fontSize(8)
        .fontColor('#FDE68A')
      Button(this.running ? '停止' : '启动')
        .width('56%')
        .height(26)
        .fontSize(11)
        .backgroundColor(this.running ? '#B91C1C' : '#1D4ED8')
        .enabled(!this.busy)
        .onClick(() => {
          this.toggleServer();
        })
      Text(this.clients > 0 ? `连接 ${this.clients}` : '手机连上面地址')
        .fontSize(8)
        .fontColor('#9CA3AF')
      Column({ space: 0 }) {
        ForEach(this.logLines, (line: string) => {
          Text(line)
            .fontSize(6)
            .fontColor('#6B7280')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }, (line: string, index: number) => `${index}-${line}`)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({ left: 6, right: 6 })
  }

  build() {
    Column() {
      if (this.tab === 3) {
        this.transportPane()
      } else {
        this.filesPane()
      }
      Row() {
        this.tabItem(0, '分类')
        this.tabItem(1, '目录')
        this.tabItem(2, '最近')
        this.tabItem(3, '服务')
      }
      .width('100%')
      .height(TAB_VP)
      .backgroundColor('#151922')
      .border({ width: { top: 1 }, color: '#232A36' })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0F1115')
  }
}

/** Placeholder source for the first frame, before the view model exists. */
class FileDataPlaceholder implements IDataSource {
  totalCount(): number {
    return 0;
  }

  getData(index: number): FileItem {
    return new FileItem();
  }

  registerDataChangeListener(listener: DataChangeListener): void {
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
  }
}
