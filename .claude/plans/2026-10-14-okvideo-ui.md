# OKVideo UI 层（MVP 全流程闭环）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Hello World 模板页替换为完整 UI 闭环：订阅配置输入 → 站点切换 → 首页/分类浏览 → 搜索 → 详情 → 播放。

**Architecture:** Navigation(NavPathStack) 页面栈承载 4 个 NavDestination 页面；`@ObservedV2` 单例 `AppState` 持有 TvboxConfig/当前站点/SiteDriver 引擎实例；引擎通过 `httpFetch` 适配出的 `FetchText` 注入；preferences 持久化经可注入 `KVStore` 接口封装（纯逻辑可本地单测）。

**Tech Stack:** ArkTS（API 26，状态管理 V2：@ComponentV2/@Local/@ObservedV2/@Trace）、ArkUI Navigation/Video/Tabs/Grid、@ohos.data.preferences、hvigor CLI。

**Spec:** `.claude/specs/2026-10-14-okvideo-ui-design.md`

## Global Constraints

- ArkTS 严格模式：禁止 `any`、无类型对象字面量；所有 import 显式类型。
- `common` 模块保持零 `@ohos` 依赖；所有 UI/@ohos 代码只放 entry。
- 引擎导入一律走包名：`import { TvboxConfig, SiteDriver, CmsJsonApi, decodeConfigContent, HomeContent, PageResult, MovieDetail, Movie, SiteConfig } from 'common'`。
- 引擎事实（勿重复造）：`Episode.url` 已由 `CmsJsonApi.detailContent` 内部调 `resolvePlayUrl` 解析为完整 URL，UI 直接用；`FetchText = (url: string, headers?: Record<string,string>) => Promise<string>`；`httpFetch(url, opts)` 返回 `{ status, headers, body, text() }`。
- 代码注释用中文，与现有代码风格一致。
- 构建命令（本机 es2abc 已补丁，见记忆 `es2abc-deadlock-lvdun-fix`）：
  `export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk && export NODE_HOME=/Applications/DevEco-Studio.app/Contents/tools/node && export PATH="$NODE_HOME/bin:$PATH" && node /Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/bin/hvigor.js --mode module -p product=default -p buildMode=debug assembleHap`（下文简称「构建命令」）。
- 本地单测命令：`node .../hvigor.js --mode module -p module=entry@default test`（**校准点**：若任务名不匹配，先用 `.../hvigor.js tasks | grep -i test` 找到 RunLocalTest 类任务名再执行）。
- 安装启动验证：`hdc install -r entry/build/default/outputs/default/entry-default-signed.hap` 后 `hdc shell aa start -b com.okvideo.app -a EntryAbility`，截图：`hdc shell snapshot_display -f /data/local/tmp/s.jpeg` + `hdc file recv`。
- 提交信息格式：`feat(entry): <中文描述>`，尾注 `Co-Authored-By: Claude Code <noreply@anthropic.com>`。
- UI 页面任务（Task 3-8）无本地单测条件，以「构建→安装→启动→截图核对」替代 TDD 的验证环，同样不许跳过。

---

### Task 1: ConfigStore —— 配置持久化（KVStore 注入，纯逻辑可测）

**Files:**
- Create: `entry/src/main/ets/state/ConfigStore.ets`
- Test: `entry/src/test/ConfigStore.test.ets`
- Modify: `entry/src/test/List.test.ets`（注册新测试文件）

**Interfaces:**
- Consumes: `decodeConfigContent`、`TvboxConfig`（from 'common'）
- Produces: `interface KVStore { getSync(k: string): string | undefined; putSync(k: string, v: string): void; deleteSync(k: string): void }`；`class ConfigStore { constructor(store: KVStore); load(): StoredConfig | null; save(url: string, json: string): void; clear(): void }`；`interface StoredConfig { url: string; configJson: string }`；纯函数 `serializeConfig(url: string, config: TvboxConfig): string`、`parseStoredConfig(json: string): StoredConfig | null`（Task 2 依赖）。

- [ ] **Step 1: 写失败测试**

```typescript
// entry/src/test/ConfigStore.test.ets
import { describe, it, expect } from '@ohos/hypium';
import { ConfigStore, KVStore, serializeConfig, parseStoredConfig } from '../main/ets/state/ConfigStore';
import { decodeConfigContent } from 'common';

// 内存 KVStore 假实现（模拟 preferences 行为）
class FakeKVStore implements KVStore {
  private map: Map<string, string> = new Map();
  getSync(k: string): string | undefined { return this.map.get(k); }
  putSync(k: string, v: string): void { this.map.set(k, v); }
  deleteSync(k: string): void { this.map.delete(k); }
}

const SAMPLE_CONFIG = `{
  "sites": [{ "key": "k1", "name": "测试站", "type": 1, "api": "https://example.com/api.php/provide/vod" }]
}`;

export default function configStoreTest() {
  describe('configStoreTest', () => {
    it('serialize_then_parse_roundtrip', 0, () => {
      const cfg = decodeConfigContent(SAMPLE_CONFIG);
      const json = serializeConfig('https://sub.example.com/conf', cfg);
      const back = parseStoredConfig(json);
      expect(back).not.toBeNull();
      if (back !== null) {
        expect(back.url === 'https://sub.example.com/conf').assertTrue();
        expect(back.configJson.length > 0).assertTrue();
      }
    });
    it('parse_bad_json_returns_null', 0, () => {
      expect(parseStoredConfig('not-json')).toBeNull();
    });
    it('save_then_load', 0, () => {
      const cfg = decodeConfigContent(SAMPLE_CONFIG);
      const store = new ConfigStore(new FakeKVStore());
      store.save('https://sub.example.com/conf', serializeConfig('https://sub.example.com/conf', cfg));
      const loaded = store.load();
      expect(loaded).not.toBeNull();
      if (loaded !== null) { expect(loaded.url === 'https://sub.example.com/conf').assertTrue(); }
    });
    it('load_empty_returns_null', 0, () => {
      expect(new ConfigStore(new FakeKVStore()).load()).toBeNull();
    });
    it('clear_removes_entry', 0, () => {
      const store = new ConfigStore(new FakeKVStore());
      store.save('u', serializeConfig('u', decodeConfigContent(SAMPLE_CONFIG)));
      store.clear();
      expect(store.load()).toBeNull();
    });
  });
}
```

