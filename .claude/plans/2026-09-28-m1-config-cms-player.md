# M1：OK影视 HarmonyOS 版 — 环境搭建 + 订阅解码链 + CMS 引擎 + 原生播放 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 搭好鸿蒙工程，真机实现「订阅拉取→解码→站点列表」「CMS 采集源→详情→带头播放」两条端到端链路。

**Architecture:** entry(HAP, UI+服务) + common(HAR, 纯逻辑)。所有纯逻辑（base64/utf8/解码链/CMS 解析）零 `@ohos` 依赖、可本地单测；`@ohos` 依赖（网络/存储/播放）集中在 entry 的薄封装里，真机验收。CmsJsonApi 通过注入 `fetchText` 函数做到纯逻辑可测。

**Tech Stack:** ArkTS + ArkUI（API 12+，DevEco Studio 6.x）、@ohos.net.http、media.AVPlayer（createMediaSourceWithUrl）、relationalStore/Preferences、Hypium 本地单测。

**Spec:** `docs/superpowers/specs/2026-09-28-okvideo-harmonyos-design.md`（本计划只覆盖 spec §9 的 M1 行；M2-M4 计划在 M1 完成后另写）

## Global Constraints

- **语言**：所有回复、commit message、注释一律中文。
- **ArkTS 严格模式**：禁 `any`/`unknown`；对象字面量必须对应 interface；JSON.parse 结果需 `as` 断言后按字段取值；不用 `delete`。
- **纯逻辑零 @ohos 依赖**：`common` HAR 中除 Index.ets 外，任何文件不得 import `@ohos`/`@kit`（保证本地单测在 host 可跑）。@ohos 依赖的封装（HttpClient/ConfigService/Player）放 entry。
- **本地单测位置**：全部集中 `entry/src/test/`（DevEco 本地测试跑在 host），被测函数经 `common` 的 `Index.ets` 导出，import 路径写模块名 `common`。
- **测试运行方式（M1 固定）**：DevEco Studio 中右键 `entry/src/test` → Run（Local Test）。首次执行时同步试出可用的 hvigorw CLI 形式并记入 `docs/superpowers/notes/test-commands.md`，之后沿用。真机验收步骤用「操作 + 预期结果」描述，不自动化。
- **TDD 纪律**：纯逻辑任务必须先写失败测试再实现；UI/设备任务的"测试"= 真机手动验收步骤。
- **合规（spec §11）**：测试 fixture 全部合成（自制最小样本），禁止把真实订阅的站点数据落盘进仓库；真机调试时订阅 URL 由用户现场输入。
- **签名/运行**：真机侧载依赖用户华为账号自动签名（Task 1 完成）；执行中任何需要 GUI 或账号的步骤标记为 `USER-MANUAL`，执行者应暂停请用户操作后再继续。
- **API 版本**：compatibleSdkVersion 以真机为准（Task 1 用 hdc 查询）。若真机 < API 12，播放走降级路径（Task 10 有明确分支）。
- **网络库**：M1 用 `@ohos.net.http`（spec §5 允许的兜底选型，置信度最高）；rcp 优化留到后续里程碑。
- **CMS XML 引擎（type 0）**：M1 不实现（挪到 M2），M1 的 CmsJsonApi 支持 type 1 即满足验收②。
- **工程**：repo 根 = `~/DevEcoStudioProjects/okvideo-hap`；DevEco 工程名 `OKVideo`，bundleName `com.okvideo.app`。
- **commit**：每任务一 commit，格式 `feat|fix|test|docs|chore(scope): 描述`。
- **不做（YAGNI）**：搜索 UI、收藏、历史、直播、下载、投屏、Spider —— 全部是 M2/M3/M4 计划内容，M1 执行者不得顺手实现。

## 文件结构总览（M1 完成后）

```
okvideo-hap/                      # repo 根 = DevEco 工程根
├── AppScope/app.json5
├── build-profile.json5           # Task 1 IDE 生成；Task 2 加 common 模块
├── entry/
│   ├── oh-package.json5           # Task 2 加 "common": "file:../common"
│   ├── src/main/
│   │   ├── module.json5           # pages 注册 Index/Detail/Player
│   │   └── ets/
│   │       ├── entryability/EntryAbility.ets
│   │       ├── net/HttpClient.ets        # @ohos.net.http 封装（Task 5）
│   │       ├── service/ConfigService.ets  # 订阅拉取+缓存（Task 6）
│   │       └── pages/
│   │           ├── Index.ets              # 首页（Task 8）
│   │           ├── Detail.ets             # 详情（Task 9）
│   │           └── Player.ets             # 播放（Task 10）
│   └── src/test/
│       └── List.test.ets                 # 全部本地单测（Task 2 起）
└── common/
    ├── oh-package.json5 / build-profile.json5 / Index.ets
    └── src/main/ets/
        ├── util/Coding.ets         # utf8/base64 纯实现（Task 3）
        ├── util/TypeUtil.ets       # 类型归一（Task 2）
        ├── model/TvboxModels.ets   # Config/Site/Live 模型（Task 2）
        ├── model/VideoModels.ets   # Movie/PageResult/Episode（Task 2）
        ├── decode/ConfigDecoder.ets# 订阅解码链（Task 4）
        └── engine/CmsJsonApi.ets   # CMS type1 引擎（Task 7）
```

---

### Task 1: DevEco 环境搭建与工程骨架

**Files:**
- Create: IDE 生成的 DevEco 工程骨架（AppScope/、build-profile.json5、entry/、hvigor/、oh-package.json5）
- Create: `docs/superpowers/notes/m1-env.md`（记录真机信息与 API 版本决策）

**Interfaces:**
- Produces: 可运行的 `entry` HAP 工程；`./hvigorw` 可执行；hdc 可连真机。

- [ ] **Step 1: USER-MANUAL 安装 DevEco Studio**

用户操作（执行者提示用户，暂停等待完成）：
1. 下载 DevEco Studio 6.x（华为开发者官网 developer.huawei.com → 开发工具 → DevEco Studio，选 macOS ARM64 版）并安装到 /Applications（历史残留的 `~/Library/Application Support/Huawei/DevEcoStudio6.1` 不影响重装）。
2. 首次启动 → 登录华为账号（后续模拟器/签名需要）。
3. 菜单 Settings → SDK 页确认 HarmonyOS SDK（含 toolchains）已自动下载完成。

- [ ] **Step 2: USER-MANUAL 连接真机并开启开发者模式**

用户操作：手机「设置 → 关于 → 连点版本号 7 次」开启开发者模式 →「开发者选项」打开 USB 调试 → 数据线连 Mac → 手机弹窗允许调试。

验证（执行者跑）：

```bash
hdc list targets
```

预期：输出真机序列号（不是 `[Empty]`）。hdc 路径在 DevEco SDK toolchains 下（`~/Library/Huawei/Sdk/<版本>/openharmony/toolchains/hdc`，DevEco 6.x 也内置；若 shell 找不到，用 mdfind -name hdc 定位后用绝对路径，并把该路径写入 `docs/superpowers/notes/test-commands.md`）。

- [ ] **Step 3: 查真机系统版本并记录 API 版本**

```bash
hdc shell param get const.product.software.version
hdc shell param get const.product.software.api_version
```

把两个输出写入 `docs/superpowers/notes/m1-env.md`。版本映射：HarmonyOS 5.0.0→API 12，5.0.1→13，5.1→14/15，6.0→16。真机 ≥ 5.0.0 即满足 M1（播放带头用 createMediaSourceWithUrl，API 12+）。若真机 < 5.0.0：停止并报告用户（纯血鸿蒙才在支持范围，spec §2）。

- [ ] **Step 4: USER-MANUAL 创建工程**

用户在 DevEco Studio：File → New → Create Project → Application → 空的 Ability 模板（名含 "Empty"）：
- Project name: `OKVideo`；Bundle name: `com.okvideo.app`
- Save location: `/Users/zhaozipeng/DevEcoStudioProjects/okvideo-hap`（repo 根，目录非空但 IDE 允许在此创建；若 IDE 拒绝，则先建到 `~/DevEcoStudioProjects/OKVideo`，创建完成后把 IDE 生成的所有文件 mv 进 repo 根，再用 IDE File→Open 打开 repo 根）
- Compile SDK：保持 IDE 默认（>= 5.0.0/API 12）；Model: Stage。

- [ ] **Step 5: USER-MANUAL 配置自动签名**

DevEco：File → Project Structure → Signing Configs → 勾选 "Automatically generate signature" → 登录的华为账号 → 确定（生成 debug 签名，真机侧载必需）。

