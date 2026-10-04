# PiliPlus 个人增强版

> **原应用 GitHub：[bggRGjQaUbCoE/PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)**
>
> 本仓库是在 PiliPlus 基础上维护的个人增强分支。基础客户端由原项目提供，感谢原作者及贡献者。

**[下载增强版 5444](https://github.com/z1braaa/PiliPlus/releases/tag/v2.1.5-live-intimacy-5444)** · **[增强版完整源码](https://github.com/z1braaa/PiliPlus/tree/codex/live-task-watch)** · [原应用下载](https://github.com/bggRGjQaUbCoE/PiliPlus/releases)

使用 Flutter 开发的 Bilibili 第三方客户端。本分支主要扩展点播 CDN、直播互动、亲密度任务、应用内小窗、临时播放队列和账号管理。增强版源码位于 `codex/live-task-watch` 分支，默认 `main` 用于展示仓库首页。

## 本分支新增与增强

### 点播 CDN 与播放恢复

- 增加独立的自动选择 CDN，可单独使用，也可配合并发加载。
- 支持多来源分块加载、可调并发路数与分块大小；自适应模式根据有效供给调整连接。
- 完善持续低速恢复、取消请求释放和测速展示。并发加载适用于 DASH 点播，效果取决于视频、节点及网络。

### 直播界面与互动

- 默认关闭的直播增强布局：礼物快捷条、聊天输入、点赞／表情／SC入口，以及粉丝团任务与大航海面板。
- 统一金币礼物的电池显示单位，完善确认、重复提交和未知结果处理。
- 为直播初始加载加入受控恢复：20秒没有有效播放数据时重试，最多2次；仍失败时提供手动重试入口。

### 自动亲密度任务

- 总开关和每个房间的授权均须手动开启，默认关闭；仅处理已关注、持有粉丝勋章且已授权的开播房间。
- 支持完整任务和“仅自动点赞”模式；未点亮但已持有勋章的房间可单独授权点赞。
- **互动与观时分开调度**：点赞、弹幕跨房间轮流执行，观时由单个独立静音、仅音频会话顺序完成，前台观看保持独立。
- 支持勋章等级从高到低／从低到高排序；已授权且有待办任务的当前直播间优先。
- 自动弹幕按账号全局30–60秒随机间隔执行，每房间独立设置文字或1–5个可用表情随机发送；点赞采用放缓间隔，官方确认完成后停止对应任务。
- 应用仍运行时可在后台继续；仅当前账号执行，匿名观看、暂停记录观看或身份冲突时暂停并提示。

### 观时记录与实时统计

- 按账号、直播间和官方任务周期分别保存，跨切房及重启保留，定时与官方任务同步。
- 显示官方完成轮数、本地有效观时、上报接受量与当前轮估算进度，保持这些口径分别可见；轮内起点未知时不显示精确百分比。
- 统计已授权房间的任务进度、运行目标、待核对与异常状态；动态页直播栏入口显示后台状态和完成比例。
- 入口随“动态页展开正在直播UP列表”和统计展示设置联动；临时折叠头像列表时仍保留入口，隐藏统计不停止任务。

### 多账号管理增强

- 在原项目多账号基础上完善管理入口，支持添加、重新登录、切换及移除本机账号；新增登录先保存，由用户手动切换。
- 切换时暂停旧账号后台任务，配置、授权、观时记录和统计按账号隔离。
- 观看记录、推荐和视频取流可跟随主账号，也可固定使用指定账号或匿名身份；跟随关系跨匿名往返与重启保留。
- 移除登录信息默认保留任务配置与记录，另提供独立清除入口。

### 应用内小窗与临时队列

- 增加应用内小窗，离开正在播放的点播／直播页后继续同一会话，支持返回与关闭；切换视频不生成旧小窗。
- 增加独立临时播放队列，支持下一条／队尾加入、拖动排序、去重移动和按账号跨重启保存。
- 应用内小窗默认关闭，临时队列默认开启；分别独立于系统画中画与云端“稍后再看”。

## 开始使用

1. 在设置中按需开启“自动选择 CDN”“并发 CDN 加载”或“直播界面增强”。
2. 在“设置 → 其他设置 → 后台亲密度任务”中开启总开关；在目标直播间开启自动点赞和自动弹幕、配置发送内容，再手动授权完整任务。仅点赞模式可独立授权。
3. 按需开启亲密度统计展示。设置页可查看统计；动态入口还需开启“动态页展开正在直播UP列表”。
4. 在“我的”页面进入账号管理。切换账号后，任务按新账号自己的设置和授权执行。

## 下载与平台

当前增强版为 **2.1.5-LIVE-INTIMACY-REVISION / 5444 预发行版**。

| 平台 | 安装包与系统要求 | 下载 |
| --- | --- | --- |
| Android | ARM64、32位ARM、x86_64 三种APK；Android 7.0+ | [5444发布页](https://github.com/z1braaa/PiliPlus/releases/tag/v2.1.5-live-intimacy-5444) |
| macOS | Apple Silicon／Intel通用DMG；macOS 13+ | [5444发布页](https://github.com/z1braaa/PiliPlus/releases/tag/v2.1.5-live-intimacy-5444) |

Android使用本机测试证书，与此前5442签名一致；不同证书的安装包无法直接覆盖。macOS使用ad-hoc本地签名，未做Apple公证。发布附件含源码清单、验证摘要和SHA256校验文件。Windows旧版可在[5442历史发布](https://github.com/z1braaa/PiliPlus/releases/tag/v2.1.5-live-intimacy-5442-r1)获取，5444本轮未构建Windows包。

## 验证范围

这些扩展已进入代码，完成度按具体场景记录。亲密度新版543项离线回归、81文件分析及两平台安装包独立校验通过，部分macOS界面和真实账号任务已验证。CDN性能、小窗完整生命周期、付费交互、第二真实账号、指定异常房间及部分跨房长时场景仍有验收缺口；5444成品未做设备安装测试。个人实际视频／直播观看历史统计仅预留扩展。

- [需求与实现追踪](https://github.com/z1braaa/PiliPlus/blob/codex/live-task-watch/docs/harness/traceability.md)
- [亲密度、统计与账号管理需求](https://github.com/z1braaa/PiliPlus/blob/codex/live-task-watch/docs/requirements/17-live-intimacy-records-statistics-accounts.md)
- [本版功能测试与剩余场景](https://github.com/z1braaa/PiliPlus/blob/codex/live-task-watch/docs/harness/live-intimacy-revision-20261003.md)
- [5444源码与安装包交付记录](https://github.com/z1braaa/PiliPlus/blob/codex/live-task-watch/docs/harness/github-release-5444.md)
- [点播CDN测量与恢复记录](https://github.com/z1braaa/PiliPlus/blob/codex/live-task-watch/docs/harness/cdn-recovery-20260930.md)
- [小窗与临时队列实现边界](https://github.com/z1braaa/PiliPlus/blob/codex/live-task-watch/docs/harness/remaining-work-live-l2.md)

## 原项目、声明与致谢

- **[PiliPlus 原项目](https://github.com/bggRGjQaUbCoE/PiliPlus)**：本分支的直接上游，基础功能及原有贡献归属原项目作者与贡献者。
- [guozhigq/pilipala](https://github.com/guozhigq/pilipala)、[orz12/PiliPalaX](https://github.com/orz12/PiliPalaX)：上游沿用的祖先项目署名。
- 原项目多账号等基础功能包含 [@My-Responsitories](https://github.com/My-Responsitories) 等贡献者的工作，沿用原有贡献归属。
- 感谢 [bilibili-API-collect](https://github.com/SocialSisterYi/bilibili-API-collect)、[media-kit](https://github.com/media-kit/media-kit)、[flutter_meedu_videoplayer](https://github.com/zezo357/flutter_meedu_videoplayer) 与 [Dio](https://pub.dev/packages/dio)。

保留原项目声明：此项目仅用于学习和测试，请于下载后24小时内删除；所用API皆从官方网站收集，不提供任何破解内容。许可证沿用 [GNU GPL v3](https://github.com/z1braaa/PiliPlus/blob/codex/live-task-watch/LICENSE)。
