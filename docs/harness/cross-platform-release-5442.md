# 5442 三平台交付记录

对应 `BUILD-REL-01`～`05`，需求见[三平台安装包与GitHub交付](../requirements/16-cross-platform-release.md)。版本 `2.1.5-LIVE-INTIMACY-QUEUE+5442` 已发布为[GitHub预发行版](https://github.com/z1braaa/PiliPlus/releases/tag/v2.1.5-live-intimacy-5442-r1)。本轮只修正Windows打包／运行库分发，不改变直播功能逻辑；安装包验收与真实直播功能验收分别记录。

## 构建与交付

固定编译源码 `2d6476dde19750dde197a723e94660e5c1fcb635`，标签 `v2.1.5-live-intimacy-5442-r1`。三平台均从该提交重建。源码已推送 `codex/live-task-watch`；后续验收文档提交不算包内编译源码。版本化环境／验证／摘要记录见[release-5442-summary.json](results/release-5442-summary.json)。

Windows使用[GitHub Actions run 37113592991](https://github.com/z1braaa/PiliPlus/actions/runs/37113592991)。首轮未发布候选 `1ed7ac690` 因缺少MSVC运行库被替换，旧CI已取消，小型反例记录保留。

| 平台 | 已验证结果与边界 |
| --- | --- |
| Android | 154.9秒Release构建；三ABI、包元数据、v2签名、ZIP／ELF、64位16KiB对齐、mpv／Flutter／AOT完整性通过，独立只读复核通过。1823个跟踪文件哈希未变，三AOT包含正式源码标识，旧候选标识不再存在。versionName2.1.5／versionCode5442、API24+／target37、com.example.piliplus；非debuggable但使用本地测试证书，不能覆盖不同证书官方包。实际设备安装／运行未验证 |
| macOS | 13+通用DMG，45个Mach-O均为arm64／x86_64，源码标识、ad-hoc严格签名、只读挂载后三关键文件摘要通过。构建期间使用macOS13部署目标及CocoaPods配置，七个跟踪native配置已原样恢复。未Apple公证；5442 GUI／真实直播未运行 |
| Windows | x64原生Release、ELF64 x86_64 AOT、版本2.1.5.5442及编译源码／显示标识通过。完整94文件payload；8个MSVC CRT均为14.51.36247.0、微软签名Valid且进入CMake manifest。EXE在独立目录实际静默安装、94文件摘要比对及卸载全部通过，install／uninstall exit0、注册清理确认；ZIP CRC、路径集合及94文件大小／SHA256再次全量比对通过。安装器NotSigned；应用GUI／真实直播未运行 |

本机唯一安装包副本在 `Downloads/PiliPlus-Release-5442`。GitHub八项附件（六包、SHA256清单、release-manifest）服务端摘要／大小匹配，全部重新下载回读匹配后发布。正式发布状态、标签提交与附件摘要再次回读确认。回读临时副本已清除。

| 文件 | SHA256 |
| --- | --- |
| PiliPlus-2.1.5-LIVE-INTIMACY-QUEUE+5442-android-arm64-v8a.apk | ad9c38410e05a1396f03523fadfdbf202238bf93246515a9cfc992c2dc70d581 |
| PiliPlus-2.1.5-LIVE-INTIMACY-QUEUE+5442-android-armeabi-v7a.apk | 4c7f6ffc2f0be06f7c3b7e179a8de1093fa951b8bbfef792602fd145d0be7ccf |
| PiliPlus-2.1.5-LIVE-INTIMACY-QUEUE+5442-android-x86_64.apk | 914234a8e02d53e1473ed6e805e785d9f8ece90cd2780ba08aef2d2334b6399a |
| PiliPlus-2.1.5-LIVE-INTIMACY-QUEUE+5442-macos-universal.dmg | 4fbb3a37e6f689b834b3f5736d0bf7e8ff5d96f9d86cafa1b93385612cfed02f |
| PiliPlus_windows_2.1.5-LIVE-INTIMACY-QUEUE+5442_x64_portable.zip | fee967f7469128400f80db407be77e23cabd7305347cb15428bffbef8ac5e8cc |
| PiliPlus_windows_2.1.5-LIVE-INTIMACY-QUEUE+5442_x64_setup.exe | b031e71474e530522f423f6f6bc548e539f1b58ee26b2f7748dbb27a03653098 |

## 功能验收边界

- 既有功能源码379项离线回归及51文件分析通过，见[后台队列记录](live-intimacy-scheduler-20261003.md)。本轮未修改Dart功能代码，按原生平台构建／包验证。
- 5440冷房官方观时0/10未增长；5441修正媒体请求头后同一样本0/10→2/10，但样本有前序观看／诊断状态，不能推断所有冷房都可累计。
- 单表情真实弹幕任务完成有证据；新版点赞节奏、两房顺序／抢占、三项全完成转房、系统休眠、真实多表情随机发送未验。
- Android实际设备安装／播放／直播与Windows应用启动／真实直播未运行。编译、安装与文件校验不升级这些功能结论。
- 下载说明已披露Android测试证书、Windows安装器未签名、macOS ad-hoc签名／未公证。

## 清理

累计已记录本地分配量清理 11,234,328,576 字节（约10.46GiB，按各路径删除前du统计），另删除约24.67MB逻辑大小的旧临时回滚快照。包括两轮build／flutter_build／hooks_runner、Pods／ephemeral、DMG打包目录、临时PowerShell／包源码下载、Windows误解压暂存及GitHub回读副本。最终清理12个精确路径，删除旧5441DMG及其过期摘要文件；本机只保留六个正式安装包。

Android临时managed worktree已归档，可恢复源码快照；当前功能worktree继续保留。共享Flutter／Android SDK／JDK／Gradle／Pub依赖、历史验证记录、用户测试文件、原安装应用与账号配置均保留。精确路径／删除分配量证据保存在本机 `verification/cleanup-report.json` 及相关小型验证记录。

GitHub删除旧5399macOS Actions安装包及新EXE／ZIP已验证的重复Actions附件共3项、132,453,721字节；删除后API回读确认。正式Release六包／两清单和小型Windows验证artifact仍保留。

Windows补包依据：[Flutter分发说明](https://docs.flutter.dev/platform-integration/windows/building#building-your-own-zip-file-for-windows)、[CMake InstallRequiredSystemLibraries](https://cmake.org/cmake/help/latest/module/InstallRequiredSystemLibraries.html)、[微软运行库部署](https://learn.microsoft.com/en-us/cpp/windows/determining-which-dlls-to-redistribute?view=msvc-170)。native CMake从编译器Redist目录发现Release库，与exe同级安装，再由fastforge／Inno封装完整目录。upload-artifact v7的archive:false单文件需按真实artifact文件名取原始响应；通用gh run download会误解包，原始EXE／ZIP最终摘要均匹配CI与GitHub。
