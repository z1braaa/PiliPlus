# 两个用户问题视频复测（2026-09-30，5436）

本轮没有复现两个视频的并发开播卡顿。主组 8 轮并发从开播到 seek 前观察均没有原生缓存暂停；用户当前缓冲设置下，全部 8 轮播放和 seek 均为零暂停。

默认缓冲的第二视频曾有一次 seek 恢复异常，因此不能宣称整体“全部不卡”。主组并发计划 8 轮、有效 8 轮，其中这 1 轮在 seek 阶段记录缓存暂停、0 轮观测未知；直连另有暂停和媒体错误，下表分别保留。两组独立复测不能撤销原负例。

主组与附加复测合计 24 轮：23 轮有效，1 轮华为直连失败；并发 12 轮的开播及 seek 前观察均为已知零暂停。没有修改源码或重编译安装包。

## 条件与版本

使用 `2.1.5-CDN-AUTO-LIVE-CDNFIX+5436` 对应实现 `f6db39a29db522ef6f97eb7dc2e257c267c07771`，冻结代理源码 SHA-256 `d4ff4b52f45edbdf221954141bc7b85a07acea87e28e98692c95061621a9bd49`。测试使用发行包 stage 内的 Mpv，其 SHA-256 `07798b406023dc8de54d5f7f9abea57a646372df1517d7e0fb855dc5482f9c8c` 与公开构建记录相符。测试时仓库 HEAD 另为文档提交，记录在机器附件，不将文档 HEAD 冒充新的播放实现。

用户说明网络为新加坡有线家宽、无 VPN；工具没有独立确认出口地区。授权取源另行使用官方 HTTPS GET，本汇总脚本不读取 Cookie、私有 manifest，不执行网络或播放器。取源请求最高画质代码 129、偏好 AVC；实际素材分别为下列画质，并非 4K。

| 视频 | 实际画质 / 编码 / 尺寸 | 时长 | 用户配置观察 / seek | 默认配置观察 / seek |
| --- | --- | ---: | --- | --- |
| `BV1Cuao6LEHK` | 1080P60（q116）/ `avc1.640032` / 1920×1080 | 84 秒 | 74 秒 / 63 秒 | 30 秒 / 63 秒 |
| `BV192ad6cEb2` | 1080P+（q112）/ `avc1.640032` / 1080×1920 | 144 秒 | 90 秒 / 108 秒 | 30 秒 / 108 秒 |

H 为关闭自动选源与并发后的华为直连；S 为自动选源、自适应并发，路数上限 8、分块 512 KiB。第一视频按 H–S–S–H，第二视频按 S–H–H–S；每模式仅两轮，不能计算可靠 P95 或宣称统计显著性。

主组遵循应用所用超时路径：H 的 mpv 网络超时 5 秒，S 为 60 秒；S 代理上游超时仍为 10 秒。它是组合策略比较，**不是相同超时下单独隔离并发收益的试验**。默认缓存 16 秒/4 MiB；用户缓存 360 秒/200 MiB，前向与后向各用相应 MiB，hysteresis 分别约 10.667/240 秒。软件解码、无画面/无声音输出与 GUI 使用仍有差异。

## 四组结果

| 视频 / 缓冲 | H 有效 / 计划 | S 有效 / 计划 | H 起播阈值中位数 | S 起播阈值中位数 | H seek 中位数 | S seek 中位数 |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| `BV1Cuao6LEHK` / user 360秒/200MiB | 2/2 | 2/2 | 2.5525秒 | 1.4304秒 | 1.1173秒 | 1.1164秒 |
| `BV192ad6cEb2` / user 360秒/200MiB | 2/2 | 2/2 | 3.0808秒 | 1.6626秒 | 1.1835秒 | 1.1676秒 |
| `BV1Cuao6LEHK` / default 16秒/4MiB | 1/2 | 2/2 | 3.9477秒 | 0.9509秒 | 2.0866秒 | 2.5107秒 |
| `BV192ad6cEb2` / default 16秒/4MiB | 2/2 | 2/2 | 1.9907秒 | 1.0999秒 | 3.0202秒 | 12.9256秒 |

各中位数仅来自该视频、该缓存、该模式的有效轮次，失败不参与时间中位数且保留在下表。没有跨视频或跨缓冲合并中位数。

## 全部 16 轮及暂停

