// DrpyWebBridge：drpy JS 插件引擎的 Web 容器桥（单例）
// 职责：后台 Web 组件挂载壳页面（drpy_shell.html）、drpy2/ext 脚本注入、
//       JS 网络请求代理（arktsReq 入队 → httpFetch → __arktsResolve 回传）、
//       DRPY 方法调用（runJavaScriptExt + 超时）。
// 注意：V2 观察在 Navigation 根内容失效的同类 SDK 问题不影响本桥（全部命令式 API）。
import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
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
const REQ_TIMEOUT_MS = 15000;

@ComponentV2
export struct DrpyWebContainer {
  // 供集成方挂载的不可见 Web 容器（1x1），承载 drpy JS 运行环境
  build() {
    Web({ src: $rawfile('drpy_shell.html'), controller: DrpyWebBridge.instance.controller })
      .width(1).height(1).opacity(0.01)
      .javaScriptAccess(true)
      .onPageEnd(() => { DrpyWebBridge.instance.onShellLoaded(); })
  }
}

export class DrpyWebBridge {
  static instance: DrpyWebBridge = new DrpyWebBridge();
  controller: webview.WebviewController = new webview.WebviewController();
  private shellLoaded: boolean = false;
  private currentSkey: string = '';
  private pendingInit: Promise<void> | null = null;

  onShellLoaded(): void { this.shellLoaded = true; }

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
    // 2) ES module 兼容注入：export default X → window.__DRPY = X（最后一处）
    hilog.info(0x0000, TAG, `drpy2 downloaded ${drpyCode.length}B, ext ${extCode.length}B`);
    const drpyInjected = replaceDefaultExport(drpyCode, '__DRPY');
    await this.runJs(drpyInjected);
    hilog.info(0x0000, TAG, 'drpy2 injected');

    // 3) Worker init：代码文本注入壳页面 → 转发 Worker → 轮询完成标志
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

  // 轮询壳页面标志函数（Worker 异步完成的等待）
  private async waitForFlag(flagExpr: string, what: string, timeoutMs: number): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const v = await this.runJs(flagExpr);
      if (v !== '') { return; }
      await new Promise<void>((res) => setTimeout(res, 200));
    }
    throw new Error(`${what} 超时`);
  }

  private async waitShell(): Promise<void> {
    const deadline = Date.now() + 8000;
    while (!this.shellLoaded && Date.now() < deadline) {
      await new Promise<void>((res) => setTimeout(res, 100));
    }
    if (!this.shellLoaded) { throw new Error('drpy 壳页面加载超时'); }
  }

  private async downloadText(url: string): Promise<string> {
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
    const callId = (await this.runJs(`__workerCall(${JSON.stringify(method)}, ${JSON.stringify(argsJson)})`)).replace(/"/g, '');
    const deadline = Date.now() + CALL_TIMEOUT_MS;
    while (Date.now() < deadline) {
      const r = await this.runJs(`__drpyResult(${JSON.stringify(callId)})`);
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
}

// ES module 兼容：把末尾的 export default X 替换为 window.<global> = X
function replaceDefaultExport(code: string, globalName: string): string {
  const idx = code.lastIndexOf('export default');
  if (idx < 0) { return code; }
  return code.substring(0, idx) + `window.${globalName} =` + code.substring(idx + 'export default'.length);
}
