// 详情页 —— FongMi 风格布局：顶部片名（☰ 展开影片信息），左侧来源站竖排胶囊，
// 右侧剧集海报卡网格：红色徽标标线路、绿色徽标标备注、片名叠印海报底部。
// 点卡片进播放页；长按卡片可下载（内置下载开启时）。
// 跨源搜索：以片名搜全部采集站（CMS/XML 并发，drpy 串行），每站取首条匹配并加载详情。
import { Nav, PlayerParam } from '../nav/Nav';
import { AppState } from '../state/AppState';
import { AppSettings } from '../state/AppSettings';
import { MovieDetail, Movie, Episode, PlayLine, SiteConfig, SiteDriver, PageResult, isSiteSupported, siteEngine } from 'common';
import { DownloadManager } from '../state/DownloadManager';
import { PlayHistory } from '../state/PlayHistory';
import { Favorites } from '../state/Favorites';

// 每个来源站的搜索+详情结果
interface SourceResult {
  siteKey: string;
  siteName: string;
  movie: Movie;
  detail: MovieDetail | null;
}

@ComponentV2
export struct DetailPage {
  app: AppState = AppState.instance;
  settings: AppSettings = AppSettings.instance;
  dl: DownloadManager = DownloadManager.instance;
  @Local sources: SourceResult[] = [];
  @Local srcIdx: number = -1; // -1 = 全部
  ph: PlayHistory = PlayHistory.instance;
  favs: Favorites = Favorites.instance;
  @Local showInfo: boolean = false;      // ☰ 展开影片信息面板
  @Local loading: boolean = false;
  @Local errMsg: string = '';
  @Local descExpanded: boolean = false;  // 简介展开/收起
  @Local searchName: string = '';        // 顶栏可编辑搜索词
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

  // 选中源是否已收藏
  @Computed get curFav(): boolean {
    const src = this.sources[this.srcIdx];
    return src === undefined ? false : this.favs.isFav(src.siteKey, src.movie.vodId);
  }

  // 选中源上次看到
  @Computed get curLastWatch(): string {
    const src = this.sources[this.srcIdx];
    return src === undefined ? '' : this.ph.lastWatchLabel(src.siteKey, src.movie.vodId);
  }

  // 右侧网格展示的来源列表：全部或单个
  @Computed get displaySources(): SourceResult[] {
    if (this.srcIdx === -1) { return this.sources; }
    const s = this.sources[this.srcIdx];
    return s === undefined ? [] : [s];
  }

