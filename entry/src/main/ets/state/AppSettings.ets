// 个性化设置：独立于订阅持久化（juying_settings 偏好文件），SettingsPage 修改后调用 save() 落盘。
// 消费点：播放倍速/长按倍速（PlayerPage）、图片尺寸（MovieGrid 列数）、聚合搜索/显示站源/站源筛选
// （HomePage 搜索链路）、无痕（搜索词不保留）、壁纸（首页背景）、缓存清理（设置页）。
// AI去广告为预留开关（生效点后续接入，UI 已标注）。内置下载已接入 DownloadManager。
import { KVStore } from './ConfigStore';

export type PicSize = 'small' | 'normal' | 'large';
export type WallpaperKind = 'default' | 'dark' | 'blue' | 'green';
export type VideoFit = 'contain' | 'cover' | 'fill';

const KEY_SETTINGS = 'juying_settings_json';

// 播放倍速档位（起播默认与长按共用取值域）
export const SPEED_OPTIONS: number[] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
// 长按倍速档位：0 = 关闭（长按不加速）
export const LONG_PRESS_OPTIONS: number[] = [0, 2.0, 3.0];

@ObservedV2
export class AppSettings {
  static instance: AppSettings = new AppSettings();

  @Trace picSize: PicSize = 'normal';        // 首页海报密度：small=4列 / normal=3列 / large=2列
  @Trace playSpeed: number = 1.0;            // 起播默认倍速
  @Trace longPressSpeed: number = 3.0;       // 播放中长按临时倍速（0=关闭）
  @Trace incognito: boolean = false;         // 无痕模式：不保留搜索词（历史功能上线后一并生效）
  @Trace aggSearch: boolean = false;         // 聚合搜索：cms/xml 并发 + drpy 串行，合并全部采集站结果
  @Trace showSite: boolean = true;           // 显示站源：搜索结果卡片角标展示来源站名
  @Trace siteFilter: boolean = false;        // 站源搜索：搜索结果顶部按站点筛选（聚合结果就绪后展示）
  @Trace aiAdFilter: boolean = false;        // AI去广告（预留：将作用于播放地址解析阶段）
  @Trace autoSkipDead: boolean = true;       // 自动跳过失效源：加载失败/无内容的源自动切下一个并隐藏
                                             // （默认开：合包采集站质量参差，坏站卡住首页不可接受；可在个性设置关）
  @Trace builtinDownload: boolean = true;
  @Trace downloadWifiOnly: boolean = false;  // 下载仅 Wi-Fi：移动网络下不启动/不续传下载
                                             // 内置下载：详情页/播放页显示下载按钮（核心功能默认开，个性设置可关）
  @Trace videoFit: VideoFit = 'contain';     // 播放画面缩放：contain=适应 contain/cover=裁剪铺满/fill=拉伸
  @Trace lineAutoPlay: boolean = true;       // 线路播放：播放失败时自动切换下一条线路
  @Trace danmakuOn: boolean = true;          // 播放页弹幕(B站匿名链路零配置,个性设置可关)
  @Trace disabledSites: string[] = [];       // 站点管理：已禁用的站点 key（下拉/搜索/跳源全部隐藏）
  @Trace detailGrid: boolean = false;          // 详情页聚合视图记忆：false=列表 true=海报网格（跨进出保留）
  @Trace wallpaper: WallpaperKind = 'default'; // 全局壁纸（颜色主题）
  @Trace wallpaperUri: string = '';            // 全局壁纸（自定义图片路径，非空时优先于颜色主题）
  @Trace liveUrl: string = '';                 // 直播源地址
  @Trace proxyUrl: string = '';                // JAR爬虫代理服务器地址（用于执行csp_*Java爬虫）

  private store: KVStore | null = null;

  // EntryAbility 装配：注入持久化后立即装载既有值
  attach(store: KVStore): void {
    this.store = store;
    this.load();
  }

  load(): void {
    const raw = this.store?.getSync(KEY_SETTINGS);
    if (raw === undefined || raw === '') { return; }
    this.applyJson(raw);
  }

  // 备份导入：JSON 字符串恢复全部设置并落盘（坏数据按默认值跳过）
  restore(json: string): boolean {
    try {
      this.applyJson(json);
      this.save();
      return true;
    } catch (e) { return false; }
  }

  private applyJson(raw: string): void {
    try {
      const obj = JSON.parse(raw) as Record<string, Object>;
      const pic = obj['picSize'];
      if (pic === 'small' || pic === 'normal' || pic === 'large') { this.picSize = pic as PicSize; }
      const ps = obj['playSpeed'];
      if (typeof ps === 'number' && SPEED_OPTIONS.indexOf(ps) >= 0) { this.playSpeed = ps; }
      const lp = obj['longPressSpeed'];
      if (typeof lp === 'number' && LONG_PRESS_OPTIONS.indexOf(lp) >= 0) { this.longPressSpeed = lp; }
      const inc = obj['incognito'];
      if (typeof inc === 'boolean') { this.incognito = inc; }
      const agg = obj['aggSearch'];
      if (typeof agg === 'boolean') { this.aggSearch = agg; }
      const ss = obj['showSite'];
      if (typeof ss === 'boolean') { this.showSite = ss; }
      const sf = obj['siteFilter'];
      if (typeof sf === 'boolean') { this.siteFilter = sf; }
      const ai = obj['aiAdFilter'];
      const asd = obj['autoSkipDead'];
      if (typeof asd === 'boolean') { this.autoSkipDead = asd; }
      if (typeof ai === 'boolean') { this.aiAdFilter = ai; }
      const dl = obj['builtinDownload'];
      if (typeof dl === 'boolean') { this.builtinDownload = dl; }
      const vf = obj['videoFit'];
      if (vf === 'contain' || vf === 'cover' || vf === 'fill') { this.videoFit = vf as VideoFit; }
      const lap = obj['lineAutoPlay'];
      if (typeof lap === 'boolean') { this.lineAutoPlay = lap; }
      const dw = obj['downloadWifiOnly'];
      if (typeof dw === 'boolean') { this.downloadWifiOnly = dw; }
      const dmk = obj['danmakuOn'];
      if (typeof dmk === 'boolean') { this.danmakuOn = dmk; }
      const ds = obj['disabledSites'];
      if (Array.isArray(ds)) { this.disabledSites = ds.filter((x: Object): boolean => typeof x === 'string') as string[]; }
      const dg = obj['detailGrid'];
      if (typeof dg === 'boolean') { this.detailGrid = dg; }
      const wp = obj['wallpaper'];
      if (wp === 'default' || wp === 'dark' || wp === 'blue' || wp === 'green') { this.wallpaper = wp as WallpaperKind; }
      const wu = obj['wallpaperUri'];
      if (typeof wu === 'string') { this.wallpaperUri = wu; }
      const lu = obj['liveUrl'];
      if (typeof lu === 'string') { this.liveUrl = lu; }
      const pu = obj['proxyUrl'];
      if (typeof pu === 'string') { this.proxyUrl = pu; }
    } catch (e) { /* 坏数据按默认值起步 */ }
  }

