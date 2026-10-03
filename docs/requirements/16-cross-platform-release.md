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
