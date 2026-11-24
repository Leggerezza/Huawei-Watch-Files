# 手表文件传（Huawei Watch 5 · FTP 服务端）

手机 ↔ 手表文件传输。手表侧跑一个 FTP 服务，**随机端口 + 随机短账号密码**，手机用任意 FTP 客户端连。

- 设备：HUAWEI WATCH 5（`RTS-AL00`），OpenHarmony 6.1.0.125，API 23
- 包名：`io.github.leggerezza.files`（与旧 CrownBridge 的 `com.example.myapplication` 不同，**可共存**）
- 构建：`targetSdkVersion 26.0.0` + `compatibleSdkVersion 6.1.0(23)`
- 代码：`entry/src/main/ets/services/{FtpServer,FsStore,NetInfo}.ets`、`pages/Index.ets`

## 当前状态

| 项 | 状态 |
| --- | --- |
| 编译 | ✅ 通过（`Build-Hap.ps1`） |
| 签名 | ❌ **未配置**，`signingConfigs` 为空，产物是 unsigned HAP |
| 真机安装/实测 | ⏸ 等签名后执行 `Deploy-Hap.ps1` + `Test-Ftp.ps1` |

签名只差一步：DevEco Studio → `File > Project Structure > Project > Signing Configs` → 勾选 **Automatically generate signature**（需登录华为账号）→ OK。之后 `build-profile.json5` 会写入 `signingConfigs`，`Build-Hap.ps1` 自动产出 signed HAP。

## 手表没有公共目录（已实测）

在应用进程内探测（`hilog` 标签 `WatchFtp`）：`/storage/media`、`/storage/media/100/local/files/Docs`、`/storage/media/100/local/files/Download`、`/mnt/share` 全部 **missing**；只有 `/data/storage/el2/base/haps/entry/files`（应用沙箱）可写。

所以 FTP 根目录 = `context.filesDir`，手机传的文件都落这里，卸载应用一并清理。手表端想让文件进"系统相册/下载"是无解的，只能由手机侧 App 中转。

参考：[应用沙箱目录](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/app-sandbox-directory)、[目录环境能力（getUserDownloadDir 仅 PC/2in1）](https://developer.huawei.com/consumer/cn/doc/doccenter-references/api/js-apis-file-environment)。

## 鉴权设计

启动时生成一对一次性凭据，显示在表盘上：

```
账号：4 位小写字母（去除 i l o）
密码：6 位（a-z 去 i l o，加 2-9 去 0 1）
```

- 每次"启动服务"重新生成，和随机端口（30000–59999）一起变
- 单连接错 3 次 → `421` 断开；全局累计错 12 次 → 服务器自动停
- `USER` 一律回 `331`，不泄露账号是否存在；密码不写日志
- 未登录时仅放行 `USER/PASS/QUIT/FEAT/SYST/NOOP`

为什么不上 FTPS / HTTPS / WebDAV：见 [docs/protocol-assessment.md](docs/protocol-assessment.md)（含 SDK 实测依据）。

## 已实现的 FTP 命令

`USER PASS SYST FEAT OPTS PWD CWD CDUP TYPE MODE STRU PASV EPSV LIST NLST MLSD MLST RETR STOR APPE REST SIZE MDTM DELE MKD RMD RNFR RNTO NOOP ABOR STAT ALLO QUIT`

- 被动模式 `PASV`(227) + `EPSV`(229)；主动 `PORT/EPRT` 明确 `502`
- 路径先归一化，`..` 在虚拟根被钳制，逃不出沙箱
- 单连接命令串行化，数据通道与命令不交错

## 使用

```powershell
# 1. 构建（首次 ~15s）
powershell -ExecutionPolicy Bypass -File .\Build-Hap.ps1

# 2. 安装并启动（自动等待手表上线）
powershell -ExecutionPolicy Bypass -File .\Deploy-Hap.ps1

# 3. 端到端自测：错误密码必须被拒 → 上传 → 下载 → SHA256 → 改名/删除
powershell -ExecutionPolicy Bypass -File .\Test-Ftp.ps1 `
    -WatchIp 192.168.137.91 -Port 33124 -User abcd -Pass k7x9qm
```

端口和账号密码以手表屏幕为准（每次启动都变），也可以读日志：

```powershell
hdc -t 192.168.137.91:44219 shell "hilog -x | grep WatchFtp | tail -3"
```

手机侧：连 `ftp://<手表IP>:<端口>`，填表盘上的账号密码。

## 目录

```
Files/
├─ Build-Hap.ps1          # 构建
├─ Deploy-Hap.ps1         # 等设备 → 安装 → 启动
├─ Test-Ftp.ps1           # 端到端自测（含错误密码拒登）
├─ docs/protocol-assessment.md
└─ entry/src/main/
   ├─ module.json5        # wearable + INTERNET / GET_NETWORK_INFO
   └─ ets/
      ├─ pages/Index.ets  # 466×466 表盘 UI
      └─ services/        # FtpServer / FsStore / NetInfo
```

## 未做 / 下一步

1. **后台保活**：现在依赖页面在前台，熄屏可能断连。要传大文件需 `backgroundTaskManager` 的 `DATA_TRANSFER` 长时任务 + `ohos.permission.KEEP_BACKGROUND_RUNNING`。
2. **HTTP 门户**（浏览器零安装）与 **WebDAV**（文件管理器挂载），见评估文档。
3. **免输入**：手表弹窗授权 IP / 显示二维码。
4. 手机端 App（选文件、进度、断点续传）。