  // 重置App：全部设置恢复默认值并落盘（配置/历史/收藏由调用方另行清理）
  resetToDefaults(): void {
    this.picSize = 'normal';
    this.playSpeed = 1.0;
    this.longPressSpeed = 3.0;
    this.incognito = false;
    this.aggSearch = false;
    this.showSite = true;
    this.siteFilter = false;
    this.aiAdFilter = false;
    this.autoSkipDead = false;
    this.builtinDownload = false;
    this.downloadWifiOnly = false;
    this.videoFit = 'contain';
    this.lineAutoPlay = true;
    this.detailGrid = false;
    this.wallpaper = 'default';
    this.wallpaperUri = '';
    this.save();
  }

  isSiteDisabled(key: string): boolean {
    return this.disabledSites.indexOf(key) >= 0;
  }

  toggleSiteDisabled(key: string): void {
    const idx = this.disabledSites.indexOf(key);
    if (idx >= 0) { this.disabledSites.splice(idx, 1); } else { this.disabledSites.push(key); }
    this.save();
  }

  // 当前设置的 JSON 快照（备份导出用）
  toJson(): string {
    const obj: Record<string, Object> = {
      'picSize': this.picSize, 'playSpeed': this.playSpeed, 'longPressSpeed': this.longPressSpeed,
      'incognito': this.incognito, 'aggSearch': this.aggSearch, 'showSite': this.showSite,
      'siteFilter': this.siteFilter, 'aiAdFilter': this.aiAdFilter, 'builtinDownload': this.builtinDownload, 'autoSkipDead': this.autoSkipDead,
      'videoFit': this.videoFit, 'lineAutoPlay': this.lineAutoPlay, 'disabledSites': this.disabledSites, 'downloadWifiOnly': this.downloadWifiOnly, 'danmakuOn': this.danmakuOn,
      'detailGrid': this.detailGrid,
      'wallpaper': this.wallpaper, 'wallpaperUri': this.wallpaperUri, 'liveUrl': this.liveUrl, 'proxyUrl': this.proxyUrl
    };
    return JSON.stringify(obj);
  }

  // 任一设置变更后由 UI 调用（fire-and-forget 语义，putSync+flush 同步落盘）
  save(): void {
    if (this.store === null) { return; }
    const obj: Record<string, Object> = {
      'picSize': this.picSize, 'playSpeed': this.playSpeed, 'longPressSpeed': this.longPressSpeed,
      'incognito': this.incognito, 'aggSearch': this.aggSearch, 'showSite': this.showSite,
      'siteFilter': this.siteFilter, 'aiAdFilter': this.aiAdFilter, 'builtinDownload': this.builtinDownload, 'autoSkipDead': this.autoSkipDead,
      'videoFit': this.videoFit, 'lineAutoPlay': this.lineAutoPlay, 'disabledSites': this.disabledSites, 'downloadWifiOnly': this.downloadWifiOnly, 'danmakuOn': this.danmakuOn,
      'detailGrid': this.detailGrid,
      'wallpaper': this.wallpaper, 'wallpaperUri': this.wallpaperUri, 'liveUrl': this.liveUrl,
      'proxyUrl': this.proxyUrl
    };
    this.store.putSync(KEY_SETTINGS, JSON.stringify(obj));
  }

  // 壁纸背景渐变色标（default 为纯白）
  wallpaperColors(): Array<[ResourceColor, number]> {
    const w = this.wallpaper;
    if (w === 'dark') { return [['#FF141416', 0.0], ['#FF232326', 1.0]]; }
    if (w === 'blue') { return [['#FF0E1E3C', 0.0], ['#FF1B3A5E', 1.0]]; }
    if (w === 'green') { return [['#FF12291F', 0.0], ['#FF1E4030', 1.0]]; }
    return [['#FFFFFFFF', 0.0], ['#FFFFFFFF', 1.0]];
  }

  // 深色壁纸下文字提亮（自定义图片也视为深色）
  isDarkWallpaper(): boolean {
    return this.wallpaper !== 'default' || this.wallpaperUri !== '';
  }

  // 各页面背景图：未设置自定义壁纸时使用内置默认渐变图（青橙），否则用用户设置的路径/链接
  bgImage(): string | Resource {
    return this.wallpaperUri === '' ? $r('app.media.bg_default_gradient') : this.wallpaperUri;
  }
}
