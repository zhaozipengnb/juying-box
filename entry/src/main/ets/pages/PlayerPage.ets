// 播放页：上半播放器 + 下方滚动详情（剧名/更新至/站源/年份地区类型/导演/演员/线路+下载/选集/简介）
// 各源给的地址有两类：媒体直链，以及 MacCMS/解析接口的网页播放页——后者起播前先用
// resolvePlayUrl 解析成直链，避免同一个视频在「app 播放器」和「内嵌网页播放器」之间摇摆。
// 解析不出的地址不静默降级，而是给出错误卡片（重试 / 网页播放 / 返回），由用户决定。
// 线路轮循：当前线路播放失败时自动切到下一线路同集继续尝试，全部线路失败才报错。
import { Nav, PlayerParam } from '../nav/Nav';
import { Episode, PlayLine, MovieDetail, SiteConfig, isDirectMedia, resolvePlayUrl, siteEngine, formatDuration } from 'common';
import { OptionPicker, PickerSpec } from '../components/OptionPicker';
import { AVPlayerEngine, EngineState, speedEnum } from '../media/AVPlayerEngine';
import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { avSession as AVSessionManager } from '@kit.AVSessionKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SPEED_OPTIONS } from '../state/AppSettings';
import { DrpyDriver } from '../spider/DrpyDriver';
import { webview } from '@kit.ArkWeb';
import { display, window } from '@kit.ArkUI';
import settings from '@ohos.settings';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';

import { AppState } from '../state/AppState';
import { AppSettings, VideoFit } from '../state/AppSettings';
import { DownloadManager, DownloadItem } from '../state/DownloadManager';
import { DanmuItem, BiliSearchItem, BiliPage, biliDanmu, biliDanmuByCid, biliSearchList, biliPagelist, dandanDanmu, logvarDanmu } from '../net/DanmuApi';
import { HlsAdFilterServer } from '../net/HlsAdFilterServer';
import { SniffProxy } from '../net/SniffProxyServer';
import { PlayHistory } from '../state/PlayHistory';
import { Favorites } from '../state/Favorites';

