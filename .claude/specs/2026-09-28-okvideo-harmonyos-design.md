# OK影视 HarmonyOS（HAP）版 — 设计文档

- 日期：2026-09-28
- 状态：待评审（评审通过后进入实施计划）
- 项目根目录：`~/DevEcoStudioProjects/okvideo-hap`
- 参照蓝本：FongMi/TV-dev（GitHub 公开仓库，与 OK影视 同解析引擎）
- 验收测试订阅：`http://www.饭太硬.net/tv`（punycode：`www.xn--sss604efuw.net`）

## 1. 背景与目标

OK影视 是 TVBox 系（FongMi 影视TV 衍生分支）的开源影视聚合播放 App：本身不内置片源，通过用户配置的订阅地址聚合多个采集站与解析站点，内置播放器播放 m3u8/mp4，支持直播、投屏、下载、收藏、历史。

**目标**：在纯血鸿蒙 HarmonyOS NEXT 上原生复刻 OK影视，全功能对齐（一步到位），真机侧载自用。

**非目标（明确边界）**：

| 项 | 原因 |
|----|------|
| T4 Python Spider 站点 | 鸿蒙无 Python 运行时，不支持，命中即明确报错 |
| 上架华为应用市场 | 聚合类应用过不了审，仅侧载自用 |
| 电视/大屏端 | HarmonyOS NEXT 应用形态为手机/平板 |
| Cast+（华为系投屏） | 后续增强项，一期只做标准 DLNA |

## 2. 需求决策记录

| 决策点 | 结论 |
|--------|------|
| 参照物 | TVBox 系 OK影视（FongMi 引擎） |
| 目标系统 | 纯血鸿蒙 HarmonyOS NEXT（API 12+，DevEco Studio 6.x） |
| 功能范围 | 全功能一步到位（CMS/Spider/嗅探/直播/投屏/下载/收藏历史/多订阅） |
| 测试设备 | 真机侧载自用 |
| 参考源码 | FongMi/TV-dev 作蓝本 |
| 技术路线 | 方案 A：原生 ArkTS + C++ JSVM 完整移植 |

## 3. 真实数据依据（饭太硬订阅实测，2026-09-28）

设计期间对真实订阅做了完整解码分析，以下为实测结论（协议实现的硬约束）：

1. **订阅解码链**（四层，ConfigService 必须完整支持）：
   `HTTP 响应 = JPEG 图片` → 取 `\xff\xd9`（JPEG 结束符）之后的内容 → 去盐（当前实测 10 字符 `odvEMkqU**`；实现时按「尝试有限偏移直到解出合法 base64」启发式探测，不硬编码）→ base64 解码 → JSON5（含 `//` 行首注释、字符串/数字类型混用）
2. **站点构成**：47 个站点，**100% type 3（T3 Spider）**，93% 为 `csp_*` API（`csp_DouDouGuard` 等）——Spider 引擎是绝对核心路径
3. **spider jar 为 JPEG 伪装**：`spider` 字段指向 `https://…/xxx.jpg;md5;e959…`，下载后需在文件内定位 zip magic（`PK\x03\x04`）提取真正 jar
4. **ext 字段存在加密变体**（非标准 base64 形如 `5++kwLhNYm9UrO9wh7Dl7eKamTee4s/5`），需对照 TVBox 源码实现解密链
5. **宽松类型**：`type: '0'`、`playerType: "2"`（字符串数字混用）——模型层必须做类型归一
6. **lives**：6 组，m3u 直链 / php 动态接口 / 自定义 UA 均有；**parses: 0**（解析全在 Spider 内部完成，外部解析接口为低频兜底路径）
7. **playerType=2 大量出现**：须尊重该字段走 Web 播放路径
8. 站点名含 emoji（`📔厂长┃不卡`），UI 需支持
9. 注：spider jar 源站 file.icve.com.cn 在设计当时的开发机网络不可达，jar 内 JS 加密结构分析列入 M3 首项任务（真机网络可达）

## 4. 总体架构

