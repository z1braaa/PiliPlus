# 定向恢复修复复测（5437候选，2026-09-30）

这8轮均完成指定原生观察，缓存暂停次数和时长均已知为0；有限的定向复测不构成全站、冷缓存或GUI流畅保证。

本轮是修复候选诊断桥接的8轮实网复测，实际配置为pool-auto 2轮、smart 6轮，与[42轮诊断](cdn-three-diagnostic-20260930.md)分别记录；此前41有效／1原包华为失败及所有负例仍保留。原包／观测版本／修复候选不合并中位数；最高实际画质和取源快照未换。发行包构建、GUI、账号原设置及凭据清理由独立记录验收。

| 视频 / 模式 | 有效且缓存已知 / 计划 | 候选起播中位秒 | 候选seek首+1秒 | 候选暂停逐轮 | 30轮诊断对应结果 |
| --- | --- | ---: | ---: | --- | --- |
| `BV1ikaZ6rELU` / pool-auto | 2/2 | 1.0710 | N/A | 1:measured/0次/0.0000s; 4:measured/0次/0.0000s | 4:measured/0次/0.0000s; 7:measured/16次/91.2155s |
| `BV1ikaZ6rELU` / smart | 2/2 | 0.9761 | N/A | 2:measured/0次/0.0000s; 3:measured/0次/0.0000s | 5:measured/0次/0.0000s; 6:measured/0次/0.0000s |
| `BV1yraR61EWN` / smart | 2/2 | 1.1128 | N/A | 1:measured/0次/0.0000s; 2:measured/0次/0.0000s | 5:measured/1次/2.7008s; 6:measured/0次/0.0000s |
| `BV1TEhB6YEpH` / smart | 2/2 | 1.3190 | 2.2655 | 1:measured/0次/0.0000s; 2:measured/0次/0.0000s | 5:measured/0次/0.0000s; 6:measured/0次/0.0000s |

## 实际恢复分支与非零故障

开启smart与实际使用分块多路分开记录。BV1ika的4轮视频均选中华为，仅4～5个上游请求，未出现stream_to_chunks或window事件；这些轮次验证健康连续流，未实网命中之前pool-auto慢Akamai分支。自动单流的低供给恢复须依赖独立确定性对照夹具及后续实网覆盖，不能凭本次2轮替代该分支验收。

BV1yra第2轮smart出现Akamai视频TimeoutException后切到分块，window依次1/2/4/8/4/2/1，共745个上游请求、原生缓存暂停0。BV1TE首轮low_supply后video window1/2/4；第二轮audio http恢复后window1/2，均完成seek后15秒且原生暂停0。这些是发生故障后的实际恢复证据，并非所有请求无故障。window是请求上限，不等于实际同时存在8个连接。

传输层仍保留BV1yra TimeoutException、BV1TE取消和HttpException。BV1ika的frame-drop可用最大值逐轮为10/10/14/11，decoder-drop为0；null输出不等于GUI掉帧。0缓存暂停不等于0请求失败或0掉帧。完整域名、选源与窗口事件、数量和截断见机器附件。

## 测量范围与身份

BV1ika观察35秒，模式顺序pool-auto／smart／smart／pool-auto；BV1yra两轮smart从0连续150秒；BV1TE两轮smart从0观察15秒后seek1200秒、继续目标后15秒。全组mpv网络60秒、桥接上游10秒、用户360s／200MiB缓冲、512KiB和自适应上限8。自适应开关均为true（应用默认值）；仅自动选源的视频低供给新分支也以该开关为条件，adaptive=false的手动策略没有由本轮验收。

核心SHA `e68379d82b87492daae0f29bb58a2e1ee4bf1f49cbff934c24fef6a1d4702413`；工具SHA `0635aae39070156729ec5b98c37513e1b1a40745690c728f9094de28bf0d326f`；编译桥接SHA `cdfb4efde0769b9fe35357ec919bf8b98429cbad481e57167f73738859fa68af`。包内同版Mpv SHA `07798b406023dc8de54d5f7f9abea57a646372df1517d7e0fb855dc5482f9c8c`，实际mpv0.36.0；release reference5436/f6只表示来源基准，并非本次候选代码身份。

False、True及None的post-seek标记现分别保留；不请求seek标为N/A，不重写42轮历史raw。首次目标+1秒推进不是完整15秒观察时间，也不能把全部seek等待当作缓存暂停。

