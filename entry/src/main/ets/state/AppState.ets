// 全局状态（V2）：配置 + 当前站点 + 引擎实例。测试可注入 testFetchText 替代真网络。
import { TvboxConfig, SiteConfig, SiteDriver, CmsJsonApi, AppYsApi, XmlCmsDriver, ProxyDriver, FetchText, decodeConfigContent,
  siteEngine, isSiteSupported, resolveSiteUrls } from 'common';
import { httpFetch } from '../net/HttpClient';
import { AppSettings } from './AppSettings';
import { ConfigStore, serializeConfig } from './ConfigStore';
import { DrpyDriver } from '../spider/DrpyDriver';
import { hilog } from '@kit.PerformanceAnalysisKit';

export type AppPhase = 'initing' | 'home';

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
  @Trace isPackSource: boolean = false;   // 当前源为本地源包（点播弹窗 📁 导入）而非互联网订阅
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

  // 站点引擎路由：type 3 且 api 为 http(s) URL（drpy JS 插件）→ DrpyDriver（Web 容器引擎）；
  // type 1（CMS JSON）→ CmsJsonApi；type 0（MacCMS XML 采集）→ XmlCmsDriver；
  // type 3 非 URL（csp_* 类名 = TVBox JAR spider，实体在 Android JAR 内，不可当 URL 下载）及其他类型不支持，
  // 不建 driver（首站选择/switchSite 均经 isSiteSupported 过滤，此处兜底）。
  private buildDriver(site: SiteConfig): void {
    const engine = siteEngine(site);
    if (engine === 'js') {
      this.currentSite = site;
      this.driver = new DrpyDriver(site);
    } else if (engine === 'cms') {
      this.currentSite = site;
      this.driver = new CmsJsonApi(site, this.makeFetchText());
    } else if (engine === 'appys') {
      this.currentSite = site;
      this.driver = new AppYsApi(site, this.makeFetchText());
    } else if (engine === 'xml') {
      this.currentSite = site;
      this.driver = new XmlCmsDriver(site, this.makeFetchText());
    } else if (engine === 'proxy') {
      const proxyUrl = AppSettings.instance.proxyUrl;
      if (proxyUrl !== '') {
        this.currentSite = site;
        this.driver = new ProxyDriver(site, this.makeFetchText(), proxyUrl);
      }
    }
  }

  // 首个受引擎支持的站点（订阅可能是纯 JAR 型，首站未必可用）
  private firstSupportedSite(config: TvboxConfig): SiteConfig | null {
    // 优先非代理源（CMS/XML/JS），代理源仅在没有其他选择时才用；禁用站点跳过
    for (const s of config.sites) {
      if (siteEngine(s) !== 'proxy' && isSiteSupported(s) && this.canDrive(s) && !AppSettings.instance.isSiteDisabled(s.key)) { return s; }
    }
    for (const s of config.sites) {
      if (isSiteSupported(s) && this.canDrive(s) && !AppSettings.instance.isSiteDisabled(s.key)) { return s; }
    }
    return null;
  }

  // 站点管理排序：交换 config.sites 中两项并持久化当前配置快照（订阅与源包通用）
  // 站点管理删除：移出 config.sites 并持久化；若删的是当前站则切到首个可用源
  removeSite(key: string): void {
    const cfg = this.config;
    if (cfg === null) { return; }
    const idx = cfg.sites.findIndex((s: SiteConfig): boolean => s.key === key);
    if (idx < 0) { return; }
    cfg.sites.splice(idx, 1);
    AppSettings.instance.disabledSites = AppSettings.instance.disabledSites.filter((k: string): boolean => k !== key);
    AppSettings.instance.save();
    if (this.store !== null) {
      this.store.save(this.subUrl, serializeConfig(this.subUrl, cfg));
    }
    if (this.currentSite?.key === key) {
      this.currentSite = null;
      this.driver = null;
      const next = this.firstSupportedSite(cfg);
      if (next !== null) {
        this.buildDriver(next);
        if (this.store !== null) { this.store.saveCurrentSite(next.key); }
      }
    }
  }

  reorderSite(from: number, to: number): void {
    const cfg = this.config;
    if (cfg === null) { return; }
    if (from < 0 || to < 0 || from >= cfg.sites.length || to >= cfg.sites.length || from === to) { return; }
    const moved = cfg.sites[from];
    cfg.sites.splice(from, 1);
    cfg.sites.splice(to, 0, moved);
    if (this.store !== null) {
      this.store.save(this.subUrl, serializeConfig(this.subUrl, cfg));
    }
  }

  // proxy 引擎需要 proxyUrl 配置才能驱动
  canDrive(site: SiteConfig): boolean {
    const e = siteEngine(site);
    if (e === 'proxy') { return AppSettings.instance.proxyUrl !== ''; }
    return true;
  }

  // 装配配置后选定起始站点：优先上次记住的 siteKey（存在且受支持），否则首个受支持站
  private pickInitialSite(config: TvboxConfig): void {
    const remembered: string = this.store?.loadCurrentSite() ?? '';
    if (remembered !== '') {
      for (const s of config.sites) {
        if (s.key === remembered && isSiteSupported(s) && this.canDrive(s) && siteEngine(s) !== 'proxy'
          && !AppSettings.instance.isSiteDisabled(s.key)) {
          this.buildDriver(s);
          return;
        }
      }
    }
    this.buildDriver(this.firstSupportedSite(config) as SiteConfig);
    console.info('OKV pickSite result=' + (this.currentSite?.key ?? 'null') + ' driver=' + (this.driver === null ? 'null' : 'ok'));
  }

  // 装配一份配置进 home 态：合并聚合源包 → 校验有受支持站点 → 选首站建 driver。
  // 返回 false 时不动 phase（调用方展示 errMsg；订阅加载失败仍停留在发起页面）。
  private applyConfig(config: TvboxConfig): boolean {
    this.stripLegacyBuiltinRefs(config);
    if (config.sites.length === 0) { return false; }
    const usableCount = config.sites.filter((s: SiteConfig): boolean => isSiteSupported(s)).length;
    if (usableCount === 0) {
      this.errMsg = '该订阅共 ' + config.sites.length + ' 个站点，但没有本引擎支持的源（支持 CMS JSON、XML 采集、drpy JS、AppYs；其余 JAR 源暂不支持）';
      return false;
    }
    this.config = config;
    this.pickInitialSite(config);
    this.phase = 'home';
    return true;
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
      resolveSiteUrls(config, url);
      if (!this.applyConfig(config)) {
        if (this.errMsg === '') { this.errMsg = '订阅中没有可用站点'; }
        return false;
      }
      this.subUrl = url;
      this.isPackSource = false;
      console.info('OKV phase->home ok');
      return true;
    } catch (e) {
      const msg = errText(e as Object);
      console.info('OKV loadFromUrl ERR ' + msg);
      this.errMsg = msg;
      return false;
    }
  }

  async initFromStore(store: ConfigStore): Promise<void> {
    this.store = store;
    this.phase = 'initing';
    const stored = store.load();
    // 无持久化源：进首页空态引导（点播弹窗填订阅链接或 📁 导入本地源包）
    if (stored === null) { this.phase = 'home'; return; }
    try {
      // 存的是 serializeConfig 序列化后的 JSON 字符串，直接走解码链文本分支
      const config = decodeConfigContent(stored.configJson);
      resolveSiteUrls(config, stored.url);   // 旧版本持久化数据里的相对路径同样归一
      if (!this.applyConfig(config)) {
        console.info('OKV initFromStore 无可用站点，首页空态引导');
        this.config = null;
        this.phase = 'home';
        return;
      }
      this.subUrl = stored.url;
      this.isPackSource = stored.url === '';
    } catch (e) {
      console.info('OKV initFromStore ERR ' + (e instanceof Error ? e.message : JSON.stringify(e)));
      this.phase = 'home';
    }
  }

  // 按站点构造引擎实例（不动 currentSite/driver 状态）：
  // 聚合搜索等需要并发访问多站的场景使用；js 引擎为单 Web 容器（跨 skey 互斥），聚合场景勿用。
  makeDriverFor(site: SiteConfig): SiteDriver | null {
    const engine = siteEngine(site);
    if (engine === 'cms') { return new CmsJsonApi(site, this.makeFetchText()); }
    if (engine === 'appys') { return new AppYsApi(site, this.makeFetchText()); }
    if (engine === 'xml') { return new XmlCmsDriver(site, this.makeFetchText()); }
    if (engine === 'js') { return new DrpyDriver(site); }
    if (engine === 'proxy') {
      const proxyUrl = AppSettings.instance.proxyUrl;
      if (proxyUrl === '') { return null; }
      return new ProxyDriver(site, this.makeFetchText(), proxyUrl);
    }
    return null;
  }

  switchSite(key: string): boolean {
    if (this.config === null) { return false; }
    for (const s of this.config.sites) {
      if (s.key === key) {
        if (!isSiteSupported(s) || !this.canDrive(s) || AppSettings.instance.isSiteDisabled(s.key)) { return false; }   // 不支持/未配置代理/已禁用的源拒绝切换
        this.buildDriver(s);
        if (this.store !== null) { this.store.saveCurrentSite(key); }   // 跨重启记忆选中源
        return true;
      }
    }
    return false;
  }

  // 清除订阅回到仅源包的首页（首页设置页/错误卡片的「清除订阅」入口；不离开 home 态，无需路由操作）
  clearConfig(): void {
    if (this.store !== null) { this.store.clear(); }
    this.config = null;
    this.currentSite = null;
    this.driver = null;
    this.isPackSource = false;
    this.phase = 'home';
  }

  // 订阅加载成功后持久化当前配置（fire-and-forget，调用方无需等待）
  persistCurrent(): void {
    if (this.store !== null && this.config !== null && this.subUrl !== '') {
      this.store.save(this.subUrl, serializeConfig(this.subUrl, this.config));
    }
  }

  // ---------- 本地源包（点播弹窗 📁 导入，替换当前互联网订阅源；与订阅二选一） ----------

  // 导入聚合源包文本（TVBox 配置格式 {sites:[...]} 或完整配置；规则可内嵌 data: URL）。
  // 语义：整体替换当前源（覆盖此前导入的源包或互联网订阅），subUrl 置空以本地源包形态持久化。
  // 返回是否成功；失败置 errMsg 由调用方提示。
  loadFromPackText(text: string): boolean {
    this.errMsg = '';
    try {
      const config = decodeConfigContent(text);
      if (config.sites.length === 0) {
        this.errMsg = '源包中没有站点';
        return false;
      }
      if (!this.applyConfig(config)) {
        if (this.errMsg === '') { this.errMsg = '源包中没有可用站点'; }
        return false;
      }
      this.subUrl = '';
      this.isPackSource = true;
      if (this.store !== null) { this.store.save('', serializeConfig('', config)); }
      console.info('OKV loadFromPackText sites=' + config.sites.length);
      return true;
    } catch (e) {
      this.errMsg = e instanceof Error ? e.message : JSON.stringify(e);
      return false;
    }
  }

  // 迁移：旧版本随包内置的站点（ext 指向已删除的 rawfile 规则）在配置装载时剥除
  private stripLegacyBuiltinRefs(config: TvboxConfig): void {
    const before = config.sites.length;
    config.sites = config.sites.filter((s: SiteConfig): boolean =>
      !(s.ext.startsWith('builtin://') && s.ext !== 'builtin://drpy2.min.js'));
    if (before - config.sites.length > 0) {
      console.info('OKV stripLegacyBuiltinRefs removed=' + (before - config.sites.length));
    }
  }
}