在 `entry/src/test/List.test.ets` 的 tests 数组中加入 `configStoreTest()`（import 同 List.test.ets 现有写法）。

- [ ] **Step 2: 跑测试确认失败**

Run: 本地单测命令（见 Global Constraints 校准点）
Expected: FAIL —— `ConfigStore` 未定义/模块不存在

- [ ] **Step 3: 最小实现**

```typescript
// entry/src/main/ets/state/ConfigStore.ets
// 配置持久化：preferences 依赖以 KVStore 接口注入，纯序列化逻辑可本地单测
import { TvboxConfig } from 'common';

export interface KVStore {
  getSync(k: string): string | undefined;
  putSync(k: string, v: string): void;
  deleteSync(k: string): void;
}

export interface StoredConfig {
  url: string;
  configJson: string;
}

const KEY_CONFIG = 'okvideo_stored_config';

export function serializeConfig(url: string, config: TvboxConfig): string {
  const stored: StoredConfig = { url: url, configJson: JSON.stringify(config) };
  return JSON.stringify(stored);
}

export function parseStoredConfig(json: string): StoredConfig | null {
  try {
    const obj = JSON.parse(json) as Record<string, Object>;
    const url = obj['url'];
    const cfg = obj['configJson'];
    if (typeof url !== 'string' || typeof cfg !== 'string') { return null; }
    return { url: url, configJson: cfg };
  } catch (e) { return null; }
}

export class ConfigStore {
  private store: KVStore;
  constructor(store: KVStore) { this.store = store; }
  load(): StoredConfig | null {
    const raw = this.store.getSync(KEY_CONFIG);
    if (raw === undefined || raw === '') { return null; }
    return parseStoredConfig(raw);
  }
  save(url: string, json: string): void { this.store.putSync(KEY_CONFIG, json); }
  clear(): void { this.store.deleteSync(KEY_CONFIG); }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: 本地单测命令
Expected: PASS（5 个用例全绿）

- [ ] **Step 5: 提交**

```bash
git add entry/src/main/ets/state/ConfigStore.ets entry/src/test/ConfigStore.test.ets entry/src/test/List.test.ets
git commit -m "feat(entry): ConfigStore 配置持久化（KVStore 注入可测）"
```

---

### Task 2: AppState —— 全局状态与引擎装配（fake 注入可测）

**Files:**
- Create: `entry/src/main/ets/state/AppState.ets`
- Test: `entry/src/test/AppState.test.ets`
- Modify: `entry/src/test/List.test.ets`

**Interfaces:**
- Consumes: `ConfigStore`/`StoredConfig`（Task 1）、`decodeConfigContent`/`TvboxConfig`/`SiteConfig`/`CmsJsonApi`/`SiteDriver`（'common'）
- Produces: `type AppPhase = 'initing' | 'config' | 'home'`；`@ObservedV2 class AppState { phase: AppPhase; config: TvboxConfig | null; currentSite: SiteConfig | null; driver: SiteDriver | null; subUrl: string; errMsg: string; static instance: AppState; makeFetchText(): FetchText; async loadFromUrl(url: string): Promise<boolean>; async initFromStore(store: ConfigStore): Promise<void>; switchSite(key: string): boolean }`

- [ ] **Step 1: 写失败测试**

```typescript
// entry/src/test/AppState.test.ets
import { describe, it, expect } from '@ohos/hypium';
import { AppState } from '../main/ets/state/AppState';
import { ConfigStore, KVStore } from '../main/ets/state/ConfigStore';

class FakeKVStore implements KVStore {
  private map: Map<string, string> = new Map();
  getSync(k: string): string | undefined { return this.map.get(k); }
  putSync(k: string, v: string): void { this.map.set(k, v); }
  deleteSync(k: string): void { this.map.delete(k); }
}

// 最小 CMS 站点响应（getHomeContent 会请求 ac=list）
const SITE_JSON = `{"class":[{"type_id":1,"type_name":"电影"}],"list":[]}`;

function makeFakeFetch(responses: Map<string, string>): (url: string, headers?: Record<string, string>) => Promise<string> {
  return async (url: string, headers?: Record<string, string>): Promise<string> => {
    const hit = responses.get(url);
    if (hit === undefined) { throw new Error('404: ' + url); }
    return hit;
  };
}

const SUB_JSON = `{"sites":[{"key":"a","name":"站点A","type":1,"api":"https://a.example/api"},{"key":"b","name":"站点B","type":1,"api":"https://b.example/api"}]}`;

