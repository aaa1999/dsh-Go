---
日期：2026-11-06
分支：main
状态：执行中
---

# dsh-Go iOS 远程客户端改造计划

（内容与上次提交一致：iOS 远程客户端，引擎留在 Linux 服务器，手机侧只做远程连接。）

## Milestone 1：iOS 平台壳 + 平台开关
1. `app/` 下 `flutter create --platforms=ios .`；Bundle ID `io.github.ccch1mneyyy.dshapp`；仅 iPhone、竖屏、iOS 14+；Info.plist 防御性权限文案（相册/相机/麦克风/语音识别/保存相册）；ATS 不预加例外。
2. 新建 `app/lib/runtime/local_runtime_support.dart` 平台开关（`!kIsWeb && Platform.isAndroid`，可注入测试），替换入口：onboarding「本机」卡片与 root_gate 本机分支、`remote_screen.dart` 自动激活/canGoLocal、设置页过滤 engine/phone/background/systemAccess 等 Android 专属页、host_switcher「本机」行、sessions_drawer/chat idle 分支、engine/safe_mode 页、`dsh_remote_backend.dart` 设备注册名平台化。不用 `runtimeMissing`（iOS 恒 false）。
3. 天然降级部分不动：岛屿、WebView 守卫、通知/语音/手机操控/桌宠等已有容错。
4. l10n 新增 key（zh/en 同步）+ `l10n_merge.py`。
5. 新增 widget 测试（平台 override）；全量 analyze/test 保持绿。

## Milestone 2：构建与 CI
- `tooling/build-ios.sh`（`flutter build ios --no-codesign`，构建号复用 build_number.py 写 CFBundleVersion）。
- ci.yml 新增 `ios` job（macos-15，pub get + analyze + build --no-codesign，缓存 CocoaPods）；test/golden 留 ubuntu，其余 job 不动。

## Milestone 3：本机与模拟器验证
flutter doctor → `flutter build ios --no-codesign` → 模拟器冒烟（onboarding 仅远程、SSH 连 Linux 服务器全链路、设置页过滤）。中继 WebRTC 留真机。

## Milestone 4：真机与分发（后续单独做，需用户配合）
真机复测；届时定签名（TestFlight / 免费 7 天侧载）；补 docs/release.md 章节。

## 文档同步（中英双语）
README、docs/release.md、docs/roadmap.md:147 状态、docs/guide 如需注明 iOS 仅远程（跑 guide_sync.py）。

## 明确不做（首版）
本机引擎、手机操控、桌宠、快捷方式/图标别名、APK 自更新；通知/Live Activity/分享接收/语音/相册/深链的 iOS 原生实现（后续每通道一个 PR）；CI 不加 macOS test/golden。

## 验证命令
`(cd app && flutter pub get && flutter analyze && flutter test)`；`flutter build ios --no-codesign`；`l10n_merge.py --check` / `guide_sync.py --check`；CI ios job 绿。

获批后先把本计划原文落盘到 `docs/plan-20261106-ios-remote-client.md`（after-plan 流程），再开始实施。不主动 commit/push。
