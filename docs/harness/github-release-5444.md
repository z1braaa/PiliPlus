# 5444 Android与macOS GitHub交付

2026-10-04，用户在[5444本机构建](android-macos-build-5444.md)完成后授权上传GitHub。对应BUILD-REL-04，补充范围见[交付需求](../requirements/16-cross-platform-release.md)。仓库为`z1braaa/PiliPlus`，分支`codex/live-task-watch`，标签`v2.1.5-live-intimacy-5444`。状态：源码已提交推送，八项附件实际回读全部匹配，已发布为[5444预发行版](https://github.com/z1braaa/PiliPlus/releases/tag/v2.1.5-live-intimacy-5444)，发布后状态和附件摘要再次核对通过。

安装包沿用已通过独立验包的四个5444成品，不重建、不改动。构建时基线58cd844131171ce1997738ca6770b1d422d22b90，产品源码当时尚未提交，1475项共同文件规范化摘要beecda9fb716e5749a98171074a59b678aabcaf2815d53eb1e1f7caf7c9a3c17；物理源码清单摘要051f268fa03c93a42637d08137e0eccdb8a9b5426c7df3fd64eca18a9417d27f。构建后源码快照为[71eb652697a2d8d32f7df8b41f230bc2f4bda0a8](https://github.com/z1braaa/PiliPlus/commit/71eb652697a2d8d32f7df8b41f230bc2f4bda0a8)，主验证和独立验证分别读取其`git archive`，1475项路径及文件SHA256与构建清单完全相同，缺项、额外项和变化项均为零。该新提交通过`source_snapshot_commit`单独标识，不冒称包内旧hash发生变化。标签实际指向该快照；后续交付文档提交不改变标签，也不算重编译源码。

已发布八项公开附件：Android三个ABI APK、macOS通用DMG、source-manifest.json、release-manifest.json、verification-summary.json和SHA256SUMS.txt。公开校验清单覆盖对应七个公开文件，源码清单、汇总与验证摘要使用同级路径，不依赖本机verification目录。安装说明与功能验收限制写入Release正文，测试记录链接固定到源码快照。公开元数据未包含本机绝对路径、账号副本、凭据或可重放地址，原始构建日志及原生配置备份没有上传。

先以草稿上传八项附件，逐个核对服务端大小／SHA256，然后实际重新下载全部附件：八文件大小及SHA256均与本地相同，公开七文件校验清单和源码规范化清单再次核对通过。发布之后API确认draft=false、prerelease=true、正文一致、八项附件均uploaded且摘要相同，GitHub标签对象实际指向71eb652697a2d8d32f7df8b41f230bc2f4bda0a8。结果见[脱敏交付摘要](results/release-5444-github-summary.json)。草稿阶段通过release ID读取API；按标签读取的发布API只在发布后确认，不将草稿时的404当成上传失败。

临时回读目录已删除，八项临时副本逻辑135401552字节；本机四个原安装包、小型公开元数据和验证证据保留。交付目录的本地汇总已补充GitHub地址及源码快照，24项本地校验清单重新生成并验证；它与GitHub的七项公开校验清单分别覆盖各自文件集合。历史5442发布保留。当前功能实现和真实测试缺口继续见[亲密度新版实施验收](live-intimacy-revision-20261003.md)，本轮上传不增加设备安装或功能通过结论。

## 仓库首页说明

用户随后要求更新首页README并显著标注原应用入口，对应BUILD-REL-06。新说明介绍六类本分支扩展，原应用`bggRGjQaUbCoE/PiliPlus`位于开头的加粗引用块，保留上游及祖先项目／贡献者署名；多账号写为现有基础上的管理增强，个人观看历史统计及未验付费闭环未标为完成。22项链接均使用完整URL，7个源码／文档路径及两发布页实际核对可达；默认main无docs目录，因此不依赖其相对文档路径。

默认main仅更新README，提交d0d6066824bd4102b15ee4e29b5d7d6a5ce985f1；实现分支README提交396d92d00。GitHub Markdown API渲染确认原项目加粗链接位于首个功能标题前，表格与引用结构正确；两分支文件实际回读与本地逐字节相同，Git blob均为01314a962a40502a017f50e0487fade3ef1d0b83。结果见[首页验证](results/readme-homepage-20261004.json)。后续提交仅补交付文档，5444标签和安装包保持不变。
