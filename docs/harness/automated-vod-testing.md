# Python 点播自动化测试

本工具既有交付对应 `AUTO-01/02/03`，匿名取源与批量筛选对应 `AUTO-04/05`，授权高画质与连续供给复核对应 `AUTO-06`，当前执行状态见[需求追踪表](traceability.md)与[验收记录](validation.md)。它为 `NET-01/02/03/04/05/06/07/12` 提供回归与测量辅助，并为 `NET-11` 提供原生播放器 seek 信号。它不会修改客户端偏好、自动读取应用／浏览器账号库、断开本机网络或购买任何服务；显式私有 Cookie 文件是[需求 11](../requirements/11-measured-cdn-and-battery.md)中获授权的只读取源扩展。它不能代替 [手动测试](manual-vod-testing.md) 中的 GUI 首画面、首声音、真实用户操作及断网恢复验收。

入口为 `tool/vod_auto_test.py`，仅依赖 Python 标准库；本轮实际使用 Python 3.9.6，建议使用 3.10 或更新版本。原生播放探针另需兼容的 `libmpv` 动态库；并发模式还需 Dart SDK，当前桥接工具支持 macOS/Linux，Windows 会明确返回 `bridge_platform_unsupported`，不能宣称 Windows 并发测量通过。既有工具报告有 JSON 与 CSV 两种文件，本轮批量流程追加本地可视报告；签名媒体地址只在内存及子进程私有管道中传递，不进入报告、命令参数或公开错误信息。

## 1. 运行已有回归测试

在仓库根目录运行：

```sh
python3 tool/vod_auto_test.py regress \
  --dart /path/to/flutter/bin/dart \
  --flutter /path/to/flutter/bin/flutter \
  --timeout-seconds 180 \
  --output /path/to/private-test-results/regress
```

SDK 已在系统路径中时，可以省略 `--dart` 和 `--flutter`。它依次执行四个 Dart 传输测试文件及四个 Flutter 测试文件，汇总成功、失败、跳过、未运行及超时数量，并记录 Git 提交、分支与工作目录是否有未提交修改。Dart 与 Flutter 的统计均从测试框架结果解析；加载、初始化和收尾等隐藏生命周期事件单列，不能当作用户用例。缺少结果摘要不被视为成功。

每个测试文件有独立墙钟时间上限，默认 180 秒，允许 1–240 秒。超时或中断会关闭对应进程组。八个文件全部通过时退出状态为 0；缺少 SDK、测试失败或超时则为 1。标准输出只显示脱敏摘要，报告不保存测试程序的原始输出。

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

工具先读取正常官方视频页的 HTML，必要时补公开 `view` 元信息与 `nav` 的 WBI 签名信息，再有限尝试 WBI 或 legacy 播放地址请求。HTML gzip 内容按正常响应解压；已有可用双轨时不重复取源。保留 `source_route`、有限 `acquisition_attempts` 和失败的 `stage/classification/http_status/api_code`。HTTP 401/403/412/429、明确挑战或登录限制会终止该素材，不绕过限制或无限重试。

请求使用新建的内存 CookieJar，可接收正常官方回复中的临时匿名 Cookie，但不读取账号库、浏览器已有 Cookie 或已安装应用配置，也不持久保存 Cookie。默认请求清晰度代码 80（1080p），但服务端可能只提供较低画质。报告的实际清晰度以选中的 DASH 视频条目为准，并记录 codec、宽、高，不以请求参数或顶层质量标签代替。当前分 P 的 `source.view.page_duration` 与投稿总 `duration` 分开保留；起点和 seek 使用当前分 P 时长检查，不能拿整投稿累计时长替代。

如果请求画质不可取得，默认拒绝运行性能对照，报告 `requested_quality_not_reproduced`。用户明确希望用可取得的低画质诊断时可加 `--allow-lower-quality`；报告仍保持 `requested_quality_reproduced=false`。例如，请求 4K（120）而实际只取得 720p 时，该试验不能宣称复现用户 4K 卡顿。

