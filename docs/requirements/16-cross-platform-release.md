# 三平台安装包与 GitHub 交付

2026-10-03 用户要求清除临时文件和旧安装包，生成 Android、Windows、macOS 安装包并上传用户 GitHub 仓库。本项已授权实施。发行号统一为 `2.1.5-LIVE-INTIMACY-QUEUE+5442`，功能沿用 [后台亲密度需求](15-live-intimacy-background-scheduler.md)，不扩大其真实平台验收结论。

| ID | 交付与最小验收 |
| --- | --- |
| BUILD-REL-01 | 同一固定源码提交与5442版本；Android Release APK覆盖arm64-v8a、armeabi-v7a、x86_64，核对包名、版本、签名、ABI、mpv和64位16KiB对齐；真实设备安装／功能未跑则明确标注 |
| BUILD-REL-02 | Windows x64原生Release构建；生成Inno Setup EXE安装器及portable ZIP；核对运行目录、AOT源码身份、PE架构、原生播放器、app-local MSVC运行库（至少msvcp140.dll、vcruntime140.dll、vcruntime140_1.dll）、文件摘要；在独立临时目录静默安装、逐文件比对并卸载，真实直播功能另列 |
| BUILD-REL-03 | macOS 13及以上通用DMG，所有Mach-O同时包含arm64／x86_64；核对版本、AOT源码身份、ad-hoc严格签名及只读挂载后的包内摘要；Apple公证未做则明确标注 |
| BUILD-REL-04 | 推送源码到用户fork工作分支，Release标签指向构建固定提交；三平台附件及SHA256清单收齐后统一发布预发行版；回读GitHub附件确认大小／摘要，不将安装包提交为Git大文件 |
| BUILD-REL-05 | 新包验证成功后删除已识别旧安装包、可重建构建缓存和临时打包目录；保留唯一新包、SDK共享依赖、历史验证证据、用户测试记录和原安装应用／配置；记录实际路径与回收大小 |

Windows使用仓库已登记的GitHub Actions工作流在本轮工作分支构建，Android与macOS使用彼此隔离的本地工作区及Flutter环境。所有平台的产物必须来自同一固定源码；后续仅新增验收文档的提交不能假称为包内编译源码。

本轮发行不读取本机登录账号，不发送弹幕／点赞，不执行付费操作。既有直播测试的通过、失败与未运行范围完整保留。Android本地测试证书、Windows未签名及macOS ad-hoc签名必须在下载说明明确披露。

## 2026-10-04 Android与macOS本机构建

用户在本版亲密度记录、双队列、统计和账号管理实施后要求编译Android和macOS版本。复用BUILD-REL-01、03的安装包验收及BUILD-REL-05的临时打包清理规则，交付号5444，显示版本2.1.5-LIVE-INTIMACY-REVISION。Android为三ABI APK，macOS为13+通用DMG，交付本机Downloads目录。

本次输入为隔离工作区当前未提交源码，与QA11产品源码清单一致；以1475项lib／assets／pubspec／lock文件的SHA256清单固定共同输入，并分别记录平台构建输入与恢复结果。包内传统提交标识指向基线提交，不能将基线提交当作本次新增功能提交。版本、共同清单、未提交状态、包内摘要、签名及未运行的设备验收随安装包交付。记录见[5444本机构建](../harness/android-macos-build-5444.md)。

## 2026-10-04 5444 GitHub交付

用户在本机构建完成后要求上传GitHub。复用BUILD-REL-04，将本版已实现源码提交至用户fork的现有`codex/live-task-watch`分支，发布5444预发行版，附件为已验证的三个Android APK和macOS通用DMG；本轮不新增Windows构建。

安装包保持原样，仍记录构建时基线及未提交状态。发布标签指向构建之后保存的源码快照提交，必须逐文件证明其1475项共同产品输入与已构建清单完全相同；用单独的`source_snapshot_commit`记录该关系，不能宣称包内传统hash已改为新提交或重新构建。公开附件附源码清单、脱敏验证摘要、发布汇总及对应文件SHA256；不上传本机原生配置备份、构建日志、账号副本或可重放会话。

先创建草稿并上传，核对GitHub附件集合、服务端摘要／大小，再实际回读全部附件核对本地摘要；通过后发布并再次检查标签、附件与预发行状态。历史5442发布保留。交付记录见[5444 GitHub上传](../harness/github-release-5444.md)。
