// 详情页 —— FongMi 风格布局：顶部片名（☰ 展开影片信息），左侧来源站竖排胶囊，
// 右侧剧集海报卡网格：红色徽标标线路、绿色徽标标备注、片名叠印海报底部。
// 点卡片进播放页；长按卡片可下载（内置下载开启时）。
// 跨源搜索：以片名搜全部采集站（CMS/XML 并发，drpy 按 Worker 池有限并发），每站取首条匹配并加载详情。
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

// 会话级搜索/详情缓存：详情页反复进出同一片名免重搜（键 = 站key|片名[|vodId]；
// 换源包整体失效，超容量整表清空。detail 可为 null——失败的详情同样缓存，免去重复等待）
const searchCache = new Map<string, PageResult>();
const detailCache = new Map<string, MovieDetail | null>();
const CACHE_MAX = 80;

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
  @Local gridView: boolean = AppSettings.instance.detailGrid;   // 聚合结果视图:false=列表 true=海报网格(记忆到设置)
  @Local loading: boolean = false;
  @Local errMsg: string = '';
  @Local descExpanded: boolean = false;  // 简介展开/收起
  @Local searchName: string = '';        // 顶栏可编辑搜索词
  @Local searchedDone: number = 0;       // 聚合进度：已完成的站数（加载文案展示 x/N）
  @Local searchedTotal: number = 0;
  private movie: Movie | null = null;
  private originSiteKey: string = '';    // 点进本页的来源站（排队列最首）
  private cacheCfgRef: Object | null = null;  // 缓存有效性标记：配置对象身份变化即清缓存

  aboutToAppear(): void {}

  @Computed get wallpaperColors(): Array<[ResourceColor, number]> {
    const w = this.settings.wallpaper;
    if (w === 'dark') { return [['#FF141416', 0.0], ['#FF232326', 1.0]]; }
    if (w === 'blue') { return [['#FF0E1E3C', 0.0], ['#FF1B3A5E', 1.0]]; }
    if (w === 'green') { return [['#FF12291F', 0.0], ['#FF1E4030', 1.0]]; }
    return [['#FFFFFFFF', 0.0], ['#FFFFFFFF', 1.0]];
  }

  @Computed get isDarkWallpaper(): boolean {
    return true;   // 默认背景为青橙渐变图，文字统一白色
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
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      const m = ctx.pathInfo.param as Movie;
      if (m !== null && m !== undefined) { this.movie = m; this.searchName = m.name; this.originSiteKey = m.siteKey ?? ''; this.search(); }
    })
  }

  @Builder
  detailBody() {
    Column() {
      // 顶栏：片名 + 源数量/详情开关 + ▦ 视图切换(直接生效)
      Row() {
        TextInput({ text: this.searchName, placeholder: '输入片名搜索' })
          .fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
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
          .fontColor('#FFFFFF')
          .padding({ left: 8 })
        Text(this.detail === null ? '' : this.showInfo ? '收起 ⌃' : '详情 ⌄')
          .fontSize(13)
          .fontColor('#B3FFFFFF')
          .padding({ left: 2, right: 6 })
          .onClick(() => { if (this.detail !== null) { this.showInfo = !this.showInfo; } })
        Image(this.gridView ? $r('app.media.ic_grid') : $r('app.media.ic_list'))
          .width(20).height(20)
          .fillColor('#FFFFFF')
          .padding({ left: 4, right: 4 })
          .onClick(() => {
            this.gridView = !this.gridView;
            this.settings.detailGrid = this.gridView;   // 视图记忆:下次进详情页沿用
            this.settings.save();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 6 })

      // 影片信息面板（"详情 ⌄" 展开）
      if (this.showInfo && this.detail !== null) {
        Column() {
          Row({ space: 12 }) {
            Image(this.detail.movie.pic === '' ? $r('app.media.startIcon') : this.detail.movie.pic)
              .width(96).height(132).objectFit(ImageFit.Cover).borderRadius(8).alt($r('app.media.startIcon'))
            Column({ space: 4 }) {
              Text('年份：' + (this.detail.year === '' ? '未知' : this.detail.year))
                .fontSize(12).fontColor('#FFFFFF').maxLines(1)
              Text('演员：' + (this.detail.actor === '' ? '未知' : this.detail.actor))
                .fontSize(12).fontColor('#FFFFFF').maxLines(2)
              Text('导演：' + (this.detail.director === '' ? '未知' : this.detail.director))
                .fontSize(12).fontColor('#FFFFFF').maxLines(1)
              Text(this.detail.movie.remark === '' ? '备注：未知' : '备注：' + this.detail.movie.remark)
                .fontSize(12).fontColor('#FFFFFF').maxLines(1)
              Row({ space: 10 }) {
                if (this.curLastWatch !== '') {
                  Text(this.curLastWatch)
                    .fontSize(12).fontColor('#FFFFFF')
                }
                Text(this.curFav ? '❤ 已收藏' : '♡ 收藏')
                  .fontSize(12)
                  .fontColor(this.curFav ? '#E53935' : '#FFFFFF')
                  .onClick(() => {
                    const src = this.sources[this.srcIdx];
                    if (src !== undefined) { this.favs.toggle(src.siteKey, src.movie); }
                  })
              }
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          }.width('100%')
          Text(this.detail.desc === '' ? '暂无简介' : this.detail.desc)
            .fontSize(12).fontColor('#FFFFFF')
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
                .fontColor('#FFFFFF')
                .fontWeight(this.srcIdx === -1 ? FontWeight.Bold : FontWeight.Normal)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .textAlign(TextAlign.Center).width('100%')
                .backgroundColor('#4D888888')
                .borderRadius(8)
                .padding({ left: 10, right: 10, top: 7, bottom: 7 })
                .onClick(() => { this.srcIdx = -1; })
              ForEach(this.sources, (s: SourceResult, i: number) => {
                Text(s.siteName)
                  .fontSize(13)
                  .fontColor('#FFFFFF')
                  .fontWeight(this.srcIdx === i ? FontWeight.Bold : FontWeight.Normal)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .textAlign(TextAlign.Center).width('100%')
                  .backgroundColor('#4D888888')
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

          // 右侧：聚合结果——列表(模板默认)/海报网格，▦ 切换
          if (this.gridView) {
            Grid() {
              ForEach(this.displaySources, (src: SourceResult, idx: number) => {
                GridItem() {
                  Column() {
                    Stack({ alignContent: Alignment.BottomStart }) {
                      Image(src.movie.pic === '' ? $r('app.media.startIcon') : src.movie.pic)
                        .width('100%').aspectRatio(0.667)
                        .objectFit(ImageFit.Cover).borderRadius(8)
                        .alt($r('app.media.startIcon'))
                      Text(src.siteName).fontSize(10).fontColor('#FFFFFF').maxLines(1)
                        .padding({ left: 5, right: 5, top: 2, bottom: 2 })
                        .backgroundColor('#99000000').borderRadius(4)
                        .position({ x: 6, y: 6 })
                      Text(src.movie.name).fontSize(11).fontColor('#FFFFFF').maxLines(1)
                        .padding({ left: 6, right: 6, bottom: 4, top: 4 })
                        .width('100%').backgroundColor('#80000000')
                        .borderRadius({ bottomLeft: 8, bottomRight: 8 })
                    }
                  }
                  .onClick(() => { this.openSource(src); })
                }
              }, (src: SourceResult, idx: number) => `${src.siteKey}-${idx}`)
            }
            .columnsTemplate('1fr 1fr')
            .columnsGap(12).rowsGap(12)
            .width('100%').layoutWeight(1).height('100%')
            .padding({ left: 12, right: 16, top: 4 })
            .scrollBar(BarState.Off)
          } else {
            List({ space: 10 }) {
              ForEach(this.displaySources, (src: SourceResult, idx: number) => {
                ListItem() {
                  Row({ space: 12 }) {
                    Image(src.movie.pic === '' ? $r('app.media.startIcon') : src.movie.pic)
                      .width(92).height(122)
                      .objectFit(ImageFit.Cover).borderRadius(8)
                      .alt($r('app.media.startIcon'))
                    Column({ space: 6 }) {
                      Text(src.movie.name).fontSize(15).fontColor('#FFFFFF')
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(src.movie.remark === '' ? src.siteName : src.movie.remark)
                        .fontSize(12).fontColor('#B3FFFFFF')
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                  }
                  .width('100%')
                  .padding({ left: 14, right: 14, top: 10, bottom: 10 })
                  .backgroundColor('#66888888')
                  .borderRadius(10)
                  .onClick(() => { this.openSource(src); })
                }
              }, (src: SourceResult, idx: number) => `${src.siteKey}-${idx}`)
            }
            .width('100%').layoutWeight(1).height('100%')
            .padding({ left: 16, right: 16, top: 4 })
            .scrollBar(BarState.Off)
          }
        }
        .width('100%')
        .layoutWeight(1)
      } else if (this.loading) {
        Text('搜索片源中… ' + this.searchedDone + '/' + this.searchedTotal + ' 站').fontSize(13).fontColor('#FFFFFF').margin({ top: 40 })
      } else if (this.errMsg !== '') {
        Column({ space: 8 }) {
          Text(this.errMsg).fontSize(13).fontColor('#E53935')
          Button('重试').fontSize(13).onClick(() => { this.search(); })
        }.margin({ top: 40 })
      } else {
        Text('无可用播放线路').fontSize(14).fontColor('#FFFFFF').margin({ top: 40 })
      }
    }.width('100%').height('100%').alignItems(HorizontalAlign.Start)
  }

  // 点聚合结果卡：带整源线路进播放页
  private openSource(src: SourceResult): void {
    const d = src.detail;
    if (d === null || d.lines.length === 0) { return; }
    const ep = d.lines[0].episodes[0];
    const param: PlayerParam = {
      ep: ep, siteKey: src.siteKey, siteName: src.siteName,
      movieName: src.movie.name, detail: d, lines: d.lines, lineIdx: 0, epIdx: 0
    };
    Nav.stack.pushPathByName('Player', param);
  }

  // 跨源搜索 + 逐站加载详情：CMS/XML 并发，drpy 4 路并发（Worker 池按站隔离）
  // 渐进式：每站搜到+详情就绪后立即推入 sources，页面实时显示，不等全部搜完。
  // 来源站（点进本页的站）排队列最首最先出结果；搜索/详情走会话级缓存，反复进出免重搜
  private async search(): Promise<void> {
    const cfg = this.app.config;
    const m = this.movie;
    if (cfg === null || m === null) { return; }
    if (this.cacheCfgRef !== cfg) {   // 换源包后缓存整体失效
      searchCache.clear();
      detailCache.clear();
      this.cacheCfgRef = cfg;
    }
    this.loading = true;
    this.errMsg = '';
    this.sources = [];
    this.srcIdx = -1;
    try {
      // 单站处理：搜 → 取首条 → 加载详情 → 推入 sources（渐进显示）
      // 搜到结果即推入，即使详情加载失败也显示该站；失败自动重试一次（慢站冷连接偶发超时）
      const handleSiteOnce = async (s: SiteConfig): Promise<void> => {
        const driver: SiteDriver | null = this.app.makeDriverFor(s);
        if (driver === null) { return; }
        const isOrigin: boolean = this.originSiteKey !== '' && s.key === this.originSiteKey;
        const ck = s.key + '|' + m.name;
        // 来源站不读缓存（站点抖动时空结果曾被缓存会一直搜不到），其余站照常命中
        let pr: PageResult | undefined = isOrigin ? undefined : searchCache.get(ck);
        if (pr === undefined) {
          pr = await driver.searchContent(m.name, false);
          // 搜索词兜底：首页标题带站点品牌尾缀（如「一生一世（2014）-国产电影精选」）时，
          // 多数站按全串精确匹配搜不到（含来源站自己），去掉尾缀用主干名重搜一次
          if (pr.items.length === 0 && m.name.lastIndexOf('-') > 0) {
            const base: string = m.name.substring(0, m.name.lastIndexOf('-'));
            const pr2: PageResult = await driver.searchContent(base, false);
            if (pr2.items.length > 0) { pr = pr2; }
          }
          if (searchCache.size >= CACHE_MAX) { searchCache.clear(); }
          if (pr.items.length > 0 || !isOrigin) { searchCache.set(ck, pr); }   // 来源站不缓存空结果
        }
        if (pr.items.length === 0) { return; }
        const dk = ck + '|' + pr.items[0].vodId;
        let detail: MovieDetail | null | undefined = detailCache.get(dk);
        if (detail === undefined) {
          detail = null;
          try { detail = await driver.detailContent([pr.items[0].vodId]); } catch (e) { /* 详情加载失败，仍推入该站 */ }
          if (detailCache.size >= CACHE_MAX) { detailCache.clear(); }
          detailCache.set(dk, detail);
        }
        this.sources = [...this.sources, { siteKey: s.key, siteName: s.name, movie: pr.items[0], detail }];
      };

      // 站序：来源站置顶，其余保持配置序
      const ordered = (arr: SiteConfig[]): SiteConfig[] => {
        const head: SiteConfig[] = this.originSiteKey === ''
          ? [] : arr.filter((s: SiteConfig): boolean => s.key === this.originSiteKey);
        const rest: SiteConfig[] = arr.filter((s: SiteConfig): boolean => s.key !== this.originSiteKey);
        return [...head, ...rest];
      };

      const supported: SiteConfig[] = ordered(cfg.sites.filter((s: SiteConfig): boolean =>
        isSiteSupported(s) && !this.settings.isSiteDisabled(s.key)));
      this.searchedTotal = supported.length;
      this.searchedDone = 0;

      const handleSite = async (s: SiteConfig): Promise<void> => {
        try {
          await handleSiteOnce(s);
        } catch (e) {
          await new Promise<void>((res: (v: void | PromiseLike<void>) => void): void => { setTimeout(res, 800); });
          await handleSiteOnce(s);
        }
      };

      // 1. CMS/XML/AppYs 有限并发：runPool 懒启动 12 路 lane（合包后站点数可达数百，
      //    无上限 Promise.all 会同时发起数百个 HTTP 请求），单站失败跳过
      const cmsSites: SiteConfig[] = [];
      const drpySites: SiteConfig[] = [];
      for (const s of supported) {
        if (siteEngine(s) === 'js') { drpySites.push(s); continue; }
        cmsSites.push(s);
      }
      await this.runPool(cmsSites, 12, handleSite);

      // 2. drpy 有限并发：桥侧 Worker 池每站一个 Worker（LRU 上限 8），跨站真并行；
      //    这里再以 4 路 lane 控制同时拉起的站数，避免瞬时 CPU/内存尖峰
      await this.runPool(drpySites, 4, handleSite);

      // 3. 收尾兜底：来源站（用户点进本页的站）仍无结果时最后补搜一次——
      //    来源站不读缓存，这次是真搜索，慢站偶发超时多一次机会
      if (this.originSiteKey !== ''
        && !this.sources.some((x: SourceResult): boolean => x.siteKey === this.originSiteKey)) {
        const os: SiteConfig | undefined = supported.find((s: SiteConfig): boolean => s.key === this.originSiteKey);
        if (os !== undefined) {
          await new Promise<void>((res: (v: void | PromiseLike<void>) => void): void => { setTimeout(res, 800); });
          try { await handleSiteOnce(os); } catch (_e) { /* 补搜失败到此为止 */ }
        }
      }

      // 4. 全部搜完仍无结果
      if (this.sources.length === 0) {
        this.errMsg = '全部站点均无结果';
      }
    } catch (e) {
      this.errMsg = (e as Error)?.message ?? '搜索异常';
    } finally {
      this.loading = false;
    }
  }

  // 有限并发池：items 按序分给 limit 条 lane，单站失败跳过，完成计数驱动加载进度文案
  private async runPool(items: SiteConfig[], limit: number, fn: (s: SiteConfig) => Promise<void>): Promise<void> {
    let next = 0;
    const lane = async (): Promise<void> => {
      while (next < items.length) {
        const s = items[next];
        next++;
        try { await fn(s); } catch (_e) { /* 单站失败跳过 */ }
        this.searchedDone++;
      }
    };
    const lanes: Promise<void>[] = [];
    for (let k = 0; k < limit && k < items.length; k++) { lanes.push(lane()); }
    await Promise.all(lanes);
  }
}