| 视频 / 缓冲 / 轮次 | 模式 | 状态 | 起播阈值秒 | 总缓存暂停 次 / 秒 | pre-seek 次 / 秒 | seek 次 / 秒 | seek restart 秒 | seek 后进度秒 | 缓存观测 |
| --- | --- | --- | ---: | --- | --- | --- | ---: | ---: | --- |
| `BV1Cuao6LEHK` / user / 1 | H | measured | 2.8487 | 0 / 0.0000 | 0 / 0.0000 | 0 / 0.0000 | 0.0989 | 1.1198 | 已知 |
| `BV1Cuao6LEHK` / user / 2 | S | measured | 2.0382 | 0 / 0.0000 | 0 / 0.0000 | 0 / 0.0000 | 0.0980 | 1.1101 | 已知 |
| `BV1Cuao6LEHK` / user / 3 | S | measured | 0.8227 | 0 / 0.0000 | 0 / 0.0000 | 0 / 0.0000 | 0.1028 | 1.1228 | 已知 |
| `BV1Cuao6LEHK` / user / 4 | H | measured | 2.2562 | 0 / 0.0000 | 0 / 0.0000 | 0 / 0.0000 | 0.1062 | 1.1148 | 已知 |
| `BV192ad6cEb2` / user / 1 | S | measured | 1.1325 | 0 / 0.0000 | 0 / 0.0000 | 0 / 0.0000 | 0.1687 | 1.1749 | 已知 |
| `BV192ad6cEb2` / user / 2 | H | measured | 3.1005 | 0 / 0.0000 | 0 / 0.0000 | 0 / 0.0000 | 0.1655 | 1.1850 | 已知 |
| `BV192ad6cEb2` / user / 3 | H | measured | 3.0610 | 0 / 0.0000 | 0 / 0.0000 | 0 / 0.0000 | 0.1678 | 1.1819 | 已知 |
| `BV192ad6cEb2` / user / 4 | S | measured | 2.1927 | 0 / 0.0000 | 0 / 0.0000 | 0 / 0.0000 | 0.1658 | 1.1603 | 已知 |
| `BV1Cuao6LEHK` / default / 1 | H | measured | 3.9477 | 2 / 2.4204 | 2 / 2.4204 | 0 / 0.0000 | 1.0914 | 2.0866 | 已知 |
| `BV1Cuao6LEHK` / default / 2 | S | measured | 1.0769 | 0 / 0.0000 | 0 / 0.0000 | 0 / 0.0000 | 1.4669 | 2.4396 | 已知 |
| `BV1Cuao6LEHK` / default / 3 | S | measured | 0.8249 | 0 / 0.0000 | 0 / 0.0000 | 0 / 0.0000 | 1.5759 | 2.5817 | 已知 |
| `BV1Cuao6LEHK` / default / 4 | H | failed（media_error） | 未知 | 未知 / 未知 | 未知 / 未知 | 未知 / 未知 | 未知 | 未知 | 未知 |
| `BV192ad6cEb2` / default / 1 | S | measured | 1.0801 | 1 / 2.7768 | 0 / 0.0000 | 1 / 2.7768 | 19.2686 | 23.0412 | 已知 |
| `BV192ad6cEb2` / default / 2 | H | measured | 1.3850 | 0 / 0.0000 | 0 / 0.0000 | 0 / 0.0000 | 1.6269 | 2.6323 | 已知 |
| `BV192ad6cEb2` / default / 3 | H | measured | 2.5965 | 0 / 0.0000 | 0 / 0.0000 | 0 / 0.0000 | 2.3964 | 3.4080 | 已知 |
| `BV192ad6cEb2` / default / 4 | S | measured | 1.1197 | 0 / 0.0000 | 0 / 0.0000 | 0 / 0.0000 | 1.8103 | 2.8101 | 已知 |

原生 `initial_progress_seconds` 计时从 loadfile 到位置达到 `start+0.1秒`；“进入已验证起播进度前”不等于数学意义上的任意 `time-pos>0`。例如 0.0333 秒的位置仍可能在该阈值之前。它不含 API 取源、代理准备、库初始化，也不等同可见首帧或可听声音。

`startup_cache_pause_*` 原始字段覆盖整段 seek 前观察，表中称 **pre-seek**，不能全写成开播暂停。总数及 pre-seek/seek 数字来自原生暂停事件；初始阈值前与持续阶段的划分依据 0.5 秒时间线采样，只是采样证据，短暂停可能没有采到，不能据此伪造分阶段精确秒数。

seek restart 是命令到原生恢复事件的等待；seek 后进度还要求确认目标位置并向前推进约 1 秒。它们都不是缓存暂停秒数：主组第二视频默认并发负例为 restart 19.2686 秒、进度 23.0412 秒，其中精确缓存暂停 1 次/2.7768 秒，三者必须分开。

## 保留的异常

