import { common } from '@kit.AbilityKit';
import { FtpServer, FtpStatus } from '../services/FtpServer';
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
  @State port: number = 0;
  @State account: string = '';
  @State password: string = '';
  @State clients: number = 0;
  @State logLines: string[] = [];

  private server: FtpServer | null = null;

  aboutToAppear(): void {
    const srv: FtpServer = new FtpServer();
    srv.onStatus = (st: FtpStatus) => {
      this.running = st.running;
      this.port = st.port;
      this.clients = st.clients;
      this.account = st.user;
      this.password = st.pass;
    };
    srv.onLog = (msg: string) => {
      const now: Date = new Date();
      this.pushLog(`${two(now.getHours())}:${two(now.getMinutes())}:${two(now.getSeconds())} ${msg}`);
    };
    this.server = srv;
    getLocalIpv4().then((value: string) => {
      this.ip = value;
      // Serve as soon as the page is up: opening the app is the user intent.
      this.toggle();
    });
  }

  aboutToDisappear(): void {
    const srv: FtpServer | null = this.server;
    this.server = null;
    if (srv !== null) {
      srv.stop();
    }
  }

  private pushLog(line: string): void {
    const next: string[] = this.logLines.slice(0);
    next.push(line);
    while (next.length > 4) {
      next.shift();
    }
    this.logLines = next;
  }

  private async toggle(): Promise<void> {
    const srv: FtpServer | null = this.server;
    if (srv === null || this.busy) {
      return;
    }
    this.busy = true;
    try {
      if (this.running) {
        await srv.stop();
        this.running = false;
        this.port = 0;
      } else {
        const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
        this.ip = await getLocalIpv4();
        const st: FtpStatus = await srv.start(ctx.filesDir, this.ip);
        this.running = true;
        this.port = st.port;
      }
    } catch (e) {
      const err: Error = e as Error;
      this.pushLog(`失败: ${err.message}`);
    } finally {
      this.busy = false;
    }
  }

  build() {
    Column({ space: 6 }) {
      Text('手表 FTP')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')

      Row({ space: 4 }) {
        Text('●')
          .fontSize(11)
          .fontColor(this.running ? '#4ADE80' : '#9CA3AF')
        Text(this.running ? '运行中' : '已停止')
          .fontSize(12)
          .fontColor(this.running ? '#4ADE80' : '#9CA3AF')
      }

      Text(this.ip)
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
        .maxLines(1)

      Text(this.running ? `端口 ${this.port}` : '随机端口 · 随机账号')
        .fontSize(13)
        .fontColor('#93C5FD')

      Text(this.running ? `账号 ${this.account}  密码 ${this.password}` : '启动后显示账号与密码')
        .fontSize(14)
        .fontColor('#FDE68A')
        .maxLines(1)

      Button(this.running ? '停止服务' : '启动服务')
        .width('82%')
        .height(40)
        .fontSize(15)
        .backgroundColor(this.running ? '#B91C1C' : '#1D4ED8')
        .enabled(!this.busy)
        .onClick(() => {
          this.toggle();
        })

      Text(this.clients > 0 ? `已连接 ${this.clients} 个客户端` : '等待手机连接')
        .fontSize(11)
        .fontColor('#9CA3AF')

      Column({ space: 2 }) {
        ForEach(this.logLines, (line: string) => {
          Text(line)
            .fontSize(9)
            .fontColor('#6B7280')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }, (line: string, index: number) => `${index}-${line}`)
      }
      .width('100%')
      .height(46)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 8 })
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#111827')
  }
}
