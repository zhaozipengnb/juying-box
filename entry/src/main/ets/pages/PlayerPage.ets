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
import { SPEED_OPTIONS } from '../state/AppSettings';
import { DrpyDriver } from '../spider/DrpyDriver';
import { webview } from '@kit.ArkWeb';
import { display, window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';

import { AppState } from '../state/AppState';
import { AppSettings } from '../state/AppSettings';
import { DownloadManager } from '../state/DownloadManager';
import { HlsAdFilterServer } from '../net/HlsAdFilterServer';
import { SniffProxy } from '../net/SniffProxyServer';
import { PlayHistory } from '../state/PlayHistory';
import { Favorites } from '../state/Favorites';

// URL → base64url(与 SniffProxyServer 的编码约定一致)
function b64urlEncode(x: string): string {
  const bytes: Uint8Array = new util.TextEncoder().encodeInto(x);
  return new util.Base64Helper().encodeToStringSync(bytes).replace(/\+/g, '-').replace(/\//g, '_');
}

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
  @Local loopPlay: boolean = false;    // 单集循环
  private channelUrls: string[] = [];  // 直播多线路地址表（来自 PlayerParam）
  private epScroller: Scroller = new Scroller();  // 选集横滑定位当前集
  @Local sniffUrl: string = '';        // 嗅探中:正在加载的网页地址(非空 = 嗅探中)
  @Local sniffing: boolean = false;
  private sniffReferer: string = '';
  private sniffController: webview.WebviewController = new webview.WebviewController();
  private sniffTimer: number = -1;
  private videoFitEnum(): ImageFit {
    if (this.settings.videoFit === 'cover') { return ImageFit.Cover; }
    if (this.settings.videoFit === 'fill') { return ImageFit.Fill; }
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
    if (this.settings.videoFit === 'fill') { return [0, 0]; }
    const den = this.density > 0 ? this.density : 1;
    const vw = this.vidW / den;
    const vh = this.vidH / den;
    if (vw <= 0 || vh <= 0) { return [0, 0]; }
    const sx = this.areaW / vw;
    const sy = this.areaH / vh;
    const s = this.settings.videoFit === 'cover' ? Math.max(sx, sy) : Math.min(sx, sy);
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
  @Local showCtrl: boolean = false;    // 自绘控制层显隐：默认隐藏，点击视频切换，播放中 4s 无操作自动隐藏
  private ctrlTimer: number = -1;      // 自动隐藏定时器（-1 = 未挂）
  @Local seekPreview: boolean = false; // 横向滑动快进/快退的预览气泡
  @Local seekDelta: number = 0;        // 滑动偏移（秒，右正左负）
  private seekFrom: number = 0;        // 手势起点的基准进度
  private panSeeking: boolean = false; // 本次手势是否有效（起手条件不满足则整段忽略）
  engine: AVPlayerEngine = new AVPlayerEngine();   // AVPlayer 内核(真倍速/循环/精准 seek)
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
      await win.setWindowBackgroundColor(on ? '#FF000000' : '#FFFFFFFF');
    } catch (e) { }
  }

  private async prepare(): Promise<void> {
    const ep = this.ep;
    if (ep === null) { return; }
    this.resolving = true;
    this.errMsg = '';
    this.sniffClear();
    let target: string = ep.url;
    // drpy（js 引擎）源：起播前先经 ext 的 play() 换直链（API 型源必需）；
    // 字符串规则源无 lazy，play 原样返回播放页地址——仅当结果确为媒体直链才采纳，
    // 否则回落通用解析（拉播放页 HTML 抽 player_aaaa/m3u8）
    const resolvedEp = await this.resolveViaDrpy(ep);
    let needSniff = false;
    if (resolvedEp !== null && isDirectMedia(resolvedEp.url)) {
      target = resolvedEp.url;
    } else if (resolvedEp !== null && resolvedEp.url !== '' && resolvedEp.parse === '1') {
      // play 结果 parse=1:url 为网页地址,需嗅探真实流(FongMi 嗅探能力对齐)
      target = resolvedEp.url;
      needSniff = true;
    } else {
      try {
        target = await resolvePlayUrl(ep.url, AppState.instance.makeFetchText());
      } catch (e) { }
    }
    if (isDirectMedia(target)) {
      if (this.settings.aiAdFilter && /\.m3u8($|\?)/i.test(target)) {
        try {
          const base: string = await HlsAdFilterServer.ensureStarted();
          if (base !== '') { target = HlsAdFilterServer.wrapUrl(target); }
        } catch (e) { }
      }
      this.playUrl = target;
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

  // 嗅探:隐藏 Web 加载播放页,监听网络请求抓媒体直链(对齐 FongMi 嗅探)
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
  private async resolveViaDrpy(ep: Episode): Promise<Episode | null> {
    const app = AppState.instance;
    const cfg = app.config;
    if (cfg === null) { return null; }
    const site: SiteConfig | undefined = cfg.sites.find((s: SiteConfig): boolean => s.key === this.siteKey);
    if (site === undefined || siteEngine(site) !== 'js') { return null; }
    const drv = app.makeDriverFor(site);
    if (!(drv instanceof DrpyDriver)) { return null; }
    try {
      const flag: string = this.lines.length > 0 ? this.lines[this.lineIdx].from : '';
      return await drv.playContent(flag, ep.url);
    } catch (e) {
      return null;
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
      // 对齐 FongMi:换线有提示(挖掘自 OK影视 onErrorEvent 降级链)
      this.getUIContext().getPromptAction().showToast({
        message: `正在切换线路至 ${next + 1}/${this.lines.length}:${this.lines[next].from}`
      });
      if (this.ep !== null) { this.prepare(); }
    } else {
      this.errMsg = '全部线路均无法播放';
    }
  }

  private switchTo(li: number, ei: number): void {
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
    this.seekDelta = offsetX * 0.3;
  }

  private panSeekEnd(): void {
    if (!this.panSeeking) { return; }
    this.panSeeking = false;
    this.seekPreview = false;
    const target = Math.max(0, Math.min(this.seekFrom + this.seekDelta, this.dur));
    this.engine.seek(target);
    this.curTime = target;
    this.lastPos = target;
    this.armCtrlHide();
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

  // 影院模式：横屏 + 播放器铺满 + 隐藏详情；再点还原。
  // 视频区常驻（见 build），切换只改布局属性与窗口方向，Video 不重建、进度与解码状态天然保留
  private toggleTheater(): void {
    this.isTheater = !this.isTheater;
    if (this.isTheater) {
      this.setImmersive(true);
      // 竖屏片保持竖屏全屏(画面满宽居中),横屏片才转横屏
      this.setOrientation(this.vidH > this.vidW && this.vidW > 0
        ? window.Orientation.PORTRAIT : window.Orientation.LANDSCAPE);
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

  // 统一壁纸配色（视频区以外透出，与其它页面一致）
  @Computed get wallpaperColors(): Array<[ResourceColor, number]> {
    const w = this.settings.wallpaper;
    if (w === 'dark') { return [['#FF141416', 0.0], ['#FF232326', 1.0]]; }
    if (w === 'blue') { return [['#FF0E1E3C', 0.0], ['#FF1B3A5E', 1.0]]; }
    if (w === 'green') { return [['#FF12291F', 0.0], ['#FF1E4030', 1.0]]; }
    return [['#FFFFFFFF', 0.0], ['#FFFFFFFF', 1.0]];
  }

  aboutToAppear(): void {
    // 视频区初始高度按屏宽/1.78 预置，避免首帧 0 高；onAreaChange 随实际容器宽度修正
    try {
      const d = display.getDefaultDisplaySync();
      this.density = d.densityPixels > 0 ? d.densityPixels : 1;
      this.videoH = d.width / this.density / 1.78;
    } catch (e) { }
    this.engine.onVideoSize = (w: number, h: number): void => {
      this.vidW = w; this.vidH = h;
    };
    // AVPlayer 回调:进度/状态/错误;倍速与循环由设置驱动
    this.engine.speed = speedEnum(this.settings.playSpeed);
    this.engine.onTime = (sec: number): void => {
      this.curTime = sec;
      this.lastPos = sec;
      this.saveProgress(false);
      // 断点续播:首次进度回调时 seek 一次(PlaybackInfo 无 duration,看完的由切集覆盖断点)
      if (!this.seekedResume && this.ep !== null) {
        this.seekedResume = true;
        const m = this.detail?.movie;
        const resume = (m !== null && m !== undefined)
          ? this.ph.resumePosition(this.siteKey, m.vodId, this.ep.url) : 0;
        if (resume > 0) { this.engine.seek(resume); }
      }
    };
    this.engine.onState = (st: EngineState): void => {
      if (st === 'prepared') { this.dur = this.engine.durationSec; }
      else if (st === 'playing') { this.isPlaying = true; }
      else if (st === 'paused') { this.isPlaying = false; }
      else if (st === 'error') {
        this.playUrl = '';
        if (this.settings.lineAutoPlay) { this.tryNextLine(); }
        else { this.errMsg = '播放失败,请手动切换线路重试'; }
      }
    };
    this.engine.onError = (msg: string): void => {
      this.playUrl = '';
      if (this.settings.lineAutoPlay) { this.tryNextLine(); }
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
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
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
      }
      .width('100%').height('100%')
    }
    .hideTitleBar(true)
    // 影院模式时返回先还原竖屏播放界面（消费本次返回），再次返回才退出播放页
    .onBackPressed((): boolean => {
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
      if (m !== null && m !== undefined) { this.isFav = this.favs.isFav(this.siteKey, m.vodId); }
      if (this.ep !== null) { this.prepare(); }
      this.setStatusBarContent('#FFFFFF');
    })
    .onWillDisappear(() => {
      this.saveProgress(true);
      this.sniffClear();
      // AVPlayer 不随页面销毁自动停止:退出播放页必须显式停掉并释放(否则声音继续)
      this.engine.stop();
      this.engine.release();
      if (this.ctrlTimer >= 0) { clearTimeout(this.ctrlTimer); this.ctrlTimer = -1; }
      this.showCtrl = false;
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

      // 右上角：收藏（全屏按钮移至底部控制栏；随控制层显隐）
      if (this.showCtrl) {
        Row({ space: 18 }) {
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
              if (this.isPlaying) { this.engine.pause(); } else { this.engine.play(); }
              this.armCtrlHide();
            })
          Image($r('app.media.ic_skip_forward')).width(22).height(22).fillColor('#FFFFFF')
            .onClick(() => { this.nextEp(); })
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
      }

      // 底部：进度条 + 时间 + 全屏（随控制层显隐；全屏直接切影院模式）
      if (this.playUrl !== '' && this.errMsg === '' && !this.resolving && !this.useWeb && this.showCtrl) {
        Row({ space: 10 }) {
          Text(formatDuration(this.curTime)).fontSize(11).fontColor('#FFFFFF')
          Slider({ value: Math.min(this.curTime, this.dur > 0 ? this.dur : 1), min: 0, max: this.dur > 0 ? this.dur : 1 })
            .layoutWeight(1)
            .selectedColor('#007DFF')
            .trackColor('#66FFFFFF')
            .blockColor('#FFFFFF')
            .onChange((value: number) => {
              this.curTime = value;
              this.engine.seek(value);
              this.armCtrlHide();
            })
          Text(formatDuration(this.dur)).fontSize(11).fontColor('#FFFFFF')
          if (this.siteKey !== 'live' && this.lines.length > 1) {
            Text(`线路${this.lineIdx + 1}`)
              .fontSize(12).fontColor('#FFFFFF')
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
            Text(`线路${this.channelLine + 1}`)
              .fontSize(12).fontColor('#FFFFFF')
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
          Text(this.curSpeed === 1.0 ? '倍速' : this.curSpeed + 'x')
            .fontSize(12).fontColor('#FFFFFF')
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
          Image(this.isTheater ? $r('app.media.ic_shrink') : $r('app.media.ic_expand'))
            .width(22).height(22).fillColor('#FFFFFF')
            .onClick(() => { this.toggleTheater(); })
        }
        .width('100%')
        .position({ x: 0, y: '100%' })
        .markAnchor({ x: 0, y: '100%' })
        .padding({ left: 12, right: 12, bottom: 8 })

        // 影院模式底部设置行(对齐模板:倍速/线路/选集/刷新/循环;内核项不适用未放)
        if (this.isTheater) {
          Row({ space: 22 }) {
            Text(this.curSpeed === 1.0 ? '1.00' : this.curSpeed + 'x')
              .fontSize(12).fontColor('#FFFFFF')
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
            if (this.lines.length > 1) {
              Text(`线路${this.lineIdx + 1}`)
                .fontSize(12).fontColor('#FFFFFF')
                .onClick(() => {
                  this.picker = {
                    title: '切换线路',
                    options: this.lines.map((l: PlayLine): string => l.from),
                    index: this.lineIdx,
                    onPick: (idx: number): void => { this.switchTo(idx, this.epIdx); }
                  };
                })
            }
            Text('选集')
              .fontSize(12).fontColor('#FFFFFF')
              .onClick(() => {
                if (this.lines.length === 0 || this.lines[this.lineIdx] === undefined) { return; }
                this.picker = {
                  title: '选集',
                  options: this.lines[this.lineIdx].episodes.map((e: Episode): string => e.name),
                  index: this.epIdx,
                  onPick: (idx: number): void => { this.switchTo(this.lineIdx, idx); }
                };
              })
            Text('刷新')
              .fontSize(12).fontColor('#FFFFFF')
              .onClick(() => { this.playUrl = ''; this.prepare(); })
            Text(this.loopPlay ? '循环开' : '循环关')
              .fontSize(12).fontColor('#FFFFFF')
              .onClick(() => {
                this.loopPlay = !this.loopPlay;
                this.engine.setLoop(this.loopPlay);
              })
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .position({ x: 0, y: '100%' }).markAnchor({ x: 0, y: '100%' })
          .padding({ bottom: 34 })
        }
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
    }
    // 点视频任意处切换控制层（子控件自身的 onClick 消费掉的不冒泡）；
    // 横向拖动（位移超 5vp）进滑动快进/快退，与点按互斥不冲突
    .onClick(() => { this.toggleCtrl(); })
    .gesture(PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 5 })
      .onActionStart((_e: GestureEvent) => { this.panSeekStart(); })
      .onActionUpdate((e: GestureEvent) => { this.panSeekMove(e.offsetX); })
      .onActionEnd((_e: GestureEvent) => { this.panSeekEnd(); })
      .onActionCancel(() => { this.panSeeking = false; this.seekPreview = false; }))
    // 长按临时加速（设置里长按倍速 >0 时生效），松开恢复起播倍速
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

        // 7. 线路 + 下载
        if (this.lines.length > 0) {
          Row({ space: 8 }) {
            Text('线路').fontSize(13).fontColor('#FFFFFF')
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
            .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).layoutWeight(1)
            if (this.ep !== null && this.settings.builtinDownload) {
              Text('下载')
                .fontSize(12).fontColor('#333333')
                .backgroundColor('#4D888888').borderRadius(4)
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .onClick(() => {
                  if (this.ep !== null && !this.dl.isDownloading(this.ep.url)) {
                    this.dl.startDownload(this.movieName, this.ep.name, this.ep.url, this.siteKey);
                  }
                })
            }
          }.width('100%').padding({ left: 16, right: 16, bottom: 10 })
        }

        // 8. 选集（横滑 chips，当前集黄色高亮并自动定位）
        if (this.lines.length > 0 && this.lines[this.lineIdx] !== undefined) {
          Column({ space: 8 }) {
            Text('选集').fontSize(13).fontColor('#FFFFFF')
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
        }.width('100%').padding({ left: 16, right: 16, bottom: 10 })
        }

        // 9. 简介
        if (this.detail !== null && this.detail.desc !== '') {
          Column({ space: 4 }) {
            Text('简介').fontSize(13).fontColor('#FFFFFF').padding({left:0})
            Text(this.detail.desc)
              .fontSize(12).fontColor('#FFFFFF').lineHeight(20)
          }.width('100%').padding({ left: 16, right: 16, bottom: 6 })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    .layoutWeight(1)
  }
}
