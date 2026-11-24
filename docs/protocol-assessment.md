# 传输协议与鉴权方案评估

评估范围：在 Huawei Watch 5（API 23，OpenHarmony 6.1.0）上，除了"随机端口 + 免密 FTP"，还能怎么加一层访问控制，以及要不要换协议（FTPS / HTTP+HTTPS / WebDAV）。

结论基于**本机 SDK 声明文件实测**，不是凭印象：

- `@ohos.net.socket.d.ts` 第 115–124 行：`constructTLSSocketServerInstance()` 存在，`@since 10`
- 同文件：`TLSSocketServer.listen(options: TLSConnectOptions)`，注释明确 "a TLS session will be created and initialized and a **certificate key will be loaded and verified**"
- 同文件：`constructTLSSocketInstance(tcpSocket)` 的 `@since 12` 重载只用于**客户端**把已建立的 TCP 升级成 TLS
- `@ohos.security.cert.d.ts`：只有 `createX509Cert`（**解析**）、`createX509CertChain`、`createCertChainValidator`，**没有自签证书生成 API**
- `@ohos.net.*` 里没有 HTTP/WebDAV **服务端** 模块，`@ohos.net.http` 只是客户端

---

## 一、四种方案对比

| 方案 | 工作量 | 手机端普及度 | 实际安全增益 | 结论 |
| --- | --- | --- | --- | --- |
| **随机短账号密码（已实现）** | 低 | 100%（所有 FTP 客户端） | 中：挡住端口扫描器/误入者，挡不住同网段抓包 | ✅ 已采用 |
| 隐式 FTPS（TLS 从第一个字节开始，端口 990） | 高 | 中低：多数手机客户端默认走"显式"，隐式要手动开 | 中：证书是内置自签，且**所有安装共用同一私钥** | ❌ 不建议 |
| 显式 FTPS（`AUTH TLS` 原地升级控制连接） | — | — | — | ❌ **做不了**：SDK 没有服务端 TLS 升级 API |
| HTTP 门户（浏览器打开即可传） | 中 | 100%（不用装 App） | 低-中：明文 HTTP，靠随机凭据 | ⭐ v2 首选 |
| WebDAV（文件管理器直接挂载） | 中高 | iOS「文件」原生支持；Android 需装 App | 低-中 | ⭐ v2.5 |
| HTTPS / 加密 WebDAV | 高 | 同 FTPS 的证书问题 | 中 | ❌ 证书问题同上 |

**关键判断：FTPS/HTTPS 在手表上不是"能不能做"的问题，是"做了也不划算"。**
隐式 FTPS 技术上可行，但要在工程里内嵌一份自签证书 + 私钥（无生成 API），意味着所有手表共用同一私钥、每个客户端都要手动信任，而且大部分手机 FTP 客户端默认发的是显式 `AUTH TLS`——正好是 SDK 做不了的那一种。投入产出比很差。

## 二、已实现的随机凭据方案

设计目标：**手机上输得完**、**每次重启就换**、**扫到了也进不来**。

| 项 | 取值 |
| --- | --- |
| 账号 | 4 位小写字母，字母表 24 个（去掉易混的 `i` `l` `o`） |
| 密码 | 6 位，字母表 31 个（`a-z` 去 `i l o`，加 `2-9` 去 `0 1`） |
| 组合空间 | 24⁴ × 31⁶ ≈ **2.9 × 10¹⁴** |
| 随机源 | `cryptoFramework.createRandom().generateRandomSync()`（真随机），失败才退回 `Math.random` |
| 生命周期 | 每次点"启动服务"重新生成，与随机端口一起变 |
| 防爆破 | 单连接错 3 次 → `421` 直接断开；全局累计错 12 次 → 服务器自动停止 |
| 信息泄露控制 | `USER` 无论对错都回 `331`，不暴露账号是否存在；密码不写日志 |
| 未登录时 | 除 `USER/PASS/QUIT/FEAT/SYST/NOOP` 外一律 `530` |

**它防得住什么**：同一热点/校园网里乱扫端口的人、隔壁随手点开你 `ftp://ip:port` 的人、误连的客户端。
**防不住什么**：能抓包的人——FTP 控制通道是明文，账号密码在线上裸奔。这一点只能靠 TLS 解决，而 TLS 在上面已被否掉。

所以对"可信局域网 + 防误入"这个真实场景，它是性价比最高的解；真要抗抓包，正确做法是**别用 FTP**，走手机端 App 自建加密通道（这也是官方对穿戴设备的推荐路径）。

## 三、更值得投的方向（按优先级）

1. **v2：HTTP 门户**（`http://手表IP:端口`）
   浏览器直接打开一个极简页面：文件列表 + 上传按钮 + 下载链接。不用装任何 App，手机/平板/电脑都能用。SDK 没有 HTTP 服务端，需要自己在 `TCPSocketServer` 上实现请求行/头/体解析，约 400–600 行，可与现有 `FsStore` 复用。

2. **v2.5：WebDAV**
   在 HTTP 引擎上加 `PROPFIND / MKCOL / PUT / MOVE / COPY` + XML 响应，约再 300 行。收益是 iOS「文件」App 能直接把手表挂成网络位置；Android 仍需第三方 App（Solid Explorer / Material Files）。

3. **v3：免输入方案**（解决"手输 10 个字符"的摩擦）
   - **手表弹窗授权**：手机连上时手表问"允许 192.168.1.7 吗？"，点一下即放行该 IP，全程不用输密码；安全性来自"人就在旁边"。
   - **手表显示二维码**：把 `ftp://账号:密码@IP:端口` 编码成二维码（466×466 屏幕足够放 v6 级二维码），手机扫一下自动填好。需要自带一个精简 QR 编码器（约 200 行，无第三方依赖）。

## 四、当前状态

- 代码已落在本工程：`entry/src/main/ets/services/{FtpServer,FsStore,NetInfo}.ets` + `pages/Index.ets`
- 编译通过（`compatibleSdkVersion 6.1.0(23)` + 本机 API 26 SDK）
- **尚未签名**：`build-profile.json5` 里 `signingConfigs` 为空，产物是 unsigned HAP，装不进手表
- 一旦在 DevEco 里开启自动签名（绑定 `io.github.leggerezza.files` 与手表 UDID），即可用 `Deploy-Hap.ps1` + `Test-Ftp.ps1` 完成真机验证；`Test-Ftp.ps1` 的第 0 步就是"错误密码必须被拒绝"
