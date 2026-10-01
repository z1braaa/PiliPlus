# PiliPlus 协作入口

本仓库的已实现并发 CDN V2 记录在 [docs/parallel-cdn-playback-v2.md](docs/parallel-cdn-playback-v2.md)。后续需求从 [docs/requirements/README.md](docs/requirements/README.md) 进入，实施与验收约定见 [docs/harness/README.md](docs/harness/README.md)。

- 开始某项工作时，先在 [需求追踪表](docs/harness/traceability.md) 找到 ID，核对当前实现、证据级别和对应验收。对未列明的新范围，先补需求和验收口径。
- 区分“已实现”“规划中”“已验证”和“未运行”。静态脚本中出现的接口只是线索，不能写成已经验证的请求协议或完成的功能。
- 播放器沿用 Flutter / media_kit / mpv。点播以 docs/requirements/11-measured-cdn-and-battery.md 的实测驱动修订为准：旧大陆优先和固定路数已降为建议，自动选源与手选 CDN 互斥，并发可独立使用。直播界面增强保持默认关闭、独立于 CDN。
- 提交实现时，按需求 ID 更新追踪表与验证记录。性能收益必须有目标网络的对照数据；礼物、入团、点亮、购买和续订的结果必须由实际服务端状态确认，不能凭静态线索或本地界面状态宣称成功。