- `BV1Cuao6LEHK` / default / H 第 1 轮：cache_pause_observed；状态 `measured`，精确总暂停 2 次/2.4204 秒。
  采样暂停位置：3.6477秒→位置0.0333秒（initial_loading_before_positive_progress）；8.9239秒→位置4.8833秒（continuous_playback_after_initial_progress）；9.4401秒→位置4.8833秒（continuous_playback_after_initial_progress）；9.9767秒→位置4.8833秒（continuous_playback_after_initial_progress）；10.4960秒→位置4.8833秒（continuous_playback_after_initial_progress）。
- `BV1Cuao6LEHK` / default / H 第 4 轮：status_failed；状态 `failed`，精确总暂停 未知 次/未知 秒。
- `BV192ad6cEb2` / default / S 第 1 轮：cache_pause_observed；状态 `measured`，精确总暂停 1 次/2.7768 秒。
  采样暂停位置：50.7455秒→位置108.1000秒（seek_recovery）；51.2693秒→位置108.1000秒（seek_recovery）；51.8032秒→位置108.1000秒（seek_recovery）；52.3207秒→位置108.1000秒（seek_recovery）；52.8464秒→位置108.1000秒（seek_recovery）。

## 独立复测

以下每组各自计数与统计，不并入主 16 轮，不替换主组 23.0412 秒恢复负例。

### app-path-repeat-default-BV192ad6cEb2

根状态 `completed`；计划 4、有效 4、失败 0、超时 0、未交付结果槽 0。

mpv 超时：`{"hw-direct": 5, "smart": 60}`；代理上游仍为10秒。

| 轮次 | 模式 | 状态 | 起播阈值秒 | 暂停次 / 秒 | seek restart 秒 | seek 进度秒 |
| --- | --- | --- | ---: | --- | ---: | ---: |
| 1 | S | measured | 0.9862 | 0 / 0.0000 | 1.4258 | 2.4266 |
| 2 | H | measured | 1.4253 | 0 / 0.0000 | 3.1198 | 4.1297 |
| 3 | H | measured | 1.6489 | 0 / 0.0000 | 3.2392 | 4.2623 |
| 4 | S | measured | 0.8476 | 0 / 0.0000 | 1.5451 | 2.5290 |

[独立原始报告](/Users/Admin/Downloads/PiliPlus-CDN-P0/outputs/cdn-two-videos-5436/app-path-repeat-default-BV192ad6cEb2/report.json)；SHA-256 `b5cc33ad2e83dccb88d1e73f1ac4d5b86d6d43852f3033f4013463f82bd5929f`。完整分组统计与内存审计保存在机器附件。

### sensitivity-10-default-BV192ad6cEb2

根状态 `completed`；计划 4、有效 4、失败 0、超时 0、未交付结果槽 0。

mpv 超时：`{"hw-direct": 10.0, "smart": 10.0}`；代理上游仍为10秒。

| 轮次 | 模式 | 状态 | 起播阈值秒 | 暂停次 / 秒 | seek restart 秒 | seek 进度秒 |
| --- | --- | --- | ---: | --- | ---: | ---: |
| 1 | S | measured | 1.0719 | 0 / 0.0000 | 1.6240 | 2.6250 |
| 2 | H | measured | 2.5261 | 0 / 0.0000 | 1.3223 | 2.3404 |
| 3 | H | measured | 3.2653 | 0 / 0.0000 | 3.3886 | 4.4054 |
| 4 | S | measured | 1.2721 | 0 / 0.0000 | 1.3563 | 2.3266 |

[独立原始报告](/Users/Admin/Downloads/PiliPlus-CDN-P0/outputs/cdn-two-videos-5436/sensitivity-10-default-BV192ad6cEb2/report.json)；SHA-256 `86d702474e2f8eac7274d7a013c69c6fc88d4b14e180f64aee5bcfb5f4343498`。完整分组统计与内存审计保存在机器附件。

## 原始证据与边界

主组计数：计划 16，有效 15，失败 1，超时 0，未交付结果的预计划槽 0。根报告终态 `completed_with_failures_or_gaps`。附加两组各 4 轮均有效，整体共 24 轮；不同条件不合并时间中位数。若硬中断，预计划 `not_run` 槽可能有未持久化的进行中尝试，其启动状态应记未知。

完整每轮时间线、五个原始内存数字及其缺失/类型/负值审计、连接与响应体读取量、源指纹、分组比较键见[机器附件](results/cdn-two-videos-5436.json)。桥接快照采于原生子进程退出之后、桥接关闭之前；非零保留额度不能自动称为泄漏或全部归零。读取量不包含未读取的取消数据、TLS、内核缓存和完整线路流量。

