# PiliPlus 协作入口

本仓库的已实现并发 CDN V2 记录在 [docs/parallel-cdn-playback-v2.md](docs/parallel-cdn-playback-v2.md)。后续需求从 [docs/requirements/README.md](docs/requirements/README.md) 进入，实施与验收约定见 [docs/harness/README.md](docs/harness/README.md)。

- 开始某项工作时，先在 [需求追踪表](docs/harness/traceability.md) 找到 ID，核对当前实现、证据级别和对应验收。对未列明的新范围，先补需求和验收口径。
- 区分“已实现”“规划中”“已验证”和“未运行”。静态脚本中出现的接口只是线索，不能写成已经验证的请求协议或完成的功能。
- 播放器沿用 PiliPlus 的 Flutter / media_kit / mpv 路径；BTR 浏览器脚本和 Electron 注入只作参考。中国大陆候选优先、点播并发与手选 CDN 的互斥，以及直播界面增强默认关闭和独立于 CDN 的要求，均以需求文档为准。
- 提交实现时，按需求 ID 更新追踪表与验证记录。性能收益必须有目标网络的对照数据；礼物、入团、点亮、购买和续订的结果必须由实际服务端状态确认，不能凭静态线索或本地界面状态宣称成功。