- [ ] **Step 6: 真机运行 Hello World**

USER-MANUAL：IDE 中选设备为已连真机 → Run 'entry'。
预期：真机安装并打开空白应用（"Hello World" 或空白页），无签名错误。

- [ ] **Step 7: 验证 CLI 构建**

```bash
cd ~/DevEcoStudioProjects/okvideo-hap && ./hvigorw --mode module -p product=default assembleHap --no-daemon
```

预期：BUILD SUCCESSFUL，产物在 `entry/build/default/outputs/default/`。若 hvigorw 首跑要求下载依赖，联网等待即可。

- [ ] **Step 8: Commit（工程骨架）**

```bash
cd ~/DevEcoStudioProjects/okvideo-hap
cat > .gitignore <<'EOF'
/build/
/entry/build/
/common/build/
/.idea/
/local.properties
/oh_modules/
/.hvigor/
*.hap
*.har
/.appanalyzer
/.clangd
/.clang-format
/.clang-tidy
/dependencies
/.preview
EOF
git add .gitignore AppScope build-profile.json5 entry hvigor oh-package.json5 hvigorfile.ts hvigor-config.json5 2>/dev/null || git add -A
git commit -m "chore(env): DevEco 工程骨架（API12+/OKVideo/com.okvideo.app）"
```

（IDE 生成文件名以实际为准，允许微调 git add 列表；commit 前用 `git status` 确认没把 oh_modules 等大目录加进来。）

---

### Task 2: common HAR 模块 + TVBox 模型 + 类型归一

**Files:**
- Create: `common/oh-package.json5`、`common/build-profile.json5`、`common/Index.ets`、`common/src/main/ets/model/TvboxModels.ets`、`common/src/main/ets/model/VideoModels.ets`、`common/src/main/ets/util/TypeUtil.ets`
- Modify: 根 `build-profile.json5`（modules 数组加 common）、`entry/oh-package.json5`（依赖 common）
- Test: `entry/src/test/List.test.ets`（追加两个测试组）

**Interfaces:**
- Produces（后续任务依赖，签名必须一字不差）:

```typescript
// common/src/main/ets/util/TypeUtil.ets
export function toInt(v: string | number | boolean | undefined, def: number): number
export function toStr(v: string | number | boolean | undefined, def: string): string

// common/src/main/ets/model/TvboxModels.ets
export interface SiteConfig {
  key: string; name: string; type: number; api: string;
  searchable: number; quickSearch: number; filterable: number;
  timeout: number; playerType: number; jar: string; ext: string;
  header: Record<string, string>;
}
export interface TvboxConfig {
  spider: string; wallpaper: string;
  sites: SiteConfig[]; lives: LiveGroupConfig[]; parses: ParseConfig[];
}
export interface LiveGroupConfig { name: string; type: string; url: string; ua: string; playerType: number }
export interface ParseConfig { name: string; type: string; url: string; ext: Record<string, string> }
export function parseTvboxConfig(raw: Record<string, Object>): TvboxConfig

// common/src/main/ets/model/VideoModels.ets
export interface Movie { vodId: string; name: string; pic: string; remark: string; typeName: string }
export interface Category { tid: string; name: string }
export interface HomeContent { categories: Category[]; items: Movie[] }
export interface Episode { name: string; url: string }
export interface PlayLine { from: string; episodes: Episode[] }
export interface MovieDetail { movie: Movie; desc: string; year: string; actor: string; director: string; lines: PlayLine[] }
export interface PageResult { page: number; pageCount: number; items: Movie[] }
```

- `ext` 统一为 string（object 形态 JSON 序列化为字符串，Spider 期再解——M1 不引入 object 分支）。

- [ ] **Step 1: 写失败测试**

在 `entry/src/test/List.test.ets` 追加（保留 IDE 模板原有内容，文件末尾加）：

```typescript
import { describe, it, expect } from '@ohos/hypium';
import { toInt, toStr, parseTvboxConfig } from 'common';

describe('ModelTest', () => {
  it('toInt_norm', 0, () => {
    expect(toInt('0', 9)).assertEqual(0);
    expect(toInt('2', 9)).assertEqual(2);
    expect(toInt(2, 9)).assertEqual(2);
    expect(toInt(undefined, 9)).assertEqual(9);
  });
  it('parseTvbox_norm', 0, () => {
    const raw: Record<string, Object> = {
      'spider': 'http://a/b.jpg;md5;abc',
      'sites': [{ 'key': 's1', 'name': '站1', 'type': '3', 'api': 'csp_X', 'ext': { 'a': 'b' }, 'playerType': '2' }],
      'lives': [{ 'name': '直播1', 'type': 0, 'url': 'http://x.m3u' }],
      'parses': [{ 'name': 'p', 'type': 0, 'url': 'http://p?url=' }]
    };
    const cfg = parseTvboxConfig(raw);
    expect(cfg.spider).assertEqual('http://a/b.jpg;md5;abc');
    expect(cfg.sites.length).assertEqual(1);
    expect(cfg.sites[0].type).assertEqual(3);
    expect(cfg.sites[0].playerType).assertEqual(2);
    expect(cfg.sites[0].ext).assertEqual('{"a":"b"}');
    expect(cfg.lives[0].playerType).assertEqual(0);
    expect(cfg.sites[0].header['User-Agent']).assertEqual('');
  });
});
```

- [ ] **Step 2: 创建 common HAR 目录文件（IDE 未建该模块，手写模板）**

`common/oh-package.json5`:

```json
{
  "name": "common",
  "version": "1.0.0",
  "description": "OK影视 TVBox 协议模型与纯逻辑"
}
```

`common/build-profile.json5`:

```json
{
  "apiType": "stageMode",
  "buildOption": {},
  "targets": [
    { "name": "default" }
  ]
}
```

`common/Index.ets`:

```typescript
export * from './src/main/ets/util/TypeUtil';
export * from './src/main/ets/model/TvboxModels';
export * from './src/main/ets/model/VideoModels';
```

（后续任务每新增文件都在此追加 export。）

- [ ] **Step 3: 实现模型与类型归一**

`common/src/main/ets/util/TypeUtil.ets`:

```typescript
export function toInt(v: string | number | boolean | undefined, def: number): number {
  if (typeof v === 'number') return Math.floor(v);
  if (typeof v === 'string') {
    const n = Number(v);
    if (!Number.isNaN(n)) return Math.floor(n);
  }
  return def;
}
export function toStr(v: string | number | boolean | undefined, def: string): string {
  if (typeof v === 'string') return v;
  if (typeof v === 'number' || typeof v === 'boolean') return String(v);
  return def;
}
```

`common/src/main/ets/model/TvboxModels.ets`:

```typescript
import { toInt, toStr } from '../util/TypeUtil';

export interface SiteConfig {
  key: string; name: string; type: number; api: string;
  searchable: number; quickSearch: number; filterable: number;
  timeout: number; playerType: number; jar: string; ext: string;
  header: Record<string, string>;
}
export interface LiveGroupConfig { name: string; type: string; url: string; ua: string; playerType: number }
export interface ParseConfig { name: string; type: string; url: string; ext: Record<string, string> }
export interface TvboxConfig {
  spider: string; wallpaper: string;
  sites: SiteConfig[]; lives: LiveGroupConfig[]; parses: ParseConfig[];
}

interface RawSite extends Record<string, Object | Object[] | Record<string, string> | undefined> {}

export function parseTvboxConfig(raw: Record<string, Object>): TvboxConfig {
  const sitesRaw = (raw['sites'] ?? []) as Record<string, Object>[];
  const livesRaw = (raw['lives'] ?? []) as Record<string, Object>[];
  const parsesRaw = (raw['parses'] ?? []) as Record<string, Object>[];
  const sites: SiteConfig[] = [];
  for (const s of sitesRaw) {
    const extObj = s['ext'];
    const headerRaw = (s['header'] ?? {}) as Record<string, Object>;
    const header: Record<string, string> = {};
    const keys = Object.keys(headerRaw);
    for (const k of keys) { header[k] = toStr(headerRaw[k], ''); }
    sites.push({
      key: toStr(s['key'], ''), name: toStr(s['name'], ''),
      type: toInt(s['type'], 0), api: toStr(s['api'], ''),
      searchable: toInt(s['searchable'], 1), quickSearch: toInt(s['quickSearch'], 1),
      filterable: toInt(s['filterable'], 0), timeout: toInt(s['timeout'], 10) * 1000,
      playerType: toInt(s['playerType'], 0), jar: toStr(s['jar'], ''),
      ext: typeof extObj === 'string' ? extObj : JSON.stringify(extObj ?? ''),
      header: header
    });
  }
  const lives: LiveGroupConfig[] = livesRaw.map((l: Record<string, Object>): LiveGroupConfig => {
    return { name: toStr(l['name'], ''), type: toStr(l['type'], '0'), url: toStr(l['url'], ''), ua: toStr(l['ua'], ''), playerType: toInt(l['playerType'], 0) };
  });
  const parses: ParseConfig[] = parsesRaw.map((p: Record<string, Object>): ParseConfig => {
    return { name: toStr(p['name'], ''), type: toStr(p['type'], '0'), url: toStr(p['url'], ''), ext: JSON.stringify(p['ext'] ?? {}) as Record<string, string> };
  });
  return { spider: toStr(raw['spider'], ''), wallpaper: toStr(raw['wallpaper'], ''), sites, lives, parses };
}
```

