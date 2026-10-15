# drpy JS 插件引擎（Spider M2）设计

日期：2026-10-15
状态：已与用户确认

## 1. 目标

支持 TVBox 订阅中 type 3 站点的 drpy JS 插件形态（实测 xhztv.top/4k.json 含 5 个此类站点：聚玩盒子4K、360官源、网红直播等），使 UI 层零改动地加载其首页/分类/详情/搜索/播放。

**明确不做**：csp_ 前缀 jar 站点（38 个，依赖 Android dex，鸿蒙无法运行，留待逐站 ArkTS 重写）；py_ 插件。

## 2. 已确认的引擎事实（drpy2.min.js 实测）

- ES module，默认导出 `{init, home, homeVod, category, detail, play, search, proxy, sniffer, isVideo, DRPY}`
- `init(cfg)` 传入 `{skey, name, type, api, ext, ...}`（站点配置对象）
- 返回值为 **JSON 字符串**（home/category/detail/search 返回与 CMS 同构的 JSON：class/list/vod_play_url 等；play 返回 `{parse, url, header}`）
- **已知限制**：play 返回的自定义 header 在 MVP 中忽略（ArkUI Video 不支持自定义请求头；m3u8 直链场景实测够用）
- 内部网络请求 `req()` 基于全局 `fetch`（运行时查找 → 可用 window.fetch 覆盖劫持）
- ext 插件（如 douban.js）由运行时 `init` 时加载执行

## 3. 架构

```
entry/src/main/ets/spider/
├── DrpyWebBridge.ets    # Web 容器单例：加载壳页面、JS↔ArkTS 消息、runJavaScriptExt 封装
└── DrpyDriver.ets       # implements SiteDriver：桥接 DRPY 接口（init 懒加载、切站点重建）
entry/src/main/resources/rawfile/
└── drpy_shell.html      # 本地壳页面：module 加载 drpy2.min.js + ext、fetch 劫持、消息协议
```

- **壳页面流程**：`?url=<drpy2 url>&ext=<ext url>&skey=<key>` 参数由 ArkTS 注入 → 壳内 module import drpy2 → fetch 劫持生效 → `init(cfg)` → 报告就绪
- **fetch 劫持**：`window.fetch = (u, o) => postMessage('req', ...)` → ArkTS `httpFetch` → 回传 `{status, body(base64/text), headers}`；超时 15s
- **调用协议**（ArkTS → JS）：`runJavaScriptExt("globalThis.__drpy.call('category','1','1')")`；壳内 `__drpy.call` 按方法名分派并 `JSON.stringify` 返回；超时 10s
- **消息回传**（JS → ArkTS）：`this.webController` 不可从 JS 主动推——统一用 runJavaScriptExt 的 Promise 返回值（req 代理用 `registerJavaScriptProxy` 同步桥 + Promise 回调，或 runJavaScript 轮询——**实现取 registerJavaScriptProxy（同步调用 ArkTS，返回值直接回 JS）**：JS 侧 fetch 劫持为**同步代理阻塞不可行**——**修正**：fetch 劫持用 async 函数 + `runJavaScriptOnDocumentStart` 注入的 `window.__arkts_req` 由 registerJavaScriptProxy 提供（JS 调 ArkTS 同步方法返回不了异步结果）→ **最终方案**：JS 侧 fetch 劫持为 async，内部 `await window.__arktsReqAsync(id, url, opts)`（proxy 注册同步发消息到 ArkTS 队列），ArkTS 处理后调 `runJavaScriptExt("__arktsResolve(id, result)")` 回传——**标准异步桥模式**
- **DrpyDriver**：构造时接收 SiteConfig；首次调用任意接口时确保桥已 init 对应插件（skey 隔离，多 drpy 站复用同一 Web、按 skey 重新 init）
- **AppState.buildDriver**：`type===1 → CmsJsonApi`；`type===3 → DrpyDriver`（lazy：桥在首次调用时创建，避免冷启动开销）

## 4. 错误处理

- 桥层：runJavaScriptExt 失败/超时（10s）→ 抛 Error（含站点名）；req 代理超时 15s → fetch reject → 插件内部处理
- 插件加载失败（drpy2/ext 下载失败）→ 站点错误卡片（errMsg 含 http 状态）
- UI 层零改动（SiteDriver 接口 + 既有错误卡片）

## 5. 测试

- DrpyDriver/消息协议封装：单测（fake bridge 注入，断言调用序列与 JSON 解析）
- fetch 劫持/壳页面：模拟器端到端（聚玩盒子4K 真实站走查：首页→分类→详情→播放，截图留档）
- 回归：既有 27 用例不破坏

## 6. 并行实施拆分（3 agent，接口先行锁定）

| Agent | 文件所有权 | 依赖 |
|-------|-----------|------|
| A | drpy_shell.html（壳+fetch 劫持+__drpy.call 分派） | 消息协议定义 |
| B | DrpyWebBridge.ets（Web 容器/代理/超时） | 消息协议定义 |
| C | DrpyDriver.ets + AppState 路由 + 单测 | SiteDriver 接口 + B 的桥接口签名 |

消息协议与桥接口签名由计划书锁定（本文档 §3），三 agent 按契约并行。
