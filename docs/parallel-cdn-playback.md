# CDN 并行下载：设计与验证

## 目标与范围

改善海外线路存在单连接吞吐瓶颈时的 DASH 点播缓冲。PiliPlus 继续负责账号、播放地址解析、选集、画质、解码、字幕和弹幕；新增部分只处理交给本地播放器的 CDN 媒体字节。

功能默认关闭，设置入口为“设置 → 音视频设置 → 并发 CDN 加载（实验性）”，与 CDN 设置相邻。打开后在下一次加载播放源时生效。初版固定最多 **4 个并发上游请求，每块 256 KiB**，不承诺任何网络环境都能提速。

仅考虑本地播放的 DASH 点播音视频、已知 `bilivideo.com` / `bilivideo.cn` / `bilivideo.net` / `akamaized.net` 媒体域名、`/upgcxcode/` 点播路径及 `.mp4` / `.m4s` 文件。域名判断须匹配完整域名边界，不能用宽松的字符串包含判断。直播、离线下载、投屏及其他媒体格式不接入；现有全局 CDN 选择不改变。启用了应用自定义代理时跳过本功能，以保留原有代理路径。

## 为什么不能直接安装 BTR

调查固定在以下提交，后续比较上游应使用提交而非会变化的 `main`：

| 项目 | 取证提交 | 适配方式 |
| --- | --- | --- |
| PiliPlus | `a0e6148e928bf2d7f6e14599cab01bde2a0630f7` | Flutter / media_kit 本地播放器 |
| Bilibili-thread-ripper | `ee8709161e5a04cce2260a2937835e37f91ebcfb`，0.9.4.0 | 浏览器扩展 / 用户脚本 |
| Bilibili-thread-ripper-desktop | `67b941af182f27443f0a3877c91085551028ba3c`，0.9.3.0-d1 | 官方 Windows Electron 客户端 |