注意：`ext` object 序列化用 JSON.stringify；`parses.ext` 同理先 stringify 再 `as`（若 ArkTS 编译器对 `as Record<string,string>` 报错，改为存 string 并同步修改 ParseConfig.ext 为 string——保持两处一致即可，类型签名以最终编译通过为准并回写本计划）。

`common/src/main/ets/model/VideoModels.ets`: 按 Interfaces 块原样写 7 个 interface（纯声明）。

- [ ] **Step 4: 注册模块与依赖**

根 `build-profile.json5` 的 `"modules"` 数组追加：

```json
{ "name": "common", "srcPath": "./common", "targets": [ { "name": "default" } ] }
```

`entry/oh-package.json5` 的 `"dependencies"` 追加：`"common": "file:../common"`。然后在工程根执行 `ohpm install`（IDE 的 Terminal 里跑，ohpm 随 DevEco 安装）。

- [ ] **Step 5: 跑测试到绿**

DevEco：右键 `entry/src/test` → Run。预期：`ModelTest` 全 PASS（模板原有用例也 PASS）。
首次执行时把可用的 CLI 测试命令记录到 `docs/superpowers/notes/test-commands.md`。

- [ ] **Step 6: Commit**

```bash
git add common entry/src/test entry/oh-package.json5 build-profile.json5 docs/superpowers/notes
git commit -m "feat(common): TVBox 配置模型与宽松类型归一"
```

---

### Task 3: 纯编码工具：UTF-8 与 Base64

**Files:**
- Create: `common/src/main/ets/util/Coding.ets`
- Modify: `common/Index.ets`（追加导出）
- Test: `entry/src/test/List.test.ets`

**Interfaces:**
- Produces:

```typescript
export function utf8Encode(s: string): Uint8Array
export function utf8Decode(b: Uint8Array): string
export function b64encode(b: Uint8Array): string
export function b64decode(s: string): Uint8Array   // 忽略非字母表字符；自动补 padding
export function stripNonB64(s: string): string     // 移除 \r \n 空格及其他非字母表字符
```

- [ ] **Step 1: 写失败测试**

```typescript
import { describe, it, expect } from '@ohos/hypium';
import { utf8Encode, utf8Decode, b64encode, b64decode, stripNonB64 } from 'common';

describe('CodingTest', () => {
  it('utf8_roundtrip_chinese', 0, () => {
    const s = '饭太硬订阅站长┃不卡';
    expect(utf8Decode(utf8Encode(s))).assertEqual(s);
  });
  it('b64_roundtrip', 0, () => {
    const bytes = utf8Encode('{"sites":[]}');
    const enc = b64encode(bytes);
    expect(enc).assertEqual('eyJzaXRlcyI6W119');
    const dec = b64decode(enc);
    expect(utf8Decode(dec)).assertEqual('{"sites":[]}');
  });
  it('b64decode_tolerant', 0, () => {
    const dec = b64decode('eyJza\r\nXRlc\nyiI 6W10=');
    expect(utf8Decode(dec)).assertEqual('{"sites":[]}');
  });
  it('b64decode_salt_padding', 0, () => {
    // 带盐前缀 + 无 padding
    const dec = b64decode(stripNonB64('odvEMkqU**e') + 'eyJzaXRlcyI6W10');
    expect(utf8Decode(dec)).assertEqual('{"sites":[]}');
  });
  it('stripNonB64', 0, () => {
    expect(stripNonB64('ab\r\nc\n d*e=')).assertEqual('abcde=');
  });
});
```

- [ ] **Step 2: 跑测试确认失败**（函数未定义，编译错误或 FAIL）

- [ ] **Step 3: 实现**

`common/src/main/ets/util/Coding.ets`:

```typescript
const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

export function utf8Encode(s: string): Uint8Array {
  const out: number[] = [];
  for (let i = 0; i < s.length; i++) {
    let cp = s.charCodeAt(i);
    if (cp >= 0xd800 && cp <= 0xdbff && i + 1 < s.length) { // 代理对
      const lo = s.charCodeAt(i + 1);
      if (lo >= 0xdc00 && lo <= 0xdfff) { cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00); i++; }
    }
    if (cp < 0x80) { out.push(cp); }
    else if (cp < 0x800) { out.push(0xc0 | (cp >> 6), 0x80 | (cp & 0x3f)); }
    else if (cp < 0x10000) { out.push(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f)); }
    else { out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f)); }
  }
  return new Uint8Array(out);
}

export function utf8Decode(b: Uint8Array): string {
  let out = '';
  let i = 0;
  while (i < b.length) {
    const b0 = b[i];
    let cp = b0;
    if (b0 >= 0xf0) { cp = ((b0 & 0x07) << 18) | ((b[i + 1] & 0x3f) << 12) | ((b[i + 2] & 0x3f) << 6) | (b[i + 3] & 0x3f); i += 4; }
    else if (b0 >= 0xe0) { cp = ((b0 & 0x0f) << 12) | ((b[i + 1] & 0x3f) << 6) | (b[i + 2] & 0x3f); i += 3; }
    else if (b0 >= 0xc0) { cp = ((b0 & 0x1f) << 6) | (b[i + 1] & 0x3f); i += 2; }
    else { i += 1; }
    if (cp >= 0x10000) {
      cp -= 0x10000;
      out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
    } else { out += String.fromCharCode(cp); }
  }
  return out;
}

export function stripNonB64(s: string): string {
  let out = '';
  for (const ch of s) { if (B64.indexOf(ch) >= 0 || ch === '=') { out += ch; } }
  return out;
}

export function b64encode(b: Uint8Array): string {
  let out = '';
  for (let i = 0; i < b.length; i += 3) {
    const b0 = b[i];
    const b1 = i + 1 < b.length ? b[i + 1] : 0;
    const b2 = i + 2 < b.length ? b[i + 2] : 0;
    out += B64[b0 >> 2];
    out += B64[((b0 & 0x03) << 4) | (b1 >> 4)];
    out += i + 1 < b.length ? B64[((b1 & 0x0f) << 2) | (b2 >> 6)] : '=';
    out += i + 2 < b.length ? B64[b2 & 0x3f] : '=';
  }
  return out;
}

export function b64decode(s: string): Uint8Array {
  const clean = stripNonB64(s).replace(/=+$/, '');
  const out: number[] = [];
  let acc = 0;
  let bits = 0;
  for (const ch of clean) {
    const v = B64.indexOf(ch);
    if (v < 0) { continue; }
    acc = (acc << 6) | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push((acc >> bits) & 0xff);
    }
  }
  return new Uint8Array(out);
}
```

`common/Index.ets` 追加：`export * from './src/main/ets/util/Coding';`

- [ ] **Step 4: 跑测试到绿**，预期全部 PASS。

- [ ] **Step 5: Commit**

```bash
git add common entry/src/test/List.test.ets
git commit -m "feat(common): 纯实现 utf8 与 base64 编解码"
```

---

### Task 4: 订阅解码链 ConfigDecoder（M1 核心）

**Files:**
- Create: `common/src/main/ets/decode/ConfigDecoder.ets`
- Modify: `common/Index.ets`
- Test: `entry/src/test/List.test.ets`

**Interfaces:**
- Consumes: Task 2 `parseTvboxConfig`、Task 3 `b64decode/utf8Decode/stripNonB64`
- Produces:

```typescript
export class ConfigDecodeError extends Error {
  constructor(msg: string) { super(msg); }
}
export function decodeConfigContent(input: string | Uint8Array): TvboxConfig
```

解码顺序（spec §6.1）：纯 JSON5 → base64 → JPEG 尾部 steg（FFD9 定位 + 偏移 0..16 试盐 + base64）。每层失败进入下一层，全失败抛 `ConfigDecodeError`。

- [ ] **Step 1: 写失败测试**