这里的默认停止适用于单素材 `playback`。下一节的 `campaign` 默认接受匿名可取得、且不高于请求值的最佳实际画质，以便完成无人值守初筛；同样必须保留画质不足提示，不能用低画质结果替代用户原 4K 条件。

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

每次原生试验墙钟截止时间 `--deadline-seconds` 默认为 90 秒，范围 5–600 秒；整组总预算 `--total-budget-seconds` 默认为 600 秒，范围 5–7200 秒；观察时间范围为 1–600 秒。最多接受 18 次试验，每个模式最多 6 次。取地址阶段也有进程截止时间，不会无限等候网络。预算耗尽的试验标为未运行，不能计为成功或零耗时；超时会清理原生播放器及代理子进程。

## 3. 自动筛选与批量对照

`AUTO-04/05` 已提供 `campaign` 入口，执行结果仍按[验收记录](validation.md)分别核对工具检查、公开发现和实际播放。官方发现入口或媒体取源仍可能受限，工具不能保证每次都选到足够素材或取得真实双轨。

```sh
python3 tool/vod_auto_test.py campaign \
  --library /path/to/libmpv.dylib \
  --dart /path/to/flutter/bin/dart \
  --count 4 --recent-days 7 --max-views 10000 \
  --popular-min-views 100000 --old-min-days 30 \
  --request-budget 8 --quality-code 80 \
  --duration-seconds 8 --start-seconds 0 --seek-seconds 30 \
  --campaign-budget-seconds 1200 \
  --order hw-direct,parallel,parallel,hw-direct --seed 0 \
  --output /path/to/private-test-results/campaign
```

`--count` 是整批视频数量上限，默认 4、最多 12 条，不是每层数量，也不是实际成功数量。默认四层各期望 1 条；8/12 条时各期望 2/3 条，缺层不硬凑。`--request-budget` 是发现请求上限，默认 8，允许 1–12；它不是每视频取源次数。发现截止 `--discovery-deadline-seconds` 默认 90 秒，允许 5–180 秒；每 trial 截止也默认 90 秒。总预算默认 1200 秒（20 分钟），允许 5–7200 秒，覆盖发现、取源和播放流程。工具顺序运行，不并发拉起多个视频来争抢测试网络。每个视频内部仍用有限路数的真实 CDN 代理；默认 8 路、1024 KiB，从 0 秒观察到 8 秒，再 seek 到 30 秒核对恢复进展。

| 分层 | 本例选择条件 | 用途 |
| --- | --- | --- |
| `recent-low` 近期低播放候选 | 发布不超过 7 天，采集时播放量不超过 10000 | 检验用户提出的易卡顿素材假说 |
| `recent-popular` 近期热门对照 | 发布不超过 7 天，采集时播放量不少于 100000 | 与问题候选保持发布时间范围相近 |
| `older-low` 较早低播放对照 | 发布至少 30 天，播放量不超过 10000 | 同样低播放、但发布时间较早 |
| `older-popular` 较早热门对照 | 发布至少 30 天，播放量不少于 100000 | 发布时间与播放量均不同的对照 |

发现按公开 `popular` → 首关键词 `search_recent` → 公开历史热门 `precious` → 同关键词 `search_older` 的有限顺序尝试；预算允许且搜索未受限时才会尝试其余关键词。关键词默认“游戏,生活,科技”，最多 3 个、每个最多 40 字符。较早搜索设置按 `--old-min-days` 计算的发布时间截止；任何搜索入口返回限制、登录要求或挑战后，整个搜索家族停止，不换关键词重复受限请求。公开推荐和历史热门不是专门的冷门集合，较早低播放组仍可能没有足够素材。