export default function appStateTest() {
  describe('appStateTest', () => {
    it('loadFromUrl_success_to_home_phase', 0, () => {
      const app = new AppState();
      const responses: Map<string, string> = new Map();
      responses.set('https://sub.example/conf', SUB_JSON);
      responses.set('https://a.example/api?ac=list', SITE_JSON);
      app.testFetchText = makeFakeFetch(responses);
      // 覆盖真实网络：loadFromUrl 内部经 makeFetchText，测试注入直接替换
    });
  });
}
```

> 注意：ArkTS 本地单测无真网络，`loadFromUrl` 的网络分验证方式为：`AppState` 暴露受测钩子 `testFetchText?: FetchText`（生产代码为 undefined，构造真实 FetchText 时优先取它）。上例补齐断言：

```typescript
    it('loadFromUrl_success_to_home_phase', 0, () => {
      const app = new AppState();
      const responses: Map<string, string> = new Map();
      responses.set('https://sub.example/conf', SUB_JSON);
      app.testFetchText = makeFakeFetch(responses);
      app.loadFromUrl('https://sub.example/conf').then((ok: boolean) => {
        expect(ok).assertTrue();
        expect(app.phase === 'home').assertTrue();
        expect(app.config !== null).assertTrue();
        expect((app.config as TvboxConfig).sites.length === 2).assertTrue();
        expect(app.currentSite?.key === 'a').assertTrue();
        expect(app.driver !== null).assertTrue();
      });
    });
    it('loadFromUrl_bad_subscription_stays_config_with_err', 0, () => {
      const app = new AppState();
      const responses: Map<string, string> = new Map();
      responses.set('https://sub.example/conf', 'garbage');
      app.testFetchText = makeFakeFetch(responses);
      app.loadFromUrl('https://sub.example/conf').then((ok: boolean) => {
        expect(ok).assertFalse();
        expect(app.phase === 'config').assertTrue();
        expect(app.errMsg !== '').assertTrue();
      });
    });
    it('initFromStore_with_saved_config_goes_home', 0, () => {
      const app = new AppState();
      const responses: Map<string, string> = new Map();
      responses.set('https://a.example/api?ac=list', SITE_JSON);
      app.testFetchText = makeFakeFetch(responses);
      const store = new ConfigStore(new FakeKVStore());
      const cfg = decodeConfigContent(SUB_JSON);
      store.save('https://sub.example/conf', serializeConfig('https://sub.example/conf', cfg));
      app.initFromStore(store).then(() => {
        expect(app.phase === 'home').assertTrue();
      });
    });
    it('switchSite_rebuilds_driver', 0, () => {
      const app = new AppState();
      const responses: Map<string, string> = new Map();
      responses.set('https://sub.example/conf', SUB_JSON);
      app.testFetchText = makeFakeFetch(responses);
      app.loadFromUrl('https://sub.example/conf').then(() => {
        const before = app.driver;
        expect(app.switchSite('b')).assertTrue();
        expect(app.driver !== before).assertTrue();
        expect(app.currentSite?.key === 'b').assertTrue();
        expect(app.switchSite('nope')).assertFalse();
      });
    });
```

（文件顶部补 `import { decodeConfigContent, TvboxConfig } from 'common';` 与 `import { serializeConfig } from '../main/ets/state/ConfigStore';`；`app.driver !== before` 为实例比较，hypium 断言用局部布尔变量包装：`const changed = app.driver !== before; expect(changed).assertTrue();`）

在 `List.test.ets` 注册 `appStateTest()`。

- [ ] **Step 2: 跑测试确认失败**

Run: 本地单测命令
Expected: FAIL —— AppState 模块不存在

- [ ] **Step 3: 最小实现**

```typescript
// entry/src/main/ets/state/AppState.ets
// 全局状态（V2）：配置 + 当前站点 + 引擎实例。测试可注入 testFetchText 替代真网络。
import { TvboxConfig, SiteConfig, SiteDriver, CmsJsonApi, FetchText, decodeConfigContent } from 'common';
import { httpFetch } from '../net/HttpClient';
import { ConfigStore } from './ConfigStore';

export type AppPhase = 'initing' | 'config' | 'home';

@ObservedV2
export class AppState {
  static instance: AppState = new AppState();
  @Trace phase: AppPhase = 'initing';
  @Trace config: TvboxConfig | null = null;
  @Trace currentSite: SiteConfig | null = null;
  @Trace driver: SiteDriver | null = null;
  @Trace subUrl: string = '';
  @Trace errMsg: string = '';
  // 测试钩子：非 undefined 时替代真实 httpFetch（生产代码不设置）
  testFetchText?: FetchText = undefined;

  makeFetchText(): FetchText {
    if (this.testFetchText !== undefined) { return this.testFetchText; }
    return async (url: string, headers?: Record<string, string>): Promise<string> => {
      const r = await httpFetch(url, { headers: headers });
      return r.text();
    };
  }

  private buildDriver(site: SiteConfig): void {
    this.currentSite = site;
    this.driver = new CmsJsonApi(site, this.makeFetchText());
  }

  async loadFromUrl(url: string): Promise<boolean> {
    this.errMsg = '';
    try {
      const r = await httpFetch(url, {});
      const config = decodeConfigContent(r.body);
      if (config.sites.length === 0) {
        this.errMsg = '订阅中没有可用站点';
        this.phase = 'config';
        return false;
      }
      this.config = config;
      this.subUrl = url;
      this.buildDriver(config.sites[0]);
      this.phase = 'home';
      return true;
    } catch (e) {
      this.errMsg = e instanceof Error ? e.message : String(e);
      this.phase = 'config';
      return false;
    }
  }

  async initFromStore(store: ConfigStore): Promise<void> {
    this.phase = 'initing';
    const stored = store.load();
    if (stored === null) { this.phase = 'config'; return; }
    try {
      const config = decodeConfigContent(stored.configJson);
      if (config.sites.length === 0) { this.phase = 'config'; return; }
      this.config = config;
      this.subUrl = stored.url;
      this.buildDriver(config.sites[0]);
      this.phase = 'home';
    } catch (e) { this.phase = 'config'; }
  }