- root_report：[文件](/Users/Admin/Downloads/PiliPlus-CDN-P0/outputs/cdn-two-videos-5436/report.json)；SHA-256 `47891a909bc966f294041327c1a8059e07309e42f24fc62a8ce3c07471312dca`。
- samples_csv：[文件](/Users/Admin/Downloads/PiliPlus-CDN-P0/outputs/cdn-two-videos-5436/samples.csv)；SHA-256 `10a0e78ec3f979fdb9c11cb2adc4316b59c53062b5f799b592b752b17024380b`。
- acquisition：[文件](/Users/Admin/Downloads/PiliPlus-CDN-P0/outputs/cdn-two-videos-5436/acquisition.json)；SHA-256 `b202fdf283112fb0d71147b0e16065e091bb7fb3d13dbd379a4979ef03d9ccf3`。
- build_record：[文件](/Users/Admin/.codex/worktrees/piliplus-upstream-python-tests/piliplus/docs/harness/results/cdn-fix-macos-build-5436.json)；SHA-256 `0ccc21c62caf23811cee9bcfceda4abb609b0cea09393d4d3d5a05335b038dd6`。
- user-BV1Cuao6LEHK：[原始分组报告](/Users/Admin/Downloads/PiliPlus-CDN-P0/outputs/cdn-two-videos-5436/user-BV1Cuao6LEHK/report.json)；SHA-256 `fe1c2db6a1a89795b3665185cb90d910c1687680917b22c8e133ed72d99fef92`。
- user-BV192ad6cEb2：[原始分组报告](/Users/Admin/Downloads/PiliPlus-CDN-P0/outputs/cdn-two-videos-5436/user-BV192ad6cEb2/report.json)；SHA-256 `a411b6f3c3cb12d6069ad1e11fa8ed3ee42dba78a10182f0d3fb4b2ad16e3cfc`。
- default-BV1Cuao6LEHK：[原始分组报告](/Users/Admin/Downloads/PiliPlus-CDN-P0/outputs/cdn-two-videos-5436/default-BV1Cuao6LEHK/report.json)；SHA-256 `da176d014995f1998ac9df06137f7fb6df628a5f816d58ac0b1f8412f000d902`。
- default-BV192ad6cEb2：[原始分组报告](/Users/Admin/Downloads/PiliPlus-CDN-P0/outputs/cdn-two-videos-5436/default-BV192ad6cEb2/report.json)；SHA-256 `664628538094ed557aca64202093513c5c7773fc654c1a6a07f55cc4a59470f6`。

这次测试没有同时重跑旧版，所以用户“旧版会卡顿”是样本选择背景，本轮不是旧新版同刻因果对照。远端缓存是否被此前访问暖起不受工具控制；结果只说明这些素材、这个时段和这些参数下的原生供给表现。实际画面、声音、交互、完整播放与其他网络仍须独立验收。

授权凭据只用于官方只读 GET，未发送至 CDN 或回环；本轮临时快照、签名素材及冻结程序清理与实际敏感值扫描见[隐私记录](results/cdn-two-videos-privacy-5436.json)。原应用和原账户资料没有由本任务覆盖或写入。私有签名素材不归档；冻结测试驱动的无凭据文本保存在[本机附件](/Users/Admin/Downloads/PiliPlus-CDN-P0/outputs/cdn-two-videos-5436/frozen-runner.py.txt)。

## 恢复异常的未验证原因与下一步

异常轮累计有 53 次上游请求和 3 条 `chunk_or_admission / HttpException`，但没有逐请求时间戳；这些错误不能被断言发生在 seek，更不能据此断言 HTTP 403、缓存未命中或资源身份不一致。退出原生播放器后、桥接关闭前的 2 条活跃请求也不能证明连接泄漏。

只读代码审查表明，身份准入及范围重试可能串行经历多个有界等待；选源的 6 秒截止并不限制整次 seek 的累计恢复时间。旧请求取消、双轨竞争和有序块供给也是待排除的假设。本轮没有证据确定其中哪一个导致了 19.2686 秒 restart 等待，不能写成已经定位或修复。

后续应先补 seek 关联的请求时间线，区分准入、等待连接、首字节、块重试、取消及双轨供给；在能重复异常的同素材对照中再评估整体恢复截止和回退策略。默认 BV1 并发 seek 中位数 2.5107s、华为有效一轮 2.0866s 的约 0.42s 差异也保留，当前少量样本不足以确定稳定退化。NET-17 继续为部分体验验收。
