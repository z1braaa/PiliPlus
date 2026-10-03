# 5442 三平台交付记录

对应 `BUILD-REL-01`～`05`，需求见[三平台安装包与GitHub交付](../requirements/16-cross-platform-release.md)。本轮不改变功能逻辑，统一版本 `2.1.5-LIVE-INTIMACY-QUEUE+5442`，同一源码构建；构建／安装包验收与真实账号／直播任务验收分别记录。

## 构建与交付

首轮候选源码为 `1ed7ac69038df07e8d9eaf904cfd2afdc2aadbcf`。审查发现 Windows 未随包分发 MSVC 运行库；首轮候选不发布，补齐后以新固定提交重建三平台。最终标签使用 `v2.1.5-live-intimacy-5442-r1`，源码及摘要在验收提交回填；旧标签保留首轮候选身份，不能当作最终发行源码。本轮源码准备包括Windows构建版本输入、原生产物验证及需求／验收文档，没有改动Dart功能逻辑。后续仅新增验收文档的提交不算包内编译源码。

| 平台 | 当前结果与边界 |
| --- | --- |
| Android | 230.5秒Release构建，三ABI均通过包元数据、v2签名、ZIP／ELF与64位16KiB对齐、mpv／Flutter／AOT完整性验证；独立只读复核通过。1823个跟踪文件哈希未变，三AOT均含固定源码标识。原生versionName2.1.5／versionCode5442，API24+／target37，包名com.example.piliplus；非debuggable但测试证书签名，不能覆盖不同证书官方包。实际设备未运行 |
| macOS | Release通用DMG已构建，最低macOS13；45个Mach-O全为arm64／x86_64，AOT源码标识、ad-hoc严格签名、只读挂载后的三关键文件摘要一致。没有Apple公证；5442原生GUI功能未运行，既有5441验收另列 |
| Windows | 构建准备YAML及官方PowerShell7.6.6语法解析通过；GitHub授权与分支推送已完成。首轮CI因缺少MSVC运行库已取消，补齐后重建并核对包内DLL、隔离安装／卸载 |

本地输出在 `Downloads/PiliPlus-Release-5442`；具体环境与最终文件摘要将统一写入版本化结果记录。

首轮未发布候选摘要（最终重建会更新）：

| 文件 | SHA256 |
| --- | --- |
| PiliPlus-2.1.5-LIVE-INTIMACY-QUEUE+5442-android-arm64-v8a.apk | 4aa11482b95177f017574a52ec88a7faa4e6f14ea7cd98ce2bcafa095608121e |
| PiliPlus-2.1.5-LIVE-INTIMACY-QUEUE+5442-android-armeabi-v7a.apk | 4a65e3f4e4a22cde20f0f16773d944dc6e56ec68b0fb5963e35672b8c55b557d |
| PiliPlus-2.1.5-LIVE-INTIMACY-QUEUE+5442-android-x86_64.apk | 3febcb168672c73279823a8b2c8268b7dc526a3cc1f9245e0e6d94fe49a96029 |
| PiliPlus-2.1.5-LIVE-INTIMACY-QUEUE+5442-macos-universal.dmg | db421b566b7c05b91d5d554e24990ec6b46f0284d3d31beef6ae6b34b91704c2 |

GitHub尚未正式发布。用户明确授权补充Workflow权限，已由用户本人完成账号验证；源码推送成功。首轮候选附件处于草稿，待最终三平台同源重建通过后替换、回读并统一发布。

## 已知验收边界

- 最终功能源码379项离线回归和51文件分析已通过，见[后台队列记录](live-intimacy-scheduler-20261003.md)。本轮未修改功能代码，按各平台原生编译验证。
- 5440冷房间官方观时0/10未增长；5441修正媒体请求头后同一样本复测0/10→2/10。该房间有先前诊断／观看状态，不能推断所有冷房间均可累计。
- 单表情真实弹幕任务完成已有证据；新版点赞节奏、两房顺序／抢占、三项全完成转房、系统休眠及真实多表情随机发送仍未验。
- Android设备上的安装／播放／直播任务与Windows真实直播功能未运行，不能凭编译成功宣称通过。
- Android本地测试证书、Windows无代码签名和macOS ad-hoc签名／未公证将随下载说明披露。

## 清理

已删除首轮构建的可重建临时目录约4.82GiB，另清除准备快照与临时工具；旧5441安装包在最终新包发布前保留。新一轮构建缓存及旧包待最终验证后统一清除并回填清单。共享SDK、账号配置、原应用、历史反例及用户记录保留。

Windows补包依据：[Flutter Windows分发说明](https://docs.flutter.dev/platform-integration/windows/building#building-your-own-zip-file-for-windows)、[CMake InstallRequiredSystemLibraries](https://cmake.org/cmake/help/latest/module/InstallRequiredSystemLibraries.html)及[微软可分发运行库](https://learn.microsoft.com/en-us/cpp/windows/determining-which-dlls-to-redistribute?view=msvc-170)。在native CMake安装阶段从编译器Redist目录发现Release库，并与exe一起安装；后续fastforge及Inno模板封装完整目录。新包通过实际DLL、CMake manifest、版本与摘要校验后才发布。
