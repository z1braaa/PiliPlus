# 三视频并发诊断（5436，2026-09-30）

本报告保留原包复现、诊断开关 pilot 和五模式消融的独立证据。所有负例仍保留；完成测试不等于性能目标达标。

本轮共42次尝试：41次取得原生测量，1次原包华为直连媒体失败。统一超时消融30/30取得测量，但其中仍有缓存暂停。`BV1TEhB6YEpH` 的并发两轮主缓存范围外 seek，restart 为1.1004/1.1873秒，随后均推进目标后的15秒且零暂停；`BV1ikaZ6rELU` 在原包和诊断关闭的复测中重现播放早期缺供给；`BV1yraR61EWN` 并发两轮的90～150秒段未重现，自动选源但关闭并发的一轮在132.449秒重现晚期暂停。

网络沿用用户说明的新加坡有线家宽、无VPN；工具未独立核实出口或运营商。按本机360秒/200MiB偏好测试，原生部分使用软件解码和null音视频输出，不能代替GUI首画面、声音或硬解体验。对每视频仅两轮的消融不作显著性、P95或全站收益结论。

原包 f6 核心、诊断核心和工具身份不同；原包应用 H5/S60 与统一60秒消融分组，不能合并中位数。消融代理上游10秒、360秒/200MiB、自适应上限8、分块512KiB。三个来源取得的实际编码/画质如下，最高请求不直接充当实际画质。

`hw-direct` 直接请求华为云；`fixed-h-auto` / `fixed-h-smart` 均走相同 auto/adaptive 算法且严格只许华为云，分别关闭/开启并发；`pool-auto` / `smart` 采用正常候选池及相同算法，分别关闭/开启并发。这是来源池与并发两个因子的对照，名字 auto 不代表旧 product-auto 路径。

| 视频 | 实际画质 | 编码/尺寸 | 时长 | 消融连续观察 / seek |
| --- | --- | --- | ---: | --- |
| `BV1TEhB6YEpH` | 1080P+（q112） | `avc1.640033` / 1440×1080 | 2345秒 | 从0连续15秒 / seek至1200秒，推进至目标+15秒 |
| `BV1ikaZ6rELU` | 4K（q120） | `avc1.640034` / 2160×3842 | 137秒 | 从0连续35秒 / 不请求seek |
| `BV1yraR61EWN` | 4K（q120） | `avc1.640034` / 3840×2160 | 1357秒 | 从0连续150秒 / 不请求seek |

## release-baseline-app-timeouts

状态 `completed_with_failures_or_gaps`；预计划 6，状态分布 `{"failed": 1, "measured": 5}`。本情景内按各视频/模式分别统计，中位数只用 measured 且缓存观测已知的轮次。

| 视频 / 模式 | 有效且缓存已知 / 计划 | 起播中位数秒 | 首个seek+1秒中位数 | 原生缓存暂停逐轮 |
| --- | --- | ---: | ---: | --- |
| `BV1TEhB6YEpH` / hw-direct | 0/1 | 未知 | 未知 | 1:failed/None次/未知秒 |
| `BV1TEhB6YEpH` / smart | 1/1 | 1.3024 | 2.3660 | 2:measured/0次/0.0000秒 |
| `BV1ikaZ6rELU` / smart | 1/1 | 1.2933 | N/A | 1:measured/1次/5.7998秒 |
| `BV1ikaZ6rELU` / hw-direct | 1/1 | 3.1797 | N/A | 2:measured/1次/1.5630秒 |
| `BV1yraR61EWN` / hw-direct | 1/1 | 2.7281 | N/A | 1:measured/0次/0.0000秒 |
| `BV1yraR61EWN` / smart | 1/1 | 1.3742 | N/A | 2:measured/1次/3.9567秒 |

