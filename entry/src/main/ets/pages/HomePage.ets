// 首页：站点 Select 切换 / 分类横滑 Tabs / MovieGrid 影片网格 / 触底分页 / 搜索入口
// 个性化设置消费点：图片尺寸（列数）、壁纸（背景）、无痕（搜索词不保留）、
// 聚合搜索 + 显示站源 + 站源筛选（搜索链路）。
import { AppState } from '../state/AppState';
import { AppSettings, PicSize } from '../state/AppSettings';
import { SearchHistory } from '../state/SearchHistory';
import { DrpyWebContainer } from '../spider/DrpyWebBridge';
import { Nav } from '../nav/Nav';
import { MovieGrid } from '../components/MovieGrid';
import { common } from '@kit.AbilityKit';
import { Category, HomeContent, Movie, PageResult, SiteDriver, SiteConfig, isSiteSupported, siteEngine } from 'common';

// 网格数据来源：决定触底翻页方式（home/search 的 pageCount 固定 1 不翻页，category 按 tid+页码追加）与错误重试入口
type ResultKind = 'home' | 'category' | 'search';

// 错误信息提取：Error/BusinessError/普通对象统一取 message
function errText(e: Object): string {
  if (e instanceof Error) { return e.message; }
  const m = (e as Record<string, Object>)['message'];
  if (typeof m === 'string' && m !== '') { return m; }
  return JSON.stringify(e);
}

@ComponentV2
export struct HomePage {
  // 持有 AppState 实例：V2 观察要求经组件成员访问 @Trace（静态链式访问不建立依赖）
  app: AppState = AppState.instance;
  @Local sites: string[] = [];        // 站点名列表（与 siteKeys 同序，Select 展示用；不支持的源不显示）
  @Local siteKeys: string[] = [];     // 站点 key 列表
  @Local siteEnabled: boolean[] = []; // 站点可用性列表（与 siteKeys 同序；csp_* 等 JAR 源为 false，Select 灰显）
  @Local siteIdx: number = 0;
  @Local cats: string[] = [];         // 分类名列表（与 catKeys 同序）
  @Local catKeys: string[] = [];      // 分类 tid 列表
  @Local catIdx: number = 0;
  @Local items: Movie[] = [];
  @Local page: number = 1;
  @Local pageCount: number = 1;
  @Local loading: boolean = false;    // 首页/分类加载中
  @Local searching: boolean = false;  // 搜索加载中（searchContent 无页码参数，结果一次性展示）
  @Local errMsg: string = '';
  @Local searchKey: string = '';
  @Local kind: ResultKind = 'home';
  // 聚合搜索的平行归属（与 items 同序）：站 key 用于点击时切站进详情，站名用于角标与筛选
  @Local aggSiteKeys: string[] = [];
  @Local aggSiteNames: string[] = [];
  @Local filterSite: string = '';   // 站源筛选当前选中（'' = 全部）
  @Local searchHistory: string[] = []; // 搜索历史标签（无痕模式下不展示）
  settings: AppSettings = AppSettings.instance;
  // 设置页返回后的刷新判据：配置对象身份变化（加载/清除订阅）才重拉，避免每次回首页都刷
  private lastConfigRef: Object | null = null;

  aboutToAppear(): void {
    this.refreshSites();
    this.lastConfigRef = this.app.config;
    this.loadHome(true);
    this.searchHistory = SearchHistory.instance.getAll();
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
    return true;   // 默认背景为青橙渐变图，文字统一白色
  }

  @Computed get wallpaperUri(): string {
    return this.settings.wallpaperUri;
  }

  @Computed get isIncognito(): boolean {
    return this.settings.incognito;
  }

  // 图片尺寸设置 → 网格列数（small=4 / normal=3 / large=2）
  private gridColumns(): number {
    const p: PicSize = this.settings.picSize;
    if (p === 'small') { return 4; }
    if (p === 'large') { return 2; }
    return 3;
  }

