# 5444 Android与macOS GitHub交付

2026-10-04，用户在[5444本机构建](android-macos-build-5444.md)完成后授权上传GitHub。对应BUILD-REL-04，补充范围见[交付需求](../requirements/16-cross-platform-release.md)。目标仓库为`z1braaa/PiliPlus`，分支`codex/live-task-watch`，标签`v2.1.5-live-intimacy-5444`，发布为预发行版。状态：准备提交、推送和附件上传。

安装包沿用已通过独立验包的四个5444成品，不重建、不改动。构建时基线58cd844131171ce1997738ca6770b1d422d22b90，产品源码当时尚未提交，1475项共同文件规范化摘要beecda9fb716e5749a98171074a59b678aabcaf2815d53eb1e1f7caf7c9a3c17；物理源码清单摘要051f268fa03c93a42637d08137e0eccdb8a9b5426c7df3fd64eca18a9417d27f。将保存构建之后的源码快照提交并与共同输入逐项核对。该新提交通过`source_snapshot_commit`单独标识，不冒称包内旧hash发生变化。

计划八项公开附件：Android三个ABI APK、macOS通用DMG、source-manifest.json、release-manifest.json、verification-summary.json和SHA256SUMS.txt。公开校验清单只覆盖对应七个公开文件，源码清单、汇总与验证摘要使用同级路径，不依赖本机verification目录。安装说明与功能验收限制写入Release正文。

发布先为草稿，附件实际上传及逐一回读验证完成后再发布；源码推送、标签、发布状态、八项附件大小和SHA256需回读确认。历史5442发布保留。当前功能实现和真实测试缺口继续见[亲密度新版实施验收](live-intimacy-revision-20261003.md)，本轮上传不增加设备安装或功能通过结论。