[完整原始报告](/Users/Admin/Downloads/PiliPlus-CDN-P0/outputs/cdn-three-diagnostic-5436/release-baseline/report.json)；SHA-256 `252707f738c18b1e1ff3fc805a79cc30d1baf8f1e0734f07d8b090b6b4530076`。

## pilot-diagnostic-off-1

状态 `completed`；预计划 1，状态分布 `{"measured": 1}`。本情景内按各视频/模式分别统计，中位数只用 measured 且缓存观测已知的轮次。

| 视频 / 模式 | 有效且缓存已知 / 计划 | 起播中位数秒 | 首个seek+1秒中位数 | 原生缓存暂停逐轮 |
| --- | --- | ---: | ---: | --- |
| `BV1ikaZ6rELU` / smart | 1/1 | 0.9601 | N/A | 1:measured/0次/0.0000秒 |

[完整原始报告](/Users/Admin/Downloads/PiliPlus-CDN-P0/outputs/cdn-three-diagnostic-5436/pilot/diagnostic-off-1/report.json)；SHA-256 `fc4fc66f957c750e204142ef219224424721e846d8ee9b44dae4dc885fd1568f`。

## pilot-diagnostic-off-2

状态 `completed`；预计划 1，状态分布 `{"measured": 1}`。本情景内按各视频/模式分别统计，中位数只用 measured 且缓存观测已知的轮次。

| 视频 / 模式 | 有效且缓存已知 / 计划 | 起播中位数秒 | 首个seek+1秒中位数 | 原生缓存暂停逐轮 |
| --- | --- | ---: | ---: | --- |
| `BV1ikaZ6rELU` / smart | 1/1 | 1.3608 | N/A | 1:measured/6次/31.2282秒 |

[完整原始报告](/Users/Admin/Downloads/PiliPlus-CDN-P0/outputs/cdn-three-diagnostic-5436/pilot/diagnostic-off-2/report.json)；SHA-256 `c5c3c8e017d6877a921e48dedaf1ba0d6761b6dd82941fc17dd0fb90b79a5717`。

## pilot-diagnostic-on-1

状态 `completed`；预计划 1，状态分布 `{"measured": 1}`。本情景内按各视频/模式分别统计，中位数只用 measured 且缓存观测已知的轮次。

| 视频 / 模式 | 有效且缓存已知 / 计划 | 起播中位数秒 | 首个seek+1秒中位数 | 原生缓存暂停逐轮 |
| --- | --- | ---: | ---: | --- |
| `BV1ikaZ6rELU` / smart | 1/1 | 0.9653 | N/A | 1:measured/0次/0.0000秒 |

[完整原始报告](/Users/Admin/Downloads/PiliPlus-CDN-P0/outputs/cdn-three-diagnostic-5436/pilot/diagnostic-on-1/report.json)；SHA-256 `35bc0a44237a8e326ba627d61fde396cb85f9899d4c7aed4d227f85a48d24a7d`。

## pilot-diagnostic-on-2

状态 `completed`；预计划 1，状态分布 `{"measured": 1}`。本情景内按各视频/模式分别统计，中位数只用 measured 且缓存观测已知的轮次。

| 视频 / 模式 | 有效且缓存已知 / 计划 | 起播中位数秒 | 首个seek+1秒中位数 | 原生缓存暂停逐轮 |
| --- | --- | ---: | ---: | --- |
| `BV1ikaZ6rELU` / smart | 1/1 | 1.0399 | N/A | 1:measured/0次/0.0000秒 |

[完整原始报告](/Users/Admin/Downloads/PiliPlus-CDN-P0/outputs/cdn-three-diagnostic-5436/pilot/diagnostic-on-2/report.json)；SHA-256 `eef84ba1dfd830fb73e878b135b663bbfbe47b66894022c10a719c512cbb8215`。

## pilot-original-after

状态 `completed`；预计划 1，状态分布 `{"measured": 1}`。本情景内按各视频/模式分别统计，中位数只用 measured 且缓存观测已知的轮次。

