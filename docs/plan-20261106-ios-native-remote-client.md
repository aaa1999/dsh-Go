---
日期：2026-11-06
分支：main
状态：执行中
---

# dsh-Go 原生 iOS 远程客户端计划（Swift/SwiftUI，替代 Flutter 路线）

> 本计划替代 docs/plan-20261106-ios-remote-client.md（Flutter iOS 壳路线，用户改要求原生开发后已中止，其代码改动已全部回退；该文档保留作为决策记录）。

## 方向

放弃 Flutter iOS 壳（本会话相关改动已全部回退），在仓库新建 `app-ios/`：原生 Swift/SwiftUI 的远程客户端。引擎跑在用户的 Linux 服务器上，App 通过 **SSH 隧道模式**连接（远端只需 SSH + `npm i -g @deepseek-ai/dsh`，App 自动拉起 `dsh web` 并本地转发——与 Android 版同一条链路）。已确认协议全契约（见下「实现依据」）。

## 技术选型

- **Swift 6 + SwiftUI，iOS 17+**，仅 iPhone。
- **SSH：swift-nio-ssh（DirectTCPIP 通道做本地转发）+ Citadel（密码/私钥认证、exec 跑引导脚本）**——纯 Swift/SPM/iOS 可用。keepalive 15s/超时 10s/2 次判死（对齐 Dart 侧）。
- **网络：URLSession + URLSessionWebSocketTask**（HTTP RPC 与 WS mux；Host 头覆盖 + Cookie 注入；实施首日先验证 URLSession 允许覆盖 Host 头——已知的低风险项，不行则退化 NWConnection）。
- **凭据：Keychain**（dsh cookie、SSH 密码/私钥）。
- **聊天渲染：MarkdownUI（SPM）**起步；代码高亮（Splash）与 LaTeX（SwiftMath）后置。
- **工程形态：XcodeGen**（`project.yml` 入库，生成 xcodeproj；CI 与本机都装 xcodegen——brew）。避免手写 pbxproj。

## 架构（镜像 Dart 侧分层，便于对照移植）

```
app-ios/
  project.yml                     XcodeGen 描述（App + 测试 target，SPM 依赖）
  Sources/
    Core/                         纯 Swift 协议层（不依赖 SwiftUI，可单测）
      DshConnection.swift         登录 token→cookie（dsh-auth-<b64(sha256(authority))>）、Host fence、健康检查
      Rpc.swift                   POST /api/<endpoint> 信封（client-request/server-response、ok:false 业务错、multipart 解码）
      Mux.swift                   /api/remote.mux WS：open/item/end/cancel/error 帧、$events ready 握手、连接代、重连退避 [0.5,1,2,4,8,10]s 抖动
      Models/                     Session/事件/StreamChunk 模型（Dart models.dart 的 MVP 子集：snapshot/event/assistant-stream、turn/step、Part 类型）
      SessionApi.swift            list/create/prompt/cancel/page/follow
      Transcript.swift            事件→聊天条目归约（MVP 简化版 transcript.dart）
    Ssh/
      SshTransport.swift          连接/认证/TOFU 指纹（SHA256:base64 OpenSSH 格式）/keepalive
      LocalForward.swift          本地 127.0.0.1 临时端口 listener → direct-tcpip，跨 SSH 重连接口（对齐 local_forward.dart）
      RemoteBootstrap.swift       1:1 复刻引导 sh 脚本与 DSHAPP 输出协议（probe 复用、~/.dsh-app-remote、60s 轮询）
      SshHostLink.swift           状态机：connect→verifyHostKey→startDsh→tunnel→login，复用判定与 forceRestart
    App/
      DshGoApp.swift、Views/（引导、主机管理、会话列表、聊天、设置）、State/
  Tests/                          Swift Testing：信封/cookie/DSHAPP 解析/mux 帧/模型/归约 单测（fixture JSON）
```

## MVP 范围（P0）