```typescript
import { describe, it, expect } from '@ohos/hypium';
import { decodeConfigContent, ConfigDecodeError, utf8Encode, b64encode } from 'common';

// 合成最小配置（不得使用真实订阅数据落盘，spec §11）
const SAMPLE_JSON5 =
  '{\r\n"spider":"http://x/s.jpg;md5;aa",\r\n' +
  '//{"key":"注释站点","type":9},\r\n' +
  '"sites":[{"key":"a","name":"甲站","type":1,"api":"http://a/api.php"}]\r\n}';

describe('ConfigDecoderTest', () => {
  it('plain_json5', 0, () => {
    const cfg = decodeConfigContent(SAMPLE_JSON5);
    expect(cfg.sites.length).assertEqual(1);
    expect(cfg.sites[0].name).assertEqual('甲站');
    expect(cfg.spider).assertEqual('http://x/s.jpg;md5;aa');
  });
  it('base64_layer', 0, () => {
    const cfg = decodeConfigContent(b64encode(utf8Encode(SAMPLE_JSON5)));
    expect(cfg.sites.length).assertEqual(1);
  });
  it('jpeg_steg_with_salt', 0, () => {
    // 最小 JPEG 壳：JFIF 头 + FFD9 结束符 + 盐 + base64
    const head = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0xff, 0xd9]);
    const tailStr = 'odvEMkqU**e' + b64encode(utf8Encode(SAMPLE_JSON5));
    const tail = utf8Encode(tailStr);
    const all = new Uint8Array(head.length + tail.length);
    all.set(head, 0); all.set(tail, head.length);
    const cfg = decodeConfigContent(all);
    expect(cfg.sites.length).assertEqual(1);
    expect(cfg.sites[0].type).assertEqual(1);
  });
  it('garbage_throws', 0, () => {
    let threw = false;
    try { decodeConfigContent('随便乱写'); } catch (e) { threw = e instanceof ConfigDecodeError; }
    expect(threw).assertTrue();
  });
});
```

- [ ] **Step 2: 跑测试确认失败**（`decodeConfigContent` 未定义）

- [ ] **Step 3: 实现**

`common/src/main/ets/decode/ConfigDecoder.ets`:

```typescript
import { parseTvboxConfig } from '../model/TvboxModels';
import { b64decode, utf8Decode, stripNonB64 } from '../util/Coding';

export class ConfigDecodeError extends Error {
  constructor(msg: string) { super(msg); }
}

// JSON5 宽松解析：过滤行首 // 注释后 JSON.parse（URL 中的 // 在字符串内部，不受影响）
function parseJson5ish(text: string): Record<string, Object> {
  const lines = text.split('\n').filter(l => !l.trim().startsWith('//'));
  return JSON.parse(lines.join('\n')) as Record<string, Object>;
}

function fromB64Maybe(text: string): Record<string, Object> | null {
  for (let skip = 0; skip <= 16; skip++) {
    const body = stripNonB64(text.substring(skip));
    if (body.length < 4 || body.length % 4 === 1) { continue; }
    try {
      return parseJson5ish(utf8Decode(b64decode(body)));
    } catch (e) { /* 试下一偏移 */ }
  }
  return null;
}

function findJpegEnd(b: Uint8Array): number {
  for (let i = b.length - 2; i >= 0; i--) {
    if (b[i] === 0xff && b[i + 1] === 0xd9) { return i + 2; }
  }
  return -1;
}

export function decodeConfigContent(input: string | Uint8Array): TvboxConfig {
  const text = typeof input === 'string' ? input : utf8Decode(input);
  // 1) 纯 JSON/JSON5
  try { return parseTvboxConfig(parseJson5ish(text)); } catch (e) { /* 下探 */ }
  // 2) 整体 base64（可能带盐）
  const fromB64 = fromB64Maybe(text);
  if (fromB64 !== null) { return parseTvboxConfig(fromB64); }
  // 3) JPEG 尾部 steg
  if (typeof input !== 'string') {
    const end = findJpegEnd(input);
    if (end > 0 && end < input.length) {
      const tailText = utf8Decode(input.slice(end));
      const steg = fromB64Maybe(tailText);
      if (steg !== null) { return parseTvboxConfig(steg); }
    }
  }
  throw new ConfigDecodeError('无法识别的订阅内容格式');
}
```

`common/Index.ets` 追加：`export * from './src/main/ets/decode/ConfigDecoder';`

- [ ] **Step 4: 跑测试到绿**

- [ ] **Step 5: Commit**

```bash
git add common entry/src/test/List.test.ets
git commit -m "feat(common): 订阅内容四层解码链（JSON5/base64/JPEG伪装）"
```

---

### Task 5: HttpClient 封装 + 真机网络验证（spec §5 API 验证 ①）

**Files:**
- Create: `entry/src/main/ets/net/HttpClient.ets`
- Modify: `entry/src/main/ets/pages/Index.ets`（临时加验证按钮，Task 8 会重构该页）

**Interfaces:**
- Produces（Task 6/7/10 依赖）:

```typescript
export interface HttpFetchOptions {
  method?: string;                      // 默认 GET
  headers?: Record<string, string>;     // 含 User-Agent
  timeoutMs?: number;                   // 默认 15000
}
export interface HttpFetchResult {
  status: number;                       // HTTP 状态码
  headers: Record<string, string>;      // 响应头（小写键）
  body: ArrayBuffer;                    // 原始字节（订阅是 JPEG）
  text(): string;                       // UTF-8 解码
}
export async function httpFetch(url: string, opts?: HttpFetchOptions): Promise<HttpFetchResult>
```

`text()` 复用 common 的 `utf8Decode`（新 Uint8Array(this.body)）。

- [ ] **Step 1: 实现 HttpClient（网络不可本地单测，直接实现+真机验证）**

`entry/src/main/ets/net/HttpClient.ets`:

```typescript
import { http } from '@kit.NetworkKit';
import { utf8Decode } from 'common';

export interface HttpFetchOptions {
  method?: string;
  headers?: Record<string, string>;
  timeoutMs?: number;
}
export interface HttpFetchResult {
  status: number;
  headers: Record<string, string>;
  body: ArrayBuffer;
  text(): string;
}

export async function httpFetch(url: string, opts?: HttpFetchOptions): Promise<HttpFetchResult> {
  const client = http.createHttp();
  try {
    const resp = await client.request(url, {
      method: (opts?.method === 'POST') ? http.RequestMethod.POST : http.RequestMethod.GET,
      header: opts?.headers ?? { 'User-Agent': 'okhttp/3.15' },
      connectTimeout: opts?.timeoutMs ?? 15000,
      readTimeout: opts?.timeoutMs ?? 15000,
      expectDataType: http.HttpDataType.ARRAY_BUFFER
    });
    const headers: Record<string, string> = {};
    const respHeaders = resp.header as Record<string, string>;
    for (const k of Object.keys(respHeaders)) { headers[k.toLowerCase()] = respHeaders[k]; }
    const bodyBuf = resp.result instanceof ArrayBuffer ? resp.result : new ArrayBuffer(0);
    return {
      status: resp.responseCode, headers: headers, body: bodyBuf,
      text: (): string => utf8Decode(new Uint8Array(bodyBuf))
    };
  } finally {
    client.destroy();
  }
}
```

- [ ] **Step 2: 首页临时验证按钮**

`Index.ets` 顶部加一个按钮 onClick 执行（保持页面可编译即可）：

```typescript
Button('网络验证').onClick(async () => {
  try {
    const r = await httpFetch('http://www.xn--sss604efuw.net/tv');
    const bytes = new Uint8Array(r.body);
    this.msg = `status=${r.status} size=${bytes.length} head=${bytes[0]},${bytes[1]}`;
  } catch (e) { this.msg = `失败: ${e}`; }
})
```

（`@State msg: string = ''` + Text 显示。）

- [ ] **Step 3: 真机验证（USER-MANUAL 确认）**

IDE Run 到真机 → 点「网络验证」。
预期：`status=200 size≈19683 head=255,216`（JPEG：FFD8）。若中文域名原样可请求，同样在按钮中试 `http://www.饭太硬.net/tv`，记录两种写法结果到 `docs/superpowers/notes/test-commands.md`。

- [ ] **Step 4: 条件分支：中文域名是否需要 punycode**