| 视频 / 模式 | 有效且缓存已知 / 计划 | 起播中位数秒 | 首个seek+1秒中位数 | 原生缓存暂停逐轮 |
| --- | --- | ---: | ---: | --- |
| `BV1ikaZ6rELU` / smart | 1/1 | 1.3590 | N/A | 1:measured/0次/0.0000秒 |

[完整原始报告](/Users/Admin/Downloads/PiliPlus-CDN-P0/outputs/cdn-three-diagnostic-5436/pilot/original-after/report.json)；SHA-256 `f1fc2809abcec5b1fa43827679d603872f1c890284dc4484a91774dbebfe5931`。

## pilot-original-before

状态 `completed`；预计划 1，状态分布 `{"measured": 1}`。本情景内按各视频/模式分别统计，中位数只用 measured 且缓存观测已知的轮次。

| 视频 / 模式 | 有效且缓存已知 / 计划 | 起播中位数秒 | 首个seek+1秒中位数 | 原生缓存暂停逐轮 |
| --- | --- | ---: | ---: | --- |
| `BV1ikaZ6rELU` / smart | 1/1 | 0.9454 | N/A | 1:measured/0次/0.0000秒 |

[完整原始报告](/Users/Admin/Downloads/PiliPlus-CDN-P0/outputs/cdn-three-diagnostic-5436/pilot/original-before/report.json)；SHA-256 `7835d45374d830465a8ed32b10b8f36eb8690e91b59d712f2c86cdb348dbb395`。

## ablation-equal60

状态 `completed`；预计划 30，状态分布 `{"measured": 30}`。本情景内按各视频/模式分别统计，中位数只用 measured 且缓存观测已知的轮次。

| 视频 / 模式 | 有效且缓存已知 / 计划 | 起播中位数秒 | 首个seek+1秒中位数 | 原生缓存暂停逐轮 |
| --- | --- | ---: | ---: | --- |
| `BV1ikaZ6rELU` / hw-direct | 2/2 | 1.7946 | N/A | 1:measured/0次/0.0000秒; 10:measured/0次/0.0000秒 |
| `BV1ikaZ6rELU` / fixed-h-auto | 2/2 | 1.0981 | N/A | 2:measured/0次/0.0000秒; 9:measured/0次/0.0000秒 |
| `BV1ikaZ6rELU` / fixed-h-smart | 2/2 | 4.1884 | N/A | 3:measured/0次/0.0000秒; 8:measured/0次/0.0000秒 |
| `BV1ikaZ6rELU` / pool-auto | 2/2 | 1.1814 | N/A | 4:measured/0次/0.0000秒; 7:measured/16次/91.2155秒 |
| `BV1ikaZ6rELU` / smart | 2/2 | 1.1051 | N/A | 5:measured/0次/0.0000秒; 6:measured/0次/0.0000秒 |
| `BV1yraR61EWN` / hw-direct | 2/2 | 1.6136 | N/A | 1:measured/0次/0.0000秒; 10:measured/2次/3.9699秒 |
| `BV1yraR61EWN` / fixed-h-auto | 2/2 | 2.0740 | N/A | 2:measured/0次/0.0000秒; 9:measured/0次/0.0000秒 |
| `BV1yraR61EWN` / fixed-h-smart | 2/2 | 4.1868 | N/A | 3:measured/0次/0.0000秒; 8:measured/0次/0.0000秒 |
| `BV1yraR61EWN` / pool-auto | 2/2 | 1.1380 | N/A | 4:measured/3次/37.6053秒; 7:measured/0次/0.0000秒 |
| `BV1yraR61EWN` / smart | 2/2 | 1.1603 | N/A | 5:measured/1次/2.7008秒; 6:measured/0次/0.0000秒 |
| `BV1TEhB6YEpH` / hw-direct | 2/2 | 2.5850 | 7.2003 | 1:measured/0次/0.0000秒; 10:measured/0次/0.0000秒 |
| `BV1TEhB6YEpH` / fixed-h-auto | 2/2 | 1.6168 | 3.3562 | 2:measured/0次/0.0000秒; 9:measured/0次/0.0000秒 |
| `BV1TEhB6YEpH` / fixed-h-smart | 2/2 | 1.6360 | 2.1767 | 3:measured/0次/0.0000秒; 8:measured/0次/0.0000秒 |
| `BV1TEhB6YEpH` / pool-auto | 2/2 | 0.9490 | 3.1189 | 4:measured/1次/0.0501秒; 7:measured/0次/0.0000秒 |
| `BV1TEhB6YEpH` / smart | 2/2 | 1.0421 | 2.1554 | 5:measured/0次/0.0000秒; 6:measured/0次/0.0000秒 |