```
┌────────────────────────────────────────────────┐
│ UI 层 (ArkUI)                                   │
│ 首页(站点切换+分类Tab+瀑布流) 搜索 详情 播放器   │
│ 直播 下载管理 收藏 历史 订阅管理 设置            │
├────────────────────────────────────────────────┤
│ 业务服务层 (ArkTS)                              │
│ SiteService PlayService LiveService            │
│ DownloadService CastService ConfigService      │
│ FavoriteService HistoryService                  │
├────────────────────────────────────────────────┤
│ 解析引擎层（统一接口，可替换）                   │
│ CmsJsonApi CmsXmlApi T3Spider(JSVM)            │
│ ParseApi Sniff(ArkWeb 嗅探)                     │
├────────────────────────────────────────────────┤
│ 基础设施层                                      │
│ rcp 网络 JSVM(C++ so) lexbor(HTML解析)         │
│ relationalStore 文件IO unzip                    │
└────────────────────────────────────────────────┘
```

### 4.1 工程结构（Hvigor 多模块）

| 模块 | 类型 | 职责 |
|------|------|------|
| `entry` | HAP | 全部页面 UI + 业务服务 |
| `common` | HAR | TVBox 协议模型（Config/Site/Movie/Result/Live…）+ 工具类 + 类型归一 |
| `spider` | HAR + C++ so | T3 JS 宿主：JSVM 初始化、宿主函数（req/pdfh/pdfa/pd）、jar 下载/解压/解密、lexbor 集成 |

不再细分模块，避免过度设计。

### 4.2 核心数据流

1. **配置流**：订阅 URL → 解码链（见 §6.1）→ sites/lives/parses/spider jar 地址 → 持久化 → 站点切换
2. **点播流**：分类列表（引擎）→ 详情（引擎）→ 播放地址（引擎 / parse 接口 / 嗅探）→ AVPlayer / Web 播放
3. **搜索流**：并发调用各站引擎 → 聚合分组展示
4. **直播流**：lives 配置（m3u/txt）→ 频道分组 → AVPlayer 播放 hls
5. **下载流**：直链/m3u8 → 分段并发下载 → 本地合并 ts

## 5. 关键技术选型与置信度（M1 第一周验证清单）

| 依赖点 | 选型 | 置信度 | 验证失败时的兜底 |
|--------|------|--------|-----------------|
| 带自定义头播放 | `media.createMediaSourceWithUrl(url, headers)` + AVPlayer（API 12+） | 高 | ArkWeb 内嵌播放 |
| JS 引擎 | NDK JSVM（QuickJS 系，API 12+） | 较高 | Web 组件内跑 quickjs-wasm |
| HTML/CSS 选择器 | C++ lexbor 进 NDK so | 高 | ArkTS 侧 htmlparser 移植 |
| 网页嗅探 | ArkWeb `onInterceptRequest` | 高 | 主动抓页面正则提取 |
| 网络库 | rcp（Remote Communication Kit） | 较高 | 回退 `@ohos.net.http` |
| DLNA | 纯 ArkTS 自研（UDP 组播 SSDP + rcp SOAP） | 高（协议成熟） | 砍控制能力只留投射 |
| SQLite | relationalStore | 高 | — |
| 解压 | `@ohos.zlib` / 自实现 zip 解析 | 高 | — |

验证方法：M1 每项写最小验证 demo（播放带头 m3u8 / JSVM 跑样例 JS / Web 拦截打印请求），真机确认后才开始对应模块的正式编码。

## 6. 模块设计

### 6.1 配置与订阅（ConfigService）

- 订阅管理：多订阅增删改、当前订阅切换、剪贴板导入、URL 容错（IDN 域名自动 punycode）
- **内容格式探测**（逐层尝试，全部失败才报错）：
  1. 纯 JSON / JSON5（先剥行首 `//` 注释）
  2. base64（清非字母表字符）→ 再按 1 处理
  3. JPEG 伪装（取 `\xff\xd9` 后内容 → 去盐 → base64 → JSON5）
- 模型类型归一：string/number 互转（`type: '0'`、`playerType: "2"`）
- 订阅缓存原始内容 + 解码结果，离线可用
- spider 字段解析：`url;md5;process:format` 语法（jar 地址/校验值/处理参数）

### 6.2 站点引擎层

统一接口（所有引擎实现同一抽象，UI 无感知）：

