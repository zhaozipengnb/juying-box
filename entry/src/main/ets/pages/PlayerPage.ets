// 播放页：上半播放器 + 下方滚动详情（剧名/更新至/站源/年份地区类型/导演/演员/线路+下载/选集/简介）
// 各源给的地址有两类：媒体直链，以及 MacCMS/解析接口的网页播放页——后者起播前先用
// resolvePlayUrl 解析成直链，避免同一个视频在「app 播放器」和「内嵌网页播放器」之间摇摆。
// 解析不出的地址不静默降级，而是给出错误卡片（重试 / 网页播放 / 返回），由用户决定。
// 线路轮循：当前线路播放失败时自动切到下一线路同集继续尝试，全部线路失败才报错。
import { Nav, PlayerParam } from '../nav/Nav';
import { Episode, PlayLine, MovieDetail, isDirectMedia, resolvePlayUrl } from 'common';
import { webview } from '@kit.ArkWeb';
import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppState } from '../state/AppState';
import { AppSettings } from '../state/AppSettings';
import { DownloadManager } from '../state/DownloadManager';
import { HlsAdFilterServer } from '../net/HlsAdFilterServer';

@ComponentV2
export struct PlayerPage {
  @Local ep: Episode | null = null;
  @Local playUrl: string = '';
  @Local resolving: boolean = true;
  @Local errMsg: string = '';
  @Local useWeb: boolean = false;
  @Local speed: number = 1.0;
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
  @Local showDanmaku: boolean = false;
  private controller: VideoController = new VideoController();
  private webController: webview.WebviewController = new webview.WebviewController();

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
    let target: string = ep.url;
    try {
      target = await resolvePlayUrl(ep.url, AppState.instance.makeFetchText());
    } catch (e) { }
    if (isDirectMedia(target)) {
      if (this.settings.aiAdFilter && /\.m3u8($|\?)/i.test(target)) {
        try {
          const base: string = await HlsAdFilterServer.ensureStarted();
          if (base !== '') { target = HlsAdFilterServer.wrapUrl(target); }
        } catch (e) { }
      }
      this.playUrl = target;
    } else if (target !== '' && target !== ep.url) {
      this.playUrl = target;
    } else {
      this.errMsg = '无法解析播放地址';
    }
    if (this.errMsg !== '' && this.lines.length > 0) {
      this.tryNextLine();
    }
    this.resolving = false;
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
    this.playUrl = '';
    this.errMsg = '';
    this.useWeb = false;
    this.prepare();
  }

  private prevEp(): void {
    if (this.epIdx > 0) { this.switchTo(this.lineIdx, this.epIdx - 1); }
  }

  private nextEp(): void {
    const eps = this.lines[this.lineIdx]?.episodes ?? [];
    if (this.epIdx < eps.length - 1) { this.switchTo(this.lineIdx, this.epIdx + 1); }
  }

  build() {
    NavDestination() {
      Column() {
        this.videoArea()
        this.detailArea()
      }
      .width('100%').height('100%')
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      const p = ctx.pathInfo.param as PlayerParam;
      if (p !== null && p !== undefined) {
        this.ep = p.ep;
        this.movieName = p.movieName ?? '';
        this.siteName = p.siteName ?? '';
        this.siteKey = p.siteKey;
        this.detail = p.detail ?? null;
        if (p.lines !== undefined && p.lines !== null) { this.lines = p.lines; }
        if (p.lineIdx !== undefined && p.lineIdx !== null) { this.lineIdx = p.lineIdx; }
        if (p.epIdx !== undefined && p.epIdx !== null) { this.epIdx = p.epIdx; }
      }
      else { this.errMsg = '播放参数缺失'; this.resolving = false; }
      if (this.ep !== null) { this.prepare(); }
    })
    .onWillDisappear(() => {
      this.setImmersive(false);
      this.setOrientation(window.Orientation.UNSPECIFIED);
    })
  }

  @Builder
  videoArea() {
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
      } else if (this.resolving || this.playUrl === '') {
        Column() {
          LoadingProgress().width(36).height(36).color('#FFFFFF')
        }.width('100%').height('100%').justifyContent(FlexAlign.Center)
      } else {
        Video({ src: this.playUrl, controller: this.controller })
          .width('100%').height('100%')
          .autoPlay(true)
          .objectFit(ImageFit.Contain)
          .onError(() => { this.playUrl = ''; this.tryNextLine(); })
      }

      // 左上角：剧名 + 正在播放第几集 + 分辨率 + 弹幕开关
      Column({ space: 4 }) {
        Text(this.movieName)
          .fontSize(14).fontColor('#FFFFFF').fontWeight(FontWeight.Bold)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.ep !== null) {
          Text('正在播放：' + this.ep.name).fontSize(12).fontColor('#CCCCCC')
        }
        Text('1080P').fontSize(11).fontColor('#999999')
        Row({ space: 4 }) {
          Text(this.showDanmaku ? '💬 弹幕开' : '💬 弹幕关').fontSize(11)
            .fontColor(this.showDanmaku ? '#F9A825' : '#999999')
            .onClick(() => { this.showDanmaku = !this.showDanmaku; })
        }
      }
      .position({ x: 12, y: 12 })
      .alignItems(HorizontalAlign.Start)

      // 右上角：投屏、收藏、设置
      Row({ space: 18 }) {
        Image($r('app.media.ic_cast')).width(18).height(18).fillColor('#CCCCCC').onClick(() => {})
        Image($r('app.media.ic_heart')).width(18).height(18).fillColor('#CCCCCC').onClick(() => {})
        Image($r('app.media.ic_settings')).width(18).height(18).fillColor('#CCCCCC').onClick(() => {})
      }
      .position({ x: '100%', y: 14 })
      .markAnchor({ x: '100%' })
      .padding({ right: 12 })

      // 中间：上一集、暂停/播放、下一集
      if (this.playUrl !== '' && this.errMsg === '') {
        Row({ space: 32 }) {
          Image($r('app.media.ic_skip_back')).width(22).height(22).fillColor('#FFFFFF')
            .onClick(() => { this.prevEp(); })
          Image(this.isPlaying ? $r('app.media.ic_pause') : $r('app.media.ic_play')).width(26).height(26).fillColor('#FFFFFF')
            .onClick(() => {
              this.isPlaying = !this.isPlaying;
              if (this.isPlaying) { this.controller.start(); } else { this.controller.pause(); }
            })
          Image($r('app.media.ic_skip_forward')).width(22).height(22).fillColor('#FFFFFF')
            .onClick(() => { this.nextEp(); })
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
      }
    }
    .width('100%')
    .aspectRatio(1.78)
    .backgroundColor('#000000')
  }

  @Builder
  detailArea() {
    Scroll() {
      Column({ space: 0 }) {
        // 1. 剧名
        Text(this.movieName)
          .fontSize(18).fontWeight(FontWeight.Bold).fontColor('#333333')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%').padding({ left: 16, right: 16, top: 14, bottom: 6 })

        // 2. 更新至第几集
        if (this.lines.length > 0 && this.lines[this.lineIdx] !== undefined) {
          Text('更新至 ' + (this.lines[this.lineIdx].episodes[this.lines[this.lineIdx].episodes.length - 1]?.name ?? ''))
            .fontSize(13).fontColor('#999999')
            .width('100%').padding({ left: 16, right: 16, bottom: 6 })
        }

        // 3. 站源
        if (this.siteName !== '') {
          Row({ space: 6 }) {
            Text('站源:').fontSize(12).fontColor('#999999')
            Text(this.siteName).fontSize(13).fontColor('#F9A825')
          }.width('100%').padding({ left: 16, right: 16, bottom: 6 })
        }

        // 4. 年份、类型
        if (this.detail !== null) {
          Row({ space: 8 }) {
            if (this.detail.year !== '') {
              Text('年份:').fontSize(12).fontColor('#999999')
              Text(this.detail.year).fontSize(12).fontColor('#666666')
            }
            if (this.detail.movie.typeName !== '') {
              Text('地区:').fontSize(12).fontColor('#999999')
              Text(this.detail.movie.typeName).fontSize(12).fontColor('#666666')
            }
            if (this.detail.movie.remark !== '') {
              Text('类型:').fontSize(12).fontColor('#999999')
              Text(this.detail.movie.remark).fontSize(12).fontColor('#666666')
            }
          }.width('100%').padding({ left: 16, right: 16, bottom: 6 })
        }

        // 5. 导演
        if (this.detail !== null && this.detail.director !== '') {
          Row() {
            Text('导演：').fontSize(12).fontColor('#999999')
            Text(this.detail.director).fontSize(12).fontColor('#666666')
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          }.width('100%').padding({ left: 16, right: 16, bottom: 6 })
        }

        // 6. 演员
        if (this.detail !== null && this.detail.actor !== '') {
          Row() {
            Text('演员：').fontSize(12).fontColor('#999999')
            Text(this.detail.actor).fontSize(12).fontColor('#666666')
              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          }.width('100%').padding({ left: 16, right: 16, bottom: 10 })
        }

        // 7. 线路 + 下载
        if (this.lines.length > 0) {
          Row({ space: 8 }) {
            Text('线路').fontSize(13).fontColor('#999999')
            Scroll() {
              Row({ space: 8 }) {
                ForEach(this.lines, (line: PlayLine, li: number) => {
                  Text(line.from || ('线路' + (li + 1)))
                    .fontSize(12)
                    .fontColor(this.lineIdx === li ? '#FFFFFF' : '#666666')
                    .backgroundColor(this.lineIdx === li ? '#F9A825' : '#F0F0F0')
                    .borderRadius(4)
                    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                    .onClick(() => { this.switchTo(li, 0); })
                }, (line: PlayLine, li: number) => li + line.from)
              }
            }
            .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).layoutWeight(1)
            if (this.ep !== null && this.settings.builtinDownload) {
              Text('下载')
                .fontSize(12).fontColor('#666666')
                .backgroundColor('#F0F0F0').borderRadius(4)
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .onClick(() => {
                  if (this.ep !== null && !this.dl.isDownloading(this.ep.url)) {
                    this.dl.startDownload(this.movieName, this.ep.name, this.ep.url, this.siteKey);
                  }
                })
            }
          }.width('100%').padding({ left: 16, right: 16, bottom: 10 })
        }

        // 8. 选集
        if (this.lines.length > 0 && this.lines[this.lineIdx] !== undefined) {
          Column({ space: 8 }) {
            Text('选集').fontSize(13).fontColor('#999999')
            Grid() {
              ForEach(this.lines[this.lineIdx].episodes, (e: Episode, ei: number) => {
                GridItem() {
                  Text(e.name)
                    .fontSize(12)
                    .fontColor(this.epIdx === ei ? '#FFFFFF' : '#666666')
                    .backgroundColor(this.epIdx === ei ? '#F9A825' : '#F5F5F5')
                    .borderRadius(4)
                    .width('100%').height(32)
                    .textAlign(TextAlign.Center)
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .onClick(() => { this.switchTo(this.lineIdx, ei); })
              }, (e: Episode, ei: number) => ei + e.name)
            }
            .columnsTemplate('1fr 1fr 1fr 1fr')
            .rowsGap(8).columnsGap(8)
            .width('100%')
            .height(Math.ceil(this.lines[this.lineIdx].episodes.length / 4) * 40)
          }.width('100%').padding({ left: 16, right: 16, bottom: 10 })
        }

        // 9. 简介
        if (this.detail !== null && this.detail.desc !== '') {
          Column({ space: 4 }) {
            Text('简介').fontSize(13).fontColor('#999999').padding({left:0})
            Text(this.detail.desc)
              .fontSize(12).fontColor('#666666').lineHeight(20)
          }.width('100%').padding({ left: 16, right: 16, bottom: 6 })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    .layoutWeight(1)
    .backgroundColor('#FFFFFF')
  }
}