BTR 浏览器版通过 [content scripts](https://github.com/MrTangLuyao/Bilibili-thread-ripper/blob/ee8709161e5a04cce2260a2937835e37f91ebcfb/manifest.json#L29-L47) 注入网页；桌面版调用 [Electron `session.setPreloads`](https://github.com/MrTangLuyao/Bilibili-thread-ripper-desktop/blob/67b941af182f27443f0a3877c91085551028ba3c/src/bootstrap.cjs#L7-L22)，在官方 `app.asar` 入口接入，并且只向指定的 [官方客户端页面](https://github.com/MrTangLuyao/Bilibili-thread-ripper-desktop/blob/67b941af182f27443f0a3877c91085551028ba3c/docs/update-interface.md#L53-L62) 注入。这些接入点不属于 PiliPlus 的播放器。

可选方案：

| 方案 | 更新与维护 | 取舍 |
| --- | --- | --- |
| **应用内 Dart loopback 代理，初版采用** | 随 PiliPlus 更新 | 改动集中在媒体传输和设置，沿用现有播放器，不增加外部运行时 |
| 独立 helper + 本地协议 | 下载引擎可独立更新 | 需另行定义协议、打包各平台进程、启动/退出、版本兼容和更新校验；BTR 当前没有现成外部服务协议 |
| 嵌入浏览器再加载原插件 | 可跟进网页脚本 | 会更换播放器接入方式及大量应用行为，超出只改 CDN 传输的范围 |

独立 helper 是桌面端的后续扩展方向，不能把当前原型描述为“安装了可以独立自动更新的 BTR 插件”。iOS 不适合按桌面方式启动独立可执行 helper，建议将下载引擎随应用分发。当前实现也没有继承 BTR 的 CDN 竞速、自适应并发或自动更新。

## 媒体传输设计

```text
PiliPlus 现有播放地址解析及 CDN 选择
    ↓ 保留远端 URL、签名查询串和请求头
注册当前播放会话的随机本地媒体地址
    ↓
media_kit / mpv → 127.0.0.1 随机端口
    ↓
有限窗口 → 最多 4 个 × 256 KiB Range → 校验 → 按原顺序回传
    ↓
现有解码、播放、字幕、弹幕
```

- **会话隔离。** 只监听 loopback，使用不可预测的资源令牌；本地请求不能传入任意远端 URL。会话保存不可变的原始远端地址；切换播放源、签名或画质时建立新资源，不原地改写正在下载的地址。
- **支持本地播放器的请求方式。** 正确处理 `GET`、`HEAD`、封闭范围和 `bytes=start-`；必要时用小范围请求获取文件总长度。不能照搬 BTR 仅接管封闭 Range 的限制，也不能因开放范围而把整部视频一次读入内存。无效或无法满足的 Range 应给出正确 HTTP 响应。
- **有界并发与缓存。** 同一代理实例内所有音视频请求共享最多 4 个上游请求的额度，不能每条音轨各开 4 个；按有限窗口取块，顺序输出并遵守下游背压。seek、关闭及会话替换要取消无用工作，释放连接和待输出数据。
- **逐块校验。** 上游必须返回 `206`；`Content-Range` 起止必须与请求一致，文件总长度必须有效且与已知值一致，正文必须恰好达到该块长度。拒绝意外 `200`、错位块、短块、超长块及总长变化，不能把这些数据拼入播放流。
- **保留 CDN 行为。** 加速针对现有逻辑选出的媒体资源。失败回退使用会话保存的原始远端 URL 和媒体请求头，不通过全局 CDN 设置的改写来恢复。完整签名地址不写入常规日志。
- **响应前后的错误不同。** 输出响应体前，加速准备或首批数据失败可以通过本地代理，使用同一原始 URL、Range 和方法重新发起单流媒体请求；这不是向播放器返回跳转到远端的 302。已经输出响应头或媒体字节后不能重发另一份完整响应；此时终止当前响应，让播放器按自身恢复逻辑重新请求，避免重复字节和静默损坏。必须把这种情况纳入验证，不能笼统声称所有失败都无缝回退。协议测试已确认截断不会混入坏数据，但现有播放器的重试条件只覆盖特定起播错误；有缓冲后的中途错误不保证自动恢复，可能需要手动重试。
- **服务不可用时回退。** 本地端口无法绑定或平台不支持时保持原媒体 URL。开关关闭、资源不符合范围或应用自定义代理启用时，也保持已有播放路径。

设计参考 BTR 的 [Range 拆分](https://github.com/MrTangLuyao/Bilibili-thread-ripper/blob/ee8709161e5a04cce2260a2937835e37f91ebcfb/src/range-core.js#L35-L62)、[响应验证](https://github.com/MrTangLuyao/Bilibili-thread-ripper/blob/ee8709161e5a04cce2260a2937835e37f91ebcfb/src/idm-downloader.js#L419-L474) 和 [按序输出](https://github.com/MrTangLuyao/Bilibili-thread-ripper/blob/ee8709161e5a04cce2260a2937835e37f91ebcfb/src/idm-downloader.js#L893-L969)。这是对设计思路的独立 Dart 实现，没有复制上游 JavaScript。原项目采用 MIT，见 [浏览器版许可](https://github.com/MrTangLuyao/Bilibili-thread-ripper/blob/ee8709161e5a04cce2260a2937835e37f91ebcfb/LICENSE) 和 [桌面版许可](https://github.com/MrTangLuyao/Bilibili-thread-ripper-desktop/blob/67b941af182f27443f0a3877c91085551028ba3c/LICENSE)。

## 验证状态与平台边界

验证日期：2026-09-22；本机 macOS arm64，Flutter 3.47.5 / Dart 3.13.4。以下分别记录网络协议、应用检查和实机范围，不将其混为完整播放验收。

可复现的本地协议测试：

```sh
dart tool/cdn_proxy_smoke_test.dart
dart analyze lib/http/cdn_playback_proxy.dart tool/cdn_proxy_smoke_test.dart
```

测试使用本地可控 CDN，无需账号。**14/14 通过**，两个文件静态分析无问题。既有 Flutter 测试 **2/2 通过**。测试过程中发现并修复取消后继续取块、出错后连接未截断的问题：现使用 `HttpServer` 解析请求，在接入时取得底层 socket，以读取侧断开通知取消上游；输出固定长度或以连接关闭定界的 HTTP 响应。

| 范围 | 必须确认的内容 | 当前状态 |
| --- | --- | --- |
| 自动化协议测试 | 封闭/开放/尾部范围、HEAD、416、错位和短块、总长变化、顺序、全局并发上限、取消、回退及拒绝未注册 URL | 14/14 通过；涵盖并发共享、乱序、重定向、首块前/后取消、未知长度单流回退、总长/ETag 改变 |
| 静态检查与构建 | 新增代码和播放接入点；不能用纯 Dart 测试代替 Flutter 应用构建 | 应用分析 0 错误、0 警告；37 项现有 info 提示，新改文件无诊断。macOS Release 云端构建和打包通过 |
| macOS | 原生播放器及沙盒 release 权限 | 真实 libmpv 的 EDL、AVC/AAC 解码与远 seek 冒烟通过；GUI / release 沙盒播放尚未验证。Release 已补充 network.server entitlement |
| Windows / Linux | 对应 media_kit/mpv 后端的 GET、HEAD、seek、连接关闭和退出行为 | 待执行 |
| Android / iOS | 本地 HTTP 媒体访问、前后台切换、系统网络策略、设备内存和后台终止 | 待执行 |
| 实际海外网络 | 完整 A/B 播放对比，而非只做模拟下载基准 | 待执行 |

真实 CDN 抽查使用匿名接口返回的 `BV17x411w7KC` / CID `279786` 的音视频轨道，对 `upos-hz-mirrorakam.akamaized.net` 的视频和音频各读取前 1 MiB。直连和代理均返回 `206`，各自逐字节一致。视频一次直连/代理耗时为 208/187 ms，音频为 73/110 ms；这只是短样本，带有顺序与缓存偏差，不能用于声称提速，尤其不能代替实际海外网络 A/B。

原生播放器冒烟使用本次构建产物内的 libmpv，仅从只读挂载的 DMG 加载其库，不启动应用、不读取账号状态。匿名视频 AVC 与音频 AAC 经过新代理组成 EDL，`vo=null` / `ao=null`，demuxer 缓存上限 2 MiB：播放至 2.0 秒（约 2180 ms），跳转至 120 秒后继续至 122.0 秒（约 2050 ms），退出码 0。两轨识别正常，视频宽 512，音频 44.1 kHz。空输出验证了原生解码和远 seek，尚未验证窗口画面、可听声音、主观同步或 release 沙盒权限。

完整应用分析需要按照仓库 `lib/scripts/patch.ps1` 的 macOS 列表，先应用上游自带 Flutter/material_ui 补丁。本次只修改临时 SDK 和依赖缓存，未改项目依赖或上游源码。未应用这些既有补丁时的报错属于构建环境不完整，不应误计为本改动的错误。37 项已有 info 默认会令 `flutter analyze` 返回非零，应保留这一事实。

没有对应平台构建和真机播放证据的平台仍标为“未验证”。真实 CDN 短片段字节校验也不能证明完整播放器行为或海外网络一定提速。

## macOS 测试版

代码构建提交：`38938a44bc456cbdce72085952405fca553cc18d`。后续文档提交不改变安装包源码。

- [成功的 macOS 构建与下载产物](https://github.com/z1braaa/PiliPlus/actions/runs/35705032963)，2026-09-22，耗时 8m5s。
- 文件：`PiliPlus_macos_2.1.4+5399.dmg`，52,114,408 字节。
- 本地 DMG SHA-256 与 GitHub 摘要相同；磁盘映像校验通过。包内应用通过 `codesign --verify --deep --strict`，包含 `x86_64` 与 `arm64`，实际签名 entitlement 中 `network.server=true`。这些检查不等同于 Apple 公证或完整 GUI 播放验收。
- GitHub 产物摘要：`sha256:709ad5a72da38b5def36d5acc2c8a5adb458696304f9cb58b36bf0afc03c068c`。
- 默认开关关闭；进入“设置 → 音视频设置 → 并发 CDN 加载（实验性）”开启，再重新打开视频。
- 出现异常时关闭同一开关并重新打开视频，即恢复现有播放路径。

未自动覆盖本机已安装的 PiliPlus。当前已通过构建、传输协议及原生解码/seek 验证；完整 GUI 播放、持续播放效果和其他平台仍按表中状态验收。

## 实际播放 A/B 计划

同一台设备、同一网络、同一账号、同一视频/分 P、同一画质编码及 CDN 设置，交替测试关闭与开启。选至少一个热门视频、一个冷门高码率视频和一个音频较复杂的样本；每组各做至少 5 次，避免固定先后顺序和上一轮缓冲造成偏差。记录测试日期、系统、构建版本、视频标识、线路和网络是否经过 VPN，不记录登录凭据或完整媒体签名。

| 指标 | 记录方法 |
| --- | --- |
| 起播延迟 p50 | 从发起播放到首帧/可听音频的时间，报告每轮值和中位数 |
| 缓冲 | 固定播放时长内的卡顿次数、累计卡顿秒数和最长一次卡顿 |
| 有效吞吐 | 到达播放器的已校验字节 / 传输时间；和媒体实际码率一起记录 |
| 流量代价 | 上游总下载字节、实际交付字节、已播放时长、停止时未使用的缓冲字节；不要只看峰值速度 |
| seek 和画质切换 | 连续前后拖动、接近结尾、切换画质/编码/分 P，检查恢复时间、音画同步、无旧块混入及旧请求及时取消 |
| 异常恢复 | 断网/恢复、CDN 拒绝 Range、签名失效、关闭播放页、应用代理开启；确认既定回退与终止行为 |

只有协议正确、目标平台播放稳定且 A/B 显示收益后，才适合整理上游 PR；若吞吐未改善或额外流量明显，保持默认关闭并据实报告结果。
