# 官方直播观看端模块调查：需求基准补充

调查日期：2026-09-23。此次只读抓取，未修改 PiliPlus 业务代码；未使用登录账号，未执行任何业务 API、送礼、入团、购买或佩戴动作。本文件于 2026-09-24 迁入项目文档，发现仍需在实施前复核。

## 结论与采用方式

直播增强功能的需求基准应来自**哔哩哔哩官方直播页及其实际加载的模块**，PiliPlus/BTR 仅作为现有能力和实现边界参考。此次从 [官方直播间](https://live.bilibili.com/6) 的 HTML 出发，沿页面直接引用与显式异步加载表读取相关 JS/CSS；没有全站爬取，也没有尝试绕过登录或风控。

已经确认官方页包含礼物控制区、弹幕输入区、勋章浮层、大航海入口、全屏礼物、SC 气泡等独立组件。粉丝团与大航海还有独立 H5 面板：页面自身通过 iframe 主机和事件桥接来承载，并非所有功能都由直播间主 Vue 组件独立完成。

建议将“直播界面增强（实验性）”作为**默认关闭、与 CDN 并发开关互相独立**的设置。关闭时沿用当前直播界面，不初始化新增面板、定时刷新、桥接或订阅；开启时按需加载用户实际打开的模块。送礼/支付/佩戴都是用户主动操作，开启增强界面不应自动触发。

## 证据等级与边界

- **已观察**：匿名 HTTP 200 返回的官方页面/资源、组件名、异步加载关系、端点文字、部分请求方法、任务字段和桥接事件。
- **静态推导**：由函数上下文识别读取或写入用途、页面模块之间的关系；本清单并不声明相应接口属于公开稳定 API。
- **未验证**：登录态真实 UI、当前房间是否具备各权益、实际参数约束、签名/CSRF/风控规则、付费下单、余额扣除、结果幂等、跨端回调、官方 Windows 客户端和所有灰度版本。

CSS/JS 下载成功不代表功能已在 PiliPlus 可用。`GET` 方法也不能独立证明请求没有副作用；以下只读取确认用途的候选将来仍需逐个核验。本次没有执行任何业务 API。

## 官方模块与我们需要的能力

| 官方观察 | 形态/证据 | PiliPlus 应纳入的需求 |
| --- | --- | --- |
| gift-control-panel | Vue 异步组件，S02:807312；主脚本存在新旧礼物面板 A/B 分支 | 礼物目录、分类、详情、数量、价格、目标主播、发送结果；以服务端可用项为准 |
| chat-control-panel | Vue 异步组件；单独 chunk 9649 | 弹幕输入、表情、勋章切换、SC 入口；错误与权限状态明确 |
| fans-medal-popover | Vue 异步组件；chunk 1357 | 查看勋章对应主播信息；勋章状态展示与操作分开 |
| guard-store | Vue 异步入口；chunk 6685，同时存在 H5 大航海入口 | 价格、权益、续费与有效期、协议与支付状态；受官方支持能力约束 |
| fullscreen-gift-control-vm | 独立全屏控制区 | 全屏仍能展开礼物与聊天，不遮挡主要播放区 |
| super-chat-bubble | 独立气泡组件和 SC 状态模块 | SC 队列、过期/撤下/审核状态、历史与发送流程 |
| fanspanel / viceroy H5 | 两个 URL 此次均返回同一 relation 应用入口（HTML 哈希相同；不意味着运行时页面相同） | 粉丝团、灯牌与大航海可评估原生页面或嵌入官方 H5；不应把外部跳转算作功能完成 |

具体组件定位以 machine manifest 中 M01–M09 为准；偏移基于保存的压缩资源，不是源码行号。

## 粉丝团、佩戴与灯牌需要分别设计

此次官方粉丝团面板发现 `task_info`、`is_lighted`、`free_intimacy`、等级、亲密度、特权与灯牌礼物信息。任务映射包含观看、发送弹幕、送礼、灯牌投喂、点赞、分享和大航海入口；它们是客户端支持的动作集合，**不表示每个账号、主播或地区都会返回全部任务**。

1. **勋章佩戴**：选中勋章 → 佩戴/摘下 → 等待服务端确认 → 更新输入区与消息样式。与点亮相互独立。
2. **粉丝团状态**：展示是否入团、等级、亲密度与每日/当前进度；领取、入团条件必须由官方返回数据决定。
3. **点亮灯牌**：官方 `feedLight` 动作会发出 `sendRelationFansGift`，或调用 `live_room_half.sendGiftDirect`。这是一条送礼链路，不能实现成更改本地 `is_lighted` 或自动重复发送。
4. **任务与奖励**：按服务端 `task_info` 渲染；切回面板刷新状态，避免根据按钮点击直接判定任务完成。客户端中发现的“三天”等文案仅属于此次资源版本，不硬编码为永远有效的业务规则。
5. **费用和结果**：操作前清楚展示礼物、数量、目标、费用与支付渠道；成功、失败和结果未知分别处理。结果未知不自动重试扣费。

## 已发现端点清单

所有端点均为**官方前端资源中的静态文字与调用上下文**，未验证真实响应合约。相对路径的所属服务/基础地址仍需在实现阶段核对，不应只凭此表直接编码。这里列出与需求直接相关的最小集合。

| ID | 用途 | 端点文字 | 观察方法 | 分类 | 精确定位：资源 ID:字符偏移 |
| --- | --- | --- | --- | --- | --- |
| E01 | 直播间礼物目录 | `/xlive/web-room/v1/giftPanel/roomGiftList` | 请求封装默认值，未确认 | 读取候选 | S02:969258 |
| E02 | 礼物分页/分类 | `/xlive/web-room/v1/giftPanel/tabRoomGiftList` | GET | 读取候选 | S02:968616 |
| E03 | 背包库存 | `/xlive/web-room/v1/gift/bag_list` | 请求封装默认值，未确认 | 读取候选 | S02:977627 |
| E04 | 礼物详情 | `/xlive/web-room/v1/giftPanel/getGiftDetail` | 请求封装默认值，未确认 | 读取候选 | S02:969345 |
| E05 | 金瓜子送礼 | `/xlive/revenue/v2/gift/sendGoldMultiUser` | POST | 写入/交易候选 | S02:1200170 |
| E06 | 银瓜子送礼 | `/xlive/revenue/v2/gift/sendSilverMultiUser` | POST | 写入/交易候选 | S02:1200213 |
| E07 | 背包送礼 | `/xlive/revenue/v2/gift/sendBagMultiUser` | POST | 写入/交易候选 | S02:1200268 |
| E08 | 用户勋章列表 | `/xlive/app-ucenter/v1/fansMedal/panel` | GET | 读取候选 | S06:107046 |
| E09 | 佩戴勋章 | `/xlive/app-ucenter/v1/fansMedal/wear` | POST | 写入候选（佩戴） | S06:107386 |
| E10 | 摘下勋章 | `/xlive/app-ucenter/v1/fansMedal/take_off` | POST | 写入候选（摘下） | S06:107764 |
| E11 | 勋章主播详情 | `/xlive/web-room/v1/index/getDanmuMedalAnchorInfo` | GET | 读取候选 | S05:5073 |
| E12 | 粉丝团进度与任务数据 | `/xlive/app-ucenter/v1/fansMedal/GetActivatedMedalInfo` | GET | 读取候选 | S13:113070 |
| E13 | 粉丝团成员榜 | `/xlive/general-interface/v1/rank/getFansMembersRank` | GET | 读取候选 | S13:113197 |
| E14 | 主播人气榜 | `/xlive/general-interface/v1/rank/getPopularAnchorRank` | GET | 读取候选 | S13:113254 |
| E15 | 大航海价格 | `/xlive/revenue/v1/guard/getGuardPrice` | GET | 读取候选 | S02:2934660 |
| E16 | 大航海订单 | `/xlive/revenue/v1/order/createOrder` | 本次未解析 | 写入/交易候选 | S07:28093 |
| E17 | SC 配置 | `/av/v1/SuperChat/config` | GET | 读取候选 | S06:30061 |
| E18 | SC 消息 | `/av/v1/SuperChat/getMessage` | GET | 读取候选 | S06:30181 |
| E19 | SC 删除 | `/av/v1/SuperChat/remove` | POST | 写入/交易候选 | S06:30144 |
| E20 | SC 订单 | `/xlive/revenue/v1/order/createOrder` | POST | 写入/交易候选 | S06:30099 |
| E21 | SC 审核回执 | `/xlive/general-interface/v1/superChat/ackForAudit` | POST | 写入/交易候选 | S02:255844 |

礼物目录还可观察到 roomGiftConfig、giftData、giftMessageV2 等不同版本入口；存在字面量不代表当前分支一定使用。背包属于账号私有状态，尽管资源请求封装未显式写 method，本次也没有尝试匿名调用它。

## 状态同步不能只做入口

主应用消息表中直接观察到 `SUPER_CHAT_MESSAGE_DELETE`、`COMBO_SEND`、`USER_TOAST_MSG`、`ROOM_REAL_TIME_MESSAGE_UPDATE`（manifest W01–W04）。需求应包含：礼物合并计数、重复消息消重、撤下/过期的 SC 清理、入团/大航海状态变化、断线重连后的状态校准。字符串存在不等于 payload 已核实，需以授权测试采样建立字段和版本兼容性用例。

## 原生与官方 H5 的两条实现路径

**原生 Flutter**：交互统一、可访问性和性能可控；代价是逐个维护接口、状态流转与官方变化。适合直播布局、消息区、礼物浏览、勋章展示、稳定可核验的基础交互。

**应用内官方 H5 面板**：官方本身也使用此模式，适合规则与支付变化频繁的粉丝团/大航海流程。可作为设计选项，必须先验证嵌入是否受支持、登录态隔离、导航限制、取消/关闭、回调以及状态同步；不能声称现在即可无缝嵌入。

已观察到的入口是 `https://live.bilibili.com/p/html/live-app-fanspanel/index.html` 与 `https://live.bilibili.com/p/html/live-app-viceroy/index.html`。可据此评估严格限定官方 HTTPS 页面及经过核验的必要资源源；不要把任意 `*.bilibili.com` 页面都自动赋予送礼或支付桥接能力。资源托管在 `s1.hdslb.com` 也不代表它应获得业务桥接权限。认证、消息来源校验和回调合约均仍未验证。

**验收口径**：用户能在应用内完成操作，并看到官方确认后的正确状态，才算对应功能完成；“点按钮后打开外部浏览器”只属于过渡入口。实际费用、支付验证、地区或账号限制仍由官方规则决定。

## 实施前的验收补充

- 默认关闭；未包含该设置的旧版升级后仍关闭，已显式保存的选择应保留；仅修改开关不触发送礼、入团或购买。
- 开关关闭时保留旧直播布局与控制项，新增模块不在后台继续刷新。
- 独立验证未登录、登录、未入团、未点亮、已点亮、背包为空、余额不足、关闭窗口、请求超时、状态未知和直播结束。
- 将“功能存在”“匿名资源可观察”“账号实测通过”“PC 客户端已对齐”分列，不能以模块数量代替功能等量验收。
- 免费/付费权益与价格均来自服务端；不照抄旧规则、默认价或静态任务期限。
- 列表展示可先行；付费流程须在认证、错误恢复和交易回执核验后单独验收。

## 抓取清单与复现

共读取 13 个相关官方资源：3 份 HTML、9 份 JS、1 份 CSS；不包含直播媒体和礼物图片，不继续递归抓取。原始快照当时保存于本机临时目录，**未纳入仓库，也不能假定仍可取得**；仓库只保留公开资源 URL、摘要、定位和必要模块/端点标识，不分发整套官方前端代码。复核偏移时，须重新取得与记录摘要一致的资源。

| ID | 官方源 URL / 本地文件名 | 字节 | SHA-256 |
| --- | --- | ---: | --- |
| S01 | [room-6.html](https://live.bilibili.com/6) | 95,461 | `f413d2e558ac0cb2d5e1b9c83928eac326ba2877db086f024811e4c77b1c1984` |
| S02 | [app.js](https://s1.hdslb.com/bfs/static/blive/blfe-live-room/static/js/app.3b48f866e1563d25d39c.js) | 3,525,464 | `fb51c9acf90afc446bc4a82ae6c5e55fc22ff5219aaf0f4cf152aa705506de82` |
| S03 | [bilibili.js](https://s1.hdslb.com/bfs/static/blive/blfe-live-room/static/js/bilibili.db8b38549c9cc2a44dc5.js) | 2,946,742 | `b4fa0b8cab5dd5c0fe178e3c22a882a88129a388983bb76c171f07f7e29eb4b6` |
| S04 | [app.css](https://s1.hdslb.com/bfs/static/blive/blfe-live-room/static/css/app.e4177406164a2f6a3f5c.vip.css) | 785,445 | `cf3e4e25ed0ff4075e90a77fb518c29a7ef14c12496831fa57a05898416dbf8a` |
| S05 | [chunk-1357.js](https://s1.hdslb.com/bfs/static/blive/blfe-live-room/static/js/1357.90ea2cfe3ee550109970.js) | 13,282 | `da9ce613bde900c7a05f7c6a3037c92fb596e472854b0848640197ff60e21fc5` |
| S06 | [chunk-9649.js](https://s1.hdslb.com/bfs/static/blive/blfe-live-room/static/js/9649.1063b9e512e83582c1bc.js) | 371,392 | `546a2c10db9cbb6ddb9195e93306b6714669bccdc022113fdbf5edca32a90aa8` |
| S07 | [chunk-6685.js](https://s1.hdslb.com/bfs/static/blive/blfe-live-room/static/js/6685.68c5e9483d5388688bbd.js) | 364,545 | `c8e2119971b9a0557d29844dc201e9dff24af3495494636bd5b66ec9f050163c` |
| S08 | [fanspanel.html](https://live.bilibili.com/p/html/live-app-fanspanel/index.html) | 4,328 | `47478b600b2cf677a1a3ac0cd276b242ddda298e7409635ece0abb9a9a24566f` |
| S09 | [viceroy.html](https://live.bilibili.com/p/html/live-app-viceroy/index.html) | 4,328 | `47478b600b2cf677a1a3ac0cd276b242ddda298e7409635ece0abb9a9a24566f` |
| S10 | [relation-index.js](https://s1.hdslb.com/bfs/static/blive/live-pay-mono/relation/relation/assets/index-CmJdpsDS.js) | 916,872 | `cc2fd1a787b94ea3558824e4738dd8afa9e9133d374fe50d11426551512a946b` |
| S11 | [FansHome.js](https://s1.hdslb.com/bfs/static/blive/live-pay-mono/relation/relation/assets/FansHome-CyGh9iPX.js) | 21,431 | `8311bfa0ca42d873070fb4d972c56d4a207764c7a8d2a108188b5dd9d84d3490` |
| S12 | [fansmedal-panel.js](https://s1.hdslb.com/bfs/static/blive/live-pay-mono/relation/relation/assets/fansmedal-panel-dwfR1anS.js) | 2,316 | `e03458d28621374476159717b7ea95c7f07101b90decf61414e6800469935a4e` |
| S13 | [reqfansGroup.js](https://s1.hdslb.com/bfs/static/blive/live-pay-mono/relation/relation/assets/reqfansGroup-Bj8HbEMm.js) | 114,286 | `86a2c88ed4eefd859ac0ee3b8f9f65e8407493f97865db8cf9489894ecee1ddf` |

机器证据索引：[official-live-module-manifest.json](official-live-module-manifest.json)。每条观察记录资源 ID、URL 可追溯的源条目、Unicode 字符偏移、UTF-8 字节偏移及必要模块/接口标识；`verified_api_contract` 一律为 false。URL 中构建哈希、模块拆分和功能灰度可能变化，未来实现前应重新从直播页解析入口，而不是长期硬编码这些资源文件名。
