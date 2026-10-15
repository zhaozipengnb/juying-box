# drpy Spider 引擎（M2）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** 支持 type 3 drpy JS 插件站点（Web 容器跑 drpy2.min.js + ext 插件），UI 零改动接入 5 个 drpy 站。

**Architecture:** DrpyDriver(SiteDriver) ↔ DrpyWebBridge(单例 Web 容器) ↔ drpy_shell.html(本地壳：module 加载 drpy2+ext、fetch 劫持走 ArkTS 网络代理、__drpy.call 分派)。

**Tech Stack:** ArkTS Web 组件（registerJavaScriptProxy + runJavaScriptExt）、rawfile 壳页面、hypium 单测。

**Spec:** `.claude/specs/2026-10-15-drpy-spider-design.md`

## Global Constraints

- SiteDriver 接口签名不得改动（common/src/main/ets/engine/SiteDriver.ets）
- ArkTS 严格模式；UI 文件（pages/）本阶段不改动（除 AppState.buildDriver 路由）
- 构建测试：`bash .claude/scripts/build.sh` / `bash .claude/scripts/test.sh`（免确认）
- 并行纪律（沿用）：并行实施者只写码不构建不提交；控制者统一构建/提交/评审
- 契约锁定（三 agent 必须逐字遵守）：

```typescript
// DrpyWebBridge.ets 导出契约（Task 1 实现，Task 3 消费）
export class DrpyWebBridge {
  static instance: DrpyWebBridge;
  // 加载运行时+插件并 init；重复调用同 skey 幂等，不同 skey 重新 init
  async ensureReady(cfg: SiteConfig): Promise<void>;
  // 调用 DRPY 方法（'home'|'homeVod'|'category'|'detail'|'play'|'search'），args 为字符串参数，返回 JSON 字符串
  async call(method: string, args: string[]): Promise<string>;
  destroy(): void;
}
// 壳页面协议（Task 2 实现，Task 1 依赖）
// ArkTS→JS: globalThis.__drpy.init(cfgJson) / __drpy.call(method, ...args) —— 由 runJavaScriptExt 执行，返回 JSON 字符串
// JS→ArkTS 网络: window.arktsReq.__req(id, url, optsJson) 同步入队；ArkTS 完成后 runJavaScriptExt 执行 __arktsResolve(id, resultJson)
//   resultJson: {"status":number,"body":"<base64>","headers":{...}}
//   JS 侧 fetch 劫持：window.fetch = async (url, opts) => {入队→等待 window.__results[id]→new Response}
```

---

### Task 1: DrpyWebBridge —— Web 容器与消息桥（agent B）

**Files:** Create `entry/src/main/ets/spider/DrpyWebBridge.ets`
**Interfaces:** 实现上述契约；内部含 req 转发（id→Promise 映射 + runJavaScriptExt 回传解析）、call 超时 10s、req 超时 15s、destroy 清理。

- [ ] Step 1: 实现（Web 组件挂后台 Stack、off-screen 1x1、javaScriptAccess、registerJavaScriptProxy(this) 注册 arktsReq、onPageEnd 无操作；ensureReady 逻辑：首次加载 `rawfile/drpy_shell.html`，完成后 runJavaScriptExt 执行 `__drpy.init(cfgJson, drpyUrl, extUrl)`——**注意**：drpy2/ext 的 module import 由壳页面按 query 参数处理改为 runJavaScriptExt 动态 import（壳页面固定无参数版），具体：`__drpy.init` 内部 `await import(drpyUrl)` 动态加载 + `import(extUrl)`，cfg 传给运行时 init）
- [ ] Step 2: 构建 + 冒烟（App 启动不崩即可，桥的完整链路在 Task 4 集成验证）
- [ ] Step 3: 提交 `feat(entry): DrpyWebBridge Web 容器与消息桥`

### Task 2: drpy_shell.html —— 壳页面与 fetch 劫持（agent A）

**Files:** Create `entry/src/main/resources/rawfile/drpy_shell.html`
**Interfaces:** 实现上述壳页面协议；`__drpy.init(cfgJson, drpyUrl, extUrl)` 动态 `import()` drpy2 与 ext（ext 若空则跳过，cfg.ext 传给运行时 init）；`__drpy.call(method, ...args)` 分派到默认导出对应函数、JSON.stringify 返回；fetch 劫持（入队→等待 __results→new Response（body 为 base64 时 atob 转字节流））；__arktsResolve(id, resultJson) 写入 __results 并 resolve。

- [ ] Step 1: 实现（纯 HTML/JS，无需构建；语法自查）
- [ ] Step 2: 提交 `feat(entry): drpy 壳页面与 fetch 劫持`

### Task 3: DrpyDriver + type 路由 + 单测（agent C）

**Files:** Create `entry/src/main/ets/spider/DrpyDriver.ets`、`entry/src/test/DrpyDriver.test.ets`；Modify `entry/src/main/ets/state/AppState.ets`（buildDriver 路由）、`entry/src/test/List.test.ets`
**Interfaces:** `DrpyDriver implements SiteDriver`（构造 SiteConfig + 可注入 bridge）；categoryContent 解析 DRPY category 返回（`{list:[{vod_id,vod_name,vod_pic,vod_remarks}],page,pagecount}` → PageResult）；home → HomeContent；detail → MovieDetail（vod_play_url 解析复用 CmsJsonApi 的 `$$$`/`#`/`$` 约定 + resolvePlayUrl 语义——**直接实现同逻辑**）；play → Episode.url（取返回 JSON 的 url 字段）；search → PageResult。
- [ ] Step 1: 写失败单测（fake bridge：固定 JSON 返回，断言解析正确性——home/category/detail/play/search 五用例 + type 路由用例：AppState.buildDriver 对 type 3 配置产出 DrpyDriver）
- [ ] Step 2: 跑测试红
- [ ] Step 3: 实现
- [ ] Step 4: 跑测试绿（27+新增全绿）
- [ ] Step 5: 提交 `feat(entry): DrpyDriver 与站点类型路由`

### Task 4: 集成端到端（控制者）

- [ ] 统一构建（T1+T2+T3 合入）
- [ ] 模拟器走查：切「聚玩盒子4K」（drpy 站）→ 首页 → 分类 → 详情 → 播放，截图留档
- [ ] 全量单测回归 + 提交 + 最终评审