[完整原始报告](/Users/Admin/Downloads/PiliPlus-CDN-P0/outputs/cdn-three-diagnostic-5436/ablation/report.json)；SHA-256 `6af847d1cc1beb6cf6eab27aef96bde7ebd25929154eacb59a0c85bb04d92271`。

## 解释边界

原生 passed 证明双轨解码与目标进度，不能解释为不卡。pause精确总数、seek restart、首次目标后1秒推进及额外15秒观察分别保留。原包旧探针 seek后仅1秒，其成功不证明恢复后15秒流畅。

起播阈值为 time-pos≥0.1秒，不是数学首次>0，也不包含API取源、代理准备和可见首帧/首音频。pre-seek字段覆盖整段观察；暂停位置与phase只由半秒时间线采样支持。BV1yra原包暂停位于约2.3秒，不能写成已经重现90秒后的问题。

CPU百分比是原生进程及其线程用量，可以超过100%，不是整机负荷；坏轮长等待会拉低累计平均，应同时查看CPU秒数及相邻半秒区间。请求hwdec与实际hwdec-current独立；estimated-frame-number不是精确解码帧数，缺失或null输出的drop指标不能替代GUI验收。

demux缓存范围仅对应main，不覆盖所有EDL音视频；范围外也不证明音频、系统或CDN无缓存。固定H的域名计数审计、raw内存负值/缺失、诊断读取量与成功flush的差异，以及暂停±2秒时序摘录见[机器附件](results/cdn-three-diagnostic-5436.json)。fullsmart已选初始主机不等于所有请求参与主机。