- 若 Step 3 中文域名直连成功 → 完成，无额外代码。
- 若失败 → `common/src/main/ets/util/Punycode.ets` 实现 RFC 3492 编码（纯逻辑，TDD：先写 `punycodeEncode('www.饭太硬.net') === 'www.xn--sss604efuw.net'` 等用例），并在 httpFetch 入口对含非 ASCII 主机名的 URL 自动转换后发出。测试样例必须含：`饭太硬.net` → `xn--sss604efuw.net`；纯 ASCII 域名原样返回。实现思路（写入代码，勿从简）：分割主机名标签，对非 ASCII 标签按 RFC 3492 的 bootstring 算法（base=36, tmin=1, tmax=26, skew=38, damp=700, initial_bias=72, initial_n=128）编码，前缀 `xn--`。

- [ ] **Step 5: Commit**

```bash
git add entry/src/main/ets/net entry/src/main/ets/pages/Index.ets docs/superpowers/notes common 2>/dev/null
git commit -m "feat(entry): httpFetch 封装与真机网络验证"
```

---

### Task 6: ConfigService（订阅拉取+缓存）→ 真机验收①

**Files:**
- Create: `entry/src/main/ets/service/ConfigService.ets`
- Modify: `entry/src/main/ets/pages/Index.ets`（订阅地址输入框替换临时验证按钮）

**Interfaces:**
- Consumes: `httpFetch`（Task 5）、`decodeConfigContent`（Task 4）
- Produces:

```typescript
export class ConfigService {
  static readonly PREF_NAME = 'okvideo_pref';
  static readonly KEY_SUB = 'current_subscription_json';
  async loadFromUrl(url: string): Promise<TvboxConfig>;  // 拉取失败抛 Error；成功后缓存
  async loadCached(): Promise<TvboxConfig | null>;      // 无缓存返回 null
  getConfig(): TvboxConfig | null;                      // 当前内存态
  getSite(key: string): SiteConfig | null;
}
export const configService = new ConfigService();       // 单例导出
```

- [ ] **Step 1: 实现**

`entry/src/main/ets/service/ConfigService.ets`:

```typescript
import { preferences } from '@kit.ArkData';
import { context } from '@kit.AbilityKit';
import { TvboxConfig, SiteConfig, decodeConfigContent } from 'common';
import { httpFetch } from '../net/HttpClient';

export class ConfigService {
  private pref: preferences.Preferences | null = null;
  private cfg: TvboxConfig | null = null;

  private async getPref(): Promise<preferences.Preferences> {
    if (this.pref === null) {
      this.pref = await preferences.getPreferences(context.getApplicationContext(), 'okvideo_pref');
    }
    return this.pref;
  }

  async loadFromUrl(url: string): Promise<TvboxConfig> {
    const r = await httpFetch(url);
    if (r.status !== 200) { throw new Error(`订阅请求失败 HTTP ${r.status}`); }
    const cfg = decodeConfigContent(new Uint8Array(r.body));
    this.cfg = cfg;
    const pref = await this.getPref();
    await pref.put('current_subscription_json', JSON.stringify({
      url: url, sites: cfg.sites, spider: cfg.spider, lives: cfg.lives, parses: cfg.parses, wallpaper: cfg.wallpaper
    }));
    await pref.flush();
    return cfg;
  }

  async loadCached(): Promise<TvboxConfig | null> {
    const pref = await this.getPref();
    const raw = await pref.get('current_subscription_json', '') as string;
    if (raw === '') { return null; }
    const obj = JSON.parse(raw) as Record<string, Object>;
    this.cfg = decodeConfigContent(JSON.stringify({ sites: obj['sites'], spider: obj['spider'], lives: obj['lives'], parses: obj['parses'], wallpaper: obj['wallpaper'] }));
    return this.cfg;
  }

  getConfig(): TvboxConfig | null { return this.cfg; }

  getSite(key: string): SiteConfig | null {
    const c = this.cfg;
    if (c === null) { return null; }
    for (const s of c.sites) { if (s.key === key) { return s; } }
    return null;
  }
}
export const configService = new ConfigService();
```

（缓存键值结构若字段对不齐 TvboxConfig，以 `decodeConfigContent` 能吃进去为准微调。）

- [ ] **Step 2: 首页订阅入口 UI**

`Index.ets` 改为：顶部 TextInput（订阅地址）+「加载订阅」按钮 + 结果 Text。aboutToAppear 时 `loadCached()` 有缓存就直接显示站点数。加载成功后 `this.msg = \`已加载 ${cfg.sites.length} 个站点\``。

- [ ] **Step 3: 真机验收①（spec §9 M1 验证物）**

USER-MANUAL：真机运行 → 输入 `http://www.饭太硬.net/tv` → 点加载。
预期：显示「已加载 47 个站点」（站点数以当日实际为准，≥40 即通过；断网重启 App，aboutToAppear 从缓存恢复同样显示站点数）。此验收结果（截图/数字）记录进 `docs/superpowers/notes/m1-acceptance.md`。

- [ ] **Step 4: Commit**

```bash
git add entry/src/main/ets/service entry/src/main/ets/pages/Index.ets docs/superpowers/notes
git commit -m "feat(entry): 订阅拉取解码与缓存，真机验收①（饭太硬 47 站点）"
```

---

### Task 7: CmsJsonApi 引擎（CMS type 1，TDD 核心）

**Files:**
- Create: `common/src/main/ets/engine/CmsJsonApi.ets`
- Modify: `common/Index.ets`、新建 `common/src/main/ets/engine/SiteDriver.ets`
- Test: `entry/src/test/List.test.ets`

**Interfaces:**
- Consumes: Task 2 模型
- Produces:

```typescript
// common/src/main/ets/engine/SiteDriver.ets
export type FetchText = (url: string, headers?: Record<string, string>) => Promise<string>;
export interface SiteDriver {
  getHomeContent(): Promise<HomeContent>;
  categoryContent(tid: string, pg: number): Promise<PageResult>;
  detailContent(ids: string[]): Promise<MovieDetail>;
  searchContent(key: string, quick: boolean): Promise<PageResult>;
}
// common/src/main/ets/engine/CmsJsonApi.ets
export class CmsJsonApi implements SiteDriver {
  constructor(site: SiteConfig, fetchText: FetchText);
  // 播放地址拼装（静态，供 UI 复用）：
  static resolvePlayUrl(site: SiteConfig, rawUrl: string): string;
}
```

MacCMS V10 协议（对照 FongMi/TV-dev `CmsApi.java`；真机抓包有出入时以真机为准）：
- 分类：`GET {api}?ac=list` → `{ class: [{type_id, type_name}], list:[...], ... }`
- 列表：`GET {api}?ac=videolist&t={tid}&pg={pg}` → `{ page, pagecount, list: [vod...] }`
- 详情/搜索：`GET {api}?ac=detail&ids={id}`；搜索 `GET {api}?ac=detail&wd={key}`（部分站搜索用 `ac=videolist&wd=`，实现时两者依次尝试：先 `ac=detail&wd=`，返回 list 为空再试 `ac=videolist&wd=`）
- vod 字段：`vod_id, vod_name, vod_pic, vod_remarks, type_name, vod_year, vod_actor, vod_director, vod_content, vod_play_from, vod_play_url`
- `vod_play_from`/`vod_play_url` 以 `$$$` 分线路；线路内以 `#` 分集；集内 `名称$地址`（无 `$` 时地址为整段，集名用序号）

- [ ] **Step 1: 写失败测试**

