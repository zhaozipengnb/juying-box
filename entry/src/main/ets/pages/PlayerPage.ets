// 播放页：全屏播放，统一使用 app 内置的 Video 播放器。
// 各源给的地址有两类：媒体直链，以及 MacCMS/解析接口的网页播放页——后者起播前先用
// resolvePlayUrl 解析成直链，避免同一个视频在「app 播放器」和「内嵌网页播放器」之间摇摆。
// 解析不出的地址不静默降级，而是给出错误卡片（重试 / 网页播放 / 返回），由用户决定。
// 全屏：Video 内置全屏按钮只在原方向内拉伸（竖屏下视频仍是一条横带）——
// 本页进入时窗口方向改为跟随传感器，另提供「全屏」按钮强制横屏，退出恢复竖屏。
// 线路轮循：当前线路播放失败时自动切到下一线路同集继续尝试，全部线路失败才报错。
// 底部面板：FongMi 风格，点击视频区可切换显示线路+剧集列表。
import { Nav, PlayerParam } from '../nav/Nav';
import { Episode, PlayLine, isDirectMedia, resolvePlayUrl } from 'common';
import { webview } from '@kit.ArkWeb';
import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppState } from '../state/AppState';
import { AppSettings } from '../state/AppSettings';
import { DownloadManager } from '../state/DownloadManager';
import { HlsAdFilterServer } from '../net/HlsAdFilterServer';

// 长按加速判定的按压时长（ms）：短于该值的点按（控制栏按钮/进度条）不触发倍速切换
const LONG_PRESS_DELAY_MS = 350;

@ComponentV2
export struct PlayerPage {
  @Local ep: Episode | null = null;
  @Local playUrl: string = '';     // 解析后的可播放地址（直链）
  @Local resolving: boolean = true;
  @Local errMsg: string = '';
  @Local useWeb: boolean = false;  // 手动兜底：内嵌浏览器播网页播放页
  @Local speed: number = 1.0;      // 当前倍速（起播取设置默认，长按临时切换）
  settings: AppSettings = AppSettings.instance;
  dl: DownloadManager = DownloadManager.instance;
  @Local movieName: string = '';
  @Local lines: PlayLine[] = [];   // 全部播放线路
  @Local lineIdx: number = 0;      // 当前线路索引
  @Local epIdx: number = 0;        // 当前剧集索引
  @Local showPanel: boolean = false; // 底部剧集面板开关
  private controller: VideoController = new VideoController();
  private webController: webview.WebviewController = new webview.WebviewController();
  private lpTimer: number = -1;    // 长按判定定时器 id