  switchSite(key: string): boolean {
    if (this.config === null) { return false; }
    for (const s of this.config.sites) {
      if (s.key === key) { this.buildDriver(s); return true; }
    }
    return false;
  }
}
```

> 实现注意：`loadFromUrl` 使用 `httpFetch(url).body`（ArrayBuffer）而非 `.text()` —— 订阅可能是 JPEG 伪装（`decodeConfigContent` 对 `Uint8Array` 才走 JPEG 分支），需 `new Uint8Array(r.body)` 传入。实现时写成 `decodeConfigContent(new Uint8Array(r.body))`。`switchSite` 后由 HomePage 监听 `driver` 变化重拉数据（Task 5）。

- [ ] **Step 4: 跑测试确认通过**

Run: 本地单测命令
Expected: PASS（4 个用例全绿）

- [ ] **Step 5: 提交**

```bash
git add entry/src/main/ets/state/AppState.ets entry/src/test/AppState.test.ets entry/src/test/List.test.ets
git commit -m "feat(entry): AppState 全局状态与引擎装配（fake 注入可测）"
```

---

### Task 3: Navigation 根容器（Index.ets 改造 + 路由表）

**Files:**
- Modify: `entry/src/main/ets/pages/Index.ets`（整体替换 Hello World）
- Create: `entry/src/main/ets/pages/ConfigPage.ets`、`entry/src/main/ets/pages/HomePage.ets`、`entry/src/main/ets/pages/DetailPage.ets`、`entry/src/main/ets/pages/PlayerPage.ets`（本任务先放最小骨架占位实现，Task 4-8 逐个替换为完整版）

**Interfaces:**
- Consumes: `AppState`（Task 2，phase 驱动首屏）
- Produces: 路由约定 —— `NavPathStack` 名称：`'Detail'`（param: `Movie`）、`'Player'`（param: `Episode`，附加字段 `siteKey` 用 `PlayerParam` 接口 `{ ep: Episode; siteKey: string }`）。各页面导出 `struct ConfigPage/HomePage/DetailPage/PlayerPage`（@ComponentV2）。DetailPage/HomePage 内通过 `this.pathStack: NavPathStack`（由 Navigation 实例传入 `NavPathStack`，页面用 `@Consume('nav')` 或构造参数——本计划统一用全局单例 `Nav.stack`）。
  - 额外创建 `entry/src/main/ets/nav/Nav.ets`：`export class Nav { static stack: NavPathStack = new NavPathStack(); }`（避免跨组件传递 stack 的样板代码）。

- [ ] **Step 1: 写最小骨架（四页 + 路由）**

```typescript
// entry/src/main/ets/nav/Nav.ets
export class Nav {
  static stack: NavPathStack = new NavPathStack();
}
```

```typescript
// entry/src/main/ets/pages/ConfigPage.ets —— Task 3 骨架，Task 4 替换
import { AppState } from '../state/AppState';

@ComponentV2
export struct ConfigPage {
  build() {
    Column() {
      Text('配置订阅（骨架）').fontSize(20)
      if (AppState.instance.phase === 'initing') { Text('加载中…') }
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
  }
}
```

```typescript
// entry/src/main/ets/pages/HomePage.ets —— Task 3 骨架，Task 5 替换
import { AppState } from '../state/AppState';

@ComponentV2
export struct HomePage {
  build() {
    Column() { Text('首页（骨架）').fontSize(20) }
      .width('100%').height('100%').justifyContent(FlexAlign.Center)
  }
}
```

```typescript
// entry/src/main/ets/pages/DetailPage.ets —— Task 3 骨架，Task 7 替换
import { Nav } from '../nav/Nav';

@ComponentV2
export struct DetailPage {
  build() {
    NavDestination() { Column() { Text('详情（骨架）') }.width('100%').height('100%').justifyContent(FlexAlign.Center) }
      .onReady((ctx: NavDestinationContext) => {})
  }
}
```

```typescript
// entry/src/main/ets/pages/PlayerPage.ets —— Task 3 骨架，Task 8 替换
@ComponentV2
export struct PlayerPage {
  build() {
    NavDestination() { Column() { Text('播放（骨架）') }.width('100%').height('100%') }
  }
}
```

```typescript
// entry/src/main/ets/pages/Index.ets —— 整体替换
import { AppState } from '../state/AppState';
import { Nav } from '../nav/Nav';
import { ConfigPage } from './ConfigPage';
import { HomePage } from './HomePage';
import { DetailPage } from './DetailPage';
import { PlayerPage } from './PlayerPage';

@Entry
@ComponentV2
struct Index {
  build() {
    Navigation(Nav.stack) {
      if (AppState.instance.phase === 'config') { ConfigPage() }
      else if (AppState.instance.phase === 'home') { HomePage() }
      else { Column() { Text('正在加载…') }.width('100%').height('100%').justifyContent(FlexAlign.Center) }
    }
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .hideToolBar(true)
    .navDestination(this.pagesMap)
  }

  @Builder
  pagesMap(name: string) {
    if (name === 'Detail') { DetailPage() }
    else if (name === 'Player') { PlayerPage() }
  }
}
```

- [ ] **Step 2: 构建并模拟器验证**

Run: 构建命令 → `hdc install -r .../entry-default-signed.hap` → `hdc shell aa start -b com.okvideo.app -a EntryAbility` → 截图
Expected: 应用显示「配置订阅（骨架）」（phase=initing→config，因 Task 2 的 initFromStore 尚未在 Ability 接线）

- [ ] **Step 3: 提交**

```bash
git add entry/src/main/ets/pages/ entry/src/main/ets/nav/Nav.ets
git commit -m "feat(entry): Navigation 根容器与四页路由骨架"
```

---

### Task 4: EntryAbility 接线 + ConfigPage 完整版

**Files:**
- Modify: `entry/src/main/ets/entryability/EntryAbility.ets`
- Modify: `entry/src/main/ets/pages/ConfigPage.ets`（替换骨架）
- Create: `entry/src/main/ets/state/PreferencesKVStore.ets`

**Interfaces:**
- Consumes: `AppState.initFromStore/store`（Task 2）、`ConfigStore`（Task 1）
- Produces: `class PreferencesKVStore implements KVStore`（包装 `preferences.Preferences`，`getSync/putSync/deleteSync` 全同步委托 preferences 同步 API）；EntryAbility `onCreate` 中初始化 preferences 并调用 `AppState.instance.initFromStore(store)`。

- [ ] **Step 1: PreferencesKVStore + EntryAbility 接线**

```typescript
// entry/src/main/ets/state/PreferencesKVStore.ets
import { preferences } from '@kit.ArkData';
import { KVStore } from './ConfigStore';

// preferences 同步 API 包装：与 ConfigStore 的 KVStore 接口对接
export class PreferencesKVStore implements KVStore {
  private pref: preferences.Preferences;
  constructor(pref: preferences.Preferences) { this.pref = pref; }
  getSync(k: string): string | undefined {
    const v = this.pref.getSync(k, '') as string;
    return v === '' ? undefined : v;
  }
  putSync(k: string, v: string): void { this.pref.putSync(k, v); this.pref.flush(); }
  deleteSync(k: string): void { this.pref.deleteSync(k); }
}
```

EntryAbility `onCreate`（在 `loadContent` 之前）：

```typescript
import { preferences } from '@kit.ArkData';
import { ConfigStore } from '../state/ConfigStore';
import { PreferencesKVStore } from '../state/PreferencesKVStore';
import { AppState } from '../state/AppState';

// onCreate 内：
const context = this.context.getApplicationContext();
preferences.getPreferences(context, 'okvideo_config').then((pref: preferences.Preferences) => {
  const store = new ConfigStore(new PreferencesKVStore(pref));
  return AppState.instance.initFromStore(store);
});
```

- [ ] **Step 2: ConfigPage 完整版（替换骨架）**

```typescript
// entry/src/main/ets/pages/ConfigPage.ets
import { AppState } from '../state/AppState';
import { ConfigStore } from '../state/ConfigStore';
import { Nav } from '../nav/Nav';

@ComponentV2
export struct ConfigPage {
  @Local inputUrl: string = '';
  @Local busy: boolean = false;

