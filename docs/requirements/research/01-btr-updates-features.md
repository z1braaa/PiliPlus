# BTR 更新日志与功能集合（调研稿）

核对日期：2026-09-23。本文是当时公开资料和源码的研究快照；迁入仓库时仅调整文档。表中“支持”指上游截至核对日的实现或声明，不表示已在用户网络重新测试。

## 版本边界

| 项目 | 本次确认的最新版本 | 发布方式与固定依据 |
|---|---|---|
| BTR 浏览器扩展 / 油猴 | **0.9.4.2**；2026-09-23 04:00:28 UTC（新加坡 12:00） | [正式 Release](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.9.4.2)，版本提交 `847848a412ae8c648a95367972bb338d8196efcb` |
| BTR 主分支 | `b0e4cbbc91f48fa9efbd5d0b48cea0f9319616a1`；2026-09-23 05:38:38 UTC | 比正式版本多一次[速度对比图更新](https://github.com/MrTangLuyao/Bilibili-thread-ripper/commit/b0e4cbbc91f48fa9efbd5d0b48cea0f9319616a1)，未发现新的运行时功能版本 |
| BTR Desktop | **0.9.4.2-d1**；2026-09-23 04:09:06 UTC | **没有 GitHub Releases 或 Tags**；通过仓库里的 [latest.json](https://github.com/MrTangLuyao/Bilibili-thread-ripper-desktop/blob/80ff27254c354eaf8e87d1ff19124122691a9259/latest.json) 和 ZIP 发版，版本提交 `80ff27254c354eaf8e87d1ff19124122691a9259` |

Desktop 面向官方 Windows Electron 客户端；浏览器版支持扩展和油猴。两者都不是可直接安装进 Flutter / libmpv 的 PiliPlus 的通用插件。Desktop 的 `-d1` 表示这一浏览器基础版本的第一版桌面适配，不等于拥有浏览器版的全部功能。[桌面适配说明](https://github.com/MrTangLuyao/Bilibili-thread-ripper-desktop/blob/80ff27254c354eaf8e87d1ff19124122691a9259/difference.md)

## 浏览器版更新日志

下表列出 API 返回的全部 **25 条正式 Release**。日期统一为 GitHub `published_at` 的 UTC 日期；上游 CHANGELOG 使用版本写入源码的日期，部分早期记录因此相差一天。旧 Release 页有些仅写安装提示，其功能摘要依据后来整理的[固定版本 CHANGELOG](https://github.com/MrTangLuyao/Bilibili-thread-ripper/blob/847848a412ae8c648a95367972bb338d8196efcb/CHANGELOG.md)。

| 版本 / 发布日期 UTC | 改动摘要 |
|---|---|
| [0.9.4.2](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.9.4.2) · 09-23 | 增加可拖动、记忆位置的设置悬浮按钮；画面全屏时隐藏；删除反复出现的首次引导。主要是设置入口修复。 |
| [0.9.4.1](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.9.4.1) · 09-23 | 头信息 / 首块、起播数据、普通数据分级排队；排队老化；实时播放截止时间及传输进度驱动备份请求；减少无效重复下载。 |
| [0.9.4.0](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.9.4.0) · 09-22 | 自动线程数；实验性直播 fMP4 HLS 加速；修复跳转回退、清晰度确认、特殊音轨和新旧播放器重复下载。 |
| [0.9.3.0](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.9.3.0) · 09-21 | 分块断点续传；按实测速率分配节点；自适应块大小；浏览器缓冲配额恢复；签名地址到期前刷新。 |
| [0.9.2.3](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.9.2.3) · 09-20 | 连续跳转及重新接管保留播放意图；诊断报告增加页面级接管、失败、回退时间线。 |
| [0.9.2.2](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.9.2.2) · 09-20 | 支持稍后再看、收藏夹中的播放。 |
| [0.9.2.1](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.9.2.1) · 09-20 | 修复单集循环；恢复可选兼容模式；取消时释放排队任务、读连接和无效响应。 |
| [0.9.2.0](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.9.2.0) · 09-19 | 自定义 CDN；遵从编码偏好；修正统计信息；改 CDN 不重开视频；统一设置面板，删除旧 ArtPlayer 代码与旧兼容模式。 |
| [0.9.1.5](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.9.1.5) · 09-19 | 预连接、更早采用已有播放清单、滑动预取；固定起播目标、跳转复用索引；Akamai 地址多节点支持、失败重试与重新接管。 |
| [0.9.1.4](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.9.1.4) · 09-18 | 清晰度切换与实际选轨同步；统计面板使用真实下载数据；修复设置面板交互。 |
| [0.9.1.3](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.9.1.3) · 09-17 | 修复播完后无限缓冲，尤其 HEVC。 |
| [0.9.1.2](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.9.1.2) · 09-16 | 默认大陆 CDN、8 线程；两次零字节失败后停用节点；错误提示默认关闭。 |
| [0.9.1.1](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.9.1.1) · 09-09 | 增加 Debug 与错误提示。 |
| [0.9.1.0](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.9.1.0) · 09-01 | 兼容模式、接管错误与恢复入口；修复接口域名、迟到清单和快速换视频。 |
| [0.9.0.4](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.9.0.4) · 08-31 | 连续切合集 / 分 P 的生命周期与旧请求隔离。 |
| [0.9.0.3](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.9.0.3) · 08-29 | 接管保持已有播放进度，避免开头重复。 |
| [0.9.0.2_](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.9.0.2_) · 08-28 | README 标签；不是新的插件功能版本。相关 0.9.0.2 主要修复切换及进度衔接。 |
| [0.9.0.1](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.9.0.1) · 08-28 | 保留官方界面，改用 Progressive MSE 媒体内核。 |
| [0.8.9.2](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.8.9.2) · 08-28 | 字幕可靠性、隔离与音量补齐。 |
| [0.8.8.1](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.8.8.1) · 08-28 | 设置持久化。 |
| [0.8.8](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.8.8) · 08-28 | 弹幕与小窗布局优化。 |
| [0.8.7](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.8.7) · 08-28 | 换视频隔离与标识匹配。 |
| [0.8.5](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.8.5) · 08-27 | 起播缓存、跳转与编码选择调整。 |
| [0.8.4](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.8.4) · 08-27 | 边下载边追加，减少起播等待。 |
| [0.8.1](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.8.1) · 08-27 | 自建播放器与多 CDN / Range 并发的初版。 |

历史补充：CHANGELOG 另记载 0.8.2–0.8.3、0.8.6、0.8.9、0.8.9.1、0.9.0 等阶段，并不都对应独立正式 Release。0.8.9 加入字幕；0.9.0 开始保留官方界面，但被维护者标为问题严重。不能把旧 ArtPlayer 自建界面功能当成当前架构。

## 当前功能集合

“浏览器全接管”保留 B 站 UI，由 BTR 管理媒体与缓存；“兼容模式 / Desktop”主要替换下载。二者拥有相同下载代码不代表获得相同的播放控制能力。

| 功能域 | 当前能力 | 生效范围 / 限制 | 依据 |
|---|---|---|---|
| 多路下载 | DASH 音视频字节范围拆分、并发、顺序输出、Range 位置/长度/总长校验 | 浏览器及 Desktop 共用下载器 | [核心源码](https://github.com/MrTangLuyao/Bilibili-thread-ripper/blob/847848a412ae8c648a95367972bb338d8196efcb/src/idm-downloader.js) |
| CDN 池 | 大陆 / 海外 / 自定义；B 站媒体域名白名单；节点与单条签名地址分别记录失败 | **并非纯地域轮转**：地域模式内仍有测速、权重、探索与慢节点退避；起播竞争还可能包含海外原始地址 | [0.9.2.0](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.9.2.0)、[0.9.3.0](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.9.3.0) |
| 并发配置 | 固定线程；自动 8→12→16→24→32，效果无改善或限流则退档 | 自动策略在播放不足时试探；固定线程最大支持 128，但上游不建议常用 | [0.9.4.0](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.9.4.0)、[设置规范](https://github.com/MrTangLuyao/Bilibili-thread-ripper/blob/847848a412ae8c648a95367972bb338d8196efcb/src/range-core.js) |
| 起播通路 | 预连接；复用先到的清单；小块先输出；优先保障音频 / 起播并留救援名额 | 首媒体块先取约 64 KiB；后续首段避免直接押在尚未成功的节点上 | [PR #10](https://github.com/MrTangLuyao/Bilibili-thread-ripper/pull/10)、[核心代码](https://github.com/MrTangLuyao/Bilibili-thread-ripper/blob/847848a412ae8c648a95367972bb338d8196efcb/src/idm-downloader.js#L988) |
| 调度 | 播放截止时间、队列分级 / 老化、接收进度、ETA、有限救援 | **0.9.4.1 新策略依赖全接管提供 deadline；Desktop / 兼容模式不提供，不能照搬其性能收益** | [0.9.4.1](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.9.4.1) |
| 块大小 / 重试 | 自适应 64 KiB–1 MiB；断点补缺；慢块备份副本，成功后取消多余连接 | 自适应来自实测连接吞吐；不是用户界面的固定块大小选项 | [0.9.3.0](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.9.3.0) |
| 容错 | 零字节节点停用；单地址拒绝单独退避；有限重试；回退与有限重新接管 | 具体回退方式不同：浏览器与官方客户端各有适配 | [PR #9](https://github.com/MrTangLuyao/Bilibili-thread-ripper/pull/9)、[桌面差异](https://github.com/MrTangLuyao/Bilibili-thread-ripper-desktop/blob/80ff27254c354eaf8e87d1ff19124122691a9259/difference.md) |
| 缓冲与续播 | 滑动窗口、回收已播放缓存；配额不足时缩短预缓冲；地址到期前刷新 | 配额与地址刷新属于浏览器全接管；Desktop 由官方播放器承担对应工作 | [PR #21](https://github.com/MrTangLuyao/Bilibili-thread-ripper/pull/21) |
| 播放连续性 | 同会话 seek、代际取消旧下载；保留播放 / 暂停意图；清晰度 / 编码、循环、合集和分 P | 多数浏览器修复解决的是 BTR 与网页内核交接，不可机械移植到 libmpv | [0.9.2.3](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.9.2.3)、[0.9.4.0](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.9.4.0) |
| 原界面能力 | 字幕、弹幕、快捷键、倍速、画中画、全屏、自动连播等继续使用官方界面 | **继承宿主功能，不是插件新增实现；不能视为礼物 / 灯牌模块** | [README](https://github.com/MrTangLuyao/Bilibili-thread-ripper/blob/847848a412ae8c648a95367972bb338d8196efcb/README.md) |
| 直播网络 | 屏蔽网页 P2P；官方同组节点分片竞速；有限预取；取消与坏节点处理 | 浏览器实验性 **fMP4 HLS**；不处理连续 FLV、TS；Desktop 还未移植 | [直播 PR #25](https://github.com/MrTangLuyao/Bilibili-thread-ripper/pull/25)、[Desktop 当前验证](https://github.com/MrTangLuyao/Bilibili-thread-ripper-desktop/blob/80ff27254c354eaf8e87d1ff19124122691a9259/docs/verification.md#L3) |
| 诊断 | 实际节点、线程、速度、缓冲、跳转恢复时间、错误和接管时间线 | 网页完整报告；桌面另有状态 / Debug 和维护日志 | [0.9.1.4](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.9.1.4)、[0.9.2.3](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.9.2.3) |
| 设置与分发 | 页面设置 / 播放器菜单；扩展手动替换；油猴自动检查更新 | 0.9.4.2 悬浮按钮只针对网页；Desktop 有独立安装、更新、卸载、覆盖后恢复工具 | [浏览器 0.9.4.2](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.9.4.2)、[Desktop README](https://github.com/MrTangLuyao/Bilibili-thread-ripper-desktop/blob/80ff27254c354eaf8e87d1ff19124122691a9259/README.md) |

## Desktop 自身的更新演进

它使用 `docs/verification.md` 作为移植与验证记录，并无独立 CHANGELOG 或 GitHub Release 列表。最新包名含浏览器版本，但浏览器独有变更可以没有相应桌面功能。

| 桌面版本 / 阶段 | 主要变化 |
|---|---|
| 0.9.1.1-d1～d5 | 从基本注入走向完整安装 / 更新 / 卸载；修复维护进程被客户端关闭连带结束；加入覆盖安装后的监视与恢复。 |
| 0.9.1.2-d1 / d2 | 大陆 CDN / 8 线程默认值及坏节点处理；修复非默认安装路径。 |
| 0.9.1.4-d1 / 0.9.1.5-d1 | 跟进共用内核；Akamai 多节点、拒绝地址隔离与重试。 |
| 0.9.2.3-d1 | 接入自定义 CDN 与多窗口设置同步。 |
| 0.9.3.0-d1 | 续传、权重和自适应块；另修客户端小音频 Range 全挤在一个节点的问题。 |
| 0.9.4.0-d1 | 接入 `<video>` 缓冲 / 卡顿信号，启用自动线程；直播仍未移植。 |
| 0.9.4.2-d1 | 同步两个共用文件，**客户端不传 deadline，新排队和对冲规则不启用**；主要下载行为保留 0.9.4.0-d1 路径。 |

来源：[桌面验证记录](https://github.com/MrTangLuyao/Bilibili-thread-ripper-desktop/blob/80ff27254c354eaf8e87d1ff19124122691a9259/docs/verification.md)。

## 对“初始载入慢”的直接参考

以下是源码与历史修复揭示的办法，不是对用户本机问题已经完成的性能定位：

1. **让关键数据尽早可用。** 元信息采用少量错峰请求；首媒体只先取小前缀，顺序输出已到齐内容，无需等完整大块。当前元信息路径最多三个候选，分别在 0 / 120 / 300 毫秒启动，首个成功即可取消其余。[实现](https://github.com/MrTangLuyao/Bilibili-thread-ripper/blob/847848a412ae8c648a95367972bb338d8196efcb/src/idm-downloader.js#L846)
2. **限制后台工作对首屏的竞争。** 头信息、首块和音频优先，普通预取之后；0.9.4.1 又用播放截止时间减少不必要备份，避免未开始的主请求被自己的副本抢先占满连接。[PR #23](https://github.com/MrTangLuyao/Bilibili-thread-ripper/pull/23)、[发布说明](https://github.com/MrTangLuyao/Bilibili-thread-ripper/releases/tag/0.9.4.1)
3. **不要使起播门槛随等待继续升高。** 固定起播目标、复用索引与清单、预连接、滑动补充，而非整批等齐；这些在 0.9.1.5 已单独处理。[PR #12](https://github.com/MrTangLuyao/Bilibili-thread-ripper/pull/12)、[PR #10](https://github.com/MrTangLuyao/Bilibili-thread-ripper/pull/10)
4. **直播起播也要让预取退让。** PR #25 特别记载，一次突发预取会抢占播放器需要的分片，因此改成少量按顺序排队，并在播放器等待时让路。[直播设计](https://github.com/MrTangLuyao/Bilibili-thread-ripper/pull/25)

BTR 仍在 README 承认第一次打开视频可能因索引、节点确认和连续缓冲准备而慢于原生。上游 0.9.4.1 的“卡顿减少”数据主要来自模拟网络；README 的速度图是维护者特定墨尔本线路和特定视频样本。它们能支持设计方向，不能证明 PiliPlus 或用户网络具有同样收益。此次未重跑 BTR 基准，也未测试最新插件。[README 边界](https://github.com/MrTangLuyao/Bilibili-thread-ripper/blob/847848a412ae8c648a95367972bb338d8196efcb/README.md#常见问题)