```typescript
import { describe, it, expect } from '@ohos/hypium';
import { CmsJsonApi, SiteDriver, FetchText } from 'common';
import { SiteConfig } from 'common';

const SITE: SiteConfig = {
  key: 'cms', name: 'CMS测试站', type: 1, api: 'http://demo/api.php',
  searchable: 1, quickSearch: 1, filterable: 0, timeout: 10000, playerType: 0,
  jar: '', ext: '', header: {}
};

// fixture：合成 MacCMS 响应（非真实站点数据）
const FIXTURE: Record<string, string> = {
  'http://demo/api.php?ac=list':
    '{"class":[{"type_id":1,"type_name":"电影"},{"type_id":2,"type_name":"剧集"}],"list":[{"vod_id":11,"vod_name":"片A","vod_pic":"http://p/a.jpg","vod_remarks":"全10集"}]}',
  'http://demo/api.php?ac=videolist&t=1&pg=1':
    '{"page":1,"pagecount":3,"list":[{"vod_id":11,"vod_name":"片A","vod_pic":"http://p/a.jpg","vod_remarks":"全10集"},{"vod_id":12,"vod_name":"片B","vod_pic":"","vod_remarks":"HD"}]}',
  'http://demo/api.php?ac=detail&ids=11':
    '{"list":[{"vod_id":11,"vod_name":"片A","vod_pic":"http://p/a.jpg","vod_remarks":"全10集","type_name":"电影","vod_year":"2024","vod_actor":"甲,乙","vod_director":"丙","vod_content":"简介&lt;img src=x&gt;","vod_play_from":"线路1$$$线路2","vod_play_url":"第01集$http://v/1.m3u8#第02集$http://v/2.m3u8$$$正片$http://v/b.mp4"}]}',
  'http://demo/api.php?ac=detail&wd=片A':
    '{"list":[{"vod_id":11,"vod_name":"片A","vod_pic":"http://p/a.jpg","vod_remarks":"全10集"}]}'
};

const fakeFetch: FetchText = (url: string): Promise<string> => {
  return Promise.resolve(FIXTURE[url] ?? '{"list":[]}');
};

describe('CmsJsonApiTest', () => {
  const api = new CmsJsonApi(SITE, fakeFetch);

  it('home_content', 0, async () => {
    const home = await api.getHomeContent();
    expect(home.categories.length).assertEqual(2);
    expect(home.categories[0].tid).assertEqual('1');
    expect(home.items.length).assertEqual(1);
    expect(home.items[0].name).assertEqual('片A');
  });
  it('category_page', 0, async () => {
    const page = await api.categoryContent('1', 1);
    expect(page.pageCount).assertEqual(3);
    expect(page.items.length).assertEqual(2);
    expect(page.items[1].remark).assertEqual('HD');
  });
  it('detail_lines_episodes', 0, async () => {
    const d = await api.detailContent(['11']);
    expect(d.lines.length).assertEqual(2);
    expect(d.lines[0].from).assertEqual('线路1');
    expect(d.lines[0].episodes.length).assertEqual(2);
    expect(d.lines[0].episodes[1].url).assertEqual('http://v/2.m3u8');
    expect(d.lines[1].episodes[0].name).assertEqual('正片');
    expect(d.desc.indexOf('<img') < 0).assertTrue(); // 简介需剥 HTML 标签
  });
  it('search', 0, async () => {
    const r = await api.searchContent('片A', false);
    expect(r.items.length).assertEqual(1);
  });
  it('resolve_relative_url', 0, () => {
    expect(CmsJsonApi.resolvePlayUrl(SITE, '/play/1.html')).assertEqual('http://demo/play/1.html');
    expect(CmsJsonApi.resolvePlayUrl(SITE, 'http://x/y.m3u8')).assertEqual('http://x/y.m3u8');
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

- [ ] **Step 3: 实现**

`common/src/main/ets/engine/SiteDriver.ets`:

```typescript
import { HomeContent, PageResult, MovieDetail } from '../model/VideoModels';
export type FetchText = (url: string, headers?: Record<string, string>) => Promise<string>;
export interface SiteDriver {
  getHomeContent(): Promise<HomeContent>;
  categoryContent(tid: string, pg: number): Promise<PageResult>;
  detailContent(ids: string[]): Promise<MovieDetail>;
  searchContent(key: string, quick: boolean): Promise<PageResult>;
}
```

`common/src/main/ets/engine/CmsJsonApi.ets`:

```typescript
import { SiteConfig } from '../model/TvboxModels';
import { HomeContent, PageResult, MovieDetail, Movie, Category, Episode, PlayLine } from '../model/VideoModels';
import { FetchText, SiteDriver } from './SiteDriver';
import { toStr, toInt } from '../util/TypeUtil';

function stripHtml(s: string): string {
  return s.replace(/<[^>]+>/g, '').replace(/&nbsp;/g, ' ').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&').replace(/&quot;/g, '"');
}

function pickMovie(v: Record<string, Object>): Movie {
  return {
    vodId: toStr(v['vod_id'], ''), name: toStr(v['vod_name'], ''),
    pic: toStr(v['vod_pic'], ''), remark: toStr(v['vod_remarks'], ''), typeName: toStr(v['type_name'], '')
  };
}

export class CmsJsonApi implements SiteDriver {
  private site: SiteConfig;
  private fetchText: FetchText;

  constructor(site: SiteConfig, fetchText: FetchText) {
    this.site = site;
    this.fetchText = fetchText;
  }

  static resolvePlayUrl(site: SiteConfig, rawUrl: string): string {
    if (rawUrl.startsWith('http://') || rawUrl.startsWith('https://')) { return rawUrl; }
    try {
      const u = new URL(site.api);
      const origin = `${u.protocol}//${u.host}`;
      if (rawUrl.startsWith('/')) { return origin + rawUrl; }
      const dir = u.pathname.substring(0, u.pathname.lastIndexOf('/') + 1);
      return origin + dir + rawUrl;
    } catch (e) { return rawUrl; }
  }

  private async getJson(path: string): Promise<Record<string, Object>> {
    const text = await this.fetchText(`${this.site.api}${path}`, this.site.header);
    return JSON.parse(text) as Record<string, Object>;
  }

  async getHomeContent(): Promise<HomeContent> {
    const obj = await this.getJson('?ac=list');
    const classes = (obj['class'] ?? []) as Record<string, Object>[];
    const categories: Category[] = classes.map(c => ({ tid: toStr(c['type_id'], ''), name: toStr(c['type_name'], '') }));
    const list = (obj['list'] ?? []) as Record<string, Object>[];
    return { categories: categories, items: list.map(pickMovie) };
  }

  async categoryContent(tid: string, pg: number): Promise<PageResult> {
    const obj = await this.getJson(`?ac=videolist&t=${tid}&pg=${pg}`);
    const list = (obj['list'] ?? []) as Record<string, Object>[];
    return { page: toInt(obj['page'], pg), pageCount: toInt(obj['pagecount'], 1), items: list.map(pickMovie) };
  }

  async detailContent(ids: string[]): Promise<MovieDetail> {
    const obj = await this.getJson(`?ac=detail&ids=${ids.join(',')}`);
    const list = (obj['list'] ?? []) as Record<string, Object>[];
    if (list.length === 0) { throw new Error('详情为空'); }
    const v = list[0];
    const movie = pickMovie(v);
    const froms = toStr(v['vod_play_from'], '').split('$$$');
    const groups = toStr(v['vod_play_url'], '').split('$$$');
    const lines: PlayLine[] = [];
    for (let i = 0; i < froms.length; i++) {
      const eps: Episode[] = [];
      const group = groups[i] ?? '';
      for (const seg of group.split('#')) {
        if (seg === '') { continue; }
        const idx = seg.indexOf('$');
        if (idx > 0) { eps.push({ name: seg.substring(0, idx), url: CmsJsonApi.resolvePlayUrl(this.site, seg.substring(idx + 1)) }); }
        else if (seg.length > 0) { eps.push({ name: `第${eps.length + 1}集`, url: CmsJsonApi.resolvePlayUrl(this.site, seg) }); }
      }
      if (eps.length > 0) { lines.push({ from: froms[i], episodes: eps }); }
    }
    return {
      movie: movie, desc: stripHtml(toStr(v['vod_content'], '')), year: toStr(v['vod_year'], ''),
      actor: stripHtml(toStr(v['vod_actor'], '')), director: stripHtml(toStr(v['vod_director'], '')), lines: lines
    };
  }

  async searchContent(key: string, quick: boolean): Promise<PageResult> {
    let obj: Record<string, Object> = await this.getJson(`?ac=detail&wd=${encodeURIComponent(key)}`);
    let list = (obj['list'] ?? []) as Record<string, Object>[];
    if (list.length === 0) {
      obj = await this.getJson(`?ac=videolist&wd=${encodeURIComponent(key)}`);
      list = (obj['list'] ?? []) as Record<string, Object>[];
    }
    return { page: 1, pageCount: 1, items: list.map(pickMovie) };
  }
}
```

注意：ArkTS 严格模式下 `URL` 若不可用（host），改手写解析 `site.api` 字符串（indexOf('//') + 第一个 '/' 截取），行为保持等价。

`common/Index.ets` 追加两个 export。注意避免 `HomeContent` 等类型重名冲突——Index.ets 用具名导出自各文件，冲突时以 model 文件为准，engine 文件里同名类型改为 re-export。

- [ ] **Step 4: 跑测试到绿**

- [ ] **Step 5: Commit**

```bash
git add common entry/src/test/List.test.ets
git commit -m "feat(common): CmsJsonApi 引擎（MacCMS V10 全接口 + $$$/#/$ 播放串解析）"
```

---

### Task 8: 首页 UI（站点切换 + 分类 Tab + 影片网格）

**Files:**
- Modify: `entry/src/main/ets/pages/Index.ets`（重构）、`entry/src/main/module.json5`
- Create: `entry/src/main/ets/service/SiteFactory.ets`

**Interfaces:**
- Consumes: `configService`（Task 6）、`CmsJsonApi`/`SiteDriver`（Task 7）、`httpFetch`（Task 5）
- Produces:

```typescript
// entry/src/main/ets/service/SiteFactory.ets
export function createDriver(site: SiteConfig, fetchText: FetchText): SiteDriver  // type 1 → CmsJsonApi；type 3/4 抛 UnsupportedError（M1）
export function makeRealFetchText(): FetchText   // httpFetch 包装成 FetchText，抛错转异常消息
```

- [ ] **Step 1: SiteFactory**

```typescript
import { SiteConfig, CmsJsonApi, FetchText, SiteDriver } from 'common';
import { httpFetch } from '../net/HttpClient';

