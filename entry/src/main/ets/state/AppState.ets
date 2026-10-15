// 全局状态（V2）：配置 + 当前站点 + 引擎实例。测试可注入 testFetchText 替代真网络。
import { TvboxConfig, SiteConfig, SiteDriver, CmsJsonApi, FetchText, decodeConfigContent } from 'common';
import { httpFetch } from '../net/HttpClient';
import { ConfigStore, serializeConfig } from './ConfigStore';

export type AppPhase = 'initing' | 'config' | 'home';

// 错误信息提取：Error/BusinessError/普通对象统一取 message（避免 [object Object]）
function errText(e: Object): string {
  if (e instanceof Error) { return e.message; }
  const m = (e as Record<string, Object>)['message'];
  if (typeof m === 'string' && m !== '') { return m; }
  return JSON.stringify(e);
}


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
  // 持久化存储引用：EntryAbility 装配后持有，供 persistCurrent 落盘（对象非观察目标，不加 @Trace）
  store: ConfigStore | null = null;

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
    console.info('OKV loadFromUrl start url=' + url);
    try {
      let content: string | Uint8Array;
      if (this.testFetchText !== undefined) {
        // 测试注入：fake 直接返回文本，走解码链文本分支
        content = await this.testFetchText(url);
      } else {
        // 生产：取原始字节走完整四层解码（JPEG 伪装订阅需 Uint8Array，string 会丢 JPEG 分支）
        const r = await httpFetch(url, {});
        content = new Uint8Array(r.body);
      }
      const config = decodeConfigContent(content);
      console.info('OKV decoded sites=' + config.sites.length + ' bytes=' + content.length);
      if (config.sites.length === 0) {
        this.errMsg = '订阅中没有可用站点';
        this.phase = 'config';
        return false;
      }
      // MVP 引擎仅支持 type 1（CMS JSON）；type 3（JS 插件）需 Spider 引擎，下阶段实现
      const cmsCount = config.sites.filter((s: SiteConfig): boolean => s.type === 1).length;
      if (cmsCount === 0) {
        this.errMsg = '该订阅共 ' + config.sites.length + ' 个站点，但全部为 JS 插件类型（暂不支持，当前仅支持 CMS JSON 类型站点）';
        this.phase = 'config';
        return false;
      }
      this.config = config;
      this.subUrl = url;
      this.buildDriver(config.sites[0]);
      this.phase = 'home';
      console.info('OKV phase->home ok');
      return true;
    } catch (e) {
      const msg = errText(e as Object);
      console.info('OKV loadFromUrl ERR ' + msg);
      this.errMsg = msg;
      this.phase = 'config';
      return false;
    }
  }

  async initFromStore(store: ConfigStore): Promise<void> {
    this.store = store;
    this.phase = 'initing';
    const stored = store.load();
    if (stored === null) { this.phase = 'config'; return; }
    try {
      // 存的是 serializeConfig 序列化后的 JSON 字符串，直接走解码链文本分支
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

  // 清空当前配置回到订阅输入页（坏订阅自救入口）
  clearConfig(): void {
    if (this.store !== null) { this.store.clear(); }
    this.config = null;
    this.currentSite = null;
    this.driver = null;
    this.subUrl = '';
    this.errMsg = '';
    this.phase = 'config';
  }

  // 订阅加载成功后持久化当前配置（fire-and-forget，调用方无需等待）
  persistCurrent(): void {
    if (this.store !== null && this.config !== null && this.subUrl !== '') {
      this.store.save(this.subUrl, serializeConfig(this.subUrl, this.config));
    }
  }
}
