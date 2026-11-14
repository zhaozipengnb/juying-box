/**
 * WebFetchBridge：ArkWeb 网页抓取层——真浏览器内核过 Cloudflare JS 挑战后抓渲染 HTML。
 * 背景：sidhub/libvio 等 "Just a moment" 挑战站,纯 HTTP(httpFetch)永远 403;
 *       ArkWeb 是真 Chromium,自动执行挑战脚本拿 cf_clearance。
 * 用法：
 *   1. Index/Home 挂载 WebFetchContainer()(1x1 不可见,about:blank 起始);
 *   2. fetchHtml(url) → 挑战等待轮询 outerHTML,非挑战页即返回;
 *   3. 成功后导出该 host 的 Cookie(cookieFor)+ 真实 UA(uaValue),调用方复用到
 *      httpFetch 快路径(cookie 与 UA 指纹绑定,必须成对),后续请求不再过 webview。
 * 单 webview 导航串行(互斥);DrpyWebBridge 的壳 webview 独立,互不干扰。
 */
import webview from '@ohos.web.webview';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'OKV-WEBF';
const NAV_TIMEOUT_MS = 20000;
const CHALLENGE_TIMEOUT_MS = 18000;
const POLL_MS = 600;

@ComponentV2
export struct WebFetchContainer {
  build() {
    Web({ src: 'about:blank', controller: WebFetchBridge.instance.controller })
      .width('100%').height('100%').opacity(0.01)
      .hitTestBehavior(HitTestMode.None)   // 点击穿透,不挡 UI
      .javaScriptAccess(true)
      .onControllerAttached(() => { WebFetchBridge.instance.onAttached(); })
      .onPageEnd(() => { WebFetchBridge.instance.onPageEnd(); })
  }
}

// 挑战页特征(任一命中即视为未过盾):CF 标准挑战 + 自建"浏览器验证"门(如 libvio 的
// 纯文本 403 Forbidden: browser verification required)。
// 注意:不能用 'challenge-platform' 做特征——CF 代理的站点在真实页面里也全程注入该脚本,
// 会把已通过盾的真页面误判为挑战页导致永远"超时"。
export function isCfChallenge(text: string): boolean {
  if (text.indexOf('<title>Just a moment') >= 0 || text.indexOf('cf_chl_opt') >= 0
    || text.indexOf('_cf_chl') >= 0) { return true; }
  const t = text.trim();
  return t.length < 500 && t.indexOf('browser verification required') >= 0;
}

export class WebFetchBridge {
  static instance: WebFetchBridge = new WebFetchBridge();
  controller: webview.WebviewController = new webview.WebviewController();
  private attached: boolean = false;
  private attachWaiters: (() => void)[] = [];
  private pageEndWaiters: (() => void)[] = [];
  private navMutex: Promise<void> = Promise.resolve();   // 单 webview 导航串行
  private ua: string = '';
  private cookieJar: Map<string, string> = new Map();    // host → Cookie 串

  onAttached(): void {
    this.attached = true;
    try { this.ua = this.controller.getUserAgent(); } catch (e) { this.ua = ''; }
    const ws = this.attachWaiters;
    this.attachWaiters = [];
    for (const w of ws) { w(); }
  }

  onPageEnd(): void {
    const ws = this.pageEndWaiters;
    this.pageEndWaiters = [];
    for (const w of ws) { w(); }
  }

  // fast-path:该 host 已过盾 → 返回缓存 Cookie(调用方须配对 uaValue())
  cookieFor(url: string): string {
    const m = url.match(/^[a-zA-Z]+:\/\/([^/]+)/);
    return m === null ? '' : (this.cookieJar.get(m[1]) ?? '');
  }

  uaValue(): string { return this.ua; }

  private async waitAttached(): Promise<void> {
    const deadline = Date.now() + 8000;
    while (!this.attached && Date.now() < deadline) {
      await new Promise<void>((res) => setTimeout(res, 100));
    }
    if (!this.attached) { throw new Error('webview 抓取层未挂载'); }
    if (this.ua === '') {
      try { this.ua = this.controller.getUserAgent(); } catch (e) { this.ua = ''; }
    }
  }

  // 在隐藏 Web 容器里执行任意 JS 并取回字符串结果(复用浏览器独有能力:
  // DecompressionStream 弹幕解压等)。结果通过 window.__evalResult 传递,轮询取回
  async evalJs(code: string): Promise<string> {
    await this.waitAttached();
    const deadline = Date.now() + 15000;
    await this.controller.runJavaScriptExt(code + ';window.__evalDone=1;');
    while (Date.now() < deadline) {
      let out = '';
      try {
        const r = await this.controller.runJavaScriptExt('String(window.__evalResult ?? \'\')');
        out = r.getString();
      } catch (e) { out = ''; }
      if (out !== '' || (await this.evalDone())) { return out; }
      await new Promise<void>((res) => setTimeout(res, 150));
    }
    return '';
  }

  private async evalDone(): Promise<boolean> {
    try {
      const r = await this.controller.runJavaScriptExt('String(window.__evalDone === 1)');
      return r.getString() === 'true';
    } catch (e) { return false; }
  }

  // 加载 url → 等 CF 挑战自动通过 → 返回渲染后 HTML
  async fetchHtml(url: string): Promise<string> {
    await this.waitAttached();
    const run = this.navMutex.then(async (): Promise<string> => {
      const endP = new Promise<void>((res) => { this.pageEndWaiters.push(res); });
      try { this.controller.loadUrl(url); }
      catch (e) { throw new Error('loadUrl 失败:' + JSON.stringify(e)); }
      await Promise.race([endP, new Promise<void>((res) => setTimeout(res, NAV_TIMEOUT_MS))]);
      const deadline = Date.now() + CHALLENGE_TIMEOUT_MS;
      let last = '';
      while (Date.now() < deadline) {
        let html = '';
        try {
          const r = await this.controller.runJavaScriptExt('document.documentElement.outerHTML');
          html = r.getString();
        } catch (e) { html = ''; }   // 挑战页重载瞬间求值可能失败,继续轮询
        if (html.length > 500 && !isCfChallenge(html)) {
          this.cacheCookies(url);
          hilog.info(0x0000, TAG, 'fetchHtml ok %{public}s len=%{public}d', url.substring(0, 80), html.length);
          return html;
        }
        last = html;
        await new Promise<void>((res) => setTimeout(res, POLL_MS));
      }
      hilog.error(0x0000, TAG, 'challenge timeout %{public}s len=%{public}d', url.substring(0, 60), last.length);
      throw new Error('CF 挑战等待超时');
    });
    this.navMutex = run.then((): void => {}, (_e: Object): void => {});
    return run;
  }

  private cacheCookies(url: string): void {
    try {
      const c: string = webview.WebCookieManager.fetchCookieSync(url);
      const m = url.match(/^[a-zA-Z]+:\/\/([^/]+)/);
      if (m !== null && c !== '') { this.cookieJar.set(m[1], c); }
    } catch (e) { /* cookie 导出失败不影响主流程 */ }
  }
}