1. 首启引导 + 添加 SSH 主机（host/port/user/密码或私钥、TOFU 指纹确认弹窗）。
2. 连接链路全通：SSH → 引导 dsh web（token 解析）→ 隧道 → 登录 cookie → mux ready。
3. 会话列表（session/list）+ 新建会话（session/create）。
4. 聊天页：session/follow 流（snapshot→event→assistant-stream，seq/revision 连续性校验与 resync）+ 发送（session/prompt）+ 停止（session/cancel）+ markdown 渲染。
5. 断线恢复：SSH 重连 + mux 退避重连 + 隧道 listener 存活语义。
6. 审批与提问（$events waterfall 重投 + $events/result 回答）——聊天闭环的一部分。
7. 设置：主机编辑/删除、启动即连。

**后置（P1+，明确不做）**：DSH Remote 中继（自研 Noise IK 状态机 + DSH/RTC 分片 + WebRTC——CryptoKit 覆盖原语但工作量成倍，二期）、会话删除桥路由（需服务器装 dsh-go-bridge）、附件/媒体上传、会话 fork/搜索、插件页、代码高亮/LaTeX、通知、iPad。

## 里程碑与验证

- **M1 工程骨架**：project.yml + App 壳 + CI `ios-native` job（macos-15：brew install xcodegen && xcodegen && xcodebuild build + swift test）。验证：CI 绿。
- **M2 协议核心 + 单测**：Core/ 全部，fixture 单测（从 Dart 测试搬 fixture）。验证：xcodebuild test 绿。
- **M3 SSH 链路 + 单测**：Ssh/ 全部；DSHAPP 解析单测。验证：单测绿。
- **M4 UI MVP**：登录→聊天全流程可用。验证：**本机 Mac 当服务器**——开系统「远程登录」(sshd) + npm 装 dsh，模拟器 App 连 `127.0.0.1` SSH 走通全链路（模拟器共享 Mac 网络栈）。
- **M5 审批/提问 + M6 打磨与真机**：真机 iPhone（已发现你的 iPhone 在局域网可见）连 Linux 服务器复测；签名分发届时定（TestFlight/侧载）。

## 实现依据（已完成的协议盘点）

- 认证：`GET /?token=` → 303 + `Set-Cookie dsh-auth-<b64url(sha256(authority))>=v1.…`；后续请求带该 Cookie 且 **Host 头必须是 `127.0.0.1:<远端端口>`**（隧道本地端口 ≠ Host 头端口）。
- 聊天流：**WebSocket `/api/remote.mux`**（非 SSE），帧词汇 open/item/end/cancel/error；每代连接先 open `$events` 等 ready；`session/follow` 出 snapshot/event/assistant-stream 三种帧，seq 与 revision 严格连续、跳号用 session/page 补洞、补不上 resync。
- SSH 引导：远端 `nohup dsh web --host 127.0.0.1 --port 0 --no-open`，输出行前缀 `DSHAPP`，`~/.dsh-app-remote/web.log` 末行 token URL；探活复用、进程 PID+启动时间防复用错杀。
- 关键文件对照：packages/dsh_client/lib/src/{connection,rpc,carrier,mux,models,session_api,transcript}.dart；app/lib/remote/ssh/{ssh_link,ssh_transport,remote_bootstrap,local_forward}.dart。

## 文档同步

新计划文档落盘 `docs/plan-20261106-ios-native-remote-client.md`（标注替代 Flutter 路线的旧计划）；docs/roadmap.md P4 更新为原生路线；CONTRIBUTING/AGENTS 增加构建命令（xcodegen + xcodebuild）。Android/Flutter 侧零改动。

## 风险

- URLSession 覆盖 Host 头需首日验证（大概率可行，退化方案 NWConnection）。
- swift-nio-ssh 在 iOS 后台挂起时的线程暂停——预期断链，重连机制兜底（与 Android WebView 行为同级）。
- XcodeGen 需要本机/CI 安装（brew）。
- dsh web 版本演进可能改协议——MVP 锁定与 Android 端相同的 dsh 版本行为，靠 $events ready 的版本协商容错。
- 不主动 commit/push；内部 PR 走 .agents/skills/pr。
