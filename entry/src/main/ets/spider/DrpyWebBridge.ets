// DrpyWebBridge：drpy JS 插件引擎的 Web 容器桥（单例）
// 职责：后台 Web 组件挂载壳页面（drpy_shell.html）、drpy2/ext 脚本注入、
//       JS 网络请求代理（arktsReq 入队 → httpFetch → __arktsResolve 回传）、
//       DRPY 方法调用（runJavaScriptExt + 超时）。
// 注意：V2 观察在 Navigation 根内容失效的同类 SDK 问题不影响本桥（全部命令式 API）。
import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { SiteConfig, b64encode, decodeDataUrl } from 'common';
import { httpFetch, HttpFetchOptions } from '../net/HttpClient';
import { DrpyCorsProxy } from '../net/DrpyCorsProxyServer';

const TAG = 'OKV-WEB';

const CALL_TIMEOUT_MS = 20000;   // 慢站冷连接( DNS+TLS+出数 )可超 10s,20s 兜底
const INIT_TIMEOUT_MS = 20000;

// drpy2 运行时 init 接收的站点配置（JSON 字符串化后传入）
// 网络代理回传结构（base64 body 供 JS 侧还原字节流）
interface DrpyReqResult {
  status: number; body: string; headers: Record<string, string>;
}

interface DrpyInitCfg {
  skey: string; name: string; type: number; api: string;
  ext: string; header: Record<string, string>; timeout: number;
}

// drpy2 的 ES module 依赖库文本（rawfile 内置，worker init 时装载，见 drpy_worker.js）
interface DrpyLibs {
  cryptojs: string; cheerio: string; template: string; gbk: string;
}
const REQ_TIMEOUT_MS = 15000;
const MAX_WORKERS = 6;   // Worker 池上限：按站缓存运行环境，LRU 淘汰（每 Worker 约数 MB）

@ComponentV2
export struct DrpyWebContainer {
  // 供集成方挂载的不可见 Web 容器（1x1），承载 drpy JS 运行环境
  build() {
    Web({ src: $rawfile('drpy_shell.html'), controller: DrpyWebBridge.instance.controller })
      .width(1).height(1).opacity(0.01)
      .javaScriptAccess(true)
      .onPageEnd(() => { DrpyWebBridge.instance.onShellLoaded(getContext(this) as common.Context); })
  }
}

// Worker 池的一个站槽位：pendingInit 复用并发去重，lastUse 驱动 LRU 淘汰
interface WorkerSlot {
  pendingInit: Promise<void> | null;
  lastUse: number;
  ready: boolean;   // init 是否已完成——未完成的槽位不参与 LRU 淘汰（否则会掐死在途 init）
}

export class DrpyWebBridge {
  static instance: DrpyWebBridge = new DrpyWebBridge();
  controller: webview.WebviewController = new webview.WebviewController();
  private shellLoaded: boolean = false;
  private slots: Map<string, WorkerSlot> = new Map();   // skey → 池槽位（Worker 本体在壳页面 workerMap）
  private appCtx: common.Context | null = null;   // 壳页面加载时捕获，用于读 rawfile 依赖库
  private libsInjected: boolean = false;
  private jsMutex: Promise<void> = Promise.resolve();   // 页面求值串行锁：并发 runJavaScriptExt 会拿到损坏结果

  onShellLoaded(ctx: common.Context): void {
    this.shellLoaded = true;
    this.appCtx = ctx;
  }

  // 确保指定站的 Worker 就绪（按站幂等；并发调用共享同一 pendingInit）。
  // 池超上限时 LRU 淘汰最久未用的站（其未完成调用的轮询会超时，由调用方重试）
  async ensureReady(cfg: SiteConfig): Promise<void> {
    const slot = this.slots.get(cfg.key);
    if (slot !== undefined && slot.pendingInit !== null) {
      slot.lastUse = Date.now();
      await slot.pendingInit;
      slot.ready = true;
      return;
    }
    const s: WorkerSlot = { pendingInit: null, lastUse: Date.now(), ready: false };
    s.pendingInit = this.doInit(cfg);
    s.pendingInit.catch((_e: Object) => {
      // init 失败不粘滞：清槽位让下次 ensureReady 重新初始化（仅当未被更新的重建覆盖）
      const cur = this.slots.get(cfg.key);
      if (cur !== undefined && cur.pendingInit === s.pendingInit) { this.slots.delete(cfg.key); }
    });
    this.slots.set(cfg.key, s);
    this.evictOverflow(cfg.key);
    await s.pendingInit;
    s.ready = true;
  }