```typescript
interface SiteDriver {
  getHomeContent(): Promise<Result>
  categoryContent(tid: string, pg: number, filter?: object): Promise<Result>
  detailContent(ids: string[]): Promise<Result>
  searchContent(key: string, quick: boolean): Promise<Result>
  playerContent?(flag: string, id: string): Promise<Result>  // 仅 Spider 类
}
```

类型分发（以 FongMi/TV-dev 源码为准）：

| 配置特征 | 引擎 |
|---------|------|
| `type 0/1` + api 为 http 采集地址 | CmsXmlApi / CmsJsonApi（MacCMS `?ac=list/videolist/detail`、`&wd=` 全协议） |
| `api` 以 `csp_` 开头 或 `type 3` | T3Spider（XPath/XBPQ 系本质是 jar 内 JS 类，统一走 Spider，不单独内置规则引擎） |
| `type 4` | 不支持，站点标记不可用并提示 |
| 播放 flag 命中 parses | ParseApi / JsonParse |
| 以上均无直链 | Sniff 嗅探兜底 |

### 6.3 T3 Spider 宿主（`spider` 模块，最高风险与投入）

```
spider 字段解析 → 下载 jar（JPEG 伪装支持：定位 PK\x03\x04）→ md5 校验
  → unzip → 站点对应 .js（明文/加密多变体，解密链对照 TVBox 源码逐一实现）
  → 注入 JSVM + 宿主全局函数：
      req(url, opts)                 → napi 线程安全函数转发 ArkTS rcp 执行
      pdfh/pdfa/pd(html, selector…) → C++ lexbor 直接执行（热路径不过桥）
      require()/local/readFile      → jar 内模块互引 + 沙箱存储
  → 站点调用：ArkTS → napi → JSVM 执行 js.homeContent(…)
      → 返回 JSON → ArkTS 反序列化为 Result
```

关键决策：

- **全局单 JSVM 实例，站点间串行执行**（quickjs 单线程模型，与 TVBox 一致）；整体调用跑在 worker 线程，`req` 网络期间异步让出，不卡 UI
- **跨语言粒度最小化**：一次 JS 生命周期调用返回完整 JSON，不做高频细粒度互调
- 解密失败/JS 崩溃的 jar/站点：捕获并标记「该站点暂不支持」，不崩溃、不影响其他站点
- M3 首项任务：分析饭太硬 jar 的真实加密结构（设计期源站不可达，见 §3 第 9 条）

### 6.4 播放调度（PlayService）

```
站点返回播放信息(直链/网页地址 + flag)
  ├─ playerType=2 → Web 播放页（ArkWeb 内嵌播放）
  ├─ flag 命中 parse 接口 → 解析接口返回直链 → 原生播放
  ├─ 直链 → 组装 header(站点 Referer/UA/Cookie) → createMediaSourceWithUrl → AVPlayer
  └─ 播放失败兜底顺序：①无 header 重试 ②parse 接口 ③ArkWeb 嗅探(rules 正则 + ads 过滤)
```

播放页能力：选集切换、倍速、上/下一集、画面比例、手势（亮度/音量/进度）、AVSession 后台播放、历史续播、片头片尾跳过设置。

### 6.5 直播（LiveService）

- 输入：lives 配置 + 用户手动添加 m3u/txt
- 解析器：m3u（`#EXTINF` tvg 属性）与 txt（`组名,#,#频道,链接`）双格式
- UDP/rtp 组播源检测到即提示不可播（鸿蒙支持有限）
- 交互：频道分组侧栏、频道收藏、记住上次频道；EPG 一期只读 m3u 内嵌 tvg-id

### 6.6 下载（DownloadService）

- mp4 直链：rcp 流式下载 + 断点续传
- m3u8：解析分片 → 3 并发下载 → ts 字节直接拼接（无需 ffmpeg）
- AES-128 加密分片：一期不支持（提示后跳过），绝大多数点播源不加密
- 任务队列持久化、重启可续、仅 Wi-Fi 开关

### 6.7 DLNA 投屏（CastService，纯 ArkTS 自研）