记录采用的发现来源、获取时间、发布时间、播放量、分层及选入理由。元信息不足、未来日期、四舍五入的万/亿播放数、入口失败或阈值筛选不够时，保留缺口和失败阶段，减少实际样本。没有数据不能自动标成低播放或较早，不能偷偷用热门视频补满问题组。也可通过 `--catalog /path/to/metadata.json` 提供本地公开元信息清单；它只抽取白名单元信息，勿放媒体地址或账号凭据，该清单仍走分层和实际元信息复核。公开入口覆盖不同，结果属于方便样本，不能当成全站随机样本。

“新视频、低播放更容易卡”只是假说。发布时间和播放量不能说明某个 CDN 是否已有缓存；起播慢、412 或候选被选中也不能证明海外节点未缓存。本轮不根据这些变量改变播放时的大陆候选优先或传输策略，只将其用于外部测试素材分层。

选择素材时固定一次时钟和 `--seed`，并在播放前锁定视频和计划；`selection_locked` 仅表示选题/顺序已固定，不表示画质、媒体可用性或播放已验证。默认顺序在相邻视频按种子镜像为 ABBA 或 BAAB：`hw → parallel → parallel → hw`，或 `parallel → hw → hw → parallel`。每视频四次连续执行，使用相同地址集、实际画质/codec、分 P、起点和观察时长；不会根据测得结果临时换题。批量使用第 1 分 P，取得轨道后复核其身份、分层元信息和 `page_duration`；默认 seek 30 秒时需当前分 P 至少 32 秒，短片不冒充成功恢复样本。HTML 的当前 CID 必须与所选分 P 一致才使用嵌入轨道；CID 未知时使用已有的选定 CID 公开 API 路线，不凭网址中的 `p` 参数猜测媒体身份。

`campaign` 默认请求 80，允许最佳可得的较低画质，并记录请求值、实际值和是否复现请求；没有合法双轨仍失败。加 `--require-quality` 则要求实际画质等于请求，不足的素材停止测量。默认匿名初筛不能覆盖需要登录权限的 4K 等条件。即使把请求改为 120，报告取得 480p/720p 时仍只能讨论该实际画质。

输出目录包含 `report.json`、`samples.csv` 和 `index.html`。HTML 可筛选四组，查看每视频实际画质/编码、华为与并发的起播/seek 恢复/缓存暂停中位数、两模式成功/计划数、起播差值与并发桥准备耗时；并链接完整 JSON 和 CSV。起播差值为“并发 − 华为”，为正表示该指标并发较慢；桥准备耗时额外单列，不包含在 native 起播指标中。

每个 trial 完成后更新检查点；用 Ctrl-C 正常停止时保留已完成记录，余项标 `not_run/user_interrupted`，进程随之清理。失败视频继续保留；预算耗尽后的剩余候选标为未运行；已超时的 trial 标为超时，不能填 0 秒成功。发现或取源全部失败时，仍生成可读报告并注明无有效播放样本。`completed_with_gaps` 表示可取得的视频全部测完但计划分层仍缺样本；`incomplete` 表示已选题中存在失败、超时或未运行，不能把两者都解释为完整通过。HTML 使用本地脱敏数据，不加载远程脚本或自动请求媒体；打开它不会重新播放视频。

先比较同视频各模式的有效结果，再查看对应分层。层内汇总按每个具有可比结果的视频一票计算差值中位数；不让某个视频的多条 trial 自动占更多权重。不同视频、不同实际画质或不同构建的秒数不能简单汇总为“并发提升比例”。每视频只有 ABBA/BAAB 四次时，只展示初筛中位数、范围、有效配对数和失败数，不作 P95、30% 改善或 GUI 流畅度结论。

## 4. 如何解释报告

`report.json` 给出基线、素材元信息、质量检查、参数、每次结果与按模式汇总；`samples.csv` 是便于人工检查的同一组逐次记录。报告只记录素材指纹，不保存签名地址；实际运行时记录 mpv 动态库、Python 工具、Dart 桥及传输源码摘要，参与比较基线，避免不同运行版本混算。工具不自动确认当前地区、运营商、有线连接或 VPN 状态；这些仍需环境记录。

