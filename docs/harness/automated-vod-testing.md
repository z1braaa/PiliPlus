# Python 点播自动化测试

本工具交付对应 `AUTO-01/02/03`，为 `NET-01/02/03/04/05/06/07/12` 提供回归与测量辅助，并为 `NET-11` 提供原生播放器 seek 信号。它不会修改客户端偏好、读取登录账号、断开本机网络或自动购买任何服务。它不能代替 [手动测试](manual-vod-testing.md) 中的 GUI 首画面、首声音、真实用户操作及断网恢复验收。

入口为 `tool/vod_auto_test.py`，仅依赖 Python 3.10 或更新版本的标准库。原生播放探针另需兼容的 `libmpv` 动态库；并发模式还需 Dart SDK，当前桥接工具支持 macOS/Linux，Windows 会明确返回 `bridge_platform_unsupported`，不能宣称 Windows 并发测量通过。工具报告有 JSON 与 CSV 两种文件；签名媒体地址只在内存及子进程私有管道中传递，不进入报告、命令参数或公开错误信息。

## 1. 运行已有回归测试

在仓库根目录运行：

```sh
python3 tool/vod_auto_test.py regress \
  --dart /path/to/flutter/bin/dart \
  --flutter /path/to/flutter/bin/flutter \
  --timeout-seconds 180 \
  --output /path/to/private-test-results/regress
```

SDK 已在系统路径中时，可以省略 `--dart` 和 `--flutter`。它依次执行三个 Dart 传输测试文件及三个 Flutter 测试文件，汇总成功、失败、跳过、未运行及超时数量，并记录 Git 提交、分支与工作目录是否有未提交修改。Dart 与 Flutter 的统计均从测试框架结果解析；加载、初始化和收尾等隐藏生命周期事件单列，不能当作用户用例。缺少结果摘要不被视为成功。

每个测试文件有独立墙钟时间上限，默认 180 秒，允许 1–240 秒。超时或中断会关闭对应进程组。六个文件全部通过时退出状态为 0；缺少 SDK、测试失败或超时则为 1。标准输出只显示脱敏摘要，报告不保存测试程序的原始输出。

## 2. 固定素材比较三个播放路径

```sh
python3 tool/vod_auto_test.py playback \
  --bvid BVxxxxxxxxxx --page 1 --quality-code 80 \
  --library /path/to/libmpv.dylib \
  --dart /path/to/flutter/bin/dart \
  --duration-seconds 8 --start-seconds 0 \
  --output /path/to/private-test-results/playback
```

`BVxxxxxxxxxx` 是占位符，需替换成实际视频编号。macOS 可使用本次构建的 `PiliPlus.app/Contents/Frameworks/Mpv.framework/Mpv`；本工具不读取包内账号或设置。其他平台需提供相应动态库。

三个模式的含义为：

| 模式 | 行为 |
| --- | --- |
| `base-direct` | 直接使用该次 API 返回的视频与音频基础地址 |
| `hw-direct` | 保留媒体路径与签名参数，仅将双轨主机改为 PiliPlus 的华为云 `hw` 主机 |
| `parallel` | 使用本仓库的真实 Dart CDN 代理与多源候选策略；默认 8 路、1024 KiB |

默认顺序为 `base-direct,hw-direct,parallel,parallel,hw-direct,base-direct`，每个模式两次。每次独立启动原生播放器，并发模式每次独立启动代理。所有试验使用一次获取的相同 URL 集，固定起点、清晰度与编解码；不会在失败后偷偷刷新某一个模式的地址。该顺序只用于初步诊断，不代表足够的性能验收样本。

如果主要比较华为云与并发，可显式指定：

```sh
python3 tool/vod_auto_test.py playback \
  --bvid BVxxxxxxxxxx --quality-code 80 \
  --library /path/to/libmpv.dylib --dart /path/to/flutter/bin/dart \
  --order hw-direct,parallel,parallel,hw-direct \
  --output /path/to/private-test-results/hw-comparison
```

可设置 `--concurrency 8`、`--chunk-kib 1024`，块大小范围为 64–4096 KiB，与真实代理约束一致。并发数为 1 仍使用多源候选、探测及代理路径，不能当成“单一华为源”的替代对照。

### 匿名清晰度限制

工具只用公开的匿名 `view/nav/playurl` 请求，不读取应用 Cookie。默认请求清晰度代码 80（1080p），但服务端可能只提供较低画质。报告的实际清晰度以选中的 DASH 视频条目为准，并记录 codec、宽、高，不以请求参数或顶层质量标签代替。

如果请求画质不可取得，默认拒绝运行性能对照，报告 `requested_quality_not_reproduced`。用户明确希望用可取得的低画质诊断时可加 `--allow-lower-quality`；报告仍保持 `requested_quality_reproduced=false`。例如，请求 4K（120）而实际只取得 720p 时，该试验不能宣称复现用户 4K 卡顿。