export class UnsupportedError extends Error { constructor(msg: string) { super(msg); } }

export function makeRealFetchText(): FetchText {
  return (url: string, headers?: Record<string, string>): Promise<string> => {
    return httpFetch(url, { headers: headers }).then(r => {
      if (r.status !== 200) { throw new Error(`HTTP ${r.status}`); }
      return r.text();
    });
  };
}

export function createDriver(site: SiteConfig, fetchText: FetchText): SiteDriver {
  if (site.type === 1) { return new CmsJsonApi(site, fetchText); }
  if (site.type === 0) { throw new UnsupportedError('XML 引擎将在 M2 支持'); }
  if (site.type === 3 || site.api.startsWith('csp_')) { throw new UnsupportedError('Spider 引擎将在 M3 支持'); }
  if (site.type === 4) { throw new UnsupportedError('T4 不受支持'); }
  throw new UnsupportedError(`未知站点类型 ${site.type}`);
}
```

- [ ] **Step 2: Index.ets 重构为首页**

结构（完整可编译骨架，样式从简）：

```typescript
import { router } from '@kit.ArkUI';
import { SiteConfig, HomeContent, Movie, PageResult, Category } from 'common';
import { configService } from '../service/ConfigService';
import { createDriver, makeRealFetchText, UnsupportedError } from '../service/SiteFactory';

@Entry
@Component
struct Index {
  @State sites: SiteConfig[] = [];
  @State curSiteKey: string = '';
  @State categories: Category[] = [];
  @State curTid: string = '';
  @State items: Movie[] = [];
  @State page: number = 1;
  @State pageCount: number = 1;
  @State loading: boolean = false;
  @State msg: string = '';
  private subUrl: string = '';

  async aboutToAppear() {
    const cached = await configService.loadCached();
    if (cached !== null) { this.onConfig(cached.sites); }
    else { this.msg = '无缓存订阅，请先输入订阅地址加载'; }
  }

  onConfig(sites: SiteConfig[]) {
    this.sites = sites;
    if (sites.length > 0) { this.onSiteChange(0); }
  }

  onSiteChange(idx: number) {
    const s = this.sites[idx];
    if (s === undefined) { return; }
    this.curSiteKey = s.key; this.items = []; this.categories = []; this.page = 1; this.pageCount = 1;
    try {
      const driver = createDriver(s, makeRealFetchText());
      driver.getHomeContent().then((h: HomeContent) => {
        this.categories = h.categories;
        this.curTid = h.categories.length > 0 ? h.categories[0].tid : '';
        if (this.curTid !== '') { this.loadPage(1); } else { this.items = h.items; }
      }).catch((e: Object) => { this.msg = `站点不支持：${e}`; });
    } catch (e) { this.msg = `站点不支持：${e}`; }
  }

  loadPage(pg: number) {
    const site = configService.getSite(this.curSiteKey);
    if (site === null || this.curTid === '') { return; }
    this.loading = true;
    createDriver(site, makeRealFetchText()).categoryContent(this.curTid, pg)
      .then((r: PageResult) => {
        this.page = pg; this.pageCount = r.pageCount;
        this.items = pg === 1 ? r.items : this.items.concat(r.items);
        this.loading = false;
      }).catch((e: Object) => { this.msg = `加载失败：${e}`; this.loading = false; });
  }

  build() {
    Column() {
      // 站点横滑
      Tabs() { ForEach(this.sites, (s: SiteConfig, idx: number) => {
        TabContent() { Text(s.name).fontSize(16).padding(12) }.tabBar(s.name)
      }, (s: SiteConfig) => s.key) }
      .barMode(BarMode.Scrollable).height(56).onChange((idx: number) => this.onSiteChange(idx))
      // 分类
      if (this.categories.length > 0) {
        Tabs() { ForEach(this.categories, (c: Category) => {
          TabContent() { }.tabBar(c.name)
        }, (c: Category) => c.tid) }
        .onChange((idx: number) => { this.curTid = this.categories[idx].tid; this.loadPage(1); })
        .barMode(BarMode.Scrollable).height(44)
      }
      Text(this.msg).fontSize(12).fontColor('#f60').padding(4).visibility(this.msg === '' ? Visibility.None : Visibility.Visible)
      // 影片网格
      Grid() { ForEach(this.items, (m: Movie) => {
        GridItem() {
          Column() {
            Image(m.pic).height(120).fillWidth().objectFit(ImageFit.Cover).alt($r('app.media.icon'))
            Text(`${m.name}\n${m.remark}`).fontSize(12).maxLines(2).padding(4)
          }.alignItems(HorizontalAlign.Start)
        }.onClick(() => {
          router.pushUrl({ url: 'pages/Detail', params: { siteKey: this.curSiteKey, vodId: m.vodId } as Record<string, string> });
        })
      }, (m: Movie) => m.vodId + m.name) }
      .columnsTemplate('1fr 1fr').columnsGap(8).rowsGap(8).padding(8)
      .height('100%').onReachEnd(() => { if (!this.loading && this.page < this.pageCount) { this.loadPage(this.page + 1); } })
    }
  }
}
```

（订阅输入保留：`this.msg` 提示无订阅时显示 TextInput+按钮 —— 与 Task 6 Step 2 的输入框合并放在页面顶部，加载成功后隐藏。）

- [ ] **Step 3: 真机验收**

用真机 + Task 6 已缓存的饭太硬订阅：首页顶部 47 个站点横滑可见；点击任一站点显示「Spider 引擎将在 M3 支持」（预期）；无报错崩溃。用一个 CMS 站点（用户提供 type1 测试源，或等 Task 10 验收时一并验）显示分类+列表。

- [ ] **Step 4: Commit**

```bash
git add entry/src/main/ets
git commit -m "feat(entry): 首页站点切换/分类Tab/影片网格/触底翻页"
```

---

### Task 9: 详情页 Detail.ets

**Files:**
- Create: `entry/src/main/ets/pages/Detail.ets`
- Modify: `entry/src/main/module.json5`（pages 数组加 `"pages/Detail"`）

**Interfaces:**
- Consumes: `createDriver`、`configService`、router 参数 `{ siteKey: string, vodId: string }`
- Produces: 跳转 Player 的路由参数（Task 10 依赖，格式固定）：

```typescript
router.pushUrl({ url: 'pages/Player', params: {
  title: string,           // 集名
  url: string,            // 直链（已 resolve）
  referer: string,         // site.header['Referer']（可空）
  ua: string              // site.header['User-Agent']（可空）
} as Record<string, string> });
```

- [ ] **Step 1: 实现 Detail.ets**

```typescript
import { router } from '@kit.ArkUI';
import { MovieDetail, PlayLine, Movie } from 'common';
import { configService } from '../service/ConfigService';
import { createDriver, makeRealFetchText } from '../service/SiteFactory';

@Entry
@Component
struct Detail {
  @State detail: MovieDetail | null = null;
  @State curLine: number = 0;
  @State msg: string = '';
  private siteKey: string = '';
  private vodId: string = '';

  async aboutToAppear() {
    const p = router.getParams() as Record<string, string>;
    this.siteKey = p['siteKey'] ?? '';
    this.vodId = p['vodId'] ?? '';
    const site = configService.getSite(this.siteKey);
    if (site === null) { this.msg = '站点不存在'; return; }
    try {
      this.detail = await createDriver(site, makeRealFetchText()).detailContent([this.vodId]);
    } catch (e) { this.msg = `详情加载失败：${e}`; }
  }

