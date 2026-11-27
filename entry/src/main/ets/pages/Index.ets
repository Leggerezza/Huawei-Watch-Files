import { common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { ServerHub, ServerStatus } from '../services/ServerHub';
import { probeBackgroundModes } from '../services/BackgroundProbe';
import { getLocalIpv4 } from '../services/NetInfo';

function two(n: number): string {
  return `${n}`.padStart(2, '0');
}

@Entry
@Component
struct Index {
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

  private hub: ServerHub | null = null;
  private keepAlive: boolean = false;

  aboutToAppear(): void {
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
    getLocalIpv4().then((value: string) => {
      this.ip = value;
      // Serve as soon as the page is up: opening the app is the user intent.
      this.toggle();
    });
  }

  aboutToDisappear(): void {
    const hub: ServerHub | null = this.hub;
    this.hub = null;
    this.releaseKeepAlive();
    if (hub !== null) {
      hub.stop();
    }
  }

  private pushLog(line: string): void {
    const now: Date = new Date();
    const next: string[] = this.logLines.slice(0);
    next.push(`${two(now.getHours())}:${two(now.getMinutes())}:${two(now.getSeconds())} ${line}`);
    while (next.length > 4) {
      next.shift();
    }
    this.logLines = next;
  }

  private async acquireKeepAlive(): Promise<void> {
    if (this.keepAlive) {
      return;
    }
    try {
      const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const info: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: ctx.abilityInfo.bundleName,
          abilityName: ctx.abilityInfo.name
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(ctx, backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent);
      this.keepAlive = true;
      this.pushLog('后台保活已开启');
    } catch (e) {
      const err: Error = e as Error;
      // Known to fail on this watch with 9800005; surfaced instead of hidden.
      this.pushLog(`保活失败: ${err.message}`);
    }
  }

  private async releaseKeepAlive(): Promise<void> {
    if (!this.keepAlive) {
      return;
    }
    this.keepAlive = false;
    try {
      const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await backgroundTaskManager.stopBackgroundRunning(ctx);
    } catch (e) {
    }
  }

  private async toggle(): Promise<void> {
    const hub: ServerHub | null = this.hub;
    if (hub === null || this.busy) {
      return;
    }
    this.busy = true;
    try {
      if (this.running) {
        await this.releaseKeepAlive();
        await hub.stop();
      } else {
        const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
        this.ip = await getLocalIpv4();
        await hub.start(ctx.filesDir, this.ip);
        // Diagnostic: learn which continuous-task modes this product grants.
        probeBackgroundModes(ctx);
        await this.acquireKeepAlive();
      }
    } catch (e) {
      const err: Error = e as Error;
      this.pushLog(`失败: ${err.message}`);
    } finally {
      this.busy = false;
    }
  }

  build() {
    Scroll() {
      Column({ space: 4 }) {
        Text('手表文件传')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')

        Row({ space: 4 }) {
          Text('●')
            .fontSize(10)
            .fontColor(this.running ? '#4ADE80' : '#9CA3AF')
          Text(this.running ? '运行中' : '已停止')
            .fontSize(11)
            .fontColor(this.running ? '#4ADE80' : '#9CA3AF')
        }

        Text(this.ip)
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .maxLines(1)

        Text(this.ftpPort > 0 ? `FTP ${this.ftpPort}  账号 ${this.ftpUser}  密码 ${this.ftpPass}` : 'FTP 未启动')
          .fontSize(11)
          .fontColor('#93C5FD')
          .maxLines(1)

        Text(this.httpPort > 0 ? `网页 ${this.httpPort}  访问码 ${this.httpCode}` : '网页未启动')
          .fontSize(11)
          .fontColor('#FDE68A')
          .maxLines(1)

        Button(this.running ? '停止服务' : '启动服务')
          .width('78%')
          .height(36)
          .fontSize(14)
          .backgroundColor(this.running ? '#B91C1C' : '#1D4ED8')
          .enabled(!this.busy)
          .onClick(() => {
            this.toggle();
          })

        Text(this.clients > 0 ? `FTP 已连接 ${this.clients}` : '手机连上面任一地址')
          .fontSize(10)
          .fontColor('#9CA3AF')

        Column({ space: 1 }) {
          ForEach(this.logLines, (line: string) => {
            Text(line)
              .fontSize(8)
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
      .padding({ left: 10, right: 10, top: 8, bottom: 8 })
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#111827')
    .scrollBar(BarState.Off)
  }
}