也可用 `--manifest /path/to/private.json` 替代 `--bvid`。文件应由用户自行提供，不能提交仓库，结构如下；所有字段必须反映真实轨道：

```json
{
  "video_urls": ["https://allowed-cdn.bilivideo.com/upgcxcode/.../video.m4s?..."],
  "audio_urls": ["https://allowed-cdn.bilivideo.com/upgcxcode/.../audio.m4s?..."],
  "quality": 80,
  "codec": "avc1.640028",
  "width": 1920,
  "height": 1080,
  "audio_codec": "mp4a.40.2"
}
```

地址为说明用占位符。每轨接受 1–4 个已知媒体域 HTTPS 地址，要求同轨路径相同；任意网站、带用户名/密码的地址、HTTP 地址以及缺少实际清晰度/codec/分辨率的清单都会拒绝。工具不会复制或保存该私有清单，但用户原文件仍应自行妥善保存及删除。

### 原生 seek 与时间上限

可加 `--seek-seconds 120`，在观察完初始播放后跳到该位置，核对恢复事件、目标位置与随后至少 1 秒的进度。目标必须在视频内且与当时位置足够远；默认观察 8 秒时，seek 到 8 秒接近无操作，不能作为恢复试验。它验证原生播放器的结果位置与进度，不能验收 PiliPlus GUI 连续 seek、暂停状态或画质切换逻辑。

每次试验墙钟截止时间 `--deadline-seconds` 默认为 90 秒，范围 5–180 秒；整组总预算 `--total-budget-seconds` 默认为 600 秒，范围 5–1800 秒；观察时间范围为 1–60 秒。最多接受 18 次试验，每个模式最多 6 次。匿名取地址阶段也有真实进程截止时间，不会无限等候网络。预算耗尽的试验标为未运行，不能计为成功或零耗时；超时会清理原生播放器及代理子进程。

## 3. 如何解释报告

`report.json` 给出基线、素材元信息、质量检查、参数、每次结果与按模式汇总；`samples.csv` 是便于人工检查的同一组逐次记录。报告只记录素材指纹，不保存签名地址；实际运行时记录 mpv 动态库、Python 工具、Dart 桥及传输源码摘要，参与比较基线，避免不同运行版本混算。工具不自动确认当前地区、运营商、有线连接或 VPN 状态；这些仍需环境记录。

| 指标 | 含义与边界 |
| --- | --- |
| `file_loaded_seconds` | mpv `file-loaded` 事件耗时；不等于画面已显示 |
| `initial_progress_seconds` | 到观察到播放位置推进的耗时；是起播代理指标，不是可见首帧或可闻首声 |
| `playback_progress_seconds` | 初始片段达到指定播放进度所需墙钟时间 |
| `cache_pause_count/seconds` | mpv 已观测到的缓存暂停次数与时间；未取得信号时为 null，不擅自填 0 |
| `startup_cache_pause_* / seek_cache_pause_*` | 起播与 seek 观察段各自的缓存暂停，分开保留未知值 |
| `seek_restart_seconds` | seek 后播放器恢复事件的耗时 |
| `seek_progress_seconds` | seek 后达到指定观察进度的耗时 |
| `start_position_verified/seek_position_verified` | 原生事件是否核对到预期位置；不是 GUI 操作验收 |
| `bridge_setup_seconds` | 并发代理启动时间，单列记录；原生播放计时不包含它 |

画面和声音输出均为 `null`，缓存配置固定采用应用默认的 4 MiB/16 秒模型并记录在报告，未读取用户设置；与实际硬件解码、窗口绘制及用户自选缓存仍有差别。请求 User-Agent 与桌面 `BrowserUa.pc` 一致。直连 mpv 网络超时为应用默认的 5 秒，并发 mpv 为 60 秒，代理的每个来源请求超时为 10 秒；播放器条件进入报告。这是应用对应路径的比较，超时策略并非相同。下载速度不等于流畅度，缓存暂停也不能完全代替人工感知。原生代码运行与传输回归通过只证明相应路径可用，不能宣称 GUI 验收通过。

汇总只对同一指纹、实际画质、codec、分辨率、起点与试验参数的数据求中位数及范围；拒绝跨基线混算。失败、超时和未知值不作为成功耗时参与统计。少量样本不计算 P95，也不自动宣称达到 30% 改善。对海外网络性能结论仍需同素材、同质量、同网络的充分对照与手动验证。

## 4. 工具自身检查

```sh
python3 -m unittest discover -s tool/tests -p 'test_*.py' -v
```

这些检查覆盖超时进程清理、大清单管道截止、私有媒体地址不进入报告、匿名实际画质不足、清单元信息约束、结果计数及混合试验基线拒绝。未设置动态库时，真实原生夹具会标为跳过；设置环境变量 `PILIPLUS_MPV_LIBRARY` 为实际动态库路径后，可同时运行本地合成视频/音频、非零起点及 seek 的原生检查。它们不能证明真实 CDN 的性能收益；具体执行结果须写入验证记录。
