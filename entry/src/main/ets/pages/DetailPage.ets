// 详情页 —— FongMi 风格布局：顶部片名（☰ 展开影片信息），左侧线路竖排胶囊
// （「全部」聚合所有线路），右侧剧集海报卡网格：红色徽标标线路、绿色徽标标备注、
// 片名叠印海报底部。点卡片进播放页；长按卡片可下载（内置下载开启时）。
import { Nav, PlayerParam } from '../nav/Nav';
import { AppState } from '../state/AppState';
import { AppSettings } from '../state/AppSettings';
import { MovieDetail, Movie, Episode, PlayLine } from 'common';
import { DownloadManager } from '../state/DownloadManager';

// 展开网格卡片：line=所属线路名（红色徽标），ep=剧集
interface EpCard {
  line: string;
  ep: Episode;
}

@ComponentV2
export struct DetailPage {
  // 持有 AppState 实例：V2 观察要求经组件成员访问 @Trace（静态链式访问不建立依赖）
  app: AppState = AppState.instance;
  settings: AppSettings = AppSettings.instance;
  dl: DownloadManager = DownloadManager.instance;
  @Local detail: MovieDetail | null = null;
  @Local lineIdx: number = 0;
  @Local showAll: boolean = true;        // 左栏「全部」：聚合所有线路的剧集
  @Local showInfo: boolean = false;      // ☰ 展开影片信息面板
  @Local loading: boolean = false;
  @Local errMsg: string = '';
  @Local descExpanded: boolean = false;  // 简介展开/收起
  @Local cardW: number = 170;            // 剧集卡宽（实测）：FlowItem 子组件 width('100%') 会解析成整流宽
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