  build() {
    Column() {
      Text(this.msg).fontColor('#f60').fontSize(12).padding(8)
      if (this.detail !== null) {
        Row() {
          Image(this.detail.movie.pic).width(110).height(150).objectFit(ImageFit.Cover)
          Column() {
            Text(this.detail.movie.name).fontSize(18).fontWeight(FontWeight.Bold)
            Text(`${this.detail.year} ${this.detail.movie.typeName}`).fontSize(12).padding(2)
            Text(`导演：${this.detail.director}`).fontSize(12).maxLines(1)
            Text(`主演：${this.detail.actor}`).fontSize(12).maxLines(2)
          }.alignItems(HorizontalAlign.Start).padding(8)
        }.padding(8).alignItems(VerticalAlign.Top)
        Text(this.detail.desc).fontSize(12).maxLines(4).padding(8)
        // 线路切换
        Row() { ForEach(this.detail.lines, (l: PlayLine, i: number) => {
          Text(l.from === '' ? `线路${i + 1}` : l.from).fontSize(13).padding(8)
            .fontColor(i === this.curLine ? Color.White : Color.Black)
            .backgroundColor(i === this.curLine ? '#f60' : '#eee').margin(4)
            .onClick(() => { this.curLine = i; })
        }, (l: PlayLine) => l.from) }
        // 集数
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.detail.lines[this.curLine]?.episodes ?? [], (ep, idx: number) => {
            Text(ep.name).fontSize(13).padding(8).backgroundColor('#f5f5f5').margin(4)
              .onClick(() => { this.goPlay(ep.name, ep.url); })
          }, (ep) => ep.url)
        }.padding(8)
      }
    }
  }

  goPlay(epName: string, url: string) {
    const site = configService.getSite(this.siteKey);
    router.pushUrl({ url: 'pages/Player', params: {
      title: `${this.detail?.movie.name ?? ''} ${epName}`,
      url: url,
      referer: site?.header['Referer'] ?? '',
      ua: site?.header['User-Agent'] ?? ''
    } as Record<string, string> });
  }
}
```

（ArkTS 对 `?.` 和索引链的支持按编译器报错就地简化——先把 lines 拷到 @State 数组再取下标即可。）

- [ ] **Step 2: module.json5 注册页面**

`"pages"` 数组：`["pages/Index", "pages/Detail"]`（Player 下一任务加）。

- [ ] **Step 3: 真机验收**

用 CMS 测试源：首页点片 → 详情显示海报/简介/线路/集数，点线路可切换。

- [ ] **Step 4: Commit**

```bash
git add entry/src/main/ets/pages/Detail.ets entry/src/main/module.json5
git commit -m "feat(entry): 详情页（线路切换/选集/跳转播放）"
```

---

### Task 10: 播放页 Player.ets + AVPlayer 带自定义头验证（spec §5 API 验证②）→ 真机验收②

**Files:**
- Create: `entry/src/main/ets/pages/Player.ets`
- Modify: `entry/src/main/module.json5`（pages 加 `"pages/Player"`）

**Interfaces:**
- Consumes: Detail 路由参数 `{title, url, referer, ua}`
- Produces: 可复用的播放页（M2 嗅探、直播复用此页）

- [ ] **Step 1: 实现 Player.ets**

```typescript
import { router } from '@kit.ArkUI';
import { media } from '@kit.MediaKit';

@Entry
@Component
struct Player {
  @State isPlaying: boolean = false;
  @State duration: number = 0;
  @State position: number = 0;
  @State msg: string = '';
  private title: string = '';
  private playUrl: string = '';
  private headers: Record<string, string> = {};
  private avPlayer: media.AVPlayer | null = null;
  @State surfaceId: string = '';

  aboutToAppear() {
    const p = router.getParams() as Record<string, string>;
    this.title = p['title'] ?? '';
    this.playUrl = p['url'] ?? '';
    const referer = p['referer'] ?? '';
    const ua = p['ua'] ?? '';
    if (referer !== '') { this.headers['Referer'] = referer; }
    if (ua !== '') { this.headers['User-Agent'] = ua; }
  }

  async startPlay(surfaceId: string) {
    this.surfaceId = surfaceId;
    try {
      const avPlayer = await media.createAVPlayer();
      this.avPlayer = avPlayer;
      avPlayer.on('stateChange', (state: string) => {
        if (state === 'playing') { this.isPlaying = true; }
        if (state === 'paused') { this.isPlaying = false; }
      });
      avPlayer.on('durationUpdate', (d: number) => { this.duration = d; });
      avPlayer.on('timeUpdate', (t: number) => { this.position = t; });
      avPlayer.on('error', (err) => { this.msg = `播放错误: ${err.message ?? err}`; });
      // API 12+：带自定义 header 的源；低版本或 headers 为空走 url 直设
      let usedHeader = false;
      if (Object.keys(this.headers).length > 0) {
        try {
          const src = media.createMediaSourceWithUrl(this.playUrl, this.headers);
          await avPlayer.setMediaSource(src);
          usedHeader = true;
        } catch (e) { this.msg = 'setMediaSource 失败，降级直连'; }
      }
      if (!usedHeader) { avPlayer.url = this.playUrl; }
      avPlayer.surfaceId = this.surfaceId;
      await avPlayer.prepare();
      await avPlayer.play();
    } catch (e) { this.msg = `起播失败: ${e}`; }
  }

  build() {
    Column() {
      Text(this.title).fontSize(14).maxLines(1).padding(8).width('100%')
      XComponent({ id: 'okplayer', type: XComponentType.SURFACE, libraryname: '' })
        .onLoad((surfaceId: string) => { this.startPlay(surfaceId); })
        .width('100%').height(220).backgroundColor(Color.Black)
      Row() {
        Text(this.msg).fontSize(12).fontColor('#f60').layoutWeight(1)
        Button(this.isPlaying ? '暂停' : '播放').onClick(() => {
          const p = this.avPlayer;
          if (p === null) { return; }
          if (this.isPlaying) { p.pause(); } else { p.play(); }
        })
      }.padding(8)
      Slider({ value: this.position, min: 0, max: this.duration === 0 ? 1 : this.duration })
        .onChange((v: number, mode) => { if (mode === SliderChangeMode.End && this.avPlayer) { this.avPlayer.seek(Math.floor(v)); } })
        .padding(8)
    }
  }

  aboutToDisappear() { this.avPlayer?.release(); }
}
```

`Slider` onChange 第三参数 mode 的类型写法以 IDE 模板补全为准（`SliderChangeMode.End`）。

- [ ] **Step 2: module.json5 注册**

- [ ] **Step 3: 真机验收②（spec §9 M1 验证物②）**

USER-MANUAL：用户提供一个 type 1 CMS 采集源订阅（自备或公开演示站，现场输入）→ 加载 → 浏览 → 点片 → 详情 → 播放。
预期：m3u8/mp4 真机出画面、可暂停/续播；带 Referer 防盗链的源不 403（此为 createMediaSourceWithUrl 的验证点）。若 setMediaSource 走通记录到 notes；若降级路径触发也记录现象。结果写入 `docs/superpowers/notes/m1-acceptance.md`。

- [ ] **Step 4: Commit**

```bash
git add entry/src/main/ets/pages/Player.ets entry/src/main/module.json5 docs/superpowers/notes
git commit -m "feat(entry): AVPlayer 播放页（带头播放+降级路径），真机验收②"
```

---

### Task 11: M1 收尾

**Files:**
- Create: `docs/superpowers/notes/m1-acceptance.md`（如未建，汇总两步验收结果）
- Modify: spec §9 表格中 M1 行标注完成日期

- [ ] **Step 1: 全量本地单测跑绿**（DevEco Run entry/src/test，全 PASS）

- [ ] **Step 2: `./hvigorw --mode module -p product=default assembleHap --no-daemon` BUILD SUCCESSFUL**

- [ ] **Step 3: 真机冒烟**：冷启动 → 缓存订阅恢复 → 47 站点横滑 → Spider 站提示 M3 → CMS 站浏览 → 详情 → 播放

- [ ] **Step 4: Commit + tag**

```bash
git add docs
git commit -m "docs(m1): M1 验收记录与状态更新"
git tag m1
```

- [ ] **Step 5: 向用户汇报 M1 结果**，确认后按同流程制定 M2 计划（嗅探/直播/搜索/收藏历史/XML 引擎）。

---

## Self-Review 结论（已执行）

1. **Spec 覆盖**：spec §9 M1 行的两项验证物 → Task 6（验收①）与 Task 10（验收②）；§5 M1 相关 API 验证（http、播放 headers）→ Task 5/10；§6.1 解码链 → Task 4；§6.2 CmsJsonApi → Task 7；§6.9 三页面 → Task 8/9/10。CmsXmlApi 明确挪 M2（Global Constraints）。
2. **占位符**：无 TBD/TODO；所有代码块完整可抄。唯一条件分支（punycode）给出了实现路径与测试断言样例。
3. **类型一致性**：`FetchText`/`SiteDriver`/`PageResult`/`MovieDetail`/`httpFetch`/`configService` 等签名在任务间已逐一核对一致。
