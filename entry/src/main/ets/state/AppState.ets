// 全局状态（V2）：配置 + 当前站点 + 引擎实例。测试可注入 testFetchText 替代真网络。
import { TvboxConfig, SiteConfig, SiteDriver, CmsJsonApi, AppYsApi, XmlCmsDriver, ProxyDriver, FetchText, decodeConfigContent,
  siteEngine, isSiteSupported, resolveSiteUrls } from 'common';
import { httpFetch } from '../net/HttpClient';
import { AppSettings } from './AppSettings';
import { ConfigStore, serializeConfig } from './ConfigStore';
import { DrpyDriver } from '../spider/DrpyDriver';
import { hilog } from '@kit.PerformanceAnalysisKit';

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
    // 优先非代理源（CMS/XML/JS），代理源仅在没有其他选择时才用
    for (const s of config.sites) {
      if (siteEngine(s) !== 'proxy' && isSiteSupported(s) && this.canDrive(s)) { return s; }
    }
    for (const s of config.sites) {
      if (isSiteSupported(s) && this.canDrive(s)) { return s; }
    }
    return null;
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
        if (s.key === remembered && isSiteSupported(s) && this.canDrive(s) && siteEngine(s) !== 'proxy') {
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
    this.mergeSourcePacks(config);
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

  // 无订阅起步：仅聚合源包（首启/清除订阅后）。未导入任何源包时回落 config 页（引导导入或填订阅）。
  private startPacksOnly(): boolean {
    const empty: TvboxConfig = { spider: '', wallpaper: '', sites: [], lives: [], parses: [] };
    this.subUrl = '';
    this.errMsg = '';
    if (this.applyConfig(empty)) {
      console.info('OKV startPacksOnly sites=' + (this.config as TvboxConfig).sites.length);
      return true;
    }
    this.phase = 'config';
    return false;
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
    this.initSourcePacks();
    const stored = store.load();
    // 无持久化订阅：有源包直接进首页，订阅在首页设置里维护
    if (stored === null) { this.startPacksOnly(); return; }
    try {
      // 存的是 serializeConfig 序列化后的 JSON 字符串，直接走解码链文本分支
      const config = decodeConfigContent(stored.configJson);
      resolveSiteUrls(config, stored.url);   // 旧版本持久化数据里的相对路径同样归一
      if (!this.applyConfig(config)) {
        console.info('OKV initFromStore 无可用站点，回退源包');
        this.startPacksOnly();
        return;
      }
      this.subUrl = stored.url;
    } catch (e) {
      console.info('OKV initFromStore ERR ' + (e instanceof Error ? e.message : JSON.stringify(e)));
      this.startPacksOnly();
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
        if (!isSiteSupported(s) || !this.canDrive(s)) { return false; }   // 不支持或未配置代理的源拒绝切换
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
    this.startPacksOnly();
  }

  // 订阅加载成功后持久化当前配置（fire-and-forget，调用方无需等待）
  persistCurrent(): void {
    if (this.store !== null && this.config !== null && this.subUrl !== '') {
      this.store.save(this.subUrl, serializeConfig(this.subUrl, this.config));
    }
  }

  // ---------- 聚合源包（app 不内置站点；用户经设置页导入源包文件，随订阅合并，跨重启可用） ----------
  private packSites: SiteConfig[] = [];
  private packsLoaded: boolean = false;

  // 注入源包站点（纯逻辑，测试可直调；生产从 ConfigStore 恢复）
  setSourcePacks(sites: SiteConfig[]): void {
    this.packSites = sites;
    this.packsLoaded = true;
  }

  // 从 ConfigStore 恢复已导入的源包；失败降级为空（不影响订阅本身）
  initSourcePacks(): void {
    if (this.packsLoaded || this.store === null) { return; }
    try {
      const json = this.store.loadSourcePacks();
      if (json === '') { this.packsLoaded = true; return; }
      const arr = JSON.parse(json) as SiteConfig[];
      if (Array.isArray(arr)) { this.packSites = arr; }
      this.packsLoaded = true;
      hilog.info(0x0000, 'OKV', 'source packs loaded %{public}d', this.packSites.length);
    } catch (e) {
      this.packsLoaded = true;
      hilog.error(0x0000, 'OKV', 'source packs load ERR %{public}s', e instanceof Error ? e.message : JSON.stringify(e));
    }
  }

  // 导入聚合源包文件（TVBox 配置格式：{sites:[...]} 或完整配置；规则可内嵌为 data: URL）。
  // 同 key 覆盖旧条目，其余追加；持久化并就地并入当前配置（换新 config 对象驱动 UI 刷新）。
  // 返回导入后的源包站点总数；解析失败抛错由调用方提示。
  importSourcePack(text: string): number {
    const incoming = decodeConfigContent(text).sites;
    if (incoming.length === 0) { throw new Error('源包中没有站点'); }
    const byKey: Map<string, SiteConfig> = new Map();
    for (const s of this.packSites) { byKey.set(s.key, s); }
    for (const s of incoming) { byKey.set(s.key, s); }
    this.packSites = Array.from(byKey.values());
    if (this.store !== null) { this.store.saveSourcePacks(JSON.stringify(this.packSites)); }
    this.packsLoaded = true;
    // 就地重并：已有配置时剥掉旧源包条目再合并（换对象身份触发观察刷新）
    if (this.config !== null) {
      const packKeys: Set<string> = new Set(this.packSites.map((s: SiteConfig): string => s.key));
      const kept = this.config.sites.filter((s: SiteConfig): boolean => !packKeys.has(s.key));
      const next: TvboxConfig = {
        spider: this.config.spider, wallpaper: this.config.wallpaper,
        sites: kept, lives: this.config.lives, parses: this.config.parses
      };
      this.mergeSourcePacks(next);
      this.config = next;
    }
    console.info('OKV importSourcePack total=' + this.packSites.length);
    return this.packSites.length;
  }

  // 清除全部已导入源包：持久化清空 + 当前配置移除源包站点（当前站被移除时自动重选）
  clearSourcePacks(): void {
    this.packSites = [];
    if (this.store !== null) { this.store.clearSourcePacks(); }
    if (this.config !== null) {
      const next: TvboxConfig = {
        spider: this.config.spider, wallpaper: this.config.wallpaper,
        sites: this.config.sites.filter((s: SiteConfig): boolean => !this.packKeys().has(s.key)),
        lives: this.config.lives, parses: this.config.parses
      };
      this.mergeSourcePacks(next);
      this.config = next;
      const curKey = this.currentSite?.key ?? '';
      if (curKey !== '' && !next.sites.some((s: SiteConfig): boolean => s.key === curKey)) {
        this.currentSite = null;
        this.driver = null;
        this.pickInitialSite(next);
      }
    }
  }

  private packKeys(): Set<string> {
    return new Set<string>(this.packSites.map((s: SiteConfig): string => s.key));
  }

  // 已导入源包站点数（设置页展示用）
  packSiteCount(): number {
    return this.packSites.length;
  }

  // 把源包站点并入配置（key 已存在则跳过——订阅站点优先，幂等）。
  // 迁移：旧版本随包内置的站点（ext 指向已删除的 rawfile 规则）从持久化配置中剥除，
  // 由导入的源包（data: 内嵌规则）重新补齐。
  private mergeSourcePacks(config: TvboxConfig): void {
    const before = config.sites.length;
    config.sites = config.sites.filter((s: SiteConfig): boolean =>
      !(s.ext.startsWith('builtin://') && s.ext !== 'builtin://drpy2.min.js'));
    const migrated = before - config.sites.length;
    if (this.packSites.length === 0) {
      if (migrated > 0) { console.info('OKV mergeSourcePacks migrated=' + migrated); }
      return;
    }
    const keys: Set<string> = new Set(config.sites.map((s: SiteConfig): string => s.key));
    let added = 0;
    for (const s of this.packSites) {
      if (keys.has(s.key)) { continue; }
      config.sites.push(s);
      keys.add(s.key);
      added++;
    }
    if (added > 0 || migrated > 0) { console.info('OKV mergeSourcePacks added=' + added + ' migrated=' + migrated); }
  }
}