  build() {
    Column({ space: 16 }) {
      Text('OK 影视').fontSize(28).fontWeight(FontWeight.Bold).margin({ top: 120 })
      Text('粘贴 TVBox 订阅链接（支持 JSON/Base64/JPEG 伪装格式）')
        .fontSize(13).fontColor('#888888')
      TextInput({ placeholder: 'https://…/config.json', text: this.inputUrl })
        .type(InputType.URL).width('86%').height(46)
        .onChange((v: string) => { this.inputUrl = v; })
      Button(this.busy ? '解析中…' : '加载订阅')
        .width('86%').height(46)
        .enabled(!this.busy && this.inputUrl.trim().length > 0)
        .onClick(() => { this.doLoad(); })
      if (AppState.instance.errMsg !== '') {
        Text('错误：' + AppState.instance.errMsg)
          .fontSize(13).fontColor('#E53935').width('86%')
      }
    }
    .width('100%').height('100%')
    .alignItems(HorizontalAlign.Center)
  }

  private async doLoad(): Promise<void> {
    this.busy = true;
    AppState.instance.errMsg = '';
    const ok = await AppState.instance.loadFromUrl(this.inputUrl.trim());
    this.busy = false;
    if (ok) {
      // 持久化（fire-and-forget）：从 EntryAbility 装配的 store 读取
      AppState.instance.persistCurrent();
      Nav.stack.replacePath({ name: 'Home' });
    }
  }
}
```

> `persistCurrent()` 为本任务在 `AppState` 补充的方法（需持有 store 引用）：
> ```typescript
> // AppState.ets 增补：initFromStore 时保存 this.store = store; 并新增
> @Trace store: ConfigStore | null = null;   // 实际不加 @Trace（对象非观察目标），普通字段即可
> persistCurrent(): void {
>   if (this.store !== null && this.config !== null && this.subUrl !== '') {
>     this.store.save(this.subUrl, serializeConfig(this.subUrl, this.config));
>   }
> }
> ```
> `Home` 首屏路由：Navigation 根内容随 `phase` 自动切换（Task 3 已实现），`replacePath({ name: 'Home' })` 仅在以 NavDestination 方式承载 Home 时需要；本实现 Home 为 Navigation 根内容，**无需入栈**，`doLoad` 成功后仅更新 `phase`（`loadFromUrl` 已置 `'home'`），删除 `Nav.stack.replacePath` 行。以实现时实际结构为准：**phase 驱动首屏切换，Config→Home 零路由操作**。

- [ ] **Step 3: 构建并模拟器验证（粘贴真实订阅源）**

Run: 构建命令 → 安装 → 启动 → 截图（ConfigPage）→ 在输入框输入任一可用订阅 URL（可先用 `hdc shell uinput` 或手动）→ 截图
Expected: 正确订阅 → 切到首页骨架；乱码 URL → 原地显示错误信息

- [ ] **Step 4: 跑全部本地单测（防回归）+ 提交**

```bash
git add entry/src/main/ets/
git commit -m "feat(entry): ConfigPage 订阅输入与 EntryAbility preferences 装配"
```

---

### Task 5: HomePage —— 站点切换 / 分类 Tabs / 影片网格 / 分页

**Files:**
- Modify: `entry/src/main/ets/pages/HomePage.ets`（替换骨架）
- Create: `entry/src/main/ets/components/MovieGrid.ets`（网格+触底分页复用组件，Task 6 搜索复用）

**Interfaces:**
- Consumes: `AppState`（driver/currentSite/switchSite）、`HomeContent`/`Movie`/`PageResult`/'common'
- Produces: `@ComponentV2 struct MovieGrid { items: Movie[]; hasMore: boolean; onLoadMore: () => void; onPick: (m: Movie) => void; loading: boolean }`；HomePage 跳转约定 `Nav.stack.pushPathByName('Detail', movie)`。

- [ ] **Step 1: MovieGrid 组件**

```typescript
// entry/src/main/ets/components/MovieGrid.ets
import { Movie } from 'common';

@ComponentV2
export struct MovieGrid {
  @Param items: Movie[] = [];
  @Param hasMore: boolean = false;
  @Param loading: boolean = false;
  onPick: (m: Movie) => void = (_m: Movie) => {};
  onLoadMore: () => void = () => {};
  private gridScroller: Scroller = new Scroller();