  // 展开网格数据：全部=聚合所有线路；单线路=所选线路。AI去广告开启时剔除广告集
  private cards(): EpCard[] {
    const d = this.detail;
    if (d === null) { return []; }
    const out: EpCard[] = [];
    const push = (line: PlayLine): void => {
      for (const e of line.episodes) {
        if (this.settings.aiAdFilter && (e.name.indexOf('广告') >= 0 || e.name.indexOf('推广') >= 0)) { continue; }
        out.push({ line: line.from, ep: e });
      }
    };
    if (this.showAll) {
      for (const l of d.lines) { push(l); }
    } else {
      const l = d.lines[this.lineIdx];
      if (l !== undefined) { push(l); }
    }
    return out;
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
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      const m = ctx.pathInfo.param as Movie;
      if (m !== null && m !== undefined) { this.movie = m; this.load(); }
    })
  }

  @Builder
  detailBody() {
    Column() {
      // 顶栏：片名 + ☰ 信息开关
      Row() {
        Text(this.detail!.movie.name)
          .fontSize(24).fontWeight(FontWeight.Bold)
          .fontColor(this.isDarkWallpaper ? '#EEEEEE' : '#222222')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text('☰')
          .fontSize(22)
          .fontColor(this.isDarkWallpaper ? '#CCCCCC' : '#555555')
          .padding({ left: 12, right: 4 })
          .onClick(() => { this.showInfo = !this.showInfo; })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 6 })

      // 影片信息面板（☰ 展开）
      if (this.showInfo) {
        Column() {
          Row({ space: 12 }) {
            Image(this.detail!.movie.pic === '' ? $r('app.media.startIcon') : this.detail!.movie.pic)
              .width(96).height(132).objectFit(ImageFit.Cover).borderRadius(8).alt($r('app.media.startIcon'))
            Column({ space: 4 }) {
              Text('年份：' + (this.detail!.year === '' ? '未知' : this.detail!.year))
                .fontSize(12).fontColor(this.isDarkWallpaper ? '#AAAAAA' : '#666666').maxLines(1)
              Text('演员：' + (this.detail!.actor === '' ? '未知' : this.detail!.actor))
                .fontSize(12).fontColor(this.isDarkWallpaper ? '#AAAAAA' : '#666666').maxLines(2)
              Text('导演：' + (this.detail!.director === '' ? '未知' : this.detail!.director))
                .fontSize(12).fontColor(this.isDarkWallpaper ? '#AAAAAA' : '#666666').maxLines(1)
              Text(this.detail!.movie.remark === '' ? '备注：未知' : '备注：' + this.detail!.movie.remark)
                .fontSize(12).fontColor(this.isDarkWallpaper ? '#AAAAAA' : '#666666').maxLines(1)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          }.width('100%')
          Text(this.detail!.desc === '' ? '暂无简介' : this.detail!.desc)
            .fontSize(12).fontColor(this.isDarkWallpaper ? '#BBBBBB' : '#444444')
            .maxLines(this.descExpanded ? 99 : 3)
            .margin({ top: 8 })
            .onClick(() => { this.descExpanded = !this.descExpanded; })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 16, right: 16, bottom: 10 })
      }

      if (this.detail!.lines.length > 0) {
        Row() {
          // 左侧线路栏：全部 + 各线路（竖排胶囊）
          Scroll() {
            Column({ space: 10 }) {
              Text('全部')
                .fontSize(15)
                .fontColor(this.showAll ? '#F9A825' : (this.isDarkWallpaper ? '#DDDDDD' : '#333333'))
                .fontWeight(this.showAll ? FontWeight.Bold : FontWeight.Normal)
                .backgroundColor(this.isDarkWallpaper ? '#26FFFFFF' : '#12000000')
                .borderRadius(12)
                .padding({ left: 14, right: 14, top: 12, bottom: 12 })
                .onClick(() => { this.showAll = true; })
              ForEach(this.detail!.lines, (l: PlayLine, i: number) => {
                Text(l.from)
                  .fontSize(15)
                  .fontColor(!this.showAll && this.lineIdx === i ? '#F9A825' : (this.isDarkWallpaper ? '#DDDDDD' : '#333333'))
                  .fontWeight(!this.showAll && this.lineIdx === i ? FontWeight.Bold : FontWeight.Normal)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .backgroundColor(this.isDarkWallpaper ? '#26FFFFFF' : '#12000000')
                  .borderRadius(12)
                  .padding({ left: 14, right: 14, top: 12, bottom: 12 })
                  .onClick(() => { this.showAll = false; this.lineIdx = i; })
              }, (l: PlayLine, i: number) => l.from + i)
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
          }
          .scrollable(ScrollDirection.Vertical)
          .scrollBar(BarState.Off)
          .align(Alignment.Top)
          .width(168)
          .height('100%')

          // 右侧剧集海报卡网格
          WaterFlow() {
            ForEach(this.cards(), (c: EpCard) => {
              FlowItem() {
                Stack({ alignContent: Alignment.BottomStart }) {
                  Image(this.detail!.movie.pic === '' ? $r('app.media.startIcon') : this.detail!.movie.pic)
                    .width(this.cardW).aspectRatio(0.67)
                    .objectFit(ImageFit.Cover)
                    .borderRadius(10)
                    .alt($r('app.media.startIcon'))
                  // 全高透明容器：顶部徽标行 + 底部备注/片名叠印
                  Column() {
                    Row({ space: 6 }) {
                      Text(c.line)
                        .fontSize(11).fontColor('#FFFFFF')
                        .maxLines(1)
                        .backgroundColor('#CCE53935')
                        .borderRadius(6)
                        .padding({ left: 6, right: 6, top: 3, bottom: 3 })
                      Blank()
                      if (this.settings.builtinDownload && !this.dl.isDownloading(c.ep.url)) {
                        Text('⬇')
                          .fontSize(13).fontColor('#FFFFFF')
                          .backgroundColor('#66000000')
                          .borderRadius(6)
                          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                      }
                    }
                    .width(this.cardW)
                    Blank()
                    if (this.detail!.movie.remark !== '') {
                      Text(this.detail!.movie.remark)
                        .fontSize(11).fontColor('#FFFFFF')
                        .maxLines(1)
                        .backgroundColor('#CC2E7D32')
                        .borderRadius(6)
                        .padding({ left: 6, right: 6, top: 3, bottom: 3 })
                        .margin({ bottom: 6 })
                    }
                    Text(c.ep.name)
                      .fontSize(15).fontWeight(FontWeight.Bold)
                      .fontColor('#FFFFFF')
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  .width(this.cardW).height(this.cardW / 0.67)
                  .padding({ left: 8, right: 8, top: 8, bottom: 8 })
                  .linearGradient({ angle: 180, colors: [['#00111111', 0.55], ['#C2000000', 1.0]] })
                }
                .width(this.cardW)
              }
              .onClick(() => {
                const param: PlayerParam = { ep: c.ep, siteKey: this.app.currentSite?.key ?? '', movieName: this.detail!.movie.name };
                Nav.stack.pushPathByName('Player', param);
              })
              .gesture(LongPressGesture({ repeat: false, duration: 500 })
                .onAction(() => {
                  if (!this.settings.builtinDownload || this.dl.isDownloading(c.ep.url)) { return; }
                  this.dl.startDownload(
                    this.detail!.movie.name, c.ep.name, c.ep.url,
                    this.app.currentSite?.key ?? ''
                  );
                }))
            }, (c: EpCard) => c.line + '_' + c.ep.url)
          }
          .columnsTemplate('1fr 1fr')
          .columnsGap(12)
          .rowsGap(12)
          .width('100%')
          .layoutWeight(1)
          .height('100%')
          .padding({ left: 12, right: 16, top: 4, bottom: 12 })
          .onAreaChange((_o: Area, n: Area) => {
            this.cardW = ((n.width as number) - 12 - 16 - 12) / 2;
          })
        }
        .width('100%')
        .layoutWeight(1)
      } else {
        Text('无可用播放线路').fontSize(14).fontColor(this.isDarkWallpaper ? '#888888' : '#999999').margin({ top: 40 })
      }
    }.width('100%').height('100%').alignItems(HorizontalAlign.Start)
  }

  private async load(): Promise<void> {
    const d = this.app.driver;
    const m = this.movie;
    if (d === null || m === null) { return; }
    this.loading = true; this.errMsg = ''; this.lineIdx = 0; this.showAll = true;
    try {
      this.detail = await d.detailContent([m.vodId]);
    } catch (e) { this.errMsg = e instanceof Error ? e.message : String(e); }
    this.loading = false;
  }
}
