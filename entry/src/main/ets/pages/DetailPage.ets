// 详情页 —— FongMi 风格布局：顶部片名（☰ 展开影片信息），左侧来源站竖排胶囊，
// 右侧剧集海报卡网格：红色徽标标线路、绿色徽标标备注、片名叠印海报底部。
// 点卡片进播放页；长按卡片可下载（内置下载开启时）。
// 跨源搜索：以片名搜全部采集站（CMS/XML 并发，drpy 串行），每站取首条匹配并加载详情。
import { Nav, PlayerParam } from '../nav/Nav';
import { AppState } from '../state/AppState';
import { AppSettings } from '../state/AppSettings';
import { MovieDetail, Movie, Episode, PlayLine, SiteConfig, SiteDriver, PageResult, isSiteSupported, siteEngine } from 'common';
import { DownloadManager } from '../state/DownloadManager';

// 每个来源站的搜索+详情结果
interface SourceResult {
  siteKey: string;
  siteName: string;
  movie: Movie;
  detail: MovieDetail | null;
}

// 展开网格卡片：line=所属线路名（红色徽标），ep=剧集
interface EpCard {
  line: string;
  ep: Episode;
}

@ComponentV2
export struct DetailPage {
  app: AppState = AppState.instance;
  settings: AppSettings = AppSettings.instance;
  dl: DownloadManager = DownloadManager.instance;
  @Local sources: SourceResult[] = [];
  @Local srcIdx: number = 0;
  @Local showInfo: boolean = false;      // ☰ 展开影片信息面板
  @Local loading: boolean = false;
  @Local errMsg: string = '';
  @Local descExpanded: boolean = false;  // 简介展开/收起
  @Local cardW: number = 170;            // 剧集卡宽（实测）：FlowItem 子组件 width('100%') 会解析成整流宽
  private movie: Movie | null = null;

  aboutToAppear(): void {}

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

  // 当前选中源的详情
  @Computed get detail(): MovieDetail | null {
    const src = this.sources[this.srcIdx];
    return src === undefined ? null : src.detail;
  }

  // 当前选中源的剧集卡片（聚合全部线路）。AI去广告开启时剔除广告集
  private cards(): EpCard[] {
    const d = this.detail;
    if (d === null) { return []; }
    const out: EpCard[] = [];
    for (const l of d.lines) {
      for (const e of l.episodes) {
        if (this.settings.aiAdFilter && (e.name.indexOf('广告') >= 0 || e.name.indexOf('推广') >= 0)) { continue; }
        out.push({ line: l.from, ep: e });
      }
    }
    return out;
  }

