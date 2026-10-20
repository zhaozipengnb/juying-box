// 详情页 —— 海报信息 + 线路切换 + 剧集网格，点剧集进入播放页（Task 7 完整版）
import { Nav, PlayerParam } from '../nav/Nav';
import { AppState } from '../state/AppState';
import { AppSettings } from '../state/AppSettings';
import { MovieDetail, Movie, Episode, PlayLine } from 'common';
import { DownloadManager } from '../state/DownloadManager';

@ComponentV2
export struct DetailPage {
  // 持有 AppState 实例：V2 观察要求经组件成员访问 @Trace（静态链式访问不建立依赖）
  app: AppState = AppState.instance;
  settings: AppSettings = AppSettings.instance;
  dl: DownloadManager = DownloadManager.instance;
  @Local detail: MovieDetail | null = null;
  @Local lineIdx: number = 0;
  @Local loading: boolean = false;
  @Local errMsg: string = '';
  @Local descExpanded: boolean = false;  // 简介展开/收起
  private movie: Movie | null = null;

  aboutToAppear(): void {
    // Navigation 参数在 NavDestination onReady 里取，此处兜底：push 顺序保证先于首帧
  }

  // @Computed 直接读取 @Trace 属性，确保 V2 依赖建立，壁纸变更立即生效
  @Computed get wallpaperColors(): Array<[ResourceColor, number]> {
    const w = this.settings.wallpaper;
    if (w === 'dark') { return [['#FF141416', 0.0], ['#FF232326', 1.0]]; }
    if (w === 'blue') { return [['#FF0E1E3C', 0.0], ['#FF1B3A5E', 1.0]]; }
    if (w === 'green') { return [['#FF12291F', 0.0], ['#FF1E4030', 1.0]]; }
    return [['#FFFFFFFF', 0.0], ['#FFFFFFFF', 1.0]];
  }

  @Computed get isDarkWallpaper(): boolean {
    return this.settings.wallpaper !== 'default' || this.settings.wallpaperUri !== '';
  }

  @Computed get wallpaperUri(): string {
    return this.settings.wallpaperUri;
  }

  build() {
    NavDestination() {
      Column() {
        if (this.loading) { LoadingProgress().width(44).height(44).margin({ top: 120 }) }
        else if (this.errMsg !== '') {
          Column({ space: 8 }) {
            Text('加载失败：' + this.errMsg).fontColor('#E53935')
            Button('重试').onClick(() => { this.load(); })
          }.margin({ top: 120 })
        }
        else if (this.detail !== null) { this.detailBody() }
      }.width('100%').height('100%')
        .linearGradient({ angle: 160, colors: this.wallpaperColors })
        .backgroundImage(this.wallpaperUri)
        .backgroundImageSize(ImageSize.Cover)
    }
    .title(this.detail?.movie.name ?? '详情')
    .onReady((ctx: NavDestinationContext) => {
      const m = ctx.pathInfo.param as Movie;
      if (m !== null && m !== undefined) { this.movie = m; this.load(); }
    })
  }

  @Builder
  detailBody() {
    Column() {
      Row({ space: 12 }) {
        Image(this.detail!.movie.pic === '' ? $r('app.media.startIcon') : this.detail!.movie.pic)
          .width(110).height(150).objectFit(ImageFit.Cover).borderRadius(8).alt($r('app.media.startIcon'))
        Column({ space: 6 }) {
          Text(this.detail!.movie.name).fontSize(18).fontWeight(FontWeight.Bold)
            .fontColor(this.isDarkWallpaper ? '#EEEEEE' : '#000000')
          Text('年份：' + (this.detail!.year === '' ? '未知' : this.detail!.year)).fontSize(13).fontColor(this.isDarkWallpaper ? '#AAAAAA' : '#666666')
          Text('演员：' + (this.detail!.actor === '' ? '未知' : this.detail!.actor))
            .fontSize(13).fontColor(this.isDarkWallpaper ? '#AAAAAA' : '#666666').maxLines(2)
          Text('导演：' + (this.detail!.director === '' ? '未知' : this.detail!.director)).fontSize(13).fontColor(this.isDarkWallpaper ? '#AAAAAA' : '#666666')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.width('100%').padding({ left: 12, right: 12, top: 14, bottom: 14 })

      // 简介默认 6 行截断，点击展开/收起
      Text(this.detail!.desc === '' ? '暂无简介' : this.detail!.desc)
        .fontSize(13).fontColor(this.isDarkWallpaper ? '#BBBBBB' : '#444444').maxLines(this.descExpanded ? 99 : 6)
        .padding({ left: 12, right: 12, top: 10 })
        .onClick(() => { this.descExpanded = !this.descExpanded; })
      Text('点击简介' + (this.descExpanded ? '收起' : '展开'))
        .fontSize(11).fontColor(this.isDarkWallpaper ? '#888888' : '#999999').padding({ left: 12, top: 4 })

      if (this.detail!.lines.length > 0) {
        Scroll() {
          Row({ space: 10 }) {
            ForEach(this.detail!.lines, (l: PlayLine, i: number) => {
              Text(l.from)
                .fontColor(this.lineIdx === i ? '#5AA9FF' : (this.isDarkWallpaper ? '#AAAAAA' : '#666666'))
                .fontWeight(this.lineIdx === i ? FontWeight.Bold : FontWeight.Normal)
                .onClick(() => { this.lineIdx = i; })
            }, (l: PlayLine, i: number) => l.from + i)
          }.padding({ left: 12, top: 14 })
        }.scrollable(ScrollDirection.Horizontal).width('100%')

        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
          ForEach(this.detail!.lines[this.lineIdx].episodes, (ep: Episode, i: number) => {
            Row() {
              Button(ep.name)
                .fontSize(13).height(36)
                .backgroundColor(this.isDarkWallpaper ? '#3A3A3C' : '#F2F3F5').fontColor(this.isDarkWallpaper ? '#CCCCCC' : '#333333')
                .onClick(() => {
                  const param: PlayerParam = { ep: ep, siteKey: this.app.currentSite?.key ?? '', movieName: this.detail!.movie.name };
                  Nav.stack.pushPathByName('Player', param);
                })
              if (this.settings.builtinDownload) {
                Button('⬇')
                  .fontSize(14).height(36).width(38).margin({ left: 4 })
                  .backgroundColor(this.isDarkWallpaper ? '#3A3A3C' : '#E8EAF0')
                  .fontColor(this.dl.isDownloading(ep.url) ? '#4CAF50' : (this.isDarkWallpaper ? '#CCCCCC' : '#666666'))
                  .enabled(!this.dl.isDownloading(ep.url))
                  .onClick(() => {
                    this.dl.startDownload(
                      this.detail!.movie.name, ep.name, ep.url,
                      this.app.currentSite?.key ?? ''
                    );
                  })
              }
            }
            .margin({ left: 8, top: 10 })
          }, (ep: Episode, i: number) => ep.url + i)
        }.width('100%').padding({ left: 4, right: 12, top: 6, bottom: 14 })
      } else {
        Text('无可用播放线路').fontSize(14).fontColor(this.isDarkWallpaper ? '#888888' : '#999999').margin({ top: 40 })
      }
    }.width('100%').height('100%').alignItems(HorizontalAlign.Start)
  }

  private async load(): Promise<void> {
    const d = this.app.driver;
    const m = this.movie;
    if (d === null || m === null) { return; }
    this.loading = true; this.errMsg = ''; this.lineIdx = 0;
    try {
      this.detail = await d.detailContent([m.vodId]);
    } catch (e) { this.errMsg = e instanceof Error ? e.message : String(e); }
    this.loading = false;
  }
}
