# OKVideo UI 层设计（MVP 全流程闭环）

日期：2026-10-14
状态：已与用户逐节确认

## 1. 背景与目标

引擎层（common 模块）已完成：订阅配置四层解码（`ConfigDecoder`）、TVBox 配置模型（`TvboxModels`）、站点驱动接口与 CMS JSON 实现（`SiteDriver`/`CmsJsonApi`）、视频数据模型（`VideoModels`）；entry 模块已有 `HttpClient.ets`（httpFetch 封装）。

UI 层目前仍是 DevEco 模板页（Hello World）。本设计目标：**第一版全流程最小闭环**——

> 输入订阅配置 → 站点切换 → 首页/分类浏览 → 搜索 → 详情 → 播放

## 2. 已确认的需求决策

| 决策点 | 结论 |
|--------|------|
| MVP 范围 | 全流程最小闭环（含播放器），站点管理/收藏/历史后续迭代 |
| 配置输入 | 手动粘贴订阅链接（引擎支持任意格式四层解码） |
| 多源 | 支持站点切换（首页顶部选择器） |
| 架构 | 方案 A：Navigation 页面栈 + 状态管理 V2 + ArkUI Video 组件 |

## 3. 整体架构

```
entry/src/main/ets/
├── pages/
│   ├── Index.ets          # Navigation 根容器（改造现有模板页）
│   ├── ConfigPage.ets     # 粘贴订阅链接 → 解码 → 存储 → 进首页
│   ├── HomePage.ets       # 站点切换器 + 分类 Tabs + 影片网格 + 搜索框
│   ├── DetailPage.ets     # 海报/简介/播放线路/剧集列表
│   └── PlayerPage.ets     # 全屏 Video 播放
├── state/
│   └── AppState.ets       # @ObservedV2 全局状态
└── net/HttpClient.ets     # 已有，fetchText 适配引擎 FetchText 签名
```

- **导航**：`Navigation(NavPathStack)` + NavDestination。首屏条件化：preferences 无配置 → ConfigPage；有配置 → 直接 HomePage。Config/Home/Detail/Player 依次入栈。
- **模块归属**：全部页面在 entry；common 保持纯引擎不依赖 UI。
- **引擎对接**：页面只依赖 `SiteDriver` 接口。切换站点 = 用新 `SiteConfig` 重建 `CmsJsonApi` 实例，UI 不感知站点类型差异。

## 4. 状态管理与数据流

### AppState（@ObservedV2 + @Trace 单例）

```
AppState
├── config: TvboxConfig        # 解码后的订阅配置
├── currentSite: SiteConfig    # 当前选中站点
├── driver: SiteDriver         # 当前引擎实例（切站点时重建）
├── ready: boolean             # 配置就绪标记
└── errMsg: string             # 全局错误
```

### 数据流

```
ConfigPage：粘贴 URL → HttpClient.fetchText → decodeConfigContent
          → preferences 持久化（原始 URL + 配置 JSON）
          → AppState.config / currentSite=sites[0] / driver=new CmsJsonApi(...)
          → 入栈 HomePage

HomePage：getHomeContent() → 分类 Tabs + 推荐网格
          categoryContent(tid, pg) → 触底分页加载
          searchContent(key, false) → 搜索结果网格
          切站点 → AppState 重建 driver → 重拉首页

DetailPage：detailContent([vodId]) → 海报/简介/线路 Tabs/剧集列表

PlayerPage：Episode.url（经 CmsJsonApi.resolvePlayUrl 解析）→ Video 组件播放
```

- 页面内列表/loading/错误用 `@Local`；跨页面共享仅 AppState。
- 引擎无状态、MVP 不做缓存；每次用户动作即一次引擎调用。

## 5. 页面细节

| 页面 | 布局 | 交互 |
|------|------|------|
| ConfigPage | 居中输入框 + 说明 + 确认按钮 | 解码失败原地显示 `ConfigDecodeError` 信息；成功自动进首页；已有配置时显示当前源并可重新输入 |
| HomePage | 顶部：站点下拉 + 搜索框；下方：横向分类 Tabs + 双列网格（海报+名称+备注） | 换源/换分类/搜索均带 loading 重拉；List 触底加载下一页 |
| DetailPage | 顶部海报+元信息（年份/演员/导演）；中部简介（可展开）；底部线路 Tabs + 剧集按钮流 | 线路切换即切换剧集列表；点剧集入播放页 |
| PlayerPage | 全屏黑底 Video，自动播放 | 组件自带控制条；onError 显示错误 + 返回按钮 |

## 6. 错误处理

统一模式：所有引擎调用 `try/catch` → 页面 `@Local errMsg` → 页面内错误卡片 + **重试按钮**（不弹窗、不崩溃）。

- 配置拉取/解码失败：ConfigPage 原地提示
- 首页/分类/搜索/详情失败：对应页面错误态 + 重试
- 播放失败：Video `onError` → 播放页错误提示 + 返回
- 网络超时：依赖 HttpClient 既有超时配置

## 7. 持久化

- `@ohos.data.preferences`，key：`sub_url`（原始订阅地址）、`config_json`（TvboxConfig JSON）
- 启动时读取：`config_json` 存在且解析成功 → 跳过 ConfigPage
- 重新输入订阅 → 覆盖存储

## 8. 测试策略

- **单元测试**：配置存取封装、AppState 站点切换逻辑（沿用工程 `@Test` 习惯，hvigor TestFramework）
- **UI 验证**：模拟器探索性测试（hdc 构建→安装→启动→截图），链路已在本机打通

## 9. 明确不做（YAGNI）

收藏/观看历史、播放倍速与自定义控制条、扫码/推送、直播（LiveConfig）、解析接口（ParseConfig）页面化、多语言、深浅色主题定制。以上留待后续迭代。