批量报告还列出发现/取源各阶段和尝试顺序、每个素材的公开选择元信息、请求与实际画质、成功/失败/超时/未运行分布以及同视频可比结果。可视报告来自这些原始逐次记录，不能以页面存在代替测量存在。HTTP 412 发生在素材发现或取源阶段时，属于该阶段未取得媒体，不是已经播放后测得卡顿；具体失败接口仅在报告保存了对应阶段时才可指出。

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

画面和声音输出均为 `null`，默认缓存为 4 MiB/16 秒，可显式用 `--buffer-mib` 和 `--buffer-seconds`匹配用户配置（本轮为 200 MiB/360 秒），工具不自动读取用户设置。实际选项与每 0.5 秒的进度、缓冲余量／速率时间线进入报告；与硬件解码、窗口绘制仍有差别。媒体请求 User-Agent 与桌面 `BrowserUa.pc` 一致，官方网页发现/取源使用正常桌面浏览器请求头。比较时建议统一传 `--network-timeout-seconds 5`；不传时直连仍为 5 秒、代理为 60 秒，不能混为公平可靠性对照。代理来源请求超时为 10 秒。下载速度不等于流畅度，缓存暂停也不能完全代替人工感知。

汇总只对同一指纹、实际画质、codec、分辨率、起点与试验参数的数据求中位数及范围；拒绝跨基线混算。失败、超时和未知值不作为成功耗时参与统计。少量样本不计算 P95，也不自动宣称达到 30% 改善。对海外网络性能结论仍需同素材、同质量、同网络的充分对照与手动验证。

## 5. 工具自身检查

```sh
python3 -m unittest discover -s tool/tests -p 'test_*.py' -v
```

这些检查覆盖超时进程清理、大清单管道截止、私有媒体地址不进入报告、匿名实际画质不足、清单元信息约束、结果计数及混合试验基线拒绝。未设置动态库时，真实原生夹具会标为跳过；设置环境变量 `PILIPLUS_MPV_LIBRARY` 为实际动态库路径后，可同时运行本地合成视频/音频、非零起点及 seek 的原生检查。它们不能证明真实 CDN 的性能收益；具体执行结果须写入验证记录。

`AUTO-04/05` 新增检查需覆盖有限回退与阶段错误、分层边界和缺失元信息、重复视频去重、候选不足、批量画质不足标识、失败后继续与预算耗尽、原始样本和可视报告一致、无有效媒体时的空图状态，以及签名地址脱敏。公开真实素材发现/播放另行记录；即使这些确定性检查通过，也不能把官方受限的入口、用户原 4K 或目标网络性能标为已通过。


## AUTO-06 双轨连续供给与原生复核

新增 `tool/vod_supply_test.py`，默认计划 40 个视频，每次同时请求视频 2 MiB、音频 128 KiB，单次 18 秒、总预算 2400 秒。检查 206、Range、长度和两轨摘要；记录失败、实际画质、首 64 KiB、完整供给与块间最长等待。没有媒体时间映射，不能称这些为实际播放卡顿次数。

模式 `hw-direct` 为华为云直连；`smart` 为自动选源加自适应并发；`auto` 仅自动选源；`parallel` 保留旧策略作为历史对照。Python 直连与 Dart 代理的连接实现不同，不能仅据下载比例宣布应用提速。`vod_auto_test.py playback` 已支持这些模式；`vod_native_suite.py` 对公开元数据清单逐个进行同一个 mpv 的 ABBA/BAAB 起播、缓存暂停和 seek 复核。

新投稿目录最多三页普通公开请求；遇到限制停止该接口族。`--new-only` 专测生活区新投稿，不能代表全站冷门视频。`--catalog` 支持可复查的公开元数据，不包含媒体签名地址或账号信息。每视频各模式共用同一组取源结果。