  build() {
    WaterFlow() {
      ForEach(this.items, (m: Movie) => {
        FlowItem() {
          Column({ space: 6 }) {
            Image(m.pic === '' ? $r('app.media.icon') : m.pic)
              .width('100%').height(180).objectFit(ImageFit.Cover).borderRadius(8)
              .alt($r('app.media.icon'))
            Text(m.name).fontSize(14).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(m.remark).fontSize(12).fontColor('#999999').maxLines(1)
          }.width('100%')
        }
        .onClick(() => { this.onPick(m); })
      }, (m: Movie) => m.vodId + '_' + m.name)
    }
    .columnsTemplate('1fr 1fr')
    .columnsGap(10).rowsGap(12)
    .width('100%').layoutWeight(1)
    .padding({ left: 12, right: 12, top: 8 })
    .onReachEnd(() => { if (this.hasMore && !this.loading) { this.onLoadMore(); } })
  }
}
```

- [ ] **Step 2: HomePage 完整版（替换骨架）**

```typescript
// entry/src/main/ets/pages/HomePage.ets
import { AppState } from '../state/AppState';
import { Nav } from '../nav/Nav';
import { MovieGrid } from '../components/MovieGrid';
import { HomeContent, PageResult, Movie, SiteDriver } from 'common';

@ComponentV2
export struct HomePage {
  @Local sites: string[] = [];          // "key|name" 复合串（Select 用）
  @Local siteKeys: string[] = [];
  @Local siteIdx: number = 0;
  @Local cats: string[] = [];           // "tid|name" 复合串
  @Local catKeys: string[] = [];
  @Local catIdx: number = 0;
  @Local items: Movie[] = [];
  @Local page: number = 1;
  @Local pageCount: number = 1;
  @Local loading: boolean = false;
  @Local errMsg: string = '';
  @Local showSearch: boolean = false;
  @Local searchKey: string = '';
  @Local searching: boolean = false;

  aboutToAppear(): void { this.refreshSites(); this.loadHome(); }

  private driver(): SiteDriver | null { return AppState.instance.driver; }

  private refreshSites(): void {
    const cfg = AppState.instance.config;
    if (cfg === null) { return; }
    this.siteKeys = cfg.sites.map((s): string => s.key);
    this.sites = cfg.sites.map((s): string => s.name);
    this.siteIdx = Math.max(0, this.siteKeys.indexOf(AppState.instance.currentSite?.key ?? ''));
  }

  private async loadHome(): Promise<void> {
    const d = this.driver();
    if (d === null) { return; }
    this.loading = true; this.errMsg = '';
    try {
      const hc: HomeContent = await d.getHomeContent();
      this.catKeys = hc.categories.map((c): string => c.tid);
      this.cats = hc.categories.map((c): string => c.name);
      this.catIdx = 0;
      this.items = hc.items;
      this.page = 1; this.pageCount = 1;
    } catch (e) { this.errMsg = e instanceof Error ? e.message : String(e); }
    this.loading = false;
  }

  private async loadCategory(tid: string, pg: number, replace: boolean): Promise<void> {
    const d = this.driver();
    if (d === null) { return; }
    this.loading = true; this.errMsg = '';
    try {
      const pr: PageResult = await d.categoryContent(tid, pg);
      this.items = replace ? pr.items : this.items.concat(pr.items);
      this.page = pr.page; this.pageCount = pr.pageCount;
    } catch (e) { this.errMsg = e instanceof Error ? e.message : String(e); }
    this.loading = false;
  }

  private async doSearch(): Promise<void> {
    const d = this.driver();
    if (d === null || this.searchKey.trim() === '') { return; }
    this.searching = true; this.errMsg = '';
    try {
      const pr: PageResult = await d.searchContent(this.searchKey.trim(), false);
      this.items = pr.items; this.page = 1; this.pageCount = pr.pageCount;
    } catch (e) { this.errMsg = e instanceof Error ? e.message : String(e); }
    this.searching = false;
  }