```
发现: UDP 组播 239.255.255.250:1900 SSDP M-SEARCH → 设备列表
连接: GET 设备描述 XML → AVTransport 控制地址
投射: SOAP SetAVTransportURI → Play
控制: Play/Pause/Seek/Stop
```

- 一期覆盖主流标准 DLNA 设备；需特殊 header 的直链部分设备拉不动时提示换源，**不做中转代理**（列为后续增强）
- 华为 Cast+ 列为后续增强

### 6.8 数据层

| 表/存储 | 用途 |
|---------|------|
| favorite | 收藏（站点/片ID/名/图/备注） |
| history | 历史（集数+进度，支持续播） |
| config | 订阅缓存 |
| download | 下载任务状态 |
| Preferences | 设置项 |

### 6.9 UI 页面清单（对齐 OK影视 手机版）

```
entry/src/main/ets/pages/
├─ Index.ets      首页：站点切换横滑 + 分类Tab + 影片瀑布流
├─ Search.ets     多站并发搜索 → 聚合分组结果
├─ Detail.ets     海报/简介/线路/选集/收藏/投屏/下载
├─ Player.ets     原生播放器
├─ WebPlayer.ets  Web 播放器（playerType=2 与嗅探宿主）
├─ Live.ets       直播分组频道
├─ Download.ets   下载管理
└─ Setting.ets    订阅管理/壁纸/播放设置
```

站点名含 emoji，列表组件须正常渲染。

## 7. 错误处理

- **站点级隔离**：单站引擎异常只标记该站不可用，不影响全局
- **订阅解码**：逐层探测，未知格式明确报错（不白屏）
- **超时与重试**：站点 timeout 字段（实测 10/15s）为默认，失败重试 1 次
- **Spider 沙箱**：JSVM 异常全捕获，转错误结果不崩进程
- **网络**：统一错误提示 + 重试入口

## 8. 测试与验收

- **单元测试**（hvigor test，CI 必跑）：订阅解码链（用本设计 §3 的真实样例做固定测试数据）、CMS 解析、m3u8 解析、DLNA 报文构造、类型归一
- **真机验收基线**（以饭太硬订阅为基准，数字按实测微调）：
  1. 47 站点全部列出
  2. ≥80% 站点可进详情、可出播放地址
  3. ≥70% 站点真机可播成功
  4. 直播 6 组加载、主流组播放正常
  5. 下载、投屏各通过 1 个真实源验收

## 9. 里程碑（实施顺序，计划阶段细化）

| 里程碑 | 内容 | 真机可验证物 |
|--------|------|-------------|
| M1 | DevEco 环境搭建 + 关键 API 验证清单（§5）+ 订阅解码链 + CMS 引擎 + 原生播放 | ① 饭太硬订阅解码成功，47 站点列表加载（此时 Spider 站不可播，属预期）② 用任意 CMS 采集源（type 0/1，用户自备或公测订阅）端到端播放成功 |
| M2 | 搜索聚合 + 嗅探播放 + 直播 + 收藏历史 | 直播可看、搜索可用 |
| M3 | T3 Spider 宿主（JSVM + lexbor + jar + 宿主函数），首项分析 jar 真实结构 | 饭太硬主流站点可播 |
| M4 | 下载 + DLNA 投屏 + 设置完善 + 打磨 | 全功能版本 |

## 10. 风险与对策

| 风险 | 等级 | 对策 |
|------|------|------|
| JSVM 与 quickjs 行为差异导致 spider 不兼容 | 高 | M3 前置攻坚；备选 Web 组件内 quickjs-wasm |
| jar 内 JS 加密变体解不开 | 高 | 对照 TVBox 解密链逐一实现；解不开降级标注 |
| `createMediaSourceWithUrl` headers 不生效 | 中 | §6.4 三层兜底链 |
| DLNA 设备碎片化 | 中 | 一期主流设备 + 标准 SOAP |
| 整体工程量大 | 高 | 里程碑推进，每步真机可验证 |

## 11. 合规边界

- 应用定位为**媒体聚合播放工具**（与 TVBox 相同）：不内置、不分发任何内容源；订阅地址由用户自行配置
- 仅限侧载自用学习，不上架应用市场；项目代码零片源数据
- 解码样例测试数据仅使用订阅格式的结构特征，不落盘任何站点内容数据