  // 筛选后可见条目的原始下标（siteLabels/切站索引与原始 items 对齐的桥梁）
  private visibleIdxs(): number[] {
    const out: number[] = [];
    for (let i = 0; i < this.items.length; i++) {
      if (this.filterSite === '' || (this.aggSiteNames[i] ?? '') === this.filterSite) { out.push(i); }
    }
    return out;
  }

  // 搜索结果角标（显示站源开 + 聚合结果有归属时展示；下标与 visibleItems 对齐）
  private siteLabels(): string[] {
    if (!this.settings.showSite || this.kind !== 'search' || this.aggSiteNames.length === 0) { return []; }
    return this.visibleIdxs().map((i: number): string => this.aggSiteNames[i] ?? '');
  }

  // 站源筛选 chips：聚合结果里出现过的站（保持稳定去重）
  private filterSiteOptions(): string[] {
    const seen: string[] = [];
    for (const n of this.aggSiteNames) {
      if (seen.indexOf(n) < 0) { seen.push(n); }
    }
    return seen;
  }

  // 当前筛选下的可见条目（filterSite 为空 = 全部）
  private visibleItems(): Movie[] {
    return this.visibleIdxs().map((i: number): Movie => this.items[i]);
  }

  private driver(): SiteDriver | null {
    return this.app.driver;
  }

  // 自动跳过失败源时已尝试的 siteKey 列表
  private _autoSkipTried: string[] = [];
  // 会话内已确认「无影片」的源（接口正常但内容为空）：下拉不显示、寻源跳过；
  // 网络类错误不记（可能瞬时故障，保留在列表可重试）。换订阅/重启恢复。
  private _deadSites: string[] = [];
  // 跳源链路中是否遇到过加载失败（区分「全部无影片」与「有源加载失败」的提示措辞）
  private _skipHitErr: boolean = false;

  // 查找下一个可用源（跳过已尝试与已确认无影片的），优先非代理源
  private findNextUsableSite(): string {
    const cfg = this.app.config;
    if (cfg === null) { return ''; }
    for (const s of cfg.sites) {
      if (isSiteSupported(s) && this.app.canDrive(s) && siteEngine(s) !== 'proxy'
        && !this._autoSkipTried.includes(s.key) && !this._deadSites.includes(s.key)) {
        return s.key;
      }
    }
    for (const s of cfg.sites) {
      if (isSiteSupported(s) && this.app.canDrive(s)
        && !this._autoSkipTried.includes(s.key) && !this._deadSites.includes(s.key)) {
        return s.key;
      }
    }
    return '';
  }

  // 从 AppState 同步站点列表（订阅已装配好，此处仅映射 UI 展示状态）
  private refreshSites(): void {
    const cfg = this.app.config;
    if (cfg === null) { return; }
    const names: string[] = [];
    const keys: string[] = [];
    const enabled: boolean[] = [];
    for (const s of cfg.sites) {
      if (!isSiteSupported(s) || !this.app.canDrive(s)) { continue; }   // 不支持或未配置代理的源不显示
      if (this._deadSites.includes(s.key)) { continue; }                // 已确认无影片的源本次会话不显示
      names.push(s.name);
      keys.push(s.key);
      enabled.push(true);
    }
    this.sites = names;
    this.siteKeys = keys;
    this.siteEnabled = enabled;
    const curKey: string = this.app.currentSite?.key ?? '';
    this.siteIdx = Math.max(0, keys.indexOf(curKey));
  }

