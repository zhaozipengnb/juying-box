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
  @Local sites: string[] = [];        // 站点名列表（与 siteKeys 同序，Select 展示用；不支持源带「（暂不支持）」后缀）
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
  @Local showSearch: boolean = false;
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
    this.loadHome();
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
    return this.settings.wallpaper !== 'default' || this.settings.wallpaperUri !== '';
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

  // 从 AppState 同步站点列表（订阅已装配好，此处仅映射 UI 展示状态）
  private refreshSites(): void {
    const cfg = this.app.config;
    if (cfg === null) { return; }
    const names: string[] = [];
    const keys: string[] = [];
    const enabled: boolean[] = [];
    for (const s of cfg.sites) {
      const ok = isSiteSupported(s);
      names.push(ok ? s.name : s.name + '（暂不支持）');
      keys.push(s.key);
      enabled.push(ok);
    }
    this.sites = names;
    this.siteKeys = keys;
    this.siteEnabled = enabled;
    const curKey: string = this.app.currentSite?.key ?? '';
    this.siteIdx = Math.max(0, keys.indexOf(curKey));
  }

  // 加载站点首页：分类 + 推荐列表（推荐无分页能力，pageCount 固定 1）
  private async loadHome(): Promise<void> {
    const d = this.driver();
    if (d === null) { return; }
    this.loading = true;
    this.errMsg = '';
    try {
      const hc: HomeContent = await d.getHomeContent();
      if (this.app.driver !== d) { return; }   // 站点已切换，丢弃过期响应
      this.cats = hc.categories.map((c: Category): string => c.name);
      this.catKeys = hc.categories.map((c: Category): string => c.tid);
      this.catIdx = 0;
      this.items = hc.items;
      this.page = 1;
      this.pageCount = 1;
      this.kind = 'home';
      this.errMsg = '';
    } catch (e) {
      this.errMsg = errText(e as Object);
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

  // 搜索：聚合关闭 = 仅当前站；聚合开启 = 全部采集站（CMS/XML 并发，drpy 串行）
  // 合并去重（同名同人近似即可用：按 vodId 站内唯一，跨站以 name+remark 近似去重会误伤，这里仅按站内 id + 站 key）
  private async doSearch(): Promise<void> {
    const kw: string = this.searchKey.trim();
    if (kw === '') { return; }
    if (this.settings.aggSearch) {
      await this.doSearchAgg(kw);
      return;
    }
    const d = this.driver();
    if (d === null) { return; }
    this.searching = true;
    this.errMsg = '';
    try {
      const pr: PageResult = await d.searchContent(kw, false);
      if (this.app.driver !== d) { return; }
      this.items = pr.items;
      this.aggSiteKeys = [];
      this.aggSiteNames = [];
      this.filterSite = '';
      this.page = 1;
      this.pageCount = 1;
      this.kind = 'search';
      this.errMsg = '';
      if (this.settings.incognito) { this.searchKey = ''; } else { SearchHistory.instance.add(kw); this.searchHistory = SearchHistory.instance.getAll(); }
    } catch (e) {
      this.errMsg = errText(e as Object);
      this.kind = 'search'; // 搜索失败也归位搜索态，重试时按搜索重放
    } finally {
      this.searching = false;
    }
  }

  // 聚合搜索：cms/xml 站并发搜，drpy(js) 站串行搜（单 Web 容器互斥），每站截取前 10 条，单站失败不拖垮整体
  private async doSearchAgg(kw: string): Promise<void> {
    const cfg = this.app.config;
    if (cfg === null) { return; }
    this.searching = true;
    this.errMsg = '';
    this.items = [];
    this.aggSiteKeys = [];
    this.aggSiteNames = [];
    this.filterSite = '';
    this.kind = 'search';
    // cms/xml 站可并发；drpy(js) 站共享单 Web 容器，须串行逐站搜
    const tasks: Promise<void>[] = [];
    const drpySites: SiteConfig[] = [];
    for (const s of cfg.sites) {
      if (!isSiteSupported(s)) { continue; }
      if (siteEngine(s) === 'js') { drpySites.push(s); continue; }
      const driver: SiteDriver | null = this.app.makeDriverFor(s);
      if (driver === null) { continue; }
      tasks.push(driver.searchContent(kw, false).then((pr: PageResult): void => {
        const cap = Math.min(pr.items.length, 10);
        for (let i = 0; i < cap; i++) {
          this.items.push(pr.items[i]);
          this.aggSiteKeys.push(s.key);
          this.aggSiteNames.push(s.name);
        }
      }).catch((_e: Object): void => { /* 单站失败跳过 */ }));
    }
    if (tasks.length === 0 && drpySites.length === 0) {
      this.errMsg = '没有可聚合搜索的采集站（当前订阅仅含 JAR 源）';
      this.searching = false;
      return;
    }
    // 先并发搜 cms/xml 站
    await Promise.all(tasks);
    // 再串行搜 drpy 站（单 Web 容器互斥，逐站 ensureReady + search）
    for (const s of drpySites) {
      const driver: SiteDriver | null = this.app.makeDriverFor(s);
      if (driver === null) { continue; }
      try {
        const pr: PageResult = await driver.searchContent(kw, false);
        const cap = Math.min(pr.items.length, 10);
        for (let i = 0; i < cap; i++) {
          this.items.push(pr.items[i]);
          this.aggSiteKeys.push(s.key);
          this.aggSiteNames.push(s.name);
        }
      } catch (_e) { /* 单站失败跳过 */ }
    }
    if (this.items.length === 0 && this.errMsg === '') {
      this.errMsg = '全部站点均无结果（或搜索接口不可用）';
    }
    if (this.settings.incognito) { this.searchKey = ''; } else { SearchHistory.instance.add(kw); this.searchHistory = SearchHistory.instance.getAll(); }
    this.searching = false;
  }

  // 错误重试：按当前数据来源重放
  private retry(): void {
    if (this.kind === 'search') { this.doSearch(); return; }
    if (this.kind === 'category') {
      const tid: string = this.catKeys[this.catIdx] ?? '';
      if (tid !== '') { this.loadCategory(tid, 1, true); return; }
    }
    this.loadHome();
  }

  build() {
    NavDestination() {
    // drpy JS 插件运行环境（1x1 不可见；Home 是栈底 NavDestination，常驻存活覆盖 Detail/Player 调用期）
    DrpyWebContainer()
    Column() {
      // 顶栏：站点切换 + 搜索入口
      Row({ space: 8 }) {
        // 注：本 SDK SelectOption 无 disabled 字段，不支持源以「（暂不支持）」后缀标记，onSelect 内校验拒绝
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
        Text('⚙')
          .fontSize(20)
          .margin({ right: 6 })
          .onClick(() => { Nav.stack.pushPathByName('Settings', ''); })
        // 下载管理入口
        Text('⬇')
          .fontSize(18)
          .margin({ right: 6 })
          .onClick(() => { Nav.stack.pushPathByName('Download', ''); })
        // sys.media.ohos_ic_public_search 在本 SDK 不存在，按预案用文本图标降级
        Text('🔍')
          .fontSize(20)
          .onClick(() => {
            if (this.loading || this.searching) { return; }
            this.showSearch = !this.showSearch;
            // 收起搜索栏时若当前是搜索结果，恢复来源视图，避免网格内容与分类条错位
            if (!this.showSearch && this.kind === 'search') {
              if (this.catKeys.length > 0) {
                this.loadCategory(this.catKeys[this.catIdx] ?? '', 1, true);
              } else {
                this.loadHome();
              }
            }
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 12 })

      if (this.showSearch) {
        Row({ space: 8 }) {
          TextInput({ placeholder: this.isIncognito ? '无痕搜索…' : '搜索影片…', text: this.searchKey })
            .layoutWeight(1).height(40)
            .onChange((v: string) => { this.searchKey = v; })
            .onSubmit(() => { if (this.searching) { return; } this.doSearch(); })
          if (this.isIncognito) {
            Text('无痕').fontSize(10).fontColor('#FF9800')
              .backgroundColor('#33FF9800').borderRadius(4)
              .padding({ left: 5, right: 5, top: 2, bottom: 2 })
          }
          Button('搜索')
            .height(40)
            .enabled(!this.searching && this.searchKey.trim().length > 0)
            .onClick(() => { this.doSearch(); })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })

        // 搜索历史标签（无痕模式下不展示）
        if (!this.isIncognito && this.searchKey.trim() === '' && this.searchHistory.length > 0) {
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.searchHistory, (tag: string) => {
              Text(tag)
                .fontSize(13)
                .fontColor(this.isDarkWallpaper ? '#AAAAAA' : '#555555')
                .backgroundColor(this.isDarkWallpaper ? '#33FFFFFF' : '#F5F5F5')
                .borderRadius(12)
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .margin({ right: 6, bottom: 6 })
                .onClick(() => {
                  this.searchKey = tag;
                  this.doSearch();
                })
            }, (tag: string): string => tag)
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 6, bottom: 10 })
        }
      }

      // 分类横滑胶囊（FongMi 风格：圆角药丸，选中实色；搜索模式下隐藏）
      if (!this.showSearch && this.cats.length > 0) {
        Scroll() {
          Row({ space: 10 }) {
            ForEach(this.cats, (c: string, i: number) => {
              Text(c)
                .fontSize(15)
                .fontColor(this.catIdx === i ? '#FFFFFF' : (this.isDarkWallpaper ? '#DDDDDD' : '#444444'))
                .fontWeight(this.catIdx === i ? FontWeight.Bold : FontWeight.Normal)
                .backgroundColor(this.catIdx === i ? '#007DFF' : (this.isDarkWallpaper ? '#33FFFFFF' : '#14000000'))
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
          Text(`“${this.searchKey}” 的结果`).fontSize(14).fontColor('#666666').layoutWeight(1)
          Text('返回浏览').fontSize(14).fontColor('#007DFF')
            .onClick(() => {
              if (this.loading || this.searching) { return; }
              this.showSearch = false;
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
              .fontColor(this.filterSite === '' ? '#FFFFFF' : '#666666')
              .backgroundColor(this.filterSite === '' ? '#007DFF' : '#F0F0F0')
              .borderRadius(14)
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .onClick(() => { this.filterSite = ''; })
            ForEach(this.filterSiteOptions(), (n: string) => {
              Text(n)
                .fontSize(13)
                .fontColor(this.filterSite === n ? '#FFFFFF' : '#666666')
                .backgroundColor(this.filterSite === n ? '#007DFF' : '#F0F0F0')
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
            this.loadHome();
          })
        }
        .width('100%')
        .margin({ top: 60 })
      } else if (this.loading && this.items.length === 0) {
        LoadingProgress().width(44).height(44).margin({ top: 80 })
      } else if (this.visibleItems().length === 0) {
        Text('暂无内容').fontSize(14).fontColor(this.isDarkWallpaper ? '#888888' : '#999999').margin({ top: 80 })
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
      .backgroundImage(this.wallpaperUri)
      .backgroundImageSize(ImageSize.Cover)
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
        this.refreshSites();
        this.lastConfigRef = this.app.config;
        this.loadHome();
      }
    })
  }
}
