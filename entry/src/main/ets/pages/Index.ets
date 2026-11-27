import { common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { promptAction } from '@kit.ArkUI';
import { ServerHub, ServerStatus } from '../services/ServerHub';
import { FsStore } from '../services/FsStore';
import { FileItem, FileListView, FileViewKind, BucketStat, bucketOf } from '../services/FileListView';
import { MediaKind, Playability, extensionOf } from '../services/Metadata';
import { getLocalIpv4 } from '../services/NetInfo';
import { probeBackgroundModes } from '../services/BackgroundProbe';
import { ImageViewer } from '../components/ImageViewer';
import { TextReader } from '../components/TextReader';

// 466x466 px at density 2 => 233x233 vp of layout space.
const ROW_VP: number = 28;
const TAB_VP: number = 30;
const HEADER_VP: number = 26;
const BUCKETS: string[] = ['Images', 'Videos', 'Audio', 'Documents', 'Archives', 'Others'];

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

function playLabel(p: Playability): string {
  if (p === Playability.SYSTEM) {
    return '可播放';
  }
  if (p === Playability.UNSUPPORTED) {
    return '仅存储';
  }
  if (p === Playability.MAYBE) {
    return '待验证';
  }
  return '';
}

@Entry
@Component
struct Index {
  @State tab: number = 0;
  @State tick: number = 0;
  @State buckets: BucketStat[] = [];
  @State items: FileItem[] = [];
  @State filter: string = '';
  @State title: string = '分类';
  @State loading: boolean = false;
  @State note: string = '';
  // navigation
  @State screen: string = 'browse';
  @State imageList: FileItem[] = [];
  @State imageIndex: number = 0;
  @State openName: string = '';
  @State openReal: string = '';
  @State openSize: number = 0;
  // overlays
  @State detailPath: string = '';
  @State detailIndex: number = -1;
  @State inputMode: string = '';
  @State inputValue: string = '';
  @State inputTarget: string = '';
  @State moveMode: string = '';
  // transport
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
      this.items = vm.data.snapshot();
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
    this.detailPath = '';
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

  private itemAt(index: number): FileItem | null {
    const vm: FileListView | null = this.vm;
    if (vm === null) {
      return null;
    }
    return index >= 0 && index < this.items.length ? this.items[index] : null;
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
    if (item.kind === MediaKind.IMAGE) {
      const items: FileItem[] = vm.data.snapshot();
      const images: FileItem[] = [];
      for (let i = 0; i < items.length; i++) {
        if (!items[i].isDir && items[i].kind === MediaKind.IMAGE) {
          images.push(items[i]);
        }
      }
      this.imageList = images;
      let at: number = 0;
      for (let i = 0; i < images.length; i++) {
        if (images[i].path === item.path) {
          at = i;
        }
      }
      this.imageIndex = at;
      this.openCurrentImage();
      return;
    }
    const ext: string = extensionOf(item.name);
    if (ext === 'txt' || ext === 'md' || ext === 'log') {
      this.openName = item.name;
      this.openReal = this.store === null ? '' : this.store.real(item.path);
      this.openSize = item.size;
      this.screen = 'text';
      return;
    }
    promptAction.showToast({ message: `${item.name}  ${playLabel(item.playable)}`, duration: 1500 });
  }

  private openCurrentImage(): void {
    if (this.imageList.length === 0 || this.store === null) {
      return;
    }
    const item: FileItem = this.imageList[this.imageIndex];
    this.openName = item.name;
    this.openReal = this.store.real(item.path);
    this.openSize = item.size;
    this.screen = 'image';
  }

  private stepImage(delta: number): void {
    if (this.imageList.length === 0) {
      return;
    }
    const next: number = (this.imageIndex + delta + this.imageList.length) % this.imageList.length;
    this.imageIndex = next;
    this.openCurrentImage();
  }

  private showDetail(index: number): void {
    const item: FileItem | null = this.itemAt(index);
    if (item === null) {
      return;
    }
    this.detailIndex = index;
    this.detailPath = item.path;
  }

  private currentDetail(): FileItem | null {
    return this.itemAt(this.detailIndex);
  }

  private refreshList(): void {
    const vm: FileListView | null = this.vm;
    if (vm === null) {
      return;
    }
    vm.invalidate();
    vm.refresh();
  }

  private async doDelete(item: FileItem): Promise<void> {
    const store: FsStore | null = this.store;
    if (store === null) {
      return;
    }
    const ok: boolean = store.removeTree(store.real(item.path));
    this.detailPath = '';
    this.refreshList();
    promptAction.showToast({ message: ok ? '已删除' : '删除失败', duration: 1500 });
  }

  private async doRename(item: FileItem, newName: string): Promise<void> {
    const store: FsStore | null = this.store;
    if (store === null || newName.length === 0) {
      return;
    }
    const idx: number = item.path.lastIndexOf('/');
    const dir: string = idx <= 0 ? '/' : item.path.substring(0, idx);
    const dst: string = dir === '/' ? `/${newName}` : `${dir}/${newName}`;
    const ok: boolean = store.rename(store.real(item.path), store.real(dst));
    this.detailPath = '';
    this.refreshList();
    promptAction.showToast({ message: ok ? '已重命名' : '重命名失败', duration: 1500 });
  }

  private async doCopyMove(item: FileItem, bucket: string, copy: boolean): Promise<void> {
    const store: FsStore | null = this.store;
    if (store === null) {
      return;
    }
    const dirReal: string = store.real(`/${bucket}`);
    if (!store.exists(dirReal)) {
      store.mkdir(dirReal);
    }
    const target: string = store.uniquePath(dirReal, item.name);
    const ok: boolean = copy ? store.copy(store.real(item.path), target) : store.move(store.real(item.path), target);
    this.detailPath = '';
    this.refreshList();
    promptAction.showToast({ message: ok ? (copy ? '已复制' : '已移动') : '操作失败', duration: 1500 });
  }

  private async doMkdir(name: string): Promise<void> {
    const store: FsStore | null = this.store;
    const vm: FileListView | null = this.vm;
    if (store === null || vm === null || name.length === 0) {
      return;
    }
    const base: string = vm.path === '/' ? '' : vm.path;
    const ok: boolean = store.mkdir(store.real(`${base}/${name}`));
    this.refreshList();
    promptAction.showToast({ message: ok ? '已创建' : '创建失败', duration: 1500 });
  }

  // ------------------------------------------------------------------ builders

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
          .width(18)
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
          .width(18)
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
          .width(18)
      }
      Text(shortName(this.title, 12))
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor('#E5E7EB')
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
        .maxLines(1)
      if (this.tab === 1) {
        Text('+')
          .fontSize(13)
          .fontColor('#93C5FD')
          .width(22)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.inputMode = 'mkdir';
            this.inputValue = '';
            this.inputTarget = '';
          })
      } else {
        Text(this.vm === null ? '' : this.vm.sortLabel())
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
    }
    .width('100%')
    .height(HEADER_VP)
    .padding({ left: 4, right: 4 })
  }

  @Builder
  fileRow(item: FileItem, index: number) {
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
    .gesture(
      LongPressGesture({ repeat: false })
        .onAction(() => {
          this.showDetail(index);
        })
    )
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
          ForEach(this.items, (item: FileItem, index: number) => {
            ListItem() {
              this.fileRow(item, index)
            }
            .height(ROW_VP)
          }, (item: FileItem) => `${item.path}`)
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

  @Builder
  detailOverlay() {
    Column({ space: 5 }) {
      Text('文件操作')
        .fontSize(10)
        .fontColor('#9CA3AF')
      Text(shortName(this.detailPath.substring(this.detailPath.lastIndexOf('/') + 1), 16))
        .fontSize(11)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
      Text(this.detailInfo())
        .fontSize(7)
        .fontColor('#93C5FD')
        .textAlign(TextAlign.Center)
      Row({ space: 6 }) {
        Text('重命名')
          .fontSize(9)
          .fontColor('#FFFFFF')
          .backgroundColor('#1D4ED8')
          .borderRadius(6)
          .padding({ left: 8, right: 8, top: 5, bottom: 5 })
          .onClick(() => {
            const item: FileItem | null = this.currentDetail();
            if (item !== null) {
              this.inputMode = 'rename';
              this.inputValue = item.name;
              this.inputTarget = item.path;
            }
          })
        Text('复制')
          .fontSize(9)
          .fontColor('#FFFFFF')
          .backgroundColor('#1F2937')
          .borderRadius(6)
          .padding({ left: 8, right: 8, top: 5, bottom: 5 })
          .onClick(() => {
            this.moveMode = 'copy';
          })
        Text('移动')
          .fontSize(9)
          .fontColor('#FFFFFF')
          .backgroundColor('#1F2937')
          .borderRadius(6)
          .padding({ left: 8, right: 8, top: 5, bottom: 5 })
          .onClick(() => {
            this.moveMode = 'move';
          })
      }
      Row({ space: 6 }) {
        Text('删除')
          .fontSize(9)
          .fontColor('#FFFFFF')
          .backgroundColor('#B91C1C')
          .borderRadius(6)
          .padding({ left: 8, right: 8, top: 5, bottom: 5 })
          .onClick(() => {
            const item: FileItem | null = this.currentDetail();
            if (item !== null) {
              this.confirmDelete(item);
            }
          })
        Text('关闭')
          .fontSize(9)
          .fontColor('#CBD5E1')
          .backgroundColor('#1F2937')
          .borderRadius(6)
          .padding({ left: 8, right: 8, top: 5, bottom: 5 })
          .onClick(() => {
            this.detailPath = '';
          })
      }
    }
    .width(200)
    .padding(10)
    .backgroundColor('#151922')
    .borderRadius(12)
    .border({ width: 1, color: '#2B3444' })
  }

  private detailInfo(): string {
    const item: FileItem | null = this.currentDetail();
    if (item === null) {
      return '';
    }
    const kind: string = item.isDir ? '目录' : (item.kind === MediaKind.IMAGE ? '图片' :
      (item.kind === MediaKind.VIDEO ? '视频' : (item.kind === MediaKind.AUDIO ? '音频' :
        (item.kind === MediaKind.TEXT ? '文本' : '文件'))));
    return `${kind} · ${fmtSize(item.size)}${item.isDir ? '' : ' · ' + playLabel(item.playable)}`;
  }

  private confirmDelete(item: FileItem): void {
    AlertDialog.show({
      title: '删除',
      message: `${item.name}\n${fmtSize(item.size)}，此操作不可撤销`,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#FCA5A5',
        action: () => {
          this.doDelete(item);
        }
      }
    });
  }

  @Builder
  inputOverlay() {
    Column({ space: 6 }) {
      Text(this.inputMode === 'mkdir' ? '新建文件夹' : '重命名')
        .fontSize(10)
        .fontColor('#9CA3AF')
      TextInput({ text: this.inputValue, placeholder: '名称' })
        .width('100%')
        .height(28)
        .fontSize(10)
        .backgroundColor('#0B0E14')
        .onChange((value: string) => {
          this.inputValue = value;
        })
      Row({ space: 8 }) {
        Text('取消')
          .fontSize(9)
          .fontColor('#CBD5E1')
          .backgroundColor('#1F2937')
          .borderRadius(6)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .onClick(() => {
            this.inputMode = '';
          })
        Text('确定')
          .fontSize(9)
          .fontColor('#FFFFFF')
          .backgroundColor('#1D4ED8')
          .borderRadius(6)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .onClick(async () => {
            const name: string = this.inputValue.trim();
            const mode: string = this.inputMode;
            const target: string = this.inputTarget;
            this.inputMode = '';
            if (name.length === 0) {
              return;
            }
            if (mode === 'mkdir') {
              await this.doMkdir(name);
            } else {
              const item: FileItem | null = this.currentDetail();
              if (item !== null && item.path === target) {
                await this.doRename(item, name);
              }
            }
          })
      }
    }
    .width(200)
    .padding(10)
    .backgroundColor('#151922')
    .borderRadius(12)
    .border({ width: 1, color: '#2B3444' })
  }

  @Builder
  moveOverlay() {
    Column({ space: 4 }) {
      Text(this.moveMode === 'copy' ? '复制到分类' : '移动到分类')
        .fontSize(10)
        .fontColor('#9CA3AF')
      ForEach(BUCKETS, (name: string) => {
        Row() {
          Text(bucketIcon(name))
            .fontSize(10)
            .width(18)
          Text(name)
            .fontSize(9)
            .fontColor('#E5E7EB')
            .layoutWeight(1)
        }
        .width('100%')
        .height(22)
        .padding({ left: 6, right: 6 })
        .onClick(async () => {
          const item: FileItem | null = this.currentDetail();
          const mode: string = this.moveMode;
          this.moveMode = '';
          if (item !== null) {
            await this.doCopyMove(item, name, mode === 'copy');
          }
        })
      }, (name: string) => name)
      Text('取消')
        .fontSize(9)
        .fontColor('#CBD5E1')
        .onClick(() => {
          this.moveMode = '';
        })
    }
    .width(190)
    .padding(8)
    .backgroundColor('#151922')
    .borderRadius(12)
    .border({ width: 1, color: '#2B3444' })
  }

  build() {
    Stack() {
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

      if (this.screen === 'image') {
        ImageViewer({
          realPath: this.openReal,
          name: this.openName,
          fileSize: this.openSize,
          ordinal: this.imageIndex + 1,
          total: this.imageList.length,
          onClose: () => {
            this.screen = 'browse';
          },
          onPrev: () => {
            this.stepImage(-1);
          },
          onNext: () => {
            this.stepImage(1);
          }
        })
      }

      if (this.screen === 'text') {
        TextReader({
          realPath: this.openReal,
          name: this.openName,
          fileSize: this.openSize,
          onClose: () => {
            this.screen = 'browse';
          }
        })
      }

      if (this.detailPath.length > 0) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#00000080')
          .onClick(() => {
            this.detailPath = '';
          })
        this.detailOverlay()
      }

      if (this.inputMode.length > 0) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#00000080')
        this.inputOverlay()
      }

      if (this.moveMode.length > 0) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#00000080')
        this.moveOverlay()
      }
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