  // 切窗口方向：全屏=强制横屏，退出=恢复竖屏（模拟器无重力传感器也能用按钮）
  private async setOrientation(o: window.Orientation): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const win = await window.getLastWindow(ctx);
      await win.setPreferredOrientation(o);
    } catch (e) { /* 方向切换失败不阻塞播放 */ }
  }

  // 沉浸式全屏：布局扩展进安全区（状态栏/导航条），窗口背景置黑。
  // 不开 layoutFullScreen 时页面只画到安全区内，安全区外露出窗口默认白底——即播放器白边的来源。
  private async setImmersive(on: boolean): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const win = await window.getLastWindow(ctx);
      await win.setWindowLayoutFullScreen(on);
      await win.setWindowBackgroundColor(on ? '#FF000000' : '#FFFFFFFF');
    } catch (e) { /* 沉浸式失败不阻塞播放（仅留白，功能可用） */ }
  }

  // 起播前解析：直链直接用；网页播放页挖出其中的媒体地址；挖不到则提示（不自动跳网页播放器）。
  // AI去广告开启且目标是 HLS：把列表地址换成本地代理（127.0.0.1），由代理过滤插播广告分块；
  // 代理启动失败或非 m3u8 时回退直连（mp4 等无广告插播问题，无需代理）。
  // 解析失败或播放出错时自动轮循下一线路。
  private async prepare(): Promise<void> {
    const ep = this.ep;
    if (ep === null) { return; }
    this.resolving = true;
    this.errMsg = '';
    let target: string = ep.url;
    try {
      target = await resolvePlayUrl(ep.url, AppState.instance.makeFetchText());
    } catch (e) { /* 解析失败按原地址起播，仍不行则走错误卡片 */ }
    if (isDirectMedia(target)) {
      if (this.settings.aiAdFilter && /\.m3u8($|\?)/i.test(target)) {
        try {
          const base: string = await HlsAdFilterServer.ensureStarted();
          if (base !== '') { target = HlsAdFilterServer.wrapUrl(target); }
        } catch (e) { /* 代理不可用回退直连 */ }
      }
      this.playUrl = target;
      this.speed = this.settings.playSpeed;   // 起播倍速取设置默认值
    } else {
      // 当前线路解析不出直链，尝试下一线路
      this.tryNextLine();
    }
    this.resolving = false;
  }

  // 轮循下一线路：切到下一线路的同集继续尝试，全部线路失败才报错
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
      if (this.ep !== null) { this.prepare(); }
    } else {
      this.errMsg = '全部线路均无法播放';
    }
  }

  // 切换到指定线路的指定剧集
  private switchTo(li: number, ei: number): void {
    if (li < 0 || li >= this.lines.length) { return; }
    const eps = this.lines[li].episodes;
    if (ei < 0 || ei >= eps.length) { return; }
    this.lineIdx = li;
    this.epIdx = ei;
    this.ep = eps[ei];
    this.playUrl = '';
    this.errMsg = '';
    this.useWeb = false;
    this.showPanel = false;
    this.prepare();
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.BottomEnd }) {
        if (this.errMsg !== '') {
          Column({ space: 12 }) {
            Text('播放失败：' + this.errMsg).fontColor('#E53935')
            Row({ space: 12 }) {
              Button('重试').onClick(() => { this.errMsg = ''; this.playUrl = ''; this.prepare(); })
              Button('网页播放').onClick(() => { this.errMsg = ''; this.useWeb = true; })
              Button('返回').onClick(() => { Nav.stack.pop(); })
            }
          }.width('100%')
        } else if (this.useWeb && this.ep !== null) {
          // 网页兜底：仅由用户在错误卡片上显式选择时进入（页面内播放器自行处理视频）
          Web({ src: this.ep.url, controller: this.webController })
            .width('100%').height('100%')
            .javaScriptAccess(true)
            .domStorageAccess(true)
            .mediaPlayGestureAccess(true)
        } else if (this.resolving || this.playUrl === '') {
          LoadingProgress().width(44).height(44)
        } else {
          Video({ src: this.playUrl, controller: this.controller })
            .width('100%').height('100%')
            .autoPlay(true)
            .objectFit(ImageFit.Contain)
            .onError(() => {
              // 播放出错：自动轮循下一线路
              this.playUrl = '';
              this.tryNextLine();
            })
            // 长按加速：按压超过阈值切临时倍速，松开/取消恢复默认；短点按（控制栏）不受影响
            .onTouch((ev: TouchEvent) => {
              if (this.settings.longPressSpeed <= 0) { return; }
              if (ev.type === TouchType.Down) {
                this.lpTimer = setTimeout(() => {
                  this.speed = this.settings.longPressSpeed;
                }, LONG_PRESS_DELAY_MS);
              } else if (ev.type === TouchType.Up || ev.type === TouchType.Cancel) {
                if (this.lpTimer >= 0) { clearTimeout(this.lpTimer); this.lpTimer = -1; }
                this.speed = this.settings.playSpeed;
              }
            })
        }

        // 右上角：全屏按钮 + 面板开关 + 返回
        Column({ space: 10 }) {
          Text('←').fontSize(22).fontColor('#FFFFFF')
            .width(40).height(40).textAlign(TextAlign.Center)
            .backgroundColor('#66000000').borderRadius(20)
            .onClick(() => { Nav.stack.pop(); })
          Text('☰').fontSize(20).fontColor('#FFFFFF')
            .width(40).height(40).textAlign(TextAlign.Center)
            .backgroundColor('#66000000').borderRadius(20)
            .onClick(() => { this.showPanel = !this.showPanel; })
          Text('⤢').fontSize(20).fontColor('#FFFFFF')
            .width(40).height(40).textAlign(TextAlign.Center)
            .backgroundColor('#66000000').borderRadius(20)
            .onClick(() => { this.setOrientation(window.Orientation.LANDSCAPE); })
        }
        .position({ x: 12, y: 12 })
        .alignItems(HorizontalAlign.Center)

        // 底部剧集面板（FongMi 风格）：线路标签 + 剧集网格
        if (this.showPanel && this.lines.length > 0) {
          this.episodePanel()
        }
      }
      .width('100%').height('100%')
      .backgroundColor('#FF000000')
      .onClick(() => { if (this.showPanel) { this.showPanel = false; } })
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      const p = ctx.pathInfo.param as PlayerParam;
      if (p !== null && p !== undefined) {
        this.ep = p.ep;
        this.movieName = p.movieName ?? '';
        if (p.lines !== undefined && p.lines !== null) { this.lines = p.lines; }
        if (p.lineIdx !== undefined && p.lineIdx !== null) { this.lineIdx = p.lineIdx; }
        if (p.epIdx !== undefined && p.epIdx !== null) { this.epIdx = p.epIdx; }
      }
      else { this.errMsg = '播放参数缺失'; this.resolving = false; }  // 兜底：无参数进错误终态，避免永久 Loading
      this.setImmersive(true);                                          // 铺满安全区 + 黑底（消白边）
      this.setOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED);  // 播放中跟随传感器旋转
      if (this.ep !== null) { this.prepare(); }
    })
    .onWillDisappear(() => {
      if (this.lpTimer >= 0) { clearTimeout(this.lpTimer); this.lpTimer = -1; }
      this.setImmersive(false);                                  // 还原窗口布局与白底
      this.setOrientation(window.Orientation.PORTRAIT);          // 离开播放页恢复竖屏
    })
    .onBackPressed(() => { return false; })
  }

  // 底部剧集面板：顶部线路标签横排，下方剧集网格可滚动
  @Builder
  episodePanel() {
    Column() {
      // 线路标签
      Scroll() {
        Row({ space: 8 }) {
          ForEach(this.lines, (l: PlayLine, i: number) => {
            Text(l.from === '' ? '线路' + (i + 1) : l.from)
              .fontSize(14)
              .fontColor(this.lineIdx === i ? '#FFFFFF' : '#AAAAAA')
              .backgroundColor(this.lineIdx === i ? '#E53935' : '#333333')
              .borderRadius(14)
              .padding({ left: 14, right: 14, top: 6, bottom: 6 })
              .onClick(() => {
                if (i !== this.lineIdx) { this.switchTo(i, 0); }
              })
          }, (l: PlayLine, i: number) => i + '_' + l.from)
        }.padding({ left: 12, right: 12 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .height(44)

      // 剧集网格
      Scroll() {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.lines[this.lineIdx]?.episodes ?? [], (e: Episode, ei: number) => {
            Text(e.name)
              .fontSize(13)
              .fontColor(this.epIdx === ei ? '#FFFFFF' : '#CCCCCC')
              .backgroundColor(this.epIdx === ei ? '#E53935' : '#444444')
              .borderRadius(6)
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .margin(4)
              .onClick(() => { this.switchTo(this.lineIdx, ei); })
          }, (e: Episode, ei: number) => ei + '_' + e.name)
        }
        .padding({ left: 8, right: 8, top: 4, bottom: 8 })
      }
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
    }
    .width('100%')
    .height('50%')
    .backgroundColor('#DD000000')
    .border({ width: { top: 1 }, color: { top: '#333333' } })
  }
}
