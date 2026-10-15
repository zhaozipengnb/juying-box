// DrpyWebBridge：drpy JS 插件引擎的 Web 容器桥（单例）
// 职责：后台 Web 组件挂载壳页面（drpy_shell.html）、drpy2/ext 脚本注入、
//       JS 网络请求代理（arktsReq 入队 → httpFetch → __arktsResolve 回传）、
//       DRPY 方法调用（runJavaScriptExt + 超时）。
// 注意：V2 观察在 Navigation 根内容失效的同类 SDK 问题不影响本桥（全部命令式 API）。
import { webview } from '@kit.ArkWeb';
import { SiteConfig, b64encode } from 'common';
import { httpFetch, HttpFetchOptions } from '../net/HttpClient';

const CALL_TIMEOUT_MS = 10000;

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
      .javaScriptProxy({
        object: new DrpyJsApi(),
        name: 'arktsReq',
        methodList: ['req'],
        controller: DrpyWebBridge.instance.controller
      })
      .onPageEnd(() => { DrpyWebBridge.instance.onShellLoaded(); })
  }
}

// 暴露给 JS 的同步入口对象（fetch 劫持通过它入队网络请求）
export class DrpyJsApi {
  req(id: string, url: string, optsJson: string): void {
    DrpyWebBridge.instance.dispatchReq(id, url, optsJson);
  }
}

export class DrpyWebBridge {
  static instance: DrpyWebBridge = new DrpyWebBridge();
  controller: webview.WebviewController = new webview.WebviewController();
  private shellLoaded: boolean = false;
  private currentSkey: string = '';
  private pendingInit: Promise<void> | null = null;

  onShellLoaded(): void { this.shellLoaded = true; }

  // JS 网络请求入队（同步返回，异步回传）
  dispatchReq(id: string, url: string, optsJson: string): void {
    let opts: Record<string, Object> = {};
    try { opts = JSON.parse(optsJson) as Record<string, Object>; } catch (e) { /* 空对象兜底 */ }
    const headersRaw = (opts['headers'] ?? {}) as Record<string, Object>;
    const headers: Record<string, string> = {};
    const keys = Object.keys(headersRaw);
    for (const k of keys) { headers[k] = `${headersRaw[k]}`; }
    const method = typeof opts['method'] === 'string' ? opts['method'] as string : 'GET';
    const fetchOpts: HttpFetchOptions = { method: method, headers: headers };
    httpFetch(url, fetchOpts).then((r) => {
      const reqResult: DrpyReqResult = {
        status: r.status,
        body: b64encode(new Uint8Array(r.body)),
        headers: r.headers
      };
      const resultJson = JSON.stringify(reqResult);
      return this.controller.runJavaScriptExt(`__arktsResolve("${id}", ${JSON.stringify(resultJson)})`);
    }).catch((e: Object) => {
      const msg = e instanceof Error ? e.message : JSON.stringify(e);
      return this.controller.runJavaScriptExt(`__arktsResolve("${id}", ${JSON.stringify(JSON.stringify({ error: msg }))})`);
    }).catch((e: Object) => {
      // 回传失败（页面已销毁/超时）静默；JS 侧由自身超时兜底
    });
  }

  // 确保运行时就绪：注入 drpy2 与 ext 脚本（export default → window.__DRPY/__EXT 兼容替换，规避 module 跨域）+ init
  async ensureReady(cfg: SiteConfig): Promise<void> {
    if (this.shellLoaded && this.currentSkey === cfg.key && this.pendingInit !== null) {
      await this.pendingInit;
      return;
    }
    this.currentSkey = cfg.key;
    this.pendingInit = this.doInit(cfg);
    await this.pendingInit;
  }

  private async doInit(cfg: SiteConfig): Promise<void> {
    await this.waitShell();
    // 1) 下载运行时与插件脚本
    const drpyCode = await this.downloadText(cfg.api);
    let extCode = '';
    if (cfg.ext !== '') { try { extCode = await this.downloadText(cfg.ext); } catch (e) { /* ext 失败不阻塞 init */ } }
    // 2) ES module 兼容注入：export default X → window.__DRPY = X（最后一处）
    const drpyInjected = replaceDefaultExport(drpyCode, '__DRPY');
    await this.runJs(drpyInjected);
    if (extCode !== '') {
      await this.runJs(replaceDefaultExport(extCode, '__EXT'));
    }
    // 3) init（drpy2 init 接收站点配置 JSON 字符串；ext 通过 cfg.ext 传递）
    const initCfg: DrpyInitCfg = {
      skey: cfg.key, name: cfg.name, type: cfg.type, api: cfg.api,
      ext: cfg.ext, header: cfg.header, timeout: cfg.timeout
    };
    const cfgJson = JSON.stringify(initCfg);
    await this.runJs(`globalThis.__drpy.init(${JSON.stringify(cfgJson)})`);
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
    const r = await this.controller.runJavaScriptExt(code);
    return r.getString();
  }

  // 调用 DRPY 方法（契约：返回 JSON 字符串；10s 超时）
  async call(method: string, args: string[]): Promise<string> {
    const argsLiteral = args.map((a: string): string => JSON.stringify(a)).join(',');
    const p = this.runJs(`globalThis.__drpy.call(${JSON.stringify(method)}${args.length > 0 ? ',' + argsLiteral : ''})`);
    const timeout = new Promise<string>((_, rej) => {
      setTimeout(() => { rej(new Error(`DRPY.${method} 调用超时`)); }, CALL_TIMEOUT_MS);
    });
    return Promise.race([p, timeout]);
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