// URL → base64url(与 SniffProxyServer 的编码约定一致)
function b64urlEncode(x: string): string {
  const bytes: Uint8Array = new util.TextEncoder().encodeInto(x);
  return new util.Base64Helper().encodeToStringSync(bytes).replace(/\+/g, '-').replace(/\//g, '_');
}

// 手势亮度跨播放页实例持久（窗口级 setWindowBrightness 无读取接口，只能自记）
let gBrightness = -1;

@ComponentV2
export struct PlayerPage {
  @Local ep: Episode | null = null;
  @Local playUrl: string = '';   // 变化即驱动 AVPlayer 引擎开关(@Monitor)
  @Local resolving: boolean = true;
  @Local errMsg: string = '';
  @Local useWeb: boolean = false;
  settings: AppSettings = AppSettings.instance;
  dl: DownloadManager = DownloadManager.instance;
  @Local movieName: string = '';
  @Local siteName: string = '';
  @Local siteKey: string = '';
  @Local detail: MovieDetail | null = null;
  @Local lines: PlayLine[] = [];
  @Local lineIdx: number = 0;
  @Local epIdx: number = 0;
  @Local isPlaying: boolean = true;
  // 设置中的画面缩放 → Video objectFit（即改即生效）
  @Local curSpeed: number = 1.0;       // 当前生效倍速（起播读设置，长按/菜单可变）
  @Local boost: number = 0;            // 长按加速中的倍速（0 = 未加速）
  @Local picker: PickerSpec | null = null;   // 居中选择弹层
  @Local channelLine: number = 0;      // 直播多线路当前线路（0 基）
  @Local showIntroSec: number = 0;     // 本剧片头结束点(秒,0=未标记):点"跳过片头"时按当前位置标记
  @Local showOutroSec: number = 0;     // 本剧片尾长度(距结尾秒数,0=未标记):点"跳过片尾"时按当前位置标记
  private channelUrls: string[] = [];  // 直播多线路地址表（来自 PlayerParam）
  private epScroller: Scroller = new Scroller();  // 选集横滑定位当前集
  @Local sniffUrl: string = '';        // 嗅探中:正在加载的网页地址(非空 = 嗅探中)
  @Local sniffing: boolean = false;
  private sniffReferer: string = '';
  private sniffController: webview.WebviewController = new webview.WebviewController();
  private sniffTimer: number = -1;
  private videoFitEnum(): ImageFit {
    if (this.videoFit === 'cover') { return ImageFit.Cover; }
    if (this.videoFit === 'fill') { return ImageFit.Fill; }
    return ImageFit.Contain;
  }

  // XComponent 显示尺寸:按视频真实宽高比在容器内缩放(contain/cover),fill 铺满
  // (竖屏片不再被强制拉伸到全屏;Stack 默认居中负责定位)
  private xcW(): Length {
    const w = this.xcDims()[0];
    return w > 0 ? w : '100%' as Length;
  }

  private xcH(): Length {
    const h = this.xcDims()[1];
    return h > 0 ? h : '100%' as Length;
  }

  private xcDims(): number[] {
    if (this.vidW <= 0 || this.vidH <= 0 || this.areaW <= 0 || this.areaH <= 0) { return [0, 0]; }
    if (this.videoFit === 'fill') { return [0, 0]; }
    const den = this.density > 0 ? this.density : 1;
    const vw = this.vidW / den;
    const vh = this.vidH / den;
    if (vw <= 0 || vh <= 0) { return [0, 0]; }
    const sx = this.areaW / vw;
    const sy = this.areaH / vh;
    const s = this.videoFit === 'cover' ? Math.max(sx, sy) : Math.min(sx, sy);
    return [Math.floor(vw * s), Math.floor(vh * s)];
  }
  @Local isFav: boolean = false;
  @Local isTheater: boolean = false;   // 影院模式：横屏全屏、隐藏下方详情
  @Local videoH: number = 0;           // 非影院模式视频区高度（vp）＝容器宽/1.78，onAreaChange 修正
  @Local vidW: number = 0;             // 视频原始宽（px，videoSizeChange 回调）
  @Local vidH: number = 0;             // 视频原始高（px）
  @Local areaW: number = 0;            // 视频容器宽（vp，onAreaChange）
  @Local areaH: number = 0;            // 视频容器高（vp）
  private density: number = 1;         // 屏幕像素密度（px→vp 换算）
  @Local curTime: number = 0;          // 当前播放进度（秒），onUpdate 驱动
  @Local dur: number = 0;              // 视频总时长（秒），onPrepared 回调取得
  ph: PlayHistory = PlayHistory.instance;
  favs: Favorites = Favorites.instance;
  private lastPos: number = 0;         // 最近一次进度（秒），退出时落盘
  private lastDur: number = 0;
  private lastSaveAt: number = 0;      // 上次持久化时间戳（节流 5s）
  private seekedResume: boolean = false;  // 断点续播只 seek 一次
  private autoNextFired: boolean = false; // 播完/跳尾只触发一次(片尾窗口长达 90s,不挡会每秒重复切集弹 toast)
  private pendingResume: number = 0;      // 播放开始前读好的断点(首帧进度会覆盖历史,必须先取)
  private liveSkip: number = 0;           // 直播自动换台已跳过的死频道数
  @Local rotationLocked: boolean = false;  // 全屏旋转锁定(锁定后不跟随传感器)
  private liveWatchdog: number = -1;      // 直播出画看门狗(12s 未播判定死频道换台)
  @Local showCtrl: boolean = false;    // 自绘控制层显隐：默认隐藏，点击视频切换，播放中 4s 无操作自动隐藏
  private ctrlTimer: number = -1;      // 自动隐藏定时器（-1 = 未挂）
  @Local seekPreview: boolean = false; // 横向滑动快进/快退的预览气泡
  @Local seekDelta: number = 0;        // 滑动偏移（秒，右正左负）
  private seekFrom: number = 0;        // 手势起点的基准进度
  private panSeeking: boolean = false; // 本次手势是否有效（起手条件不满足则整段忽略）
  private uiSeeking: boolean = false;  // Slider 拖动中：屏蔽 onTime 回写，否则滑块被旧进度拽回(拖不动)
  private seekPending: boolean = false;// seek 已发出：丢弃引擎seek前的首个进度回调，防滑块回跳
  @Local gestureTip: string = '';      // 左右半屏竖滑的音量/亮度提示气泡
  private vbVolumeSide: boolean = false;
  private vbActive: boolean = false;      // 竖滑只在左右边缘区域激活(中部下拉不误触) // 本次竖滑落在右半屏(音量)；false=左半屏(亮度)
  private volCur: number = -1;         // 当前媒体音量(应用侧同步跟踪,setVolume 后立即更新)
  private volReady: boolean = false;   // 音量基准就绪(首次异步读取完成前手势不动,避免旧基准跳变)
  private volHoldTimer: number = -1;   // 音量重申定时器
  private volMax: number = 0;          // 媒体最大音量(0=获取失败,本次音量手势不生效)
  private brightCache: number = 0.5;   // 亮度缓存(0..1)，手势基准；上次手势设置值经 gBrightness 跨实例持久
  private volLast: number = -1;        // 上次设置的音量档位（去重用）
  private tipTimer: number = -1;       // 提示气泡延时清除定时器
  private brightTimer: number = -1;    // 亮度重申定时器(对抗系统自动亮度覆盖)
  private sysBrightModeSet: boolean = false;  // 本次会话是否已把系统亮度模式切为手动
  engine: AVPlayerEngine = new AVPlayerEngine();   // AVPlayer 内核(真倍速/循环/精准 seek)
  static activeEngine: AVPlayerEngine | null = null;   // 退后台自动暂停用的引擎槽(EntryAbility.onBackground 调用)

  static pauseIfPlaying(): void {
    const e = PlayerPage.activeEngine;
    if (e !== null) { e.pauseIfPlaying(); }
  }
  // 投屏(AVSession + 系统投播选择器):队列里放 TV 可直接拉流的公网直链(本机代理地址 TV 拉不到)
  private avSession: AVSessionManager.AVSession | null = null;
  private castHelper: AVSessionManager.AVCastPickerHelper | null = null;
  private castUrl: string = '';        // 可投直链(代理包装前的地址);''=当前内容不可投(网页/未解析)
  @Local casting: boolean = false;     // 输出设备处于投屏连接
  @Local castDeviceName: string = '';
  // 弹幕(弹弹play):数据按时间升序;Canvas 层每帧重绘,滚动位置由 curTime 驱动(暂停即冻结)
  danmus: DanmuItem[] = [];
  private danmuIdx: number = 0;        // 首条未上屏弹幕指针
  private danmuTimer: number = -1;     // 重绘循环
  private danmuLastSec: number = -999; // seek 检测基准
  private danmuClockAt: number = 0;    // 最近一次引擎进度回调时刻:弹幕平滑外推锚点(回调间隔大,直锚 curTime 一顿一顿)
  private danmuWCache: Map<number, number> = new Map();   // 文本宽度缓存(按条目下标,measureText 很贵)
  private danmu2D: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  @Local buffering: boolean = false;   // 播放器缓冲中(START→END 之间)
  @Local bufPercent: number = 0;       // 缓冲进度 0-100
  private bufTimer: number = -1;       // 缓冲延迟显示计时器(短缓冲不闪浮层)
  // 弹幕面板:播放页内开关/手动搜索选库/时间偏移(弥补自动匹配的死板)
  @Local showDmPanel: boolean = false;
  @Local dmOn: boolean = true;             // 播放页内弹幕显示开关
  @Local dmStage: string = 'main';         // main | search | pages
  @Local dmKeyword: string = '';
  @Local dmVideos: BiliSearchItem[] = [];
  @Local dmPages: BiliPage[] = [];
  @Local dmSearching: boolean = false;
  @Local dmSelVideo: string = '';       // 搜索阶段选中的 bvid
  @Local dmOffset: number = 0;             // 弹幕时间偏移(秒,正值=弹幕延后出现)
  // 批量下载选集面板(原型:下载=选集弹层,可切线路/多选/显示各集下载状态)
  @Local showDlPanel: boolean = false;
  @Local dlLineIdx: number = 0;        // 面板内线路
  @Local dlSel: boolean[] = [];        // 各集选中态
  @Local dlResolveText: string = '';   // 批量解析进度/结果提示
  private dlBusy: boolean = false;     // 批量解析进行中(防重复触发)
  private xcController: XComponentController = new XComponentController();
  private webController: webview.WebviewController = new webview.WebviewController();

  // 播放页顶部为黑色视频区，状态栏图标用白色；离开时还原
  private async setStatusBarContent(color: string): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const win = await window.getLastWindow(ctx);
      await win.setWindowSystemBarProperties({ statusBarContentColor: color });
    } catch (e) { }
  }

  private async setOrientation(o: window.Orientation): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const win = await window.getLastWindow(ctx);
      await win.setPreferredOrientation(o);
    } catch (e) { }
  }

  private async setImmersive(on: boolean): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const win = await window.getLastWindow(ctx);
      await win.setWindowLayoutFullScreen(on);
      // 退出播放器恢复暗色窗口底(此前恢复白色:系统标题栏透明,下载/历史页标题区会透出白底)
      await win.setWindowBackgroundColor('#FF000000');
    } catch (e) { }
  }

  private async prepare(): Promise<void> {
    const ep = this.ep;
    if (ep === null) { return; }
    this.resolving = true;
    this.errMsg = '';
    this.sniffClear();
    this.castUrl = '';   // 换集先清可投直链,确认直链后再补
    let target: string = ep.url;
    this.engine.isLive = this.siteKey === 'live';   // 直播流禁用倍速/循环(prepared 时调会 error)
    // 断点在播放开始前读取:首个进度回调会以当前位置覆盖历史记录,顺序反了续播必失效
    const m0 = this.detail?.movie;
    this.pendingResume = (this.ep !== null && m0 !== null && m0 !== undefined)
      ? (this.ph.resumePosition(this.siteKey, m0.vodId, this.ep.url)
        || this.ph.resumePositionByName(this.movieName, this.ep.name, this.epIdx)) : 0;
    this.seekedResume = false;
    this.autoNextFired = false;
    if (this.siteKey === 'live') { this.armLiveWatchdog(); }
    if (target.startsWith('file://')) {
      // 已下载的本地文件:直接播,不走解析/防盗链代理/投屏队列(文件在沙箱里,链路都无意义)
      this.playUrl = target;
      this.resolving = false;
      return;
    }
    // drpy（js 引擎）源：起播前先经 ext 的 play() 换直链（API 型源必需）；
    // 字符串规则源无 lazy，play 原样返回播放页地址——仅当结果确为媒体直链才采纳，
    // 否则回落通用解析（拉播放页 HTML 抽 player_aaaa/m3u8）
    const resolvedEp = await this.resolveViaDrpy(ep);
    let needSniff = false;
    if (resolvedEp !== null && isDirectMedia(resolvedEp.url)) {
      target = resolvedEp.url;
    } else if (resolvedEp !== null && resolvedEp.url !== '' && resolvedEp.parse === '1') {
      // play 结果 parse=1:url 为网页地址,需嗅探真实流(主流播放器嗅探能力对齐)
      target = resolvedEp.url;
      needSniff = true;
    } else {
      try {
        target = await resolvePlayUrl(ep.url, AppState.instance.makeFetchText());
      } catch (e) { }
    }
    if (isDirectMedia(target)) {
      this.castUrl = target;   // 代理包装前记录:投屏队列放 TV 可直接拉流的原始直链
      if (this.settings.aiAdFilter && /\.m3u8($|\?)/i.test(target)) {
        try {
          const base: string = await HlsAdFilterServer.ensureStarted();
          if (base !== '') { target = HlsAdFilterServer.wrapUrl(target); }
        } catch (e) { }
      }
      this.playUrl = target;
      this.updateCastSession(ep.name, this.castUrl);
      this.loadDanmaku();
    } else if (needSniff && target !== '') {
      this.startSniff(target);
    } else if (target !== '' && target !== ep.url) {
      this.playUrl = target;
    } else {
      this.errMsg = '无法解析播放地址';
    }
    if (this.errMsg !== '' && this.lines.length > 0 && this.settings.lineAutoPlay) {
      this.tryNextLine();
    }
    this.resolving = false;
  }

  // 嗅探:隐藏 Web 加载播放页,监听网络请求抓媒体直链(对齐主流播放器嗅探)
  private startSniff(pageUrl: string): void {
    this.sniffReferer = pageUrl;
    this.sniffUrl = pageUrl;
    this.sniffing = true;
    this.sniffTimer = setTimeout((): void => { this.sniffFail(); }, 18000);
  }

  private async sniffHit(mediaUrl: string): Promise<void> {
    if (this.sniffTimer >= 0) { clearTimeout(this.sniffTimer); this.sniffTimer = -1; }
    this.sniffing = false;
    this.sniffUrl = '';
    this.castUrl = mediaUrl;   // 嗅探到的原始直链可投(下方 SniffProxy 包装仅本机播放用)
    // 直链带防盗链(referer/UA):经本地 SniffProxy 带 headers 回源,AVPlayer 播本地地址
    try {
      const base: string = await SniffProxy.ensureStarted();
      if (base === '') { this.engine.open(mediaUrl, this.isPlaying); return; }
      const headers: Record<string, string> = {
        'referer': this.sniffReferer,
        'User-Agent': 'Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36'
      };
      const wrapped: string = base + '/h/' + b64urlEncode(JSON.stringify(headers)) + '/' + b64urlEncode(mediaUrl);
      this.engine.open(wrapped, this.isPlaying);
    } catch (e) {
      this.engine.open(mediaUrl, this.isPlaying);
    }
  }



  private sniffFail(): void {
    this.sniffing = false;
    this.sniffUrl = '';
    this.sniffTimer = -1;
    this.errMsg = '嗅探真实地址失败，可尝试网页播放';
  }

  private sniffClear(): void {
    this.sniffing = false;
    this.sniffUrl = '';
    if (this.sniffTimer >= 0) { clearTimeout(this.sniffTimer); this.sniffTimer = -1; }
  }

  // js 引擎站点经 DrpyDriver.playContent 解析直链；非 js 站点或解析失败返回 ''（回落通用解析）
  private async resolveViaDrpy(ep: Episode, flagOverride: string = ''): Promise<Episode | null> {
    const app = AppState.instance;
    const cfg = app.config;
    if (cfg === null) { return null; }
    const site: SiteConfig | undefined = cfg.sites.find((s: SiteConfig): boolean => s.key === this.siteKey);
    if (site === undefined || siteEngine(site) !== 'js') { return null; }
    const drv = app.makeDriverFor(site);
    if (!(drv instanceof DrpyDriver)) { return null; }
    try {
      const flag: string = flagOverride !== '' ? flagOverride
        : (this.lines.length > 0 ? this.lines[this.lineIdx].from : '');
      return await drv.playContent(flag, ep.url);
    } catch (e) {
      return null;
    }
  }

  // 面板内单集的下载状态(''=未下载),按影片+集名匹配(选集时还没有直链)
  private epDlState(epName: string): string {
    const it = this.dl.findByEp(this.movieName, epName);
    return it ? it.status : '';
  }

  // 打开批量下载面板:默认停在当前播放线路,全不选
  private openDlPanel(): void {
    this.dlLineIdx = this.lineIdx;
    const eps = this.lines[this.lineIdx]?.episodes ?? [];
    this.dlSel = eps.map((_e: Episode): boolean => false);
    this.dlResolveText = '';
    this.showDlPanel = true;
  }

  // 批量下载:逐集解析直链(与播放同链路:drpy play → 通用解析),成功的入队,失败的跳过
  private async batchDownload(): Promise<void> {
    if (this.dlBusy) { return; }
    const line = this.lines[this.dlLineIdx];
    if (line === undefined) { return; }
    const picks: Episode[] = [];
    line.episodes.forEach((e: Episode, i: number): void => {
      if (i < this.dlSel.length && this.dlSel[i] && this.epDlState(e.name) === '') {
        picks.push(e);
      }
    });
    if (picks.length === 0) { return; }
    this.dlBusy = true;
    let ok = 0;
    const flag = line.from;
    // 源站防盗链头:站点配置 header + 默认 UA——CDN 按 UA/Referer 掐流时下载必须带同样头
    const dlHeaders: Record<string, string> = { 'User-Agent': 'okhttp/4.9.3' };
    const site = AppState.instance.config?.sites.find((s: SiteConfig): boolean => s.key === this.siteKey);
    if (site !== undefined) {
      const ks = Object.keys(site.header);
      for (const k of ks) { dlHeaders[k] = site.header[k]; }
    }
    if (await this.dl.wifiBlocked()) {
      this.dlResolveText = '当前为移动网络，下载仅 Wi-Fi 已开启';
      this.dlBusy = false;
      setTimeout((): void => { if (!this.dlBusy) { this.dlResolveText = ''; } }, 3000);
      return;
    }
    try {
      for (let i = 0; i < picks.length; i++) {
        const ep = picks[i];
        this.dlResolveText = `解析 ${i + 1}/${picks.length}：${ep.name}`;
        let direct = '';
        const resolved = await this.resolveViaDrpy(ep, flag);
        if (resolved !== null && isDirectMedia(resolved.url)) {
          direct = resolved.url;
        } else {
          try {
            const t = await resolvePlayUrl(ep.url, AppState.instance.makeFetchText());
            if (isDirectMedia(t)) { direct = t; }
          } catch (err) { }
        }
        if (direct === '') { continue; }
        await this.dl.startDownload(this.movieName, ep.name, direct, this.siteKey, dlHeaders);
        ok++;
      }
    } finally {
      // 解析链路任何异常都不能卡死面板(dlBusy 卡住 = 面板按钮永久失效)
      this.dlBusy = false;
      this.dlResolveText = ok > 0 ? `已加入下载 ${ok} 集` : '解析失败，未加入下载';
      this.dlSel = this.dlSel.map((_v: boolean): boolean => false);
      setTimeout((): void => { if (!this.dlBusy) { this.dlResolveText = ''; } }, 2500);
    }
  }

  private tryNextLine(): void {
    if (this.lines.length === 0) {
      this.errMsg = '该源给的是网页播放页，app 播放器无法直接播放';
      return;
    }
    const next = this.lineIdx + 1;
    if (next < this.lines.length) {
      this.lineIdx = next;
      const eps = this.lines[next].episodes;
      const ei = Math.min(this.epIdx, eps.length - 1);
      this.epIdx = ei >= 0 ? ei : 0;
      this.ep = eps[this.epIdx] ?? null;
      this.playUrl = '';
      // 对齐主流播放器:换线有提示(onErrorEvent 降级链)
      this.getUIContext().getPromptAction().showToast({
        message: `正在切换线路至 ${next + 1}/${this.lines.length}:${this.lines[next].from}`
      });
      if (this.ep !== null) { this.prepare(); }
    } else {
      this.errMsg = '全部线路均无法播放';
    }
  }

  private setDanmus(items: DanmuItem[]): void {
    this.danmus = items;
    this.danmuIdx = 0;
    this.danmuLastSec = -999;
    this.danmuWCache.clear();   // 换集后下标对不上,宽度缓存作废
  }

  // 面板搜索:关键词 → B站视频列表(失败有 toast,不再静默)
  private dmPanelSearch(): void {
    const kw = this.dmKeyword.trim();
    if (kw === '' || this.dmSearching) { return; }
    this.dmSearching = true;
    biliSearchList(kw).then((list: BiliSearchItem[]): void => {
      this.dmVideos = list;
      this.dmSearching = false;
      if (list.length === 0) {
        this.getUIContext().getPromptAction().showToast({ message: '没有搜到相关视频' });
      }
    }).catch((e: Object): void => {
      this.dmSearching = false;
      const msg = e instanceof Error ? e.message : String(e);
      hilog.error(0x0000, 'OKV-Player', 'dm search fail: %{public}s', msg);
      this.getUIContext().getPromptAction().showToast({ message: '搜索失败：' + msg });
    });
  }

  private clearDanmaku(): void {
    const W = Math.floor(this.areaW * this.density);
    const H = Math.floor(this.areaH * this.density);
    if (W > 0 && H > 0) { this.danmu2D.clearRect(0, 0, W, H); }
  }

  // 拉取当前集弹幕:弹弹play 已配置则优先(聚合源,按剧+集精确匹配),空手/失败回退 B站匿名
  private async loadDanmaku(): Promise<void> {
    this.setDanmus([]);
    if (!this.settings.danmakuOn || this.siteKey === 'live' || this.useWeb || this.ep === null) {
      return;
    }
    // 聚合源优先(danmu_api 免费自部署 → 弹弹play 凭据内置时),都空手再走 B站匿名
    try {
      const lv = await logvarDanmu(this.movieName, this.ep.name, this.epIdx);
      if (lv.length > 0) {
        this.setDanmus(lv);
        hilog.info(0x0000, 'OKV-Player', 'danmu(logvar) %{public}d', lv.length);
        return;
      }
    } catch (e) {
      hilog.error(0x0000, 'OKV-Player', 'danmu(logvar) fail: %{public}s', e instanceof Error ? e.message : String(e));
    }
    try {
      const dd = await dandanDanmu(this.movieName, this.ep.name, this.epIdx);
      if (dd.length > 0) {
        this.setDanmus(dd);
        hilog.info(0x0000, 'OKV-Player', 'danmu(dandan) %{public}d', dd.length);
        return;
      }
    } catch (e) {
      hilog.error(0x0000, 'OKV-Player', 'danmu(dandan) fail: %{public}s', e instanceof Error ? e.message : String(e));
    }
    const bili = await biliDanmu(this.movieName, this.ep.name, this.epIdx);
    if (bili.length > 0) {
      this.setDanmus(bili);
      hilog.info(0x0000, 'OKV-Player', 'danmu(bili) %{public}d', bili.length);
    } else {
      hilog.info(0x0000, 'OKV-Player', 'danmu no match');
    }
  }

  // 弹幕重绘:播放头 = 引擎最后进度 + 距上次回调的经过时间(平滑外推)——
  // 引擎进度回调几百 ms 一跳,直接锚 curTime 逐帧重绘就是一顿一顿;暂停冻结;seek 超 3s 重置指针
  private drawDanmaku(): void {
    const ctx = this.danmu2D;
    const W = Math.floor(this.areaW * this.density);
    const H = Math.floor(this.areaH * this.density);
    if (W <= 0 || H <= 0) { return; }
    if (!this.dmOn) { ctx.clearRect(0, 0, W, H); return; }
    ctx.clearRect(0, 0, W, H);
    if (this.danmus.length === 0 || this.curTime <= 0 || this.resolving) { return; }
    const now = Date.now();
    let t = this.curTime;
    if (this.isPlaying) {
      t += Math.min((now - this.danmuClockAt) / 1000, 1.5);   // 缓冲/卡顿时最多外推 1.5s,防止弹幕飘走
    } else {
      this.danmuClockAt = now;   // 暂停期间持续对齐锚点,恢复播放不跳变
    }
    // seek/换集:t 跳变超 3s(后退也覆盖) → 指针归零,由下方推进重定位
    if (Math.abs(t - this.danmuLastSec) > 3) { this.danmuIdx = 0; }
    const DUR = 8;   // 每条弹幕滚过全屏的时长(秒)
    // 头部推进:已滚出窗口的历史弹幕直接跳过——原来每帧从 0 全量扫描几千条,是卡顿的另一半原因
    while (this.danmuIdx < this.danmus.length && this.danmus[this.danmuIdx].t + this.dmOffset < t - DUR) {
      this.danmuIdx++;
    }
    const font = Math.floor(15 * this.density);
    ctx.font = `${font}px sans-serif`;
    ctx.textBaseline = 'top';
    ctx.globalAlpha = 0.75;   // 半透明:弹幕从人物身上"透"过去,不挡脸
    const laneH = Math.max(28 * this.density, H / 6);
    const scrollLanes: boolean[] = [];   // 泳道占用(滚动弹幕避让)
    for (let i = this.danmuIdx; i < this.danmus.length; i++) {
      const d = this.danmus[i];
      const elapsed = t - (d.t + this.dmOffset);
      if (elapsed < 0) { break; }   // 按出场时间升序:后面的都还没出现
      if (elapsed > DUR) { continue; }
      let tw = this.danmuWCache.get(i);
      if (tw === undefined) { tw = ctx.measureText(d.text).width; this.danmuWCache.set(i, tw); }
      const scroll = d.mode !== 4 && d.mode !== 5;   // 底部/顶部固定弹幕不滚动
      ctx.fillStyle = '#000000';
      if (scroll) {
        const x = W - (elapsed / DUR) * (W + tw);
        // 泳道避让:同一泳道的前一条还没走远就不再堆叠
        const lane = Math.abs(this.simpleHash(d.text)) % 6;
        if (elapsed < 2 && scrollLanes[lane]) { continue; }
        scrollLanes[lane] = true;
        const y = lane * laneH + 4;
        ctx.fillText(d.text, x + 1, y + 1);
        ctx.fillStyle = d.color;
        ctx.fillText(d.text, x, y);
      } else {
        // 底部/顶部固定:水平居中,驻留 4 秒
        if (elapsed > 4) { continue; }
        const x = W / 2 - tw / 2;
        const y = d.mode === 5 ? 4 : H - font - 8;
        ctx.fillText(d.text, x + 1, y + 1);
        ctx.fillStyle = d.color;
        ctx.fillText(d.text, x, y);
      }
    }
    ctx.globalAlpha = 1;
    this.danmuLastSec = t;
  }

  private simpleHash(s: string): number {
    let h = 0;
    for (let i = 0; i < s.length; i++) { h = (h * 31 + s.charCodeAt(i)) & 0x7FFFFFFF; }
    return h;
  }

  private startDanmuLoop(): void {
    if (this.danmuTimer >= 0) { return; }
    this.danmuTimer = setInterval((): void => { this.drawDanmaku(); }, 33);
  }

  // 直播出画看门狗:12s 没到 playing 判定当前频道不可用,自动换台(死频道挂起可能几十秒不报错)
  private armLiveWatchdog(): void {
    if (this.liveWatchdog >= 0) { clearTimeout(this.liveWatchdog); }
    this.liveWatchdog = setTimeout((): void => {
      this.liveWatchdog = -1;
      if (this.siteKey === 'live' && !this.isPlaying && this.playUrl !== '') {
        hilog.info(0x0000, 'OKV-Player', 'watchdog: channel no picture in 12s, switch');
        this.playUrl = '';
        this.tryNextChannel();
      }
    }, 12000);
  }

  // 直播换台:当前频道不可播时自动切下一频道(同组内顺序试,上限 10 个;直播源死链多,
  // 死在一个运营商内网频道上就报错会让用户以为直播全坏)
  private tryNextChannel(): void {
    if (this.liveWatchdog >= 0) { clearTimeout(this.liveWatchdog); this.liveWatchdog = -1; }
    hilog.info(0x0000, 'OKV-Player', 'tryNextChannel site=%{public}s lines=%{public}d epIdx=%{public}d', this.siteKey, this.lines.length, this.epIdx);
    if (this.siteKey !== 'live' || this.lines.length === 0) { return; }
    const eps = this.lines[this.lineIdx]?.episodes ?? [];
    if (eps.length === 0) { return; }
    if (this.liveSkip >= 10) {
      this.errMsg = '连续 10 个频道不可播，请手动换台';
      this.liveSkip = 0;
      return;
    }
    const next = this.epIdx + 1;
    if (next >= eps.length) {
      this.errMsg = '本组频道均无法播放，请手动换台';
      this.liveSkip = 0;
      return;
    }
    this.liveSkip++;
    this.epIdx = next;
    this.ep = eps[next] ?? null;
    this.playUrl = '';
    this.isPlaying = true;   // 直播换台永远自动播(继承的 isPlaying 可能是 false 导致 prepared 后不 play)
    this.getUIContext().getPromptAction().showToast({
      message: `频道不可用，切换至 ${this.ep?.name}`
    });
    if (this.ep !== null) { this.prepare(); }
  }

  // 本集播完自动连播下一集(已是最后一集则停在片尾)
  private autoNextEpisode(): void {
    if (this.ep === null) { return; }
    const eps = this.lines[this.lineIdx]?.episodes ?? [];
    const next = this.epIdx + 1;
    if (next >= eps.length) {
      this.getUIContext().getPromptAction().showToast({ message: '已播完全部剧集' });
      return;
    }
    this.switchTo(this.lineIdx, next);
  }

  private switchTo(li: number, ei: number): void {
    if (this.siteKey === 'live') { this.liveSkip = 0; }   // 用户手动选台重置换台计数
    if (li < 0 || li >= this.lines.length) { return; }
    const eps = this.lines[li].episodes;
    if (ei < 0 || ei >= eps.length) { return; }
    this.lineIdx = li;
    this.epIdx = ei;
    this.ep = eps[ei];
    this.epScroller.scrollToIndex(ei);
    this.playUrl = '';
    this.errMsg = '';
    this.useWeb = false;
    this.prepare();
  }

  // "跳过片头"点击:已标记且仍在片头内 → 直接跳到记忆点;否则以当前位置标记为本剧片头结束点。
  // 标记后本剧后续集起播自动跳到该位置(无断点时)
  private markSkipIntro(): void {
    if (this.showIntroSec > 0 && this.curTime < this.showIntroSec - 2) {
      this.seekPending = true;
      this.engine.seek(this.showIntroSec);
      this.curTime = this.showIntroSec;
      this.lastPos = this.showIntroSec;
      this.armCtrlHide();
      return;
    }
    this.showIntroSec = Math.max(1, Math.round(this.curTime));
    this.persistShowSkip();
    this.getUIContext().getPromptAction().showToast({ message: '已记住本剧片头位置，后续集自动跳过' });
  }

  // "跳过片尾"点击:立即连播下一集,并把距结尾时长记为本剧片尾长度(后续集到点自动连播)
  private markSkipOutro(): void {
    if (this.dur > 0) {
      this.showOutroSec = Math.max(5, Math.round(this.dur - this.curTime));
      this.persistShowSkip();
    }
    this.autoNextEpisode();
  }

  // 本剧跳过标记落盘:按 site+vodId 各剧独立记忆(换剧/重启后各自保留)
  private persistShowSkip(): void {
    const m = this.detail?.movie;
    if (m === null || m === undefined) { return; }
    this.settings.setShowSkip(this.siteKey, m.vodId, this.showIntroSec, this.showOutroSec);
  }

  // 选集行"更多":打开全部剧集选择弹层(与全屏设置行"选集"同款,长剧横滑条摆不下全部)
  private showEpPicker(): void {
    if (this.lines.length === 0 || this.lines[this.lineIdx] === undefined) { return; }
    this.picker = {
      title: '选集',
      options: this.lines[this.lineIdx].episodes.map((e: Episode): string => e.name),
      index: this.epIdx,
      onPick: (idx: number): void => { this.switchTo(this.lineIdx, idx); }
    };
  }

  // 进度落盘：final=退出时强制；否则节流 5s。无痕模式不记
  private saveProgress(final: boolean): void {
    const m = this.detail?.movie;
    if (m === null || m === undefined || this.ep === null || this.playUrl === '') { return; }
    if (this.settings.incognito) { return; }
    const now = Date.now();
    if (!final && now - this.lastSaveAt < 5000) { return; }
    this.lastSaveAt = now;
    this.ph.update(this.siteKey, m, this.ep, this.lineIdx, this.epIdx, this.lastPos, this.lastDur);
  }

  // 控制层显隐：点击视频切换；挂 4s 自动隐藏（仅播放中），暂停时常驻不隐藏
  private toggleCtrl(): void {
    this.showCtrl = !this.showCtrl;
    this.armCtrlHide();
  }

  // 横向滑动快进/快退：起手记录基准进度，拖动按 0.3s/vp 实时预览，松手一次 seek。
  // 时长未知（dur<=0）/非直链播放状态时整段手势忽略，不影响点按显隐
  private panSeekStart(): void {
    this.panSeeking = this.playUrl !== '' && this.errMsg === '' && !this.resolving && !this.useWeb && this.dur > 0;
    if (!this.panSeeking) { return; }
    this.seekFrom = Math.min(this.lastPos > 0 ? this.lastPos : this.curTime, this.dur);
    this.seekDelta = 0;
    this.seekPreview = true;
  }

  private panSeekMove(offsetX: number): void {
    if (!this.panSeeking) { return; }
    this.seekDelta = offsetX * 0.15;   // 0.3s/vp 太灵敏,降到 0.15
  }

  private panSeekEnd(): void {
    if (!this.panSeeking) { return; }
    this.panSeeking = false;
    this.seekPreview = false;
    const target = Math.max(0, Math.min(this.seekFrom + this.seekDelta, this.dur));
    this.engine.seek(target);
    this.curTime = target;
    this.danmuClockAt = Date.now();
    this.lastPos = target;
    this.seekPending = true;   // 丢弃 seek 完成前的旧进度回调，防滑块回跳
    this.armCtrlHide();
  }

  // 左右半屏竖滑：左=亮度、右=音量（对齐主流播放器习惯）。起手按触点 x 分流，
  // 音量走 AudioManager(MEDIA 流)，亮度走窗口 setWindowBrightness；提示气泡居中显示，松手延时消退
  private vbStart(e: GestureEvent): void {
    if (this.useWeb || this.errMsg !== '' || this.playUrl === '') { return; }
    const fl = e.fingerList;
    const x = fl.length > 0 ? fl[0].localX : 0;
    // 只在左右边缘 30% 区域响应竖滑——屏幕中部下拉(拉通知栏)不再误触亮度/音量
    if (x > this.areaW * 0.3 && x < this.areaW * 0.7) {
      this.vbActive = false;
      return;
    }
    this.vbActive = true;
    if (this.tipTimer >= 0) { clearTimeout(this.tipTimer); this.tipTimer = -1; }
    this.vbVolumeSide = x >= this.areaW * 0.7;
    if (this.vbVolumeSide) {
      // 每次手势强制重读系统真实音量(系统音量可能被外部改变:硬件键/其他应用/重启)
      this.volReady = false;
      this.readVolumes();
      hilog.info(0x0000, 'OKV-VOL', 'vbStart right: re-reading system volume');
    } else {
      hilog.info(0x0000, 'OKV-VOL', 'vbStart left(brightness)');
    }
  }

  // 音量查询是 Promise API：异步读基准与上限，解析前 vbMove 因 volMax=0 空转
  private async readVolumes(): Promise<void> {
    try {
      const am = audio.getAudioManager();
      this.volMax = await am.getMaxVolume(audio.AudioVolumeType.MEDIA);
      const cur = await am.getVolume(audio.AudioVolumeType.MEDIA);
      this.volCur = cur;
      this.volLast = cur;
      this.volReady = true;
      hilog.info(0x0000, 'OKV-VOL', 'readVolumes ok max=%{public}d cur=%{public}d', this.volMax, this.volCur);
    } catch (err) {
      this.volMax = 0;
      hilog.error(0x0000, 'OKV-VOL', 'readVolumes fail: %{public}s', err instanceof Error ? err.message : String(err));
    }
  }

  private vbMove(e: GestureEvent): void {
    if (!this.vbActive || this.useWeb || this.errMsg !== '' || this.playUrl === '') { return; }
    const dy = e.offsetY;   // vp，上滑为负
    if (this.vbVolumeSide && this.volReady && this.volMax > 0 && this.volCur >= 0) {
      let v = Math.round(this.volCur + this.volMax * (-dy / 500));   // 500vp 拉满全量程,降灵敏度
      hilog.info(0x0000, 'OKV-VOL', 'move dy=%{public}d v=%{public}d', Math.round(dy), v);
      v = Math.max(0, Math.min(this.volMax, v));
      if (v !== this.volLast) {   // 去重：拖动事件远密于音量档位，避免洪水式 setVolume
        this.volLast = v;
        this.volCur = v;   // 同步跟踪:下一次手势的基准永远是最新音量(缺失此行=每次手势都从旧基准重来)
        try {
          audio.getAudioManager().setVolume(audio.AudioVolumeType.MEDIA, v).catch((): void => { });
        } catch (err) { }
      }
      this.gestureTip = '音量 ' + Math.round(v * 100 / this.volMax) + '%';
    } else if (!this.vbVolumeSide) {
      let b = this.brightCache + (-dy / 500);   // 500vp 拉 0→1,降灵敏度
      b = Math.max(0.05, Math.min(1, b));
      this.brightCache = b;
      gBrightness = b;
      this.applyBrightness(b);
      // 双写系统亮度:仅窗口覆盖会被系统自动亮度回调打回(实测),切手动模式+写系统值才稳
      if (!this.sysBrightModeSet) {
        this.sysBrightModeSet = true;
        try {
          settings.setValue(getContext(this) as common.UIAbilityContext, settings.display.AUTO_SCREEN_BRIGHTNESS,
            String(settings.display.MANUAL_SCREEN_BRIGHTNESS_MODE)).catch((): void => { });
        } catch (err) { }
      }
      try {
        settings.setValue(getContext(this) as common.UIAbilityContext, settings.display.SCREEN_BRIGHTNESS_STATUS,
          String(Math.round(b * 255))).catch((): void => { });
      } catch (err) { }
      this.gestureTip = '亮度 ' + Math.round(b * 100) + '%';
    }
  }

  private vbEnd(): void {
    this.vbActive = false;
    if (this.tipTimer >= 0) { clearTimeout(this.tipTimer); }
    this.tipTimer = setTimeout(() => { this.gestureTip = ''; this.tipTimer = -1; }, 700);
  }

  private applyBrightness(b: number): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      window.getLastWindow(ctx).then((w: window.Window): void => {
        w.setWindowBrightness(b);
      }).catch((): void => { });
    } catch (err) { }
  }

  // 投屏:创建 AVSession(通知栏播放控制附带生效),跟随输出设备变化显示投屏状态
  private async setupCastSession(): Promise<void> {
    if (this.avSession !== null) { return; }
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const s = await AVSessionManager.createAVSession(ctx, 'juying-play', 'video');
      s.on('outputDeviceChange', (state: AVSessionManager.ConnectionState, device: AVSessionManager.OutputDeviceInfo): void => {
        this.casting = state === AVSessionManager.ConnectionState.STATE_CONNECTED;
        this.castDeviceName = this.casting ? (device.devices[0]?.deviceName ?? '') : '';
      });
      // 通知栏/系统媒体控制器的播放暂停指令
      s.on('play', (): void => { this.engine.play(); this.isPlaying = true; });
      s.on('pause', (): void => { this.engine.pause(); this.isPlaying = false; });
      await s.activate();
      this.avSession = s;
    } catch (e) { }
  }

  // 当前集可投直链写入会话队列(投播设备直接拉这个地址;代理包装前的原始 URL)
  private async updateCastSession(name: string, url: string): Promise<void> {
    const s = this.avSession;
    if (s === null || url === '') { return; }
    try {
      const m = this.detail?.movie;
      const showTitle = this.movieName !== '' ? this.movieName : name;
      // 下拉/锁屏媒体卡:标题=剧名、艺人=集名、封面=海报(此前只传集名,卡上没有剧报)
      const meta: AVSessionManager.AVMetadata = {
        assetId: url,
        title: showTitle,
        artist: name,
        mediaImage: (m !== null && m !== undefined && m.pic !== '') ? m.pic : undefined
      };
      await s.setAVMetadata(meta);
      await s.setAVQueueTitle(this.movieName);
      await s.setAVQueueItems([{
        itemId: 0,
        description: { assetId: url, title: showTitle, mediaType: 'video' }
      }]);
    } catch (e) { }
  }

  private async openCastPicker(): Promise<void> {
    try {
      if (this.castHelper === null) {
        const ctx = getContext(this) as common.UIAbilityContext;
        this.castHelper = new AVSessionManager.AVCastPickerHelper(ctx);
      }
      await this.castHelper.select();
      hilog.info(0x0000, 'OKV-Player', 'cast picker select ok');
    } catch (e) {
      hilog.error(0x0000, 'OKV-Player', 'cast picker err: ' + (e instanceof Error ? e.message : JSON.stringify(e)));
    }
  }

  // playUrl 变化 → 引擎开关:空地址停止,非空打开并自动播放
  @Monitor('playUrl')
  onPlayUrl(): void {
    if (this.playUrl === '') { this.engine.stop(); return; }
    this.engine.open(this.playUrl, this.isPlaying);
  }

  private armCtrlHide(): void {
    if (this.ctrlTimer >= 0) { clearTimeout(this.ctrlTimer); this.ctrlTimer = -1; }
    if (!this.showCtrl || !this.isPlaying) { return; }
    this.ctrlTimer = setTimeout(() => { this.showCtrl = false; this.ctrlTimer = -1; }, 4000);
  }

  // 全屏旋转锁:锁定后窗口方向固定(不随传感器转),解锁恢复按片源方向的传感器跟随
  private toggleRotationLock(): void {
    this.rotationLocked = !this.rotationLocked;
    if (this.rotationLocked) {
      this.setOrientation(window.Orientation.LOCKED);   // 锁定当前方向
    } else {
      const portraitVideo = this.vidH > this.vidW && this.vidW > 0;
      this.setOrientation(portraitVideo ? window.Orientation.AUTO_ROTATION_PORTRAIT : window.Orientation.AUTO_ROTATION_LANDSCAPE);
    }
    this.getUIContext().getPromptAction().showToast({
      message: this.rotationLocked ? '已锁定旋转' : '已解锁旋转'
    });
  }

  // 影院模式：横屏 + 播放器铺满 + 隐藏详情；再点还原。
  // 视频区常驻（见 build），切换只改布局属性与窗口方向，Video 不重建、进度与解码状态天然保留
  private toggleTheater(): void {
    this.isTheater = !this.isTheater;
    this.updateCutoutDepth();   // 每次进全屏重测挖孔(旋转/窗口变化后 rects 可能更新)
    if (this.isTheater) {
      this.setImmersive(true);
      // 竖屏片保持竖屏全屏(画面满宽居中),横屏片才转横屏。
      // 先按片源方向锁定落位(系统自动旋转关闭时也能强制转过去),落位后切传感器跟随——
      // 全屏内手机翻转屏幕跟着转;AUTO_ROTATION_* 限制在同向半球,横屏片不会转到竖屏
      const portraitVideo = this.vidH > this.vidW && this.vidW > 0;
      this.setOrientation(portraitVideo ? window.Orientation.PORTRAIT : window.Orientation.LANDSCAPE);
      setTimeout((): void => {
        if (this.isTheater) {
          this.setOrientation(portraitVideo
            ? window.Orientation.AUTO_ROTATION_PORTRAIT : window.Orientation.AUTO_ROTATION_LANDSCAPE);
        }
      }, 600);
    } else {
      this.setImmersive(false);
      this.setOrientation(window.Orientation.UNSPECIFIED);
    }
  }

  private prevEp(): void {
    if (this.epIdx > 0) { this.switchTo(this.lineIdx, this.epIdx - 1); }
  }

  private nextEp(): void {
    const eps = this.lines[this.lineIdx]?.episodes ?? [];
    if (this.epIdx < eps.length - 1) { this.switchTo(this.lineIdx, this.epIdx + 1); }
  }

  // 壁纸/画面比例镜像:V2 对 @ObservedV2 单例直读不建立响应依赖(实测坑),onChange 显式通知刷镜像,
  // 设置页改完立即生效(播放页常驻导航栈不重建,没有重建时机)
  @Local wallpaperColors: Array<[ResourceColor, number]> = [['#FFFFFFFF', 0.0], ['#FFFFFFFF', 1.0]];
  @Local videoFit: VideoFit = 'contain';
  @Local cutoutDepth: number = 40;      // 前摄挖孔深度(vp):getCutoutInfo 实测,全屏两侧图标自动避让
  private settingsCb: (() => void) | null = null;

  private syncSettings(): void {
    this.wallpaperColors = this.settings.wallpaperColors();
    this.videoFit = this.settings.videoFit;
  }

  // 取前摄挖孔实际深度(px,自然方向=竖屏的 top 边):横屏时挖孔落在左右缘中部,两侧图标避让用。
  // 取不到挖孔信息(老设备/模拟器)按 40vp 兜底
  private async updateCutoutDepth(): Promise<void> {
    try {
      const info = await display.getDefaultDisplaySync().getCutoutInfo();
      let maxPx = 0;
      for (const r of info.boundingRects) {
        maxPx = Math.max(maxPx, r.top + r.height);   // 本 SDK Rect 是 left/top/width/height
      }
      if (maxPx === 0) { this.cutoutDepth = 24; return; }
      const d = maxPx / (this.density > 0 ? this.density : 3) + 10;   // 挖孔外再留 10vp
      this.cutoutDepth = Math.max(36, Math.min(90, d));
      hilog.info(0x0000, 'OKV-Player', 'cutout depth %{public}d vp', Math.round(this.cutoutDepth));
    } catch (e) {
      hilog.info(0x0000, 'OKV-Player', 'cutout info fail, keep fallback');
    }
  }

  aboutToDisappear(): void {
    if (this.settingsCb !== null) { this.settings.offChange(this.settingsCb); this.settingsCb = null; }
  }

  aboutToAppear(): void {
    this.settingsCb = (): void => { this.syncSettings(); };
    this.settings.onChange(this.settingsCb);
    this.syncSettings();
    // 视频区初始高度按屏宽/1.78 预置，避免首帧 0 高；onAreaChange 随实际容器宽度修正
    try {
      const d = display.getDefaultDisplaySync();
      this.density = d.densityPixels > 0 ? d.densityPixels : 1;
      this.videoH = d.width / this.density / 1.78;
    } catch (e) { }
    this.updateCutoutDepth();
    if (gBrightness >= 0) { this.brightCache = gBrightness; }   // 延续上次手势亮度
    PlayerPage.activeEngine = this.engine;
    this.setupCastSession();
    this.engine.onVideoSize = (w: number, h: number): void => {
      this.vidW = w; this.vidH = h;
    };
    this.engine.onBufferingStart = (): void => {
      // 正常播放中缓冲余量波动也会触发 START——延迟 800ms,短缓冲不闪浮层
      if (this.bufTimer >= 0) { clearTimeout(this.bufTimer); }
      this.bufTimer = setTimeout((): void => {
        this.bufTimer = -1;
        this.buffering = true;
      }, 800);
    };
    this.engine.onBufferingEnd = (): void => {
      if (this.bufTimer >= 0) { clearTimeout(this.bufTimer); this.bufTimer = -1; }
      this.buffering = false;
    };
    this.engine.onBufferingPercent = (p: number): void => { this.bufPercent = p; };
    // AVPlayer 回调:进度/状态/错误;倍速与循环由设置驱动
    this.engine.speed = speedEnum(this.settings.playSpeed);
    this.engine.onTime = (sec: number): void => {
      // Slider 拖动中不回写(否则滑块被旧进度拽回)；seek 后的首个回调仍可能是旧位置，丢弃
      if (this.uiSeeking) { return; }
      if (this.seekPending) { this.seekPending = false; return; }
      // 断点续播:首个进度回调先 seek 到断点——必须先于 saveProgress,
      // 否则首帧位置(≈0)会覆盖历史记录,重开时永远从头播(实测踩坑)
      if (!this.seekedResume && this.pendingResume > 0) {
        this.seekedResume = true;
        this.engine.seek(this.pendingResume);
        return;
      }
      // 自动跳过片头("跳头"时长>0):无断点续播时开播直接跳过片头;有断点尊重用户进度。
      // 片长>片头时长的 3 倍才跳(短片没有片头;也保证跳完不会落进片尾窗口被立刻切下一集)
      if (!this.seekedResume && this.pendingResume <= 0 && this.showIntroSec > 0
        && this.dur > this.showIntroSec * 3 && this.siteKey !== 'live') {
        this.seekedResume = true;   // 复用一次性标记:每集只跳一次,手动回跳片头不会重跳
        this.engine.seek(this.showIntroSec);
        this.getUIContext().getPromptAction().showToast({ message: '已自动跳过片头' });
        return;
      }
      // 本集播完:自动切下一集(直播无末尾;已是最后一集则停在片尾)
      // "跳尾"时长>0:距片尾 N 秒即切,跳过片尾字幕;=0:播到最后一秒才切。
      // 片尾窗口内进度回调每秒都会命中,autoNextFired 保证只触发一次;进度按看完落盘,
      // 避免下次续播正好落在窗口内、一打开又被自动切走
      const endAt = this.showOutroSec > 0 ? this.dur - this.showOutroSec : this.dur - 1;
      if (this.dur > this.showOutroSec + 60 && sec >= endAt && this.siteKey !== 'live'
        && this.ep !== null && !this.autoNextFired) {
        this.autoNextFired = true;
        this.lastPos = this.dur;
        this.saveProgress(true);
        this.getUIContext().getPromptAction().showToast({ message: '已自动跳过片尾' });
        this.autoNextEpisode();
        return;
      }
      this.curTime = sec;
      this.danmuClockAt = Date.now();   // 弹幕平滑外推锚点
      this.lastPos = sec;
      this.saveProgress(false);
    };
    this.engine.onState = (st: EngineState): void => {
      if (st === 'prepared') { this.dur = this.engine.durationSec; }
      else if (st === 'playing') {
        this.isPlaying = true;
        this.buffering = false;   // playing 态出现即缓冲已结束(兜底 END 丢失的流)
        if (this.liveWatchdog >= 0) { clearTimeout(this.liveWatchdog); this.liveWatchdog = -1; }
      }
      else if (st === 'paused') { this.isPlaying = false; }
      else if (st === 'error') {
        this.playUrl = '';
        this.buffering = false;
        hilog.info(0x0000, 'OKV-Player', 'onState error site=%{public}s', this.siteKey);
        if (this.siteKey === 'live') { this.tryNextChannel(); }
        else if (this.settings.lineAutoPlay) { this.tryNextLine(); }
        else if (this.siteKey === 'live') { this.tryNextChannel(); }
      else { this.errMsg = '播放失败,请手动切换线路重试'; }
      }
    };
    this.engine.onError = (msg: string): void => {
      this.playUrl = '';
      hilog.info(0x0000, 'OKV-Player', 'onError site=%{public}s msg=%{public}s', this.siteKey, msg);
      if (this.siteKey === 'live') { this.tryNextChannel(); }
      else if (this.settings.lineAutoPlay) { this.tryNextLine(); }
      else { this.errMsg = '播放失败,请手动切换线路重试'; }
    };
  }

  build() {
    NavDestination() {
      Stack() {
      Column() {
        // 视频区常驻不重建：影院切换只改高度属性（'100%' ↔ 屏宽/1.78），Video 持续播放无卡顿
        Column() { this.videoInner() }
          .width('100%')
          .height(this.isTheater ? '100%' : this.videoH)
          .backgroundColor('#000000')
          .clip(true)
          .onAreaChange((_o: Area, n: Area) => {
            this.areaW = n.width as number;
            this.areaH = n.height as number;
          })
        // 不加 expandSafeArea：根布局已扩到状态栏下，本容器画在 [0,videoH]；
        // 自带 expandSafeArea(TOP) 会使子组件布局原点下移一个状态栏高度，clip 又按本容器盒子裁，
        // 底部锚定的控制行会被裁掉 124px（进度条看不到的直接根因）
        if (!this.isTheater) {
          this.detailArea()
        }
      }
      .width('100%').height('100%')
      .onAreaChange((_o: Area, n: Area) => {
        const w = n.width as number;
        if (w > 0) { this.videoH = w / 1.78; }
      })
      .linearGradient({ angle: 160, colors: this.wallpaperColors })
      .backgroundImage(this.settings.bgImage())
      .backgroundImageSize(ImageSize.Cover)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      if (this.picker !== null) {
        OptionPicker({
          title: this.picker.title,
          options: this.picker.options,
          selectedIndex: this.picker.index,
          onPick: (idx: number): void => {
            const pk: PickerSpec | null = this.picker;
            if (pk !== null) { pk.onPick(idx); }
            this.picker = null;
          },
          onClose: (): void => { this.picker = null; }
        })
      }

      if (this.showDlPanel) {
        this.downloadPanel()
      }

      if (this.showDmPanel) {
        this.dmPanel()
      }
      }
      .width('100%').height('100%')
    }
    .hideTitleBar(true)
    // 影院模式时返回先还原竖屏播放界面（消费本次返回），再次返回才退出播放页
    .onBackPressed((): boolean => {
      if (this.showDlPanel) {
        if (!this.dlBusy) { this.showDlPanel = false; }
        return true;
      }
      if (this.isTheater) {
        this.toggleTheater();
        return true;
      }
      return false;
    })
    .onReady((ctx: NavDestinationContext) => {
      this.channelLine = 0;
      const p = ctx.pathInfo.param as PlayerParam;
      if (p !== null && p !== undefined) {
        this.ep = p.ep;
        this.channelUrls = p.channelUrls ?? [];
        this.movieName = p.movieName ?? '';
        this.siteName = p.siteName ?? '';
        this.siteKey = p.siteKey;
        this.detail = p.detail ?? null;
        if (p.lines !== undefined && p.lines !== null) { this.lines = p.lines; }
        if (p.lineIdx !== undefined && p.lineIdx !== null) { this.lineIdx = p.lineIdx; }
        if (p.epIdx !== undefined && p.epIdx !== null) { this.epIdx = p.epIdx; }
      }
      else { this.errMsg = '播放参数缺失'; this.resolving = false; }
      const m = this.detail?.movie;
      if (m !== null && m !== undefined) {
        this.isFav = this.favs.isFav(this.siteKey, m.vodId);
        // 装载本剧跳过配置(须在 prepare 之前:起播自动跳片头用的就是这组值)
        const cfg = this.settings.showSkip(this.siteKey, m.vodId);
        if (cfg !== null) {
          this.showIntroSec = cfg.introSec;
          this.showOutroSec = cfg.outroSec;
        }
      }
      if (this.ep !== null) { this.prepare(); }
      this.setStatusBarContent('#FFFFFF');
    })
    .onWillDisappear(async () => {
      this.saveProgress(true);
      this.sniffClear();
      // AVPlayer 不随页面销毁自动停止:退出播放页必须显式停掉并释放(否则声音继续)
      this.engine.stop();
      this.engine.release();
      // 退出播放页销毁投屏会话(投播随之结束)
      if (PlayerPage.activeEngine === this.engine) { PlayerPage.activeEngine = null; }
      if (this.avSession !== null) {
        this.avSession.destroy();
        this.avSession = null;
        this.castHelper = null;
        this.casting = false;
        this.castDeviceName = '';
      }
      if (this.ctrlTimer >= 0) { clearTimeout(this.ctrlTimer); this.ctrlTimer = -1; }
      if (this.liveWatchdog >= 0) { clearTimeout(this.liveWatchdog); this.liveWatchdog = -1; }
      if (this.bufTimer >= 0) { clearTimeout(this.bufTimer); this.bufTimer = -1; }
      if (this.danmuTimer >= 0) { clearInterval(this.danmuTimer); this.danmuTimer = -1; }
      if (this.brightTimer >= 0) { clearInterval(this.brightTimer); this.brightTimer = -1; }
      if (this.volHoldTimer >= 0) { clearInterval(this.volHoldTimer); this.volHoldTimer = -1; }
      this.showCtrl = false;
      this.rotationLocked = false;
      this.setImmersive(false);
      this.setStatusBarContent('#000000');
      this.setOrientation(window.Orientation.UNSPECIFIED);
    })
  }

  @Builder
  videoInner() {
    Stack() {
      if (this.errMsg !== '') {
        Column({ space: 12 }) {
          Text('播放失败：' + this.errMsg).fontColor('#E53935').fontSize(14)
          Row({ space: 12 }) {
            Button('重试').fontSize(13).onClick(() => { this.errMsg = ''; this.playUrl = ''; this.prepare(); })
            Button('网页播放').fontSize(13).onClick(() => { this.errMsg = ''; this.useWeb = true; })
            Button('返回').fontSize(13).onClick(() => { Nav.stack.pop(); })
          }
        }.width('100%').height('100%').justifyContent(FlexAlign.Center)
      } else if (this.useWeb && this.ep !== null) {
        Web({ src: this.ep.url, controller: this.webController })
          .width('100%').height('100%')
          .javaScriptAccess(true).domStorageAccess(true).mediaPlayGestureAccess(true)
      } else if (this.sniffing) {
        // 嗅探:视频区直接加载网页(真实尺寸,页面播放器才会发起视频请求),
        // onInterceptRequest 抓到媒体直链后由 AVPlayer 接管
        Stack() {
          Web({ src: this.sniffUrl, controller: this.sniffController })
            .width('100%').height('100%')
            .javaScriptAccess(true)
            .onInterceptRequest((event): WebResourceResponse | undefined => {
              const reqUrl: string = (event as OnInterceptRequestEvent).request.getRequestUrl();
              if (this.sniffing && /\.(m3u8|mp4|mkv|flv)(\?|&|#|$)/i.test(reqUrl)) {
                this.sniffHit(reqUrl);
              }
              return undefined;
            })
          Text('正在嗅探视频地址…')
            .fontSize(12).fontColor('#FFFFFF')
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor('#B3000000')
            .borderRadius(8)
            .position({ x: '50%', y: 14 }).markAnchor({ x: '50%' })
        }.width('100%').height('100%').backgroundColor('#000000')
      } else if (this.resolving || this.playUrl === '') {
        Column() {
          LoadingProgress().width(36).height(36).color('#FFFFFF')
        }.width('100%').height('100%').justifyContent(FlexAlign.Center)
      } else {
        XComponent({ id: 'playerSurface', type: 'surface', controller: this.xcController })
          .width(this.xcW()).height(this.xcH())
          .onLoad(() => {
            // surface 就绪:注入引擎(AVPlayer 用 surfaceId 渲染)
            this.engine.setSurface(this.xcController.getXComponentSurfaceId());
          })
      }

      // 弹幕层:盖在画面上,触摸穿透(手势/控制由下层处理);开启且数据就绪时逐帧重绘
      if (this.playUrl !== '' && !this.resolving && !this.useWeb) {
        Canvas(this.danmu2D)
          .width('100%').height('100%')
          .onReady(() => { this.startDanmuLoop(); })
      }

      // 手势层：自绘播放时覆盖整个视频区,吃掉点按/横竖滑/长按。位于画面之上、各控制行之下——
      // Slider/按钮等上层控件命中的触摸不再与全局手势竞争(进度条因此可拖可点)。
      // 嗅探网页/网页播放/错误态不渲染此层,Web 与错误按钮直接接管触摸
      if (this.playUrl !== '' && this.errMsg === '' && !this.resolving && !this.useWeb) {
        Column()
          .width('100%').height('100%')
          .onClick(() => { this.toggleCtrl(); })
          .gesture(PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 5 })
            .onActionStart((_e: GestureEvent) => { this.panSeekStart(); })
            .onActionUpdate((e: GestureEvent) => { this.panSeekMove(e.offsetX); })
            .onActionEnd((_e: GestureEvent) => { this.panSeekEnd(); })
            .onActionCancel(() => { this.panSeeking = false; this.seekPreview = false; }))
          .gesture(PanGesture({ fingers: 1, direction: PanDirection.Vertical, distance: 5 })
            .onActionStart((e: GestureEvent) => { this.vbStart(e); })
            .onActionUpdate((e: GestureEvent) => { this.vbMove(e); })
            .onActionEnd((_e: GestureEvent) => { this.vbEnd(); })
            .onActionCancel((_e: GestureEvent) => { this.vbEnd(); }))
          .gesture(LongPressGesture({ duration: 350, repeat: false })
            .onAction((_e: GestureEvent) => {
              if (this.settings.longPressSpeed > 0 && this.isPlaying && this.playUrl !== '') {
                this.boost = this.settings.longPressSpeed;
                this.engine.setSpeed(this.boost);
              }
            })
            .onActionEnd((_e: GestureEvent) => {
              if (this.boost > 0) { this.boost = 0; this.engine.setSpeed(this.curSpeed); }
            })
            .onActionCancel(() => {
              if (this.boost > 0) { this.boost = 0; this.engine.setSpeed(this.curSpeed); }
            }))
      }


      // 左上角：剧名 + 正在播放第几集 + 分辨率 + 弹幕开关（随控制层显隐）
      if (this.showCtrl) {
        Column({ space: 4 }) {
          Text(this.movieName)
            .fontSize(14).fontColor('#FFFFFF').fontWeight(FontWeight.Bold)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.ep !== null) {
            Text('正在播放：' + this.ep.name).fontSize(12).fontColor('#FFFFFF')
          }
          Text('1080P').fontSize(11).fontColor('#FFFFFF')
        }
        .position({ x: 12, y: 12 })
        .alignItems(HorizontalAlign.Start)
      }

      // 右上角：投屏 + 收藏（全屏按钮移至底部控制栏；随控制层显隐）
      if (this.showCtrl) {
        Row({ space: 18 }) {
          if (this.castUrl !== '') {
            Image($r('app.media.ic_cast')).width(20).height(20)
              .fillColor('#FFFFFF')
              .onClick(() => { this.openCastPicker(); })
          }
          Image($r('app.media.ic_heart')).width(20).height(20)
            .fillColor(this.isFav ? '#E53935' : '#FFFFFF')
            .onClick(() => {
              const m = this.detail?.movie;
              if (m !== null && m !== undefined) { this.isFav = this.favs.toggle(this.siteKey, m); }
            })
        }
        .position({ x: '100%', y: 14 })
        .markAnchor({ x: '100%' })
        .padding({ right: 12 })
      }

      // 中间：上一集、暂停/播放、下一集（随控制层显隐）
      if (this.playUrl !== '' && this.errMsg === '' && this.showCtrl) {
        Row({ space: 32 }) {
          Image($r('app.media.ic_skip_back')).width(22).height(22).fillColor('#FFFFFF')
            .onClick(() => { this.prevEp(); })
          Image(this.isPlaying ? $r('app.media.ic_pause') : $r('app.media.ic_play')).width(26).height(26).fillColor('#FFFFFF')
            .onClick(() => {
              this.isPlaying = !this.isPlaying;
              // 翻转后的新状态决定引擎动作:isPlaying=true 应 play——此前写成 pause 导致
              // 干净状态下首次点击永远 no-op(播放中点暂停调了 play),表现为"按钮有时不生效"
              if (this.isPlaying) { this.engine.play(); } else { this.engine.pause(); }
              this.armCtrlHide();
            })
          Image($r('app.media.ic_skip_forward')).width(22).height(22).fillColor('#FFFFFF')
            .onClick(() => { this.nextEp(); })
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
      }

      // 底部：进度条 + 时间 + 全屏（随控制层显隐；全屏直接切影院模式）
      // 两行收进一个内容自适应高度的底部锚定 Column——此前各自独立全宽锚定,影院模式设置行的
      // 透明盒子(带 34vp 底 padding)整个盖在收缩按钮上并把点击吞掉,全屏后退出按钮因此无反应
      // 锚定依赖「容器盒子=裁剪盒=子布局空间」三者重合——视频容器不可加 expandSafeArea(见上)
      if (this.playUrl !== '' && this.errMsg === '' && !this.resolving && !this.useWeb && this.showCtrl) {
        Column() {
          Row({ space: 10 }) {
            Text(formatDuration(this.curTime)).fontSize(11).fontColor('#FFFFFF')
            Slider({ value: Math.min(this.curTime, this.dur > 0 ? this.dur : 1), min: 0, max: this.dur > 0 ? this.dur : 1 })
              .layoutWeight(1)
              .selectedColor('#007DFF')
              .trackColor('#66FFFFFF')
              .blockColor('#FFFFFF')
              .onChange((value: number, mode: SliderChangeMode) => {
                // 拖动/点按期间只更新显示(uiSeeking 屏蔽 onTime 旧进度回写)，松手(End)才真正 seek——
                // 此前每帧 seek 会被引擎进度回调拽回，表现为进度条拖不动
                if (mode === SliderChangeMode.Begin) {
                  this.uiSeeking = true;
                  this.seekPending = false;
                }
                this.curTime = value;
                this.danmuClockAt = Date.now();   // 拖动预览时弹幕跟手
                if (mode === SliderChangeMode.End) {
                  this.uiSeeking = false;
                  this.seekPending = true;
                  this.engine.seek(value);
                  this.lastPos = value;
                  this.armCtrlHide();
                }
              })
            Text(formatDuration(this.dur)).fontSize(11).fontColor('#FFFFFF')
            Image(this.isTheater ? $r('app.media.ic_shrink') : $r('app.media.ic_expand'))
              .width(22).height(22).fillColor('#FFFFFF')
              .onClick(() => { this.toggleTheater(); })
          }
          .width('100%')
          .padding({ left: 12, right: 12, bottom: 8 })
          // 全屏设置行:进度条下方集中排列(线路/弹幕/倍速/旋转锁/刷新/循环/选集)
          if (this.isTheater) {
            Row({ space: 18 }) {
              if (this.siteKey !== 'live' && this.lines.length > 1) {
                Text(`线路${this.lineIdx + 1}`).fontSize(12).fontColor('#FFFFFF')
                  .onClick(() => {
                    this.picker = {
                      title: '切换线路',
                      options: this.lines.map((l: PlayLine): string => l.from),
                      index: this.lineIdx,
                      onPick: (idx: number): void => { this.switchTo(idx, this.epIdx); }
                    };
                  })
              }
              if (this.channelUrls.length > 1) {
                Text(`线路${this.channelLine + 1}`).fontSize(12).fontColor('#FFFFFF')
                  .onClick(() => {
                    this.picker = {
                      title: '切换线路',
                      options: this.channelUrls.map((_u: string, i: number): string => `线路${i + 1}`),
                      index: this.channelLine,
                      onPick: (idx: number): void => {
                        this.channelLine = idx;
                        this.playUrl = this.channelUrls[idx];
                      }
                    };
                  })
              }
              Text('弹幕').fontSize(12).fontColor('#FFFFFF')
                .onClick(() => { this.showDmPanel = true; this.dmStage = 'main'; })
              Text(this.curSpeed === 1.0 ? '倍速' : this.curSpeed + 'x').fontSize(12).fontColor('#FFFFFF')
                .onClick(() => {
                  this.picker = {
                    title: '播放倍速',
                    options: SPEED_OPTIONS.map((s: number): string => s + 'x'),
                    index: SPEED_OPTIONS.indexOf(this.curSpeed),
                    onPick: (idx: number): void => {
                      this.curSpeed = SPEED_OPTIONS[idx];
                      this.settings.playSpeed = this.curSpeed;
                      this.settings.save();
                      this.engine.setSpeed(this.curSpeed);
                    }
                  };
                })
              Text('刷新').fontSize(12).fontColor('#FFFFFF')
                .onClick(() => { this.playUrl = ''; this.prepare(); })
              // 跳过片头:常驻(仅直播隐藏)——第一次点=把当前位置标记为本剧片头结束点;
              // 已标记过且还在片头内 → 直接跳到记忆点
              if (this.siteKey !== 'live') {
                Text('跳过片头').fontSize(12).fontColor('#FFFFFF')
                  .onClick(() => { this.markSkipIntro(); })
              }
              // 跳过片尾:常驻(有下一集且非直播)——点了立即连播下一集,
              // 并把距结尾时长记为本剧片尾长度(后续集到点自动连播)
              if (this.siteKey !== 'live'
                && this.epIdx + 1 < (this.lines[this.lineIdx]?.episodes.length ?? 0)) {
                Text('跳过片尾').fontSize(12).fontColor('#FFFFFF')
                  .onClick(() => { this.markSkipOutro(); })
              }
              Text('选集').fontSize(12).fontColor('#FFFFFF')
                .onClick(() => {
                  if (this.lines.length === 0 || this.lines[this.lineIdx] === undefined) { return; }
                  this.picker = {
                    title: '选集',
                    options: this.lines[this.lineIdx].episodes.map((e: Episode): string => e.name),
                    index: this.epIdx,
                    onPick: (idx: number): void => { this.switchTo(this.lineIdx, idx); }
                  };
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.End)   // 右下角对齐
            .padding({ left: 12, right: 12, bottom: 16 })
          }
        }
        .width('100%')
        .position({ x: 0, y: '100%' })
        .markAnchor({ x: 0, y: '100%' })
        // 吞掉底部控制块空白处的点击:不下穿手势层切走控制层,顺手续期保活
        .onClick(() => { this.armCtrlHide(); })
      }

      // 长按加速提示
      if (this.boost > 0) {
        Text(`${this.boost}x 倍速播放中 »`)
          .fontSize(15).fontColor('#FFEB3B').fontWeight(FontWeight.Medium)
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .backgroundColor('#B3000000')
          .borderRadius(10)
          .position({ x: '50%', y: 60 }).markAnchor({ x: '50%' })
      }

      // 返回:全屏右侧,锁定图标正上方——效果与进度条右侧的收缩图标一致(退出全屏回嵌入模式)
      if (this.isTheater && this.showCtrl) {
        Image($r('app.media.ic_back')).width(22).height(22)
          .fillColor('#FFFFFF')
          .onClick(() => { this.toggleTheater(); })
          .position({ x: '100%', y: '50%' })
          .markAnchor({ x: '100%', y: '50%' })
          // 距边 70vp:反向横屏时前摄挖孔会落在右缘中部,同样往内避让
          .translate({ x: -this.cutoutDepth, y: -44 })
      }

      // 旋转锁:全屏右侧中部,随控制层显隐(锁定状态本身持续生效,仅图标隐藏)
      if (this.isTheater && this.showCtrl) {
        Image(this.rotationLocked ? $r('app.media.ic_lock') : $r('app.media.ic_lock_open')).width(22).height(22)
          .fillColor(this.rotationLocked ? '#4D9EFF' : '#FFFFFF')
          .onClick(() => { this.toggleRotationLock(); })
          .position({ x: '100%', y: '50%' })
          .markAnchor({ x: '100%', y: '50%' })
          // 距边 70vp:反向横屏时摄像头在右缘中部,同弹幕图标一并避让
          .translate({ x: -this.cutoutDepth })
      }

      // 弹幕开关:全屏左侧中部(镜像右侧旋转锁),点亮=开,点灭清屏;与弹幕面板的开关同一状态并持久化
      if (this.isTheater && this.showCtrl) {
        Image($r('app.media.ic_danmu')).width(22).height(22)
          .fillColor(this.dmOn ? '#4D9EFF' : '#FFFFFF')
          .onClick(() => {
            this.dmOn = !this.dmOn;
            if (!this.dmOn) { this.clearDanmaku(); }
            this.settings.danmakuOn = this.dmOn;
            this.settings.save();
          })
          .position({ x: 0, y: '50%' })
          .markAnchor({ x: 0, y: '50%' })
          // 距边 = 挖孔实测深度:横屏时前摄恰在左右缘中部
          .translate({ x: this.cutoutDepth })
      }

      // 缓冲加载指示(快进/慢网时 START→END 之间):转圈+缓冲进度,触摸穿透不挡手势
      if (this.buffering && this.playUrl !== '' && !this.resolving) {
        Column({ space: 8 }) {
          LoadingProgress().width(36).height(36).color('#FFFFFF')
          Text(this.bufPercent > 0 ? `加载中 ${this.bufPercent}%` : '加载中')
            .fontSize(12).fontColor('#FFFFFF')
        }
        .padding({ left: 18, right: 18, top: 14, bottom: 14 })
        .backgroundColor('#B3000000')
        .borderRadius(12)
      }

      // 投屏状态提示(画面已到 TV,本机黑屏属正常)
      if (this.casting) {
        Text('正在投屏到 ' + this.castDeviceName)
          .fontSize(13).fontColor('#FFFFFF')
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .backgroundColor('#B3000000')
          .borderRadius(10)
          .position({ x: '50%', y: 110 }).markAnchor({ x: '50%' })
      }

      // 横向滑动快进/快退预览气泡（Stack 默认居中）
      if (this.seekPreview) {
        Column({ space: 4 }) {
          Text((this.seekDelta >= 0 ? '快进 ' : '快退 ') + Math.abs(Math.round(this.seekDelta)) + ' 秒')
            .fontSize(14).fontColor('#FFFFFF').fontWeight(FontWeight.Medium)
          Text(formatDuration(Math.max(0, Math.min(this.seekFrom + this.seekDelta, this.dur)))
            + ' / ' + formatDuration(this.dur))
            .fontSize(12).fontColor('#CCFFFFFF')
        }
        .padding({ left: 16, right: 16, top: 10, bottom: 10 })
        .backgroundColor('#B3000000')
        .borderRadius(12)
      }

      // 左右半屏竖滑的音量/亮度提示（Stack 默认居中）
      if (this.gestureTip !== '') {
        Text(this.gestureTip)
          .fontSize(14).fontColor('#FFFFFF').fontWeight(FontWeight.Medium)
          .padding({ left: 16, right: 16, top: 10, bottom: 10 })
          .backgroundColor('#B3000000')
          .borderRadius(12)
      }
    }
    // Stack 必须钉死为容器大小：底部控制层 position(y:'100%') 锚定 Stack 底边，
    // XComponent 按宽高比缩放后 Stack 若自适应子组件，锚点随之漂移(cover 时进度条被 clip 裁出容器)
    .width('100%').height('100%')
    // 点按/横竖滑/长按手势已移到上方专属手势层(见 videoInner 内注释)：
    // 挂在 Stack 根上会和 Slider 等控制层子控件抢事件,导致进度条拖不动、点按被吞

  }



  @Builder
  detailArea() {
    Scroll() {
      Column({ space: 0 }) {
        // 1. 剧名
        Text(this.movieName)
          .fontSize(18).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%').padding({ left: 16, right: 16, top: 14, bottom: 6 })

        // 2. 更新至第几集
        if (this.lines.length > 0 && this.lines[this.lineIdx] !== undefined) {
          Text('更新至 ' + (this.lines[this.lineIdx].episodes[this.lines[this.lineIdx].episodes.length - 1]?.name ?? ''))
            .fontSize(13).fontColor('#FFFFFF')
            .width('100%').padding({ left: 16, right: 16, bottom: 6 })
        }

        // 3. 站源
        if (this.siteName !== '') {
          Row({ space: 6 }) {
            Text('站源:').fontSize(12).fontColor('#FFFFFF')
            Text(this.siteName).fontSize(13).fontColor('#FFFFFF')
          }.width('100%').padding({ left: 16, right: 16, bottom: 6 })
        }

        // 4. 年份、类型
        if (this.detail !== null) {
          Row({ space: 8 }) {
            if (this.detail.year !== '') {
              Text('年份:').fontSize(12).fontColor('#FFFFFF')
              Text(this.detail.year).fontSize(12).fontColor('#FFFFFF')
            }
            if (this.detail.movie.typeName !== '') {
              Text('地区:').fontSize(12).fontColor('#FFFFFF')
              Text(this.detail.movie.typeName).fontSize(12).fontColor('#FFFFFF')
            }
            if (this.detail.movie.remark !== '') {
              Text('类型:').fontSize(12).fontColor('#FFFFFF')
              Text(this.detail.movie.remark).fontSize(12).fontColor('#FFFFFF')
            }
          }.width('100%').padding({ left: 16, right: 16, bottom: 6 })
        }

        // 5. 导演
        if (this.detail !== null && this.detail.director !== '') {
          Row() {
            Text('导演：').fontSize(12).fontColor('#FFFFFF')
            Text(this.detail.director).fontSize(12).fontColor('#FFFFFF')
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          }.width('100%').padding({ left: 16, right: 16, bottom: 6 })
        }

        // 6. 演员
        if (this.detail !== null && this.detail.actor !== '') {
          Row() {
            Text('演员：').fontSize(12).fontColor('#FFFFFF')
            Text(this.detail.actor).fontSize(12).fontColor('#FFFFFF')
              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          }.width('100%').padding({ left: 16, right: 16, bottom: 10 })
        }

        // 7. 线路(标题行+chips 行,与选集块同构);下载入口用"更多"同款文字+箭头样式
        if (this.lines.length > 0) {
          Column({ space: 8 }) {
            Row() {
              Text('线路').fontSize(13).fontColor('#FFFFFF')
              Blank()
              if (this.ep !== null && this.settings.builtinDownload) {
                Row({ space: 2 }) {
                  Text('下载').fontSize(12).fontColor('#FFFFFF')
                  Image($r('app.media.ic_chevron_right')).width(14).height(14).fillColor('#FFFFFF')
                }
                .onClick(() => { this.openDlPanel(); })
              }
            }.width('100%')
            Scroll() {
              Row({ space: 8 }) {
                ForEach(this.lines, (line: PlayLine, li: number) => {
                  Text(line.from || ('线路' + (li + 1)))
                    .fontSize(12)
                    .fontColor(this.lineIdx === li ? '#FFFFFF' : '#DDDDDD')
                    .backgroundColor('#4D888888')
                    .borderRadius(4)
                    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                    .onClick(() => { this.switchTo(li, 0); })
                }, (line: PlayLine, li: number) => li + line.from)
              }
            }
            .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).align(Alignment.Start).width('100%')
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 10 })
        }

        // 8. 选集（横滑 chips，当前集黄色高亮并自动定位）
        // padding 必须挂在 Column 上:原先误挂在 List 上导致"选集"标题没有左缩进、与"线路"不齐
        if (this.lines.length > 0 && this.lines[this.lineIdx] !== undefined) {
          Column({ space: 8 }) {
            Row() {
              Text('选集').fontSize(13).fontColor('#FFFFFF')
              Blank()
              Row({ space: 2 }) {
                Text('更多').fontSize(12).fontColor('#FFFFFF')
                Image($r('app.media.ic_chevron_right')).width(14).height(14).fillColor('#FFFFFF')
              }
              .onClick(() => { this.showEpPicker(); })
            }.width('100%')
            List({ space: 8, scroller: this.epScroller }) {
              ForEach(this.lines[this.lineIdx].episodes, (e: Episode, ei: number) => {
                ListItem() {
                  Text(e.name)
                    .fontSize(12)
                    .fontColor(this.epIdx === ei ? '#FFEB3B' : '#DDDDDD')
                    .backgroundColor('#4D888888')
                    .borderRadius(18)
                    .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .onClick(() => { this.switchTo(this.lineIdx, ei); })
              }, (e: Episode, ei: number) => ei + e.name)
            }
            .listDirection(Axis.Horizontal)
            .scrollBar(BarState.Off)
            .width('100%')
            .height(40)
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 10 })
        }

        // 9. 简介(标题与线路/选集同缩进;desc trim 掉源站返回的首行空白)
        if (this.detail !== null && this.detail.desc !== '') {
          Column({ space: 4 }) {
            Text('简介').fontSize(13).fontColor('#FFFFFF')
            Text(this.detail.desc.trim())
              .fontSize(12).fontColor('#FFFFFF').lineHeight(20)
              .width('100%')
          }.width('100%')
          .padding({ left: 16, right: 16, bottom: 6 })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    // Scroll 内容不足一屏时默认居中摆放子组件——必须顶对齐,详情才从播放器正下方开始
    .align(Alignment.Top)
    .layoutWeight(1)
  }

  // 面板里单集 chip 的状态后缀:' ✓'已下载 / 进度% / ' ✕'失败
  private epDlSuffix(epName: string): string {
    const it = this.dl.findByEp(this.movieName, epName);
    if (!it) { return ''; }
    if (it.status === 'completed') { return ' ✓'; }
    if (it.status === 'failed') { return ' ✕'; }
    return ` ${it.progress}%`;
  }

  // 弹幕面板:开关/时间偏移/手动搜索选库(自动匹配失败时的补救)。三阶段:main/search/pages
  @Builder
  dmPanel() {
    Stack() {
      Column()
        .width('100%').height('100%')
        .onClick(() => {
          this.showDmPanel = false;
          this.dmStage = 'main';
        })
      Column({ space: 10 }) {
        Row() {
          Text('弹幕').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
          Blank()
          Text('✕').fontSize(16).fontColor('#99FFFFFF')
            .padding({ left: 10, right: 2, top: 4, bottom: 4 })
            .onClick(() => {
              this.showDmPanel = false;
              this.dmStage = 'main';
            })
        }.width('100%')
        if (this.dmStage === 'main') {
          Row() {
            Text('弹幕显示').fontSize(14).fontColor('#FFFFFF').layoutWeight(1)
            Text(this.dmOn ? '开' : '关').fontSize(14).fontColor(this.dmOn ? '#4D9EFF' : '#99FFFFFF')
              .padding({ left: 12, right: 12 })
          }
          .width('100%').padding({ top: 8, bottom: 8 })
          .onClick(() => {
            this.dmOn = !this.dmOn;
            if (!this.dmOn) { this.clearDanmaku(); }
          })
          Row() {
            Text('时间偏移').fontSize(14).fontColor('#FFFFFF').layoutWeight(1)
            Text('−5s').fontSize(14).fontColor('#FFFFFF').padding({ left: 10, right: 10 })
              .onClick(() => { this.dmOffset -= 5; })
            Text(`${this.dmOffset}s`).fontSize(13).fontColor('#4D9EFF').width(56).textAlign(TextAlign.Center)
            Text('＋5s').fontSize(14).fontColor('#FFFFFF').padding({ left: 10, right: 10 })
              .onClick(() => { this.dmOffset += 5; })
          }.width('100%').padding({ top: 6, bottom: 6 })
          Row() {
            Text('重新匹配当前集').fontSize(14).fontColor('#FFFFFF').layoutWeight(1)
            Text('›').fontSize(16).fontColor('#99FFFFFF')
          }
          .width('100%').padding({ top: 10, bottom: 10 })
          .onClick(() => { this.loadDanmaku(); })
          Row() {
            Text('搜索弹幕库').fontSize(14).fontColor('#FFFFFF').layoutWeight(1)
            Text('›').fontSize(16).fontColor('#99FFFFFF')
          }
          .width('100%').padding({ top: 10, bottom: 10 })
          .onClick(() => { this.dmStage = 'search'; })
        } else if (this.dmStage === 'search') {
          Row({ space: 8 }) {
            TextInput({ text: this.dmKeyword!!, placeholder: '按片名/剧名搜索' })
              .fontSize(13).layoutWeight(1).height(40)
              .onChange((v: string) => { this.dmKeyword = v; })
              .enterKeyType(EnterKeyType.Search)
              .onSubmit(() => { this.dmPanelSearch(); })
            Button('搜索').height(40).fontSize(13)
              .backgroundColor('#007DFF').fontColor('#FFFFFF')
              .onClick(() => { this.dmPanelSearch(); })
          }.width('100%')
          List({ space: 6 }) {
            if (this.dmSearching) {
              ListItem() {
                Row() { LoadingProgress().width(24).height(24).color('#FFFFFF') }
                  .width('100%').justifyContent(FlexAlign.Center).padding(10)
              }
            }
            ForEach(this.dmVideos, (v: BiliSearchItem) => {
              ListItem() {
                Row() {
                  Text(v.title).fontSize(13).fontColor('#FFFFFF')
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
                  Text(`${v.play}`).fontSize(11).fontColor('#99FFFFFF')
                }.width('100%')
              }
              .padding({ left: 12, right: 12, top: 8, bottom: 8 })
              .borderRadius(8).backgroundColor('#22FFFFFF')
              .onClick(() => {
                this.dmSelVideo = v.bvid;
                biliPagelist(v.bvid).then((pages: BiliPage[]): void => {
                  this.dmPages = pages;
                  this.dmStage = 'pages';
                });
              })
            }, (v: BiliSearchItem) => v.bvid)
          }
          .layoutWeight(1).scrollBar(BarState.Off).width('100%')
        } else if (this.dmStage === 'pages') {
          Row() {
            Text('选择分P(集)').fontSize(14).fontColor('#FFFFFF').layoutWeight(1)
            Text('‹ 返回').fontSize(13).fontColor('#4D9EFF')
              .onClick(() => { this.dmStage = 'search'; })
          }.width('100%').padding({ bottom: 4 })
          List({ space: 6 }) {
            ForEach(this.dmPages, (p: BiliPage) => {
              ListItem() {
                Row() {
                  Text(p.part === '' ? `P${p.cid}` : p.part).fontSize(13).fontColor('#FFFFFF')
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
                }.width('100%')
              }
              .padding({ left: 12, right: 12, top: 8, bottom: 8 })
              .borderRadius(8).backgroundColor('#22FFFFFF')
              .onClick(() => {
                biliDanmuByCid(p.cid).then((items: DanmuItem[]): void => {
                  this.setDanmus(items);
                  this.dmStage = 'main';
                  this.showDmPanel = false;
                  this.getUIContext().getPromptAction().showToast({
                    message: items.length > 0 ? `已加载弹幕 ${items.length} 条` : '该分P无弹幕'
                  });
                });
              })
            }, (p: BiliPage) => `${p.cid}`)
          }
          .layoutWeight(1).scrollBar(BarState.Off).width('100%')
        }
      }
      .width('70%')
      .constraintSize({ maxWidth: 400 })
      .height(240)
      .backgroundColor('#D9262629')
      .borderRadius(14)
      .padding(12)
      .onClick(() => { })
    }
    .width('100%').height('100%')
  }

  // 批量下载选集面板(底部弹层):线路切换 + 全选/清空 + 集多选(带下载状态) + 下载按钮
  @Builder
  downloadPanel() {
    Column() {
      // 上方遮罩:点空白关闭
      Column()
        .width('100%').layoutWeight(1)
        .onClick(() => { if (!this.dlBusy) { this.showDlPanel = false; } })
      Column({ space: 10 }) {
        Row() {
          Text('下载选集')
            .fontSize(16).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
          Blank()
          Text('✕').fontSize(16).fontColor('#99FFFFFF')
            .padding({ left: 10, right: 2, top: 4, bottom: 4 })
            .onClick(() => { if (!this.dlBusy) { this.showDlPanel = false; } })
        }.width('100%')
        if (this.lines.length > 1) {
          Scroll() {
            Row({ space: 8 }) {
              ForEach(this.lines, (l: PlayLine, li: number) => {
                Text(l.from || ('线路' + (li + 1)))
                  .fontSize(12).fontColor('#FFFFFF')
                  .backgroundColor(this.dlLineIdx === li ? '#007DFF' : '#4D888888')
                  .borderRadius(4).padding({ left: 8, right: 8, top: 4, bottom: 4 })
                  .onClick(() => {
                    if (this.dlBusy || li === this.dlLineIdx) { return; }
                    this.dlLineIdx = li;
                    this.dlSel = (this.lines[li]?.episodes ?? []).map((_e: Episode): boolean => false);
                  })
              }, (l: PlayLine, li: number) => li + l.from)
            }
          }
          .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).align(Alignment.Start).width('100%')
        }
        Row({ space: 14 }) {
          Text('全选').fontSize(12).fontColor('#4D9EFF')
            .onClick(() => { if (!this.dlBusy) { this.dlSel = this.dlSel.map((_v: boolean): boolean => true); } })
          Text('清空').fontSize(12).fontColor('#99FFFFFF')
            .onClick(() => { if (!this.dlBusy) { this.dlSel = this.dlSel.map((_v: boolean): boolean => false); } })
          Blank()
          Text(this.dlResolveText).fontSize(12).fontColor('#FFEB3B').maxLines(1)
        }.width('100%')
        Scroll() {
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.lines[this.dlLineIdx]?.episodes ?? [], (e: Episode, ei: number) => {
              Text(e.name + this.epDlSuffix(e.name))
                .fontSize(12)
                .fontColor(this.dlSel[ei] ? '#FFFFFF' : '#E6FFFFFF')
                .fontWeight(this.dlSel[ei] ? FontWeight.Medium : FontWeight.Normal)
                .backgroundColor(this.dlSel[ei] ? '#007DFF' : '#4D888888')
                .opacity(this.epDlState(e.name) !== '' ? 0.55 : 1)
                .borderRadius(16)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .margin({ right: 8, bottom: 8 })
                .constraintSize({ maxWidth: '46%' })
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .onClick(() => {
                  const st = this.epDlState(e.name);
                  // 失败任务允许重新勾选重下
                  if (this.dlBusy || (st !== '' && st !== 'failed')) { return; }
                  this.dlSel[ei] = !this.dlSel[ei];
                })
            }, (e: Episode, ei: number) => this.dlLineIdx + '_' + ei + '_' + e.name)
          }
          .width('100%')
        }
        .scrollable(ScrollDirection.Vertical).scrollBar(BarState.Off)
        .width('100%').layoutWeight(1).align(Alignment.Top)
        Button(`下载选中 ${this.dlSel.filter((v: boolean): boolean => v).length} 集`)
          .width('100%').fontSize(14).fontColor('#FFFFFF')
          .backgroundColor(this.dlBusy ? '#66666666' : '#007DFF')
          .onClick(() => { this.batchDownload(); })
      }
      .width('100%').height('58%')
      .backgroundColor('#D9262629')
      .borderRadius({ topLeft: 16, topRight: 16 })
      .padding(12)
      // 卡片本体点击不关闭
      .onClick(() => { })
    }
    .width('100%').height('100%')
  }
}
