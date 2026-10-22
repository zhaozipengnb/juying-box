// 个性化设置：独立于订阅持久化（okvideo_settings 偏好文件），SettingsPage 修改后调用 save() 落盘。
// 消费点：播放倍速/长按倍速（PlayerPage）、图片尺寸（MovieGrid 列数）、聚合搜索/显示站源/站源筛选
// （HomePage 搜索链路）、无痕（搜索词不保留）、壁纸（首页背景）、缓存清理（设置页）。
// AI去广告为预留开关（生效点后续接入，UI 已标注）。内置下载已接入 DownloadManager。
import { KVStore } from './ConfigStore';

export type PicSize = 'small' | 'normal' | 'large';
export type WallpaperKind = 'default' | 'dark' | 'blue' | 'green';

const KEY_SETTINGS = 'okvideo_settings_json';

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
  @Trace builtinDownload: boolean = false;   // 内置下载：详情页/播放页显示下载按钮
  @Trace wallpaper: WallpaperKind = 'default'; // 全局壁纸（颜色主题）
  @Trace wallpaperUri: string = '';            // 全局壁纸（自定义图片路径，非空时优先于颜色主题）

  private store: KVStore | null = null;

  // EntryAbility 装配：注入持久化后立即装载既有值
  attach(store: KVStore): void {
    this.store = store;
    this.load();
  }

  load(): void {
    const raw = this.store?.getSync(KEY_SETTINGS);
    if (raw === undefined || raw === '') { return; }
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
      if (typeof ai === 'boolean') { this.aiAdFilter = ai; }
      const dl = obj['builtinDownload'];
      if (typeof dl === 'boolean') { this.builtinDownload = dl; }
      const wp = obj['wallpaper'];
      if (wp === 'default' || wp === 'dark' || wp === 'blue' || wp === 'green') { this.wallpaper = wp as WallpaperKind; }
      const wu = obj['wallpaperUri'];
      if (typeof wu === 'string') { this.wallpaperUri = wu; }
    } catch (e) { /* 坏数据按默认值起步 */ }
  }

  // 任一设置变更后由 UI 调用（fire-and-forget 语义，putSync+flush 同步落盘）
  save(): void {
    if (this.store === null) { return; }
    const obj: Record<string, Object> = {
      'picSize': this.picSize, 'playSpeed': this.playSpeed, 'longPressSpeed': this.longPressSpeed,
      'incognito': this.incognito, 'aggSearch': this.aggSearch, 'showSite': this.showSite,
      'siteFilter': this.siteFilter, 'aiAdFilter': this.aiAdFilter, 'builtinDownload': this.builtinDownload,
      'wallpaper': this.wallpaper, 'wallpaperUri': this.wallpaperUri
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
}