  // 加载站点首页：分类 + 推荐列表（推荐无分页能力，pageCount 固定 1）
  // autoSkip=true 时，加载失败自动跳到下一个可用源（初始加载/重试/配置变更用）
  private async loadHome(autoSkip: boolean = false): Promise<void> {
    const d = this.driver();
    console.info('OKV loadHome start autoSkip=' + autoSkip + ' driver=' + (d === null ? 'null' : 'ok') + ' site=' + (this.app.currentSite?.key ?? '?') + ' engine=' + (this.app.currentSite?.api ?? '?'));
    if (d === null) { return; }
    this.loading = true;
    this.errMsg = '';
    let emptyHit = false;   // 区分「无影片」与网络/解析类错误：前者记死源，后者可重试
    try {
      const hc: HomeContent = await d.getHomeContent();
      if (this.app.driver !== d) { return; }   // 站点已切换，丢弃过期响应
      // 无影片判定（记死源用）：分类与推荐均为空；分类可用即视为有影片
      const bothEmpty = hc.categories.length === 0 && hc.items.length === 0;
      if (bothEmpty) { emptyHit = true; }
      // 自动跳过时：无推荐即跳过；手动选源时：分类和列表都为空才报错
      const emptyFail = autoSkip ? hc.items.length === 0 : bothEmpty;
      if (emptyFail) {
        throw new Error('源返回空内容');
      }
      this.cats = hc.categories.map((c: Category): string => c.name);
      this.catKeys = hc.categories.map((c: Category): string => c.tid);
      this.catIdx = 0;
      this.items = hc.items;
      this.page = 1;
      this.pageCount = 1;
      this.kind = 'home';
      this.errMsg = '';
      this._autoSkipTried = [];
      this._skipHitErr = false;
    } catch (e) {
      const msg = errText(e as Object);
      const curKey = this.app.currentSite?.key ?? '?';
      console.info('OKV loadHome ERR site=' + curKey + ' engine=' + (this.app.currentSite?.api ?? '?') + ' msg=' + msg);
      // 已确认无影片：记入死源并从下拉隐藏（网络类错误不记，保留在列表可重试）
      if (emptyHit && curKey !== '?' && curKey !== '' && !this._deadSites.includes(curKey)) {
        this._deadSites.push(curKey);
        this.refreshSites();
      }
      if (!emptyHit) { this._skipHitErr = true; }
      // 自动跳过失败源；手动选中的源无影片时同样跳到下一可用源
      if ((autoSkip || emptyHit) && this._autoSkipTried.length < 50) {
        if (!this._autoSkipTried.includes(curKey)) { this._autoSkipTried.push(curKey); }
        const nextKey = this.findNextUsableSite();
        console.info('OKV autoSkip check autoSkip=' + autoSkip + ' tried=' + this._autoSkipTried.length + ' nextKey=' + nextKey);
        if (nextKey !== '' && nextKey !== curKey) {
          console.info('OKV autoSkip ' + curKey + ' -> ' + nextKey + ' (' + this._autoSkipTried.length + ' tried)');
          if (this.app.switchSite(nextKey)) {
            this.siteIdx = Math.max(0, this.siteKeys.indexOf(nextKey));
            this.loadHome(true);
            return;
          }
        }
        // 全部源都试过了，给出汇总提示（全是无影片 vs 存在加载失败，措辞区分）
        this.errMsg = this._skipHitErr
          ? '已尝试 ' + this._autoSkipTried.length + ' 个源均无法加载，请检查订阅或网络'
          : '所有源均无影片';
        this._autoSkipTried = [];
        this._skipHitErr = false;
      } else {
        console.info('OKV autoSkip skip reason autoSkip=' + autoSkip + ' tried=' + this._autoSkipTried.length);
        this.errMsg = msg;
        this._autoSkipTried = [];   // 重置以便重试时重新自动跳过
      }
    } finally {
      this.loading = false;
    }
  }

  // 加载分类列表页：replace=true 替换列表（切分类），false 触底追加
  private async loadCategory(tid: string, pg: number, replace: boolean): Promise<void> {
    const d = this.driver();
    if (d === null || tid === '') { return; }
    this.loading = true;
    this.errMsg = '';
    try {
      const pr: PageResult = await d.categoryContent(tid, pg);
      if (this.app.driver !== d) { return; }
      // 追加前按 vodId 去重，避免源站分页边界重叠导致重复项
      const fresh = pr.items.filter((m: Movie): boolean => !this.items.some((o: Movie): boolean => o.vodId === m.vodId));
      this.items = replace ? pr.items : this.items.concat(fresh);
      this.page = pr.page;
      this.pageCount = pr.pageCount;
      this.kind = 'category';
      this.errMsg = '';
    } catch (e) {
      this.errMsg = errText(e as Object);
    } finally {
      this.loading = false;
    }
  }

