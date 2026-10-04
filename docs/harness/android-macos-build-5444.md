# 5444 Android与macOS本机构建

2026-10-04，用户要求将已实现的本版代码编译为Android与macOS安装包。对应BUILD-REL-01、03及本机清理部分BUILD-REL-05，范围见[交付需求补充](../requirements/16-cross-platform-release.md)。状态：两个平台Release构建、封装、验包、独立复核和临时包清理已完成。

产品输入与QA11清单一致，1475项共同文件清单规范化SHA256为beecda9fb716e5749a98171074a59b678aabcaf2815d53eb1e1f7caf7c9a3c17。计算方式为对路径→文件SHA256字典使用Python `json.dumps(sort_keys=True, separators=(',', ':'))`，UTF-8编码后取SHA256；带缩进的交付文件`verification/source-manifest.json`本身SHA256为051f268fa03c93a42637d08137e0eccdb8a9b5426c7df3fd64eca18a9417d27f，两者分别记录，不混用。工作区codex/live-task-watch构建时基线为58cd844131171ce1997738ca6770b1d422d22b90，当时本版功能为未提交代码。传统包内提交标识是基线，不代表本轮新增功能的已提交身份。

版本号2.1.5／构建5444，显示版本2.1.5-LIVE-INTIMACY-REVISION。产物、源码清单及验证记录交付到[/Users/Admin/Downloads/PiliPlus-Release-5444](/Users/Admin/Downloads/PiliPlus-Release-5444)。Android覆盖arm64-v8a、armeabi-v7a和x86_64；macOS覆盖Apple Silicon与Intel，最低13.0。

本轮仅编译、封装和核对，不增加真实设备功能通过结论；本版已有回归与真实账号证据及剩余缺口见[实施验收](live-intimacy-revision-20261003.md)。本机构建不读取账号副本或运行自动互动。

## 安装包与验证

| 产物 | 字节数 | SHA256 |
| --- | ---: | --- |
| Android arm64-v8a APK | 24558523 | 65db19711411db8195de24f5d0b2dee147c664052cce00358bae106f365fc665 |
| Android armeabi-v7a APK | 24528273 | 60a39629c01d94dafb7350b0b77a5bddfe3a8ab146d418616cf1783d0ccedf01 |
| Android x86_64 APK | 25471454 | 67d5df510c38eab154b3450d325e91d947cf7ec36acf63f470d51d7f8c73d271 |
| macOS universal DMG | 60669584 | 3392643638412973b89feba836d8edfa1b9afd82073aba726a2415ffca80f0c2 |

Android使用Flutter 3.47.5／Dart 3.13.4、Java 17、SDK 37和NDK 28.2.13676358，离线Release构建104.516秒、退出码0。每个APK仅含相应ABI的7个原生库，含mpv；包名com.example.piliplus、系统版本2.1.5／5444、API 24及以上、target 37、非debuggable，包内AOT基线标识和显示版本已核对。v2签名及ZIP 16KiB对齐核对通过，全部64位ELF的PT_LOAD对齐为16或64KiB；32位库实际也为16或64KiB，仅记录值，不代替真实设备兼容性结论。签名使用本机既有测试证书SHA256 c4e037a40be304509e4e5bbecc8c8042a7566e9342a62b19bf7c757e23d2c335。实际重新校验5442三个APK后，证书、包名一致且构建号提高，具备覆盖升级的这些必要条件；真实安装升级未运行。

macOS Release构建退出码0，包名com.example.piliplus、系统版本2.1.5／5444、最低13.0。全部45个Mach-O均含arm64与x86_64，最低系统版本均不高于13.0；mpv及Flutter原生依赖随包交付。ad-hoc深度严格签名通过，DMG只读挂载后核心文件摘要和签名通过；Apple公证未做。安装和5444成品GUI／直播功能未运行。

两平台1475项共同输入在构建前后完全一致，Android额外1536项平台清单前后相同；本轮临时修改的原生配置已还原。验包未发现Hive账号存储文件。平台构建日志、原生恢复记录、逐库检查、5442签名比较和包摘要位于交付目录`verification/android`与`verification/macos`；共同输入及独立初审见`verification/build-input.json`、`verification/source-manifest.json`与`verification/independent-input-review.json`。

## 独立复核及清理

独立复核实际读取四个成品而非仅采信构建报告。Android逐包摘要、包名／版本／签名／ABI、7库ELF和ZIP对齐及无Hive检查通过；macOS独立校验DMG、只读挂载后对stage的359项完整目录（文件SHA256、权限、软链接）逐项一致，全部45个Mach-O的两个slice架构、最低系统版本和签名通过。独立挂载已卸载、临时mount目录已删除。报告见`verification/independent-android-review.json`、`verification/independent-macos-review.json`和`verification/independent-final-review.json`。

Android独立验包器第一次断言失败来自SDK37签名输出由`Signer #1`变为`V2 Signer`，旧解析器未匹配证书字段；实际v2验证成功。修正独立解析器后重跑三包通过，首次失败证据保留，APK与产品源码未改动、未重复编译。

四成品验证成功后清理以下精确路径，QA进程未运行；校验日志、原安装应用、账号设置、共享工具链和历史正式5442交付保留：

- `/Users/Admin/.cache/piliplus-tools/live-intimacy-revision-20261003/PiliPlus Intimacy QA.app`
- `/Users/Admin/.cache/piliplus-tools/live-intimacy-revision-20261003/android-build/PiliPlus-2.1.5-LIVE-INTIMACY-REVISION-QA+5443-android-arm64-v8a-pass9.apk`
- `/Users/Admin/Downloads/PiliPlus-Release-5444/verification/macos/package-stage`

实际已删除文件逻辑大小305986523字节，约292MiB；APFS可能共享数据块，未测量物理磁盘释放量。清理前目录清单摘要、文件数、删除原因和保留范围见`verification/cleanup.json`。交付目录保留[汇总清单](/Users/Admin/Downloads/PiliPlus-Release-5444/release-manifest.json)、[文件校验](/Users/Admin/Downloads/PiliPlus-Release-5444/SHA256SUMS.txt)和[安装说明](/Users/Admin/Downloads/PiliPlus-Release-5444/README.md)。

本轮文档链接及`git diff --check`检查通过，android／macos未留下临时原生源码变动。本机构建结束时尚未新建源码提交或上传5444安装包；用户随后授权上传，现已保存相同源码快照并发布GitHub，见[5444交付记录](github-release-5444.md)。构建时的基线、未提交状态和原验包记录保持历史事实。