  build() {
    Column() {
      // 顶栏：站点切换 + 搜索入口
      Row({ space: 8 }) {
        Select(this.sites.map((s: string): SelectOption => { return { value: s } as SelectOption; }))
          .selected(this.siteIdx).value(this.sites[this.siteIdx] ?? '站点')
          .onSelect((idx: number) => {
            this.siteIdx = idx;
            AppState.instance.switchSite(this.siteKeys[idx]);
            this.loadHome();
          })
        Blank()
        Image($r('sys.media.ohos_ic_public_search')).width(24).height(24)
          .onClick(() => { this.showSearch = !this.showSearch; })
      }.width('100%').padding({ left: 12, right: 12, top: 8 })

      if (this.showSearch) {
        Row({ space: 8 }) {
          TextInput({ placeholder: '搜索影片…', text: this.searchKey })
            .layoutWeight(1).height(40)
            .onChange((v: string) => { this.searchKey = v; })
            .onSubmit(() => { this.doSearch(); })
          Button('搜').height(40).onClick(() => { this.doSearch(); })
        }.width('100%').padding({ left: 12, right: 12 })
      }

      if (!this.showSearch && this.cats.length > 0) {
        Scroll() {
          Row({ space: 10 }) {
            ForEach(this.cats, (c: string, i: number) => {
              Text(c)
                .fontSize(this.catIdx === i ? 16 : 14)
                .fontColor(this.catIdx === i ? '#007DFF' : '#666666')
                .fontWeight(this.catIdx === i ? FontWeight.Bold : FontWeight.Normal)
                .onClick(() => {
                  this.catIdx = i;
                  this.loadCategory(this.catKeys[i], 1, true);
                })
            }, (c: string, i: number) => c + i)
          }.padding({ left: 12, right: 12, top: 8 })
        }.scrollable(ScrollDirection.Horizontal).width('100%')
      }

      if (this.errMsg !== '') {
        Column({ space: 8 }) {
          Text('加载失败：' + this.errMsg).fontColor('#E53935').fontSize(13)
          Button('重试').onClick(() => {
            if (this.showSearch) { this.doSearch(); }
            else if (this.catKeys.length > 0) { this.loadCategory(this.catKeys[this.catIdx], 1, true); }
            else { this.loadHome(); }
          })
        }.margin({ top: 60 })
      } else if (this.loading && this.items.length === 0) {
        LoadingProgress().width(44).height(44).margin({ top: 80 })
      } else {
        MovieGrid({
          items: this.items,
          hasMore: this.page < this.pageCount,
          loading: this.loading,
          onPick: (m: Movie) => { Nav.stack.pushPathByName('Detail', m); },
          onLoadMore: () => {
            if (this.catKeys.length > 0 && this.page < this.pageCount) {
              this.loadCategory(this.catKeys[this.catIdx], this.page + 1, false);
            }
          }
        })
      }
    }
    .width('100%').height('100%')
  }
}
```

> Select 复合字段说明：站点列表用 `sites[]` 名称展示 + `siteKeys[]` 对应 key，避免解析复合串；分类同理由 `catKeys[]/cats[]` 成对维护。`sys.media.ohos_ic_public_search` 为系统图标；若编译报缺资源，改用 `Text('🔍')`。

- [ ] **Step 3: 构建并模拟器验证**

Run: 构建 → 安装 → 启动（已存配置直接进首页）→ 截图核对：顶栏站点选择器、分类横滑条、影片网格、触底翻页（网格尾部出现新页数据）、切站点后网格刷新
Expected: 各交互无崩溃，错误源时出现错误卡片+重试

- [ ] **Step 4: 提交**

```bash
git add entry/src/main/ets/pages/HomePage.ets entry/src/main/ets/components/MovieGrid.ets
git commit -m "feat(entry): HomePage 站点切换/分类/网格分页与搜索入口"
```

---

### Task 6: HomePage 搜索结果呈现（接入 Task 5 已埋的 doSearch）

**Files:**
- Modify: `entry/src/main/ets/pages/HomePage.ets`（仅微调：搜索态下网格标题栏与返回按钮）

**Interfaces:**
- Consumes: Task 5 全部（doSearch 已在 Task 5 实现）
- Produces: 无新接口

- [ ] **Step 1: 搜索态 UI 微调**（在网格上方加条件标题栏）

在 `build()` 的网格分支前插入：

```typescript
      if (this.showSearch && this.items.length > 0) {
        Row() {
          Text(`“${this.searchKey}” 的结果`).fontSize(14).fontColor('#666666').layoutWeight(1)
          Text('返回浏览').fontSize(14).fontColor('#007DFF')
            .onClick(() => { this.showSearch = false; this.loadHome(); })
        }.width('100%').padding({ left: 12, right: 12, top: 8 })
      }
```

- [ ] **Step 2: 构建并模拟器验证**

Run: 构建 → 安装 → 启动 → 点搜索图标 → 输关键词 → 截图
Expected: 显示结果网格与「返回浏览」；清空/无结果时网格空而不崩溃

- [ ] **Step 3: 提交**

```bash
git add entry/src/main/ets/pages/HomePage.ets
git commit -m "feat(entry): 搜索结果呈现与返回浏览"
```

---

### Task 7: DetailPage —— 详情/线路/剧集

**Files:**
- Modify: `entry/src/main/ets/pages/DetailPage.ets`（替换骨架）

**Interfaces:**
- Consumes: `Nav.stack`（接收 param `Movie`）、`AppState.driver`、`MovieDetail`/`PlayLine`/`Episode`/'common'
- Produces: 跳转约定 `Nav.stack.pushPathByName('Player', { ep: episode, siteKey: AppState.instance.currentSite?.key ?? '' } as PlayerParam)`；`interface PlayerParam { ep: Episode; siteKey: string }` 定义在 `entry/src/main/ets/nav/Nav.ets`（Task 8 消费）。

- [ ] **Step 1: 完整实现**

```typescript
// entry/src/main/ets/pages/DetailPage.ets
import { Nav, PlayerParam } from '../nav/Nav';
import { AppState } from '../state/AppState';
import { MovieDetail, Movie, Episode, PlayLine } from 'common';

@ComponentV2
export struct DetailPage {
  @Local detail: MovieDetail | null = null;
  @Local lineIdx: number = 0;
  @Local loading: boolean = false;
  @Local errMsg: string = '';
  private movie: Movie | null = null;

  aboutToAppear(): void {
    // Navigation 参数在 NavDestination onReady 里取，此处兜底：push 顺序保证先于首帧
  }

  build() {
    NavDestination() {
      Column() {
        if (this.loading) { LoadingProgress().width(44).height(44).margin({ top: 120 }) }
        else if (this.errMsg !== '') {
          Column({ space: 8 }) {
            Text('加载失败：' + this.errMsg).fontColor('#E53935')
            Button('重试').onClick(() => { this.load(); })
          }.margin({ top: 120 })
        }
        else if (this.detail !== null) { this.detailBody() }
      }.width('100%').height('100%')
    }
    .title(this.detail?.movie.name ?? '详情')
    .onReady((ctx: NavDestinationContext) => {
      const m = ctx.pathInfo.param as Movie;
      if (m !== null && m !== undefined) { this.movie = m; this.load(); }
    })
  }