  build() {
    NavDestination() {
      Column() {
        this.detailBody()
      }.width('100%').height('100%')
        .linearGradient({ angle: 160, colors: this.wallpaperColors })
        .backgroundImage(this.wallpaperUri)
        .backgroundImageSize(ImageSize.Cover)
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      const m = ctx.pathInfo.param as Movie;
      if (m !== null && m !== undefined) { this.movie = m; this.search(); }
    })
  }

  @Builder
  detailBody() {
    Column() {
      // 顶栏：片名 + 源数量 + ☰ 信息开关
      Row() {
        Text(this.movie?.name ?? '')
          .fontSize(24).fontWeight(FontWeight.Bold)
          .fontColor(this.isDarkWallpaper ? '#EEEEEE' : '#222222')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.sources.length + '源')
          .fontSize(13)
          .fontColor(this.isDarkWallpaper ? '#999999' : '#888888')
          .padding({ left: 8, right: 8 })
        Text('☰')
          .fontSize(22)
          .fontColor(this.isDarkWallpaper ? '#CCCCCC' : '#555555')
          .padding({ left: 4, right: 4 })
          .onClick(() => { this.showInfo = !this.showInfo; })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 6 })

      // 影片信息面板（☰ 展开）
      if (this.showInfo && this.detail !== null) {
        Column() {
          Row({ space: 12 }) {
            Image(this.detail.movie.pic === '' ? $r('app.media.startIcon') : this.detail.movie.pic)
              .width(96).height(132).objectFit(ImageFit.Cover).borderRadius(8).alt($r('app.media.startIcon'))
            Column({ space: 4 }) {
              Text('年份：' + (this.detail.year === '' ? '未知' : this.detail.year))
                .fontSize(12).fontColor(this.isDarkWallpaper ? '#AAAAAA' : '#666666').maxLines(1)
              Text('演员：' + (this.detail.actor === '' ? '未知' : this.detail.actor))
                .fontSize(12).fontColor(this.isDarkWallpaper ? '#AAAAAA' : '#666666').maxLines(2)
              Text('导演：' + (this.detail.director === '' ? '未知' : this.detail.director))
                .fontSize(12).fontColor(this.isDarkWallpaper ? '#AAAAAA' : '#666666').maxLines(1)
              Text(this.detail.movie.remark === '' ? '备注：未知' : '备注：' + this.detail.movie.remark)
                .fontSize(12).fontColor(this.isDarkWallpaper ? '#AAAAAA' : '#666666').maxLines(1)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          }.width('100%')
          Text(this.detail.desc === '' ? '暂无简介' : this.detail.desc)
            .fontSize(12).fontColor(this.isDarkWallpaper ? '#BBBBBB' : '#444444')
            .maxLines(this.descExpanded ? 99 : 3)
            .margin({ top: 8 })
            .onClick(() => { this.descExpanded = !this.descExpanded; })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 16, right: 16, bottom: 10 })
      }

      if (this.detail !== null && this.detail.lines.length > 0) {
        Row() {
          // 左侧来源站列表（竖排胶囊）
          Scroll() {
            Column({ space: 6 }) {
              ForEach(this.sources, (s: SourceResult, i: number) => {
                Text(s.siteName)
                  .fontSize(13)
                  .fontColor(this.srcIdx === i ? '#F9A825' : (this.isDarkWallpaper ? '#DDDDDD' : '#333333'))
                  .fontWeight(this.srcIdx === i ? FontWeight.Bold : FontWeight.Normal)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .backgroundColor(this.srcIdx === i
                    ? (this.isDarkWallpaper ? '#33F9A825' : '#1AF9A825')
                    : (this.isDarkWallpaper ? '#26FFFFFF' : '#12000000'))
                  .borderRadius(8)
                  .padding({ left: 10, right: 10, top: 7, bottom: 7 })
                  .onClick(() => { this.srcIdx = i; })
              }, (s: SourceResult, i: number) => s.siteKey + i)
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
          }
          .scrollable(ScrollDirection.Vertical)
          .scrollBar(BarState.Off)
          .align(Alignment.Top)
          .width(116)
          .height('100%')
          .padding({ left: 12 })

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
                const src = this.sources[this.srcIdx];
                const d = src.detail;
                const lines = d !== null ? d.lines : [];
                let lineIdx = 0;
                let epIdx = 0;
                for (let i = 0; i < lines.length; i++) {
                  const idx = lines[i].episodes.findIndex((e: Episode) => e.url === c.ep.url);
                  if (idx >= 0) { lineIdx = i; epIdx = idx; break; }
                }
                const param: PlayerParam = { ep: c.ep, siteKey: src.siteKey, movieName: src.movie.name, lines: lines, lineIdx: lineIdx, epIdx: epIdx };
                Nav.stack.pushPathByName('Player', param);
              })
              .gesture(LongPressGesture({ repeat: false, duration: 500 })
                .onAction(() => {
                  if (!this.settings.builtinDownload || this.dl.isDownloading(c.ep.url)) { return; }
                  const src = this.sources[this.srcIdx];
                  this.dl.startDownload(src.movie.name, c.ep.name, c.ep.url, src.siteKey);
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
      } else if (this.loading) {
        Text('搜索片源中…').fontSize(13).fontColor(this.isDarkWallpaper ? '#AAAAAA' : '#999999').margin({ top: 40 })
      } else if (this.errMsg !== '') {
        Column({ space: 8 }) {
          Text(this.errMsg).fontSize(13).fontColor('#E53935')
          Button('重试').fontSize(13).onClick(() => { this.search(); })
        }.margin({ top: 40 })
      } else {
        Text('无可用播放线路').fontSize(14).fontColor(this.isDarkWallpaper ? '#888888' : '#999999').margin({ top: 40 })
      }
    }.width('100%').height('100%').alignItems(HorizontalAlign.Start)
  }

  // 跨源搜索 + 逐站加载详情：CMS/XML 并发，drpy 串行（单 Web 容器互斥）
  // 渐进式：每站搜到+详情就绪后立即推入 sources，页面实时显示，不等全部搜完
  private async search(): Promise<void> {
    const cfg = this.app.config;
    const m = this.movie;
    if (cfg === null || m === null) { return; }
    this.loading = true;
    this.errMsg = '';
    this.sources = [];
    this.srcIdx = 0;
    try {
      // 单站处理：搜 → 取首条 → 加载详情 → 有线路则推入 sources（渐进显示）
      const handleSite = async (s: SiteConfig): Promise<void> => {
        const driver: SiteDriver | null = this.app.makeDriverFor(s);
        if (driver === null) { return; }
        const pr: PageResult = await driver.searchContent(m.name, false);
        if (pr.items.length === 0) { return; }
        const detail: MovieDetail = await driver.detailContent([pr.items[0].vodId]);
        if (detail !== null && detail.lines.length > 0) {
          this.sources = [...this.sources, { siteKey: s.key, siteName: s.name, movie: pr.items[0], detail }];
        }
      };

      // 1. CMS/XML 并发
      const tasks: Promise<void>[] = [];
      const drpySites: SiteConfig[] = [];
      for (const s of cfg.sites) {
        if (!isSiteSupported(s)) { continue; }
        if (siteEngine(s) === 'js') { drpySites.push(s); continue; }
        tasks.push(handleSite(s).catch((_e: Object): void => { /* 单站失败跳过 */ }));
      }
      await Promise.all(tasks);

      // 2. drpy 串行（单 Web 容器互斥）
      for (const s of drpySites) {
        try { await handleSite(s); } catch (_e) { /* 单站失败跳过 */ }
      }

      // 3. 全部搜完仍无结果
      if (this.sources.length === 0) {
        this.errMsg = '全部站点均无结果';
      }
    } catch (e) {
      this.errMsg = (e as Error)?.message ?? '搜索异常';
    } finally {
      this.loading = false;
    }
  }
}