  // 搜索：直接跳转 DetailPage，由 DetailPage 做跨源搜索（渐进式展示各源结果）
  private doSearch(): void {
    const kw: string = this.searchKey.trim();
    if (kw === '') { return; }
    // 保存搜索历史
    if (this.settings.incognito) { this.searchKey = ''; } else { SearchHistory.instance.add(kw); this.searchHistory = SearchHistory.instance.getAll(); }
    // 直接跳 DetailPage，用只含 name 的 Movie 触发跨源搜索
    Nav.stack.pushPathByName('Detail', { vodId: '', name: kw, pic: '', remark: '', typeName: '' } as Movie);
  }

  // 错误重试：按当前数据来源重放
  private retry(): void {
    if (this.kind === 'search') { this.doSearch(); return; }
    if (this.kind === 'category') {
      const tid: string = this.catKeys[this.catIdx] ?? '';
      if (tid !== '') { this.loadCategory(tid, 1, true); return; }
    }
    this.loadHome(true);
  }

  build() {
    NavDestination() {
    Column() {
    // drpy JS 插件运行环境（1x1 不可见；Home 是栈底 NavDestination，常驻存活覆盖 Detail/Player 调用期）
    DrpyWebContainer()
      // 顶栏：站点切换 + 搜索入口
      Row({ space: 8 }) {
        // 不支持的源已在 refreshSites 中过滤，此处仅展示可用源
        Select(this.sites.map((s: string): SelectOption => {
          const opt: SelectOption = { value: s };
          return opt;
        }))
          .selected(this.siteIdx)
          .value(this.sites[this.siteIdx] ?? '站点')
          .onSelect((idx: number) => {
            if (idx === this.siteIdx || this.loading || this.searching) { return; }
            if (!(this.siteEnabled[idx] ?? true)) { return; }   // 不支持源（JAR 类名）灰显且不可选
            this.siteIdx = idx;
            if (this.app.switchSite(this.siteKeys[idx] ?? '')) {
              this.loadHome();
            }
          })
        Blank()
        // 订阅维护入口：无订阅也能用内置源，订阅随时在这里补配/更换
        // 直播入口
        Text('📺')
          .fontSize(20)
          .margin({ right: 6 })
          .onClick(() => { Nav.stack.pushPathByName('Live', ''); })

        Image($r('app.media.ic_settings'))
          .width(20).height(20)
          .fillColor('#FFFFFF')
          .margin({ right: 10 })
          .onClick(() => { Nav.stack.pushPathByName('Settings', ''); })
        // 下载管理入口
        Image($r('app.media.ic_download'))
          .width(20).height(20)
          .fillColor('#FFFFFF')
          .margin({ right: 10 })
          .onClick(() => { Nav.stack.pushPathByName('Download', ''); })
        // 搜索入口
        Image($r('app.media.ic_search'))
          .width(20).height(20)
          .fillColor('#FFFFFF')
          .onClick(() => {
            if (this.loading || this.searching) { return; }
            Nav.stack.pushPathByName('Search', '');
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 12 })

      // 分类横滑胶囊（FongMi 风格：圆角药丸，选中实色）
      if (this.cats.length > 0) {
        Scroll() {
          Row({ space: 10 }) {
            ForEach(this.cats, (c: string, i: number) => {
              Text(c)
                .fontSize(15)
                .fontColor('#FFFFFF')
                .fontWeight(this.catIdx === i ? FontWeight.Bold : FontWeight.Normal)
                .backgroundColor(this.catIdx === i ? '#007DFF' : '#1A888888')
                .borderRadius(20)
                .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                .onClick(() => {
                  if (this.loading || this.searching) { return; }
                  this.catIdx = i;
                  this.loadCategory(this.catKeys[i] ?? '', 1, true);
                })
            }, (c: string, i: number) => c + '_' + i)
          }
          .padding({ left: 16, right: 16 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .width('100%')
        .padding({ top: 8, bottom: 8 })
      }

      // 搜索态标题栏：显示当前关键词与「返回浏览」入口（仅搜索结果就绪时展示）
      if (this.kind === 'search' && this.items.length > 0) {
        Row() {
          Text(`“${this.searchKey}” 的结果`).fontSize(14).fontColor('#FFFFFF').layoutWeight(1)
          Text('返回浏览').fontSize(14).fontColor('#FFFFFF')
            .onClick(() => {
              if (this.loading || this.searching) { return; }
              this.loadHome();
            })
        }.width('100%').padding({ left: 12, right: 12, top: 10 })
      }

      // 站源筛选 chips：聚合结果就绪且开关开启时展示（站源搜索）
      if (this.settings.siteFilter && this.kind === 'search' && this.filterSiteOptions().length > 0) {
        Scroll() {
          Row({ space: 8 }) {
            Text('全部')
              .fontSize(13)
              .fontColor('#FFFFFF')
              .backgroundColor(this.filterSite === '' ? '#007DFF' : '#1A888888')
              .borderRadius(14)
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .onClick(() => { this.filterSite = ''; })
            ForEach(this.filterSiteOptions(), (n: string) => {
              Text(n)
                .fontSize(13)
                .fontColor('#FFFFFF')
                .backgroundColor(this.filterSite === n ? '#007DFF' : '#1A888888')
                .borderRadius(14)
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .onClick(() => { this.filterSite = n; })
            }, (n: string) => n)
          }
          .padding({ left: 12, right: 12 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .width('100%')
        .padding({ left: 12, right: 12 })
        .margin({ top: 8 })
      }

      if (this.errMsg !== '') {
        Column({ space: 8 }) {
          Text('加载失败：' + this.errMsg).fontSize(13).fontColor('#E53935')
          Button('重试').onClick(() => { this.retry(); })
          Button('清除订阅').onClick(() => {
            // 清除订阅回内置源起步（AppState 内重建 driver），原地刷新首页视图即可
            this.app.clearConfig();
            this.refreshSites();
            this.lastConfigRef = this.app.config;
            this.loadHome(true);
          })
        }
        .width('100%')
        .margin({ top: 60 })
      } else if (this.loading && this.items.length === 0) {
        LoadingProgress().width(44).height(44).margin({ top: 80 })
      } else if (this.visibleItems().length === 0) {
        Text('暂无内容').fontSize(14).fontColor('#FFFFFF').margin({ top: 80 })
      } else {
        MovieGrid({
          items: this.visibleItems(),
          siteLabels: this.siteLabels(),
          columns: this.gridColumns(),
          hasMore: this.page < this.pageCount && this.filterSite === '',
          loading: this.loading || this.searching,
          onPick: (m: Movie, _idx: number) => {
            // 统一跳转 DetailPage：以片名跨源搜索，左侧源列表 + 右侧剧集
            Nav.stack.pushPathByName('Detail', m);
          },
          onLoadMore: () => {
            // 触底：仅分类模式有下一页（home/search 的 pageCount 固定 1，hasMore=false 不会进入）
            const tid: string = this.catKeys[this.catIdx] ?? '';
            this.loadCategory(tid, this.page + 1, false);
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .linearGradient({ angle: 160, colors: this.wallpaperColors })
      .backgroundImage(this.settings.bgImage())
      .backgroundImageSize(ImageSize.Cover)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .hideTitleBar(true)
    .onBackPressed(() => {
      // Home 是栈底目的地：Back 退到后台（不弹栈），弹出会露出根占位且再次 Back 才能退出
      if (Nav.stack.size() <= 1) {
        try {
          (getContext(this) as common.UIAbilityContext).moveAbilityToBackground();
          return true;
        } catch (e) { return false; }
      }
      return false;
    })
    .onShown(() => {
      // 从设置页返回：加载/清除订阅会更换 AppState.config 对象，据此重拉站点列表与首页内容
      if (this.app.config !== this.lastConfigRef) {
        this._deadSites = [];   // 新订阅重新评估各源，恢复被隐藏的源
        this.refreshSites();
        this.lastConfigRef = this.app.config;
        this.loadHome(true);
      } else if (this.items.length === 0 && this.errMsg === '' && !this.loading) {
        // 冷启动时 initFromStore 可能晚于 aboutToAppear 完成，onShown 补拉
        this.loadHome(true);
      }
    })
  }
}