  @Builder
  detailBody() {
    Column() {
      Row({ space: 12 }) {
        Image(this.detail!.movie.pic === '' ? $r('app.media.icon') : this.detail!.movie.pic)
          .width(110).height(150).objectFit(ImageFit.Cover).borderRadius(8).alt($r('app.media.icon'))
        Column({ space: 4 }) {
          Text(this.detail!.movie.name).fontSize(18).fontWeight(FontWeight.Bold)
          Text('年份：' + (this.detail!.year === '' ? '未知' : this.detail!.year)).fontSize(13).fontColor('#666666')
          Text('演员：' + (this.detail!.actor === '' ? '未知' : this.detail!.actor))
            .fontSize(13).fontColor('#666666').maxLines(2)
          Text('导演：' + (this.detail!.director === '' ? '未知' : this.detail!.director)).fontSize(13).fontColor('#666666')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.width('100%').padding(12)

      Text(this.detail!.desc === '' ? '暂无简介' : this.detail!.desc)
        .fontSize(13).fontColor('#444444').maxLines(6)
        .padding({ left: 12, right: 12 })

      if (this.detail!.lines.length > 0) {
        Scroll() {
          Row({ space: 10 }) {
            ForEach(this.detail!.lines, (l: PlayLine, i: number) => {
              Text(l.from)
                .fontColor(this.lineIdx === i ? '#007DFF' : '#666666')
                .fontWeight(this.lineIdx === i ? FontWeight.Bold : FontWeight.Normal)
                .onClick(() => { this.lineIdx = i; })
            }, (l: PlayLine, i: number) => l.from + i)
          }.padding({ left: 12, top: 12 })
        }.scrollable(ScrollDirection.Horizontal).width('100%')

        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
          ForEach(this.detail!.lines[this.lineIdx].episodes, (ep: Episode, i: number) => {
            Button(ep.name)
              .fontSize(13).height(36).margin({ left: 8, top: 8 })
              .backgroundColor('#F2F3F5').fontColor('#333333')
              .onClick(() => {
                const param: PlayerParam = { ep: ep, siteKey: AppState.instance.currentSite?.key ?? '' };
                Nav.stack.pushPathByName('Player', param);
              })
          }, (ep: Episode, i: number) => ep.url + i)
        }.width('100%').padding({ left: 4, right: 12 })
      } else {
        Text('无可用播放线路').fontSize(14).fontColor('#999999').margin({ top: 40 })
      }
    }.width('100%').height('100%').alignItems(HorizontalAlign.Start)
  }

  private async load(): Promise<void> {
    const d = AppState.instance.driver;
    const m = this.movie;
    if (d === null || m === null) { return; }
    this.loading = true; this.errMsg = ''; this.lineIdx = 0;
    try {
      this.detail = await d.detailContent([m.vodId]);
    } catch (e) { this.errMsg = e instanceof Error ? e.message : String(e); }
    this.loading = false;
  }
}
```

`Nav.ets` 追加 PlayerParam：

```typescript
import { Episode } from 'common';
export interface PlayerParam { ep: Episode; siteKey: string }
```

- [ ] **Step 2: 构建并模拟器验证**

Run: 构建 → 安装 → 启动 → 首页点任意影片 → 截图；切线路；点剧集
Expected: 详情数据渲染；线路切换剧集列表变化；点剧集进入播放页骨架

- [ ] **Step 3: 提交**

```bash
git add entry/src/main/ets/pages/DetailPage.ets entry/src/main/ets/nav/Nav.ets
git commit -m "feat(entry): DetailPage 详情/线路/剧集列表"
```

---

### Task 8: PlayerPage —— 全屏播放

**Files:**
- Modify: `entry/src/main/ets/pages/PlayerPage.ets`（替换骨架）

**Interfaces:**
- Consumes: `Nav.stack`（param `PlayerParam`）、ArkUI `Video` 组件 + `VideoController`
- Produces: 无

- [ ] **Step 1: 完整实现**

```typescript
// entry/src/main/ets/pages/PlayerPage.ets
import { Nav, PlayerParam } from '../nav/Nav';
import { Episode } from 'common';

@ComponentV2
export struct PlayerPage {
  @Local ep: Episode | null = null;
  @Local errMsg: string = '';
  private controller: VideoController = new VideoController();

  build() {
    NavDestination() {
      Stack() {
        if (this.errMsg !== '') {
          Column({ space: 12 }) {
            Text('播放失败：' + this.errMsg).fontColor('#E53935')
            Row({ space: 12 }) {
              Button('重试').onClick(() => { this.errMsg = ''; this.controller.start(); })
              Button('返回').onClick(() => { Nav.stack.pop(); })
            }
          }.width('100%')
        } else if (this.ep !== null) {
          Video({ src: this.ep.url, controller: this.controller })
            .width('100%').height('100%')
            .autoPlay(true)
            .objectFit(ImageFit.Contain)
            .onError(() => { this.errMsg = '视频加载或解码失败'; })
        } else {
          LoadingProgress().width(44).height(44)
        }
      }.width('100%').height('100%').backgroundColor(Color.Black)
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      const p = ctx.pathInfo.param as PlayerParam;
      if (p !== null && p !== undefined) { this.ep = p.ep; }
    })
    .onBackPressed(() => { return false; })
  }
}
```

- [ ] **Step 2: 构建并模拟器验证**

Run: 构建 → 安装 → 启动 → 详情 → 点剧集 → 截图（等待 3 秒再截，让视频起播）
Expected: 全屏播放器起播有画面/声音；坏源显示错误卡片（重试/返回可用）

- [ ] **Step 3: 提交**

```bash
git add entry/src/main/ets/pages/PlayerPage.ets
git commit -m "feat(entry): PlayerPage 全屏播放与错误处理"
```

---

### Task 9: 端到端收口

**Files:**
- Modify: 无新文件（全链路验证 + 回归）

**Interfaces:**
- Consumes: 全部前序任务
- Produces: 可用版本

- [ ] **Step 1: 本地单测全量回归**

Run: 本地单测命令
Expected: 全部 PASS（含既有 Model/CmsJsonApi/ConfigDecoder/Coding 测试）

- [ ] **Step 2: 真实订阅全流程走查**

用真实订阅源在模拟器完成：粘贴订阅 → 首页 → 切站点 → 切分类 → 翻页 → 搜索 → 详情 → 切线路 → 播放（正常源 + 一个坏源验证错误卡片）。每步截图留档。

- [ ] **Step 3: 清理与提交**

删除遗留调试文件（若存在）；确认 `git status` 无意外改动：

```bash
git status --short
git add -A
git commit -m "chore(entry): UI MVP 端到端收口"
```

---

## Self-Review 记录

1. **Spec 覆盖**：配置输入（Task 4）✓ 站点切换（Task 5）✓ 分类/网格/分页（Task 5）✓ 搜索（Task 5+6）✓ 详情/线路/剧集（Task 7）✓ 播放（Task 8）✓ 持久化（Task 1+4）✓ 错误统一模式（各任务）✓ 导航结构（Task 3）✓
2. **占位符扫描**：无 TBD/TODO；Task 4 中「以实现时实际结构为准」一段已给出确定性结论（phase 驱动、删 replacePath 行）。
3. **类型一致性**：`KVStore/StoredConfig/serializeConfig/parseStoredConfig`（T1）→ T2/T4 引用一致；`AppState.makeFetchText/testFetchText/switchSite/persistCurrent`（T2/T4）一致；`MovieGrid` props（T5）→ T6 一致；`PlayerParam`（T7 定义于 Nav.ets）→ T8 引用一致；路由名 `'Detail'/'Player'`（T3 pagesMap ↔ T5/T7 pushPathByName）一致。