主demux缓存范围不覆盖全部EDL音视频、OS或CDN缓存；CPU及空输出掉帧不代表GUI表现。初始缺值、trace截断和负内存原值保留。诊断读取包含passthrough，socket flush不是已解码播放，旧observed读数不能当作等量线路流量。

每组仍仅少量重复，同源快照此前已被访问，远端冷缓存与出口地理未证实；这8轮没有同时重新测试直接华为控制，不能用跨时段结果证明一般加速收益。

[机器附件](results/cdn-recovery-5437.json)保留全部8槽、按视频／模式的独立中位数、旧负例、raw报告／CSV SHA和本机路径，以及CPU／主缓存／有界暂停摘录。

[recovery-BV1ikaZ6rELU 完整报告](/Users/Admin/Downloads/PiliPlus-CDN-P0/outputs/cdn-three-diagnostic-5436/recovery/BV1ikaZ6rELU/report.json)；SHA-256 `61d4d421d45461cd0835b2492e02b410a130dd44dfa5fe231e74d1210b9f9819`。

[recovery-BV1yraR61EWN 完整报告](/Users/Admin/Downloads/PiliPlus-CDN-P0/outputs/cdn-three-diagnostic-5436/recovery/BV1yraR61EWN/report.json)；SHA-256 `763b0a2f905ce2cab35f4adbb910011adea4095e355389a91576e4541e9301ad`。

[recovery-BV1TEhB6YEpH 完整报告](/Users/Admin/Downloads/PiliPlus-CDN-P0/outputs/cdn-three-diagnostic-5436/recovery/BV1TEhB6YEpH/report.json)；SHA-256 `5b13ffbd729afa8804ddb942218b47070f1bfbf2c2fcd501c79054326beecd13`。

## 已交付修复与构建

应用源码提交 `cd0689c959ed07dd4558428e93d14948524820af` 与上述核心SHA一致。取消可以中断openUrl/response.close等待，及时释放名额并清理晚到请求/响应；自动选源且自适应开启的视频低供给通过已准入候选转为单窗口恢复，健康视频与低码率音频保持连续响应。passthrough补计实际读取字节，不放宽Range、总长度、各源validator、跨源样本或epoch验证。

独立原算法/修复对照中，旧取消在约3秒watchdog后仍等1005ms才释放，修复在取消后0–4ms释放；旧auto-only慢视频未触发低供给恢复，修复夹具已恢复，并验证健康流不切片、不一致peer拒绝、健康低码率音频不误切。86项传输用例在等价样式调整前通过，8项新增用例在最终源码重跑通过，11文件分析0问题；Python152项为151通过/1跳过，相关Flutter24项通过。初版私有编译错误与12项info均保留为已修复阶段历史，详见[分阶段夹具记录](results/cdn-recovery-fixtures-5437.json)。这些对照证明代码行为，不量化一般网络加速。

`2.1.5-CDN-AUTO-LIVE-RECOVERY+5437` macOS Release已构建：45个Mach-O均arm64/x86_64、最低macOS13、ad-hoc深度严格验签、只读DMG挂载一致性及包内源提交身份通过；包内Mpv SHA与本次原生测试一致。见[构建记录](results/cdn-recovery-macos-build-5437.json)。[测试包](/Users/Admin/Downloads/PiliPlus-CDN-P0/PiliPlus-2.1.5-CDN-AUTO-LIVE-RECOVERY+5437-macos-universal.dmg) SHA-256 `3446825904dd1aaef3f82433788ebe653c9a5fdb902d9f3a128b1497bcf384bd`。原安装及账号未覆盖，本次新包GUI未运行。

临时Cookie、签名素材、私有运行时及定位文件的清理和实际敏感值扫描见[独立隐私记录](results/cdn-three-diagnostic-privacy-5437.json)。

## 后续验收

NET-14/17完整体验仍为部分验收：默认16s/4MiB缓存、长期VBR与实际播放期限反馈、重复输掉请求后的候选代价更新、自身validator变化后的安全重新准入、GUI首帧/声音/硬解和其他网络/平台仍缺证据。不能删除身份检查来掩盖恢复问题。八轮成功不会覆盖先前42轮的负例，也不能替代较大同一时段华为配对对照。