下载模式按视频循环轮换，使各模式都有机会先测；首批历史初筛为华为云首尾、中间实验模式互换，需单列设计差异。不能制造或确认冷缓存。诊断中的上游正文数仅统计已观测正文，不含 TLS 和取消后未读取的数据。桥启动时间单列，应用本身没有反复启动 Dart 解释器的开销。

高画质受匿名接口限制时必须标注实际画质。低画质字节供给和无画面输出的 mpv 通过，不能证明登录 1080p/4K 或 GUI 首帧、声音验收通过。

### 授权高画质与初始／中段复测（5436）

`--cookie-file /path/to/private-cookies.json` 接受平面 Cookie 名称／值 JSON 对象，例如 `{"SESSDATA":"…","bili_jct":"…"}`。仅在用户授权后使用，将文件放在仓库外、仅本人可读；用后删除。Cookie 仅可发送至 HTTPS 的 `www.bilibili.com`／`api.bilibili.com` 精确域，重定向也受此限制；不会发送至 CDN 或回环代理，不写入报告。工具不提供自动账号库抽取。官方发现仍匿名，遇限制停止对应入口，不绕过挑战。

```sh
python3 tool/vod_supply_test.py \
  --catalog /path/to/public-catalog.json \
  --cookie-file /path/to/private-cookies.json \
  --count 40 --quality-code 120 --codec avc \
  --video-mib 8 --audio-kib 256 --middle-window \
  --modes hw-direct,smart --concurrency 8 --chunk-kib 512 \
  --trial-seconds 30 --budget-seconds 1800 \
  --output /path/to/test-results/supply
```

不加 `--require-quality` 时记录并测试最佳实际画质，不能把 1080p 写成 4K。供给最多 100 视频，原生 suite 最多 40，主 `campaign` 仍最多 12；后者总预算现允许至 7200 秒。首窗与中窗共用同一媒体来源，使用首窗成功响应的验证总长计算两轨各自的字节偏移并裁剪长度；重复首窗的小文件标为 `not_applicable`，未取得长度或预算不足保留 `not_run`。供给预算阻止超额启动新试验，但阻塞网络读、诊断和进程清理可能带来几秒尾时，不能宣称绝对硬截止。全批按 BV／窗口／偏移／实际画质／codec／来源指纹分别核对摘要；字节中点不等于媒体时间中点。目录层标签与取源后实时播放量分层单独报告，不用旧热度冒充当前冷门。

原生问题样本可用 `playback --bvid BV14Fao6HEB8 --cookie-file … --quality-code 120 --order hw-direct,smart,smart,hw-direct --duration-seconds 90 --seek-seconds 105 --buffer-seconds 360 --buffer-mib 200 --network-timeout-seconds 5`，并传入实际 `--library`／`--dart`及输出目录。seek 105 仅适用于本轮该分 P 的 120 秒长度，其他素材需另选合法目标。上游正文和缓冲／竞争副本计数用于定位，正文不是包含 TLS 与未读取取消数据的完整网络流量，payload 预约也不是进程 RSS。


### 5434 公平超时与新增回归

原生批次可传 `--network-timeout-seconds 5`，让华为云与代理使用相同播放器网络超时；不传则沿用应用的直连 5 秒／代理 60 秒，不能直接据后者的成功率断言更可靠。`regress` 已加入 measured transport 和电池换算套件。

```sh
python3 tool/vod_native_suite.py --catalog /path/to/public-catalog.json --output /path/to/equal-timeout --library /Applications/PiliPlus.app/Contents/Frameworks/Mpv.framework/Mpv --count 8 --seconds 30 --network-timeout-seconds 5
```

[本轮实际结果](cdn-auto-evaluation-20260929.md)与[机器摘要](results/cdn-auto-evaluation-20260929.json)包含未通过样本，不能只统计输出成功的行。