  // 池淘汰：超过 MAX_WORKERS 时终止最久未用站的 Worker（只淘汰 init 已完成的槽位）
  private evictOverflow(keepKey: string): void {
    if (this.slots.size <= MAX_WORKERS) { return; }
    let oldestKey = '';
    let oldest = Number.MAX_VALUE;
    this.slots.forEach((v: WorkerSlot, k: string) => {
      if (k !== keepKey && v.ready && v.lastUse < oldest) { oldest = v.lastUse; oldestKey = k; }
    });
    if (oldestKey === '') { return; }
    this.slots.delete(oldestKey);
    hilog.info(0x0000, TAG, 'evict worker skey=%{public}s', oldestKey);
    this.mutexRunJs(`__workerEvict(${JSON.stringify(oldestKey)})`).catch((_e: Object) => { /* 淘汰失败忽略 */ });
  }

  private async doInit(cfg: SiteConfig): Promise<void> {
    hilog.info(0x0000, TAG, 'doInit begin skey=%{public}s', cfg.key);
    await this.waitShell();
    // 1) 下载运行时与插件脚本（builtin:// data:// 即时；远端规则走网络）
    const drpyCode = await this.downloadText(cfg.api);
    let extCode = '';
    if (cfg.ext !== '') { try { extCode = await this.downloadText(cfg.ext); } catch (e) { /* ext 失败不阻塞 init */ } }
    hilog.info(0x0000, TAG, `skey=${cfg.key} drpy2 ${drpyCode.length}B, ext ${extCode.length}B`);
    // 2) 依赖库/代理（全站共享，一次性）；3) 注入并拉起该站 Worker（drpy2/ext 经参数传入防并发互踩）
    await this.ensureLibs();
    let proxyBase = '';
    try { proxyBase = await DrpyCorsProxy.ensureStarted(); } catch (e) { /* 代理失败不阻塞 init */ }
    await this.mutexRunJs(`window.__drpyProxyBase = ${JSON.stringify(proxyBase)}`);
    const initCfg: DrpyInitCfg = {
      skey: cfg.key, name: cfg.name, type: cfg.type, api: cfg.api,
      ext: cfg.ext, header: cfg.header, timeout: cfg.timeout
    };
    await this.mutexRunJs(`__workerInit(${JSON.stringify(cfg.key)}, ${JSON.stringify(JSON.stringify(initCfg))}, `
      + `${JSON.stringify(drpyCode)}, ${JSON.stringify(extCode)})`);
    await this.waitForFlag(cfg.key, 'drpy init', INIT_TIMEOUT_MS);
    hilog.info(0x0000, TAG, 'drpy init done skey=%{public}s', cfg.key);
  }

  // drpy2 依赖库一次性注入壳页面（全站共享；文本较大，避免每次 init 重复传输）
  private async ensureLibs(): Promise<void> {
    if (this.libsInjected) { return; }
    const cryptojs = await this.readRawfile('crypto-js.js');
    const cheerio = await this.readRawfile('cheerio.min.js');
    const template = await this.readRawfile('template.js');
    const gbk = await this.readRawfile('gbk.js');
    const libs: DrpyLibs = { cryptojs: cryptojs, cheerio: cheerio, template: template, gbk: gbk };
    await this.mutexRunJs(`window.__drpyLibs = ${JSON.stringify(libs)}`);
    this.libsInjected = true;
    hilog.info(0x0000, TAG, 'drpy libs injected');
  }

  private readRawfile(name: string): Promise<string> {
    if (this.appCtx === null) { return Promise.reject(new Error('桥无上下文（壳页面未加载）')); }
    return this.appCtx.resourceManager.getRawFileContent(name).then((u8: Uint8Array): string => {
      const td = new util.TextDecoder('utf-8');
      return td.decodeToString(u8);
    });
  }