  build() {
    NavDestination() {
      Column() {
        this.detailBody()
      }.width('100%').height('100%')
        .linearGradient({ angle: 160, colors: this.wallpaperColors })
        .backgroundImage(this.settings.bgImage())
        .backgroundImageSize(ImageSize.Cover)
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      const m = ctx.pathInfo.param as Movie;
      if (m !== null && m !== undefined) { this.movie = m; this.searchName = m.name; this.search(); }
    })
  }

  @Builder
  detailBody() {
    Column() {
      // 顶栏：片名 + 源数量 + ☰ 信息开关
      Row() {
        TextInput({ text: this.searchName, placeholder: '输入片名搜索' })
          .fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor(this.isDarkWallpaper ? '#EEEEEE' : '#222222')
          .backgroundColor(Color.Transparent)
          .maxLines(1)
          .layoutWeight(1)
          .onChange((v: string) => { this.searchName = v; })
          .onSubmit(() => {
            if (this.searchName.trim() === '') { return; }
            if (this.movie !== null) { this.movie.name = this.searchName.trim(); }
            this.search();
          })
        Text(this.sources.length + '源')
          .fontSize(13)
          .fontColor(this.isDarkWallpaper ? '#999999' : '#888888')
          .padding({ left: 8, right: 8 })
        Image($r('app.media.ic_list'))
          .width(20).height(20)
          .fillColor(this.isDarkWallpaper ? '#CCCCCC' : '#555555')
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
              Row({ space: 10 }) {
                if (this.curLastWatch !== '') {
                  Text(this.curLastWatch)
                    .fontSize(12).fontColor('#F9A825')
                }
                Text(this.curFav ? '❤ 已收藏' : '♡ 收藏')
                  .fontSize(12)
                  .fontColor(this.curFav ? '#E53935' : (this.isDarkWallpaper ? '#AAAAAA' : '#666666'))
                  .onClick(() => {
                    const src = this.sources[this.srcIdx];
                    if (src !== undefined) { this.favs.toggle(src.siteKey, src.movie); }
                  })
              }
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

      if (this.sources.length > 0) {
        Row() {
          // 左侧来源站列表（竖排胶囊）
          Scroll() {
            Column({ space: 6 }) {
              Text('全部')
                .fontSize(13)
                .fontColor(this.srcIdx === -1 ? '#F9A825' : (this.isDarkWallpaper ? '#DDDDDD' : '#333333'))
                .fontWeight(this.srcIdx === -1 ? FontWeight.Bold : FontWeight.Normal)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .textAlign(TextAlign.Center).width('100%')
                .backgroundColor(this.srcIdx === -1
                  ? (this.isDarkWallpaper ? '#33F9A825' : '#1AF9A825')
                  : (this.isDarkWallpaper ? '#26FFFFFF' : '#12000000'))
                .borderRadius(8)
                .padding({ left: 10, right: 10, top: 7, bottom: 7 })
                .onClick(() => { this.srcIdx = -1; })
              ForEach(this.sources, (s: SourceResult, i: number) => {
                Text(s.siteName)
                  .fontSize(13)
                  .fontColor(this.srcIdx === i ? '#F9A825' : (this.isDarkWallpaper ? '#DDDDDD' : '#333333'))
                  .fontWeight(this.srcIdx === i ? FontWeight.Bold : FontWeight.Normal)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .textAlign(TextAlign.Center).width('100%')
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
          .width(84)
          .height('100%')
          .padding({ left: 12 })

          // 右侧：所有来源站海报网格，一行两个
          Grid() {
            ForEach(this.displaySources, (src: SourceResult, idx: number) => {
              GridItem() {
                Column() {
                  Stack({ alignContent: Alignment.BottomStart }) {
                    Image(src.movie.pic === '' ? $r('app.media.startIcon') : src.movie.pic)
                      .width('100%').aspectRatio(0.667)
                      .objectFit(ImageFit.Cover).borderRadius(8)
                      .alt($r('app.media.startIcon'))
                    // 左上角源名徽标
                    Text(src.siteName).fontSize(10).fontColor('#FFFFFF').maxLines(1)
                      .padding({ left: 5, right: 5, top: 2, bottom: 2 })
                      .backgroundColor('#99000000').borderRadius(4)
                      .position({ x: 6, y: 6 })
                    // 底部片名
                    Text(src.movie.name).fontSize(11).fontColor('#FFFFFF').maxLines(1)
                      .padding({ left: 6, right: 6, bottom: 4, top: 4 })
                      .width('100%').backgroundColor('#80000000')
                      .borderRadius({ bottomLeft: 8, bottomRight: 8 })
                  }
                }
                .onClick(() => {
                  const d = src.detail;
                  if (d === null || d.lines.length === 0) { return; }
                  const ep = d.lines[0].episodes[0];
                  const param: PlayerParam = {
                    ep: ep, siteKey: src.siteKey, siteName: src.siteName,
                    movieName: src.movie.name, detail: d, lines: d.lines, lineIdx: 0, epIdx: 0
                  };
                  Nav.stack.pushPathByName('Player', param);
                })
              }
            }, (src: SourceResult, idx: number) => `${src.siteKey}-${idx}`)
          }
          .columnsTemplate('1fr 1fr')
          .columnsGap(12).rowsGap(12)
          .width('100%').layoutWeight(1).height('100%')
          .padding({ left: 12, right: 16, top: 4 })
          .scrollBar(BarState.Off)
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
    this.srcIdx = -1;
    try {
      // 单站处理：搜 → 取首条 → 加载详情 → 推入 sources（渐进显示）
      // 搜到结果即推入，即使详情加载失败也显示该站
      const handleSite = async (s: SiteConfig): Promise<void> => {
        const driver: SiteDriver | null = this.app.makeDriverFor(s);
        if (driver === null) { return; }
        const pr: PageResult = await driver.searchContent(m.name, false);
        if (pr.items.length === 0) { return; }
        let detail: MovieDetail | null = null;
        try {
          detail = await driver.detailContent([pr.items[0].vodId]);
        } catch (e) { /* 详情加载失败，仍推入该站 */ }
        this.sources = [...this.sources, { siteKey: s.key, siteName: s.name, movie: pr.items[0], detail }];
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
