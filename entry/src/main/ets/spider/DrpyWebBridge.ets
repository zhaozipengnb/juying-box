// DrpyWebBridge：drpy JS 插件引擎的 Web 容器桥（单例）
// 职责：后台 Web 组件挂载壳页面（drpy_shell.html）、drpy2/ext 脚本注入、
//       JS 网络请求代理（arktsReq 入队 → httpFetch → __arktsResolve 回传）、
//       DRPY 方法调用（runJavaScriptExt + 超时）。
// 注意：V2 观察在 Navigation 根内容失效的同类 SDK 问题不影响本桥（全部命令式 API）。
import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { SiteConfig, b64encode } from 'common';
import { httpFetch, HttpFetchOptions } from '../net/HttpClient';

const TAG = 'OKV-WEB';

const CALL_TIMEOUT_MS = 10000;
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

export class DrpyWebBridge {
  static instance: DrpyWebBridge = new DrpyWebBridge();
  controller: webview.WebviewController = new webview.WebviewController();
  private shellLoaded: boolean = false;
  private currentSkey: string = '';
  private pendingInit: Promise<void> | null = null;
  private appCtx: common.Context | null = null;   // 壳页面加载时捕获，用于读 rawfile 依赖库
  private libsInjected: boolean = false;

  onShellLoaded(ctx: common.Context): void {
    this.shellLoaded = true;
    this.appCtx = ctx;
  }

  // 确保运行时就绪：注入 drpy2 与 ext 脚本（export default → window.__DRPY/__EXT 兼容替换，规避 module 跨域）+ init
  async ensureReady(cfg: SiteConfig): Promise<void> {
    hilog.info(0x0000, TAG, `ensureReady skey=${cfg.key} shellLoaded=${this.shellLoaded} cur=${this.currentSkey}`);
    if (this.shellLoaded && this.currentSkey === cfg.key && this.pendingInit !== null) {
      await this.pendingInit;
      return;
    }
    this.currentSkey = cfg.key;
    this.pendingInit = this.doInit(cfg);
    await this.pendingInit;
  }

  private async doInit(cfg: SiteConfig): Promise<void> {
    hilog.info(0x0000, TAG, 'doInit begin');
    await this.waitShell();
    hilog.info(0x0000, TAG, 'shell ready, downloading scripts');
    // 1) 下载运行时与插件脚本
    const drpyCode = await this.downloadText(cfg.api);
    let extCode = '';
    if (cfg.ext !== '') { try { extCode = await this.downloadText(cfg.ext); } catch (e) { /* ext 失败不阻塞 init */ } }
    hilog.info(0x0000, TAG, `ext source ${extCode.length}B captured`);
    hilog.info(0x0000, TAG, `drpy2 downloaded ${drpyCode.length}B, ext ${extCode.length}B`);

    // 2) Worker init：依赖库 + 代码文本注入壳页面 → 转发 Worker → 轮询完成标志
    await this.ensureLibs();
    await this.runJs(`window.__drpy2Code = ${JSON.stringify(drpyCode)}`);
    await this.runJs(`window.__extCode = ${JSON.stringify(extCode)}`);
    const initCfg: DrpyInitCfg = {
      skey: cfg.key, name: cfg.name, type: cfg.type, api: cfg.api,
      ext: cfg.ext, header: cfg.header, timeout: cfg.timeout
    };
    await this.runJs(`__workerInit(${JSON.stringify(JSON.stringify(initCfg))})`);
    await this.waitForFlag('__drpyInitDone()', 'drpy init', INIT_TIMEOUT_MS);
    hilog.info(0x0000, TAG, 'drpy init done');
  }

  // drpy2 依赖库一次性注入壳页面（跨 skey 复用；文本较大，避免每次 init 重复传输）
  private async ensureLibs(): Promise<void> {
    if (this.libsInjected) { return; }
    const cryptojs = await this.readRawfile('crypto-js.js');
    const cheerio = await this.readRawfile('cheerio.min.js');
    const template = await this.readRawfile('template.js');
    const gbk = await this.readRawfile('gbk.js');
    const libs: DrpyLibs = { cryptojs: cryptojs, cheerio: cheerio, template: template, gbk: gbk };
    await this.runJs(`window.__drpyLibs = ${JSON.stringify(libs)}`);
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

  // 轮询壳页面标志函数（Worker 异步完成的等待）；标志以 '1'/'0' 表达（见壳页面 __drpyInitDone）；
  // init 失败时会返回具体错误字符串（非 '0'/'1'），直接抛出，避免等满 20s 只泛泛报「超时」
  private async waitForFlag(flagExpr: string, what: string, timeoutMs: number): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const v = this.unwrap(await this.runJs(flagExpr));
      if (v === '1') { return; }
      if (v !== '' && v !== '0') { throw new Error(`${what}: ${v}`); }
      await new Promise<void>((res) => setTimeout(res, 200));
    }
    const lastErr = this.unwrap(await this.runJs('__drpyInitError()'));
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
    // 内置源：builtin://<文件名> 直接读 rawfile/builtin/（规则与运行时随包分发，不走网络）
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

  // 调用 DRPY 方法（契约：返回 JSON 字符串；10s 超时）
  // 发起走 __workerCall（同步返回 id），结果经 Worker 回写后轮询 __drpyResult 取回
  async call(method: string, args: string[]): Promise<string> {
    hilog.info(0x0000, TAG, `call ${method} args=${args.join(',')}`);
    const argsJson = JSON.stringify(args);
    const callId = this.unwrap(await this.runJs(`__workerCall(${JSON.stringify(method)}, ${JSON.stringify(argsJson)})`));
    const deadline = Date.now() + CALL_TIMEOUT_MS;
    while (Date.now() < deadline) {
      const r = this.unwrap(await this.runJs(`__drpyResult(${JSON.stringify(callId)})`));
      if (r !== '') {
        hilog.info(0x0000, TAG, `call ${method} done ${r.length}B: ${r.substring(0, 100)}`);
        const parsed = JSON.parse(r) as Record<string, Object>;
        if (parsed['__error'] !== undefined) { throw new Error(`${parsed['__error']}`); }
        return r;
      }
      await new Promise<void>((res) => setTimeout(res, 200));
    }
    throw new Error(`DRPY.${method} 调用超时`);
  }

  destroy(): void {
    this.shellLoaded = false;
    this.currentSkey = '';
    this.pendingInit = null;
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