[官方0.36 ABI](https://raw.githubusercontent.com/mpv-player/mpv/v0.36.0/libmpv/client.h) 与[对应属性文档](https://raw.githubusercontent.com/mpv-player/mpv/v0.36.0/DOCS/man/input.rst)用于约束typed node/main范围解释；实际库版本和SHA另外保留。

## 因果分析

### 未缓冲 seek 是否正常

10轮跳转前，主demux报告范围约0～375秒，1200秒目标均在范围外；全部推进到目标+15秒。华为直连restart为7.2791/5.1005秒，并发为1.1004/1.1873秒。restart与表中目标后1秒的进度耗时不同。数秒网络取数和解码恢复可以正常发生，不能只因进度条或峰值速度认定故障；本轮并发恢复更短，但小样本和访问顺序不能证明恒定加速，也不能证明所有缓存层均冷。

### 供给不足与快测速的局限

`BV1ikaZ6rELU` 的pool-auto第7轮累计16次/91.2155秒暂停。同模式第4轮走华为连续流，35秒内容约35.97秒完成且零暂停；第7轮约127.41秒完成。第7轮Akamai中段256KiB资格请求从open到body_complete约40毫秒（约6.55MB/s，body-only窗口约9毫秒更高），实际连续视频响应约0.668MB/s。视频总大小267,919,299bytes/137秒，平均需求约1.956MB/s。进入Ali单路块恢复后，约26.74MB在50.60秒交付，约0.528MB/s，只够平均需求的27%。MB在此按1,000,000bytes计算；需求均值不是每个局部VBR窗口的精确需求。

首次耗尽在媒体8.6417秒、墙钟10.2729秒。前期没有排队或身份拒绝；代码在parallel=false时也跳过了持续低供给恢复条件，直到墙钟63.049秒连续响应超时才转块恢复。这是独立自动选源路径的实现缺口，不能直接归为并发本身的故障。等待时CPU区间中位数约0.43%，相同35秒内容的累计CPU工作量与健康轮接近，支持等待数据，而非持续软件解码饱和；不排除GUI或系统瞬时因素。

### 身份拒绝与取消等待延长恢复

同一坏轮在墙钟71.952秒，华为精确206 Range/总长度均相符，但其自身此前准入的ETag和Last-Modified均变化，被正确拒绝；随后cosov失败，Ali到79.692秒才补齐。71.339～79.692秒约8.353秒没有新的有序视频交付，对应媒体22.35秒处的缓存耗尽。华为失效发生在早期多次暂停之后，不能解释最初故障；样本校验通过也不证明它当时供给快。响应标记变化不证明内容变化或CDN冷缓存，安全检查不可删除。

两轮fixed-h-smart起播6.7998/7.0554秒均有相同链路：首请求无headers/字节，约3秒idle取消，约6秒才启动fallback，原请求约10秒才释放slot。代码等待openUrl/response.close没有立即感知Transfer取消。它使只有一个候选的选源继续等6秒上限，也让失败恢复占槽更久；不支持进一步区分DNS、TCP、TLS或服务端处理。

`BV1yraR61EWN` pool-auto第4轮的晚期暂停也符合“低供给先触发、拒绝与取消延长”的链路：媒体132.449秒前缓存从1.664秒降到0.064秒；Bos随后在墙钟159.034秒被身份检查拒绝，08c在162.037秒idle取消却到169.038秒才释放等待。157.933～170.717秒没有有序视频输出，最后由华为响应恢复。没有排队事件支持槽位饱和解释。

### 并发短暂停与仍未定位的边界

`BV1yraR61EWN` smart第5轮唯一暂停在媒体6.7734秒，2.7008秒；90～150秒段两次均零暂停。最初流供给几乎停止，5.944秒转块恢复；后块先到，先块在8.363秒才到，造成短时有序供给缺口。身份拒绝及首次排队均在该暂停之后，不能作为起因。候选输掉重复请求后代价更新不足是待验证线索，没有据此修改排序或宣称根治。

两次trace-on均零暂停，trace-off其中一次有6次/31.2282秒暂停；因此开启诊断不是异常必要条件，也未观察到稳定负向规律。各两次串行重复无法证明观测零扰动；trace-off仍含新的原生缓存/CPU采样。旧原生工具前后各一轮与新工具也不属于只改变trace的严格对照。

### 流量计数与待验修复

旧observed_upstream_body_bytes遗漏passthrough：例如fixed-H-smart坏起播轮只记2,972,646bytes音频，诊断却实际读取270,891,945bytes并交付267,919,299bytes视频及2,972,646bytes音频。另一轮也有相同漏记。不能把旧计数小解释为节省流量；机器附件分别保留legacy、诊断读取和flush数字。读取量仍不是TLS、取消未读数据或完整线路流量。

可控候选修复只针对取消感知等待、完整读取计数和自动选源的视频低供给恢复；音频阈值、身份检查与分块并发上限不放宽。是否落地及后续同视频验证另列，不以候选存在充当已验证修复。全站、长时间GUI、不同网络和校验标记漂移后的安全重新准入仍未完整验收。

后续已在源码提交 `cd0689c959…` 落地有限修复，并完成独立8轮原生复测与5437 macOS构建；见[恢复报告](cdn-recovery-20260930.md)。本文件仍保留42轮修复前阶段及全部异常，不以新阶段成功覆盖。