  // 轮询壳页面 init 完成标志（按站）；标志以 '1'/'0' 表达（见壳页面 __drpyInitDone）；
  // init 失败时超时路径取按站错误串直接抛出，避免等满 20s 只泛泛报「超时」
  private async waitForFlag(skey: string, what: string, timeoutMs: number): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const v = this.unwrap(await this.mutexRunJs(`__drpyInitDone(${JSON.stringify(skey)})`));
      if (v === '1') { return; }
      if (v !== '' && v !== '0') { throw new Error(`${what}: ${v}`); }
      await new Promise<void>((res) => setTimeout(res, 50));
    }
    const lastErr = this.unwrap(await this.mutexRunJs(`__drpyInitError(${JSON.stringify(skey)})`));
    throw new Error(`${what} 超时${lastErr !== '' ? '，原因：' + lastErr : ''}`);
  }

  private async waitShell(): Promise<void> {
    const deadline = Date.now() + 8000;
    while (!this.shellLoaded && Date.now() < deadline) {
      await new Promise<void>((res) => setTimeout(res, 100));
    }
    if (!this.shellLoaded) { throw new Error('drpy 壳页面加载超时'); }
  }

  private async downloadText(url: string): Promise<string> {
    // data: URL：规则可内嵌进聚合源包文件（base64 或 URL 编码文本），离线可导入
    if (url.startsWith('data:')) {
      return decodeDataUrl(url);
    }
    // builtin://<文件名>：包内引擎资源（drpy2 运行时等），经桥本地加载
    if (url.startsWith('builtin://')) {
      return this.readRawfile('builtin/' + url.substring('builtin://'.length));
    }
    const r = await httpFetch(url, {});
    if (r.status !== 200) { throw new Error(`脚本下载失败 HTTP ${r.status}: ${url}`); }
    return r.text();
  }

  private async runJs(code: string): Promise<string> {
    try {
      const r = await this.controller.runJavaScriptExt(code);
      return r.getString();
    } catch (e) {
      hilog.error(0x0000, TAG, 'runJs ERR %{public}s', e instanceof Error ? e.message : JSON.stringify(e));
      throw e as Error;
    }
  }

  // 页面求值串行锁：所有 runJavaScriptExt 必须经此互斥——并发求值会拿到 ArkWeb 损坏的
  // 序列化结果（"This type not support..."）。锁只包住单次求值（毫秒级），不同站的调用
  // 流程（发起+轮询）在 promise 层交错共享锁，Worker 池的并行度不受影响
  private mutexRunJs(code: string): Promise<string> {
    const run = this.jsMutex.then((): Promise<string> => this.runJs(code));
    this.jsMutex = run.then((_s: string): void => {}, (_e: Object): void => {});
    return run;
  }

  // 调用指定站 Worker 的 DRPY 方法（契约：返回 JSON 字符串；10s 超时）
  // 发起走 __workerCall（同步返回 id），结果经 Worker 回写后轮询 __drpyResult 取回。
  // 不同站的调用互不阻塞（各自 Worker 并行）；同站的多个调用在 Worker 内排队（单线程）
  async call(method: string, args: string[], skey: string): Promise<string> {
    const slot = this.slots.get(skey);
    if (slot !== undefined) { slot.lastUse = Date.now(); }   // 活跃站的 LRU 时间戳随调用刷新
    hilog.info(0x0000, TAG, `call skey=${skey} ${method} args=${args.join(',')}`);
    const argsJson = JSON.stringify(args);
    const callId = this.unwrap(await this.mutexRunJs(
      `__workerCall(${JSON.stringify(skey)}, ${JSON.stringify(method)}, ${JSON.stringify(argsJson)})`));
    if (callId === 'noworker') { throw new Error(`DRPY.${method}: worker 未就绪（${skey}）`); }
    const deadline = Date.now() + CALL_TIMEOUT_MS;
    while (Date.now() < deadline) {
      const r = this.unwrap(await this.mutexRunJs(`__drpyResult(${JSON.stringify(callId)})`));
      if (r !== '') {
        hilog.info(0x0000, TAG, `call skey=${skey} ${method} done ${r.length}B: ${r.substring(0, 100)}`);
        let parsed: Record<string, Object>;
        try {
          parsed = JSON.parse(r) as Record<string, Object>;
        } catch (e) {
          throw new Error(`DRPY.${method} 返回非 JSON（${r.substring(0, 60)}）`);
        }
        if (parsed['__error'] !== undefined) { throw new Error(`${parsed['__error']}`); }
        return r;
      }
      await new Promise<void>((res) => setTimeout(res, 50));
    }
    throw new Error(`DRPY.${method} 调用超时`);
  }

  destroy(): void {
    this.shellLoaded = false;
    this.slots.forEach((_v: WorkerSlot, k: string) => {
      this.mutexRunJs(`__workerEvict(${JSON.stringify(k)})`).catch((_e: Object) => { /* 忽略 */ });
    });
    this.slots.clear();
  }

  // ArkWeb getString 以 JSON 形式回传表达式结果（字符串带引号、'' → '""'）。
  // 不还原会把 '""' 误判为已完成/有结果——init 轮询假阳性、call 结果污染的根源。
  private unwrap(raw: string): string {
    if (raw.length >= 2 && raw.startsWith('"') && raw.endsWith('"')) {
      try { return JSON.parse(raw) as string; } catch (e) { /* 非法转义退回原样 */ }
    }
    return raw;
  }
}
