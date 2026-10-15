// 首页：站点 Select 切换 / 分类横滑 Tabs / MovieGrid 影片网格 / 触底分页 / 搜索入口
import { AppState } from '../state/AppState';
import { Nav } from '../nav/Nav';
import { MovieGrid } from '../components/MovieGrid';
import { Category, HomeContent, Movie, PageResult, SiteDriver } from 'common';

// 网格数据来源：决定触底翻页方式（home/search 的 pageCount 固定 1 不翻页，category 按 tid+页码追加）与错误重试入口
type ResultKind = 'home' | 'category' | 'search';

@ComponentV2
export struct HomePage {
  // 持有 AppState 实例：V2 观察要求经组件成员访问 @Trace（静态链式访问不建立依赖）
  app: AppState = AppState.instance;
  @Local sites: string[] = [];        // 站点名列表（与 siteKeys 同序，Select 展示用）
  @Local siteKeys: string[] = [];     // 站点 key 列表
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

  aboutToAppear(): void {
    this.refreshSites();
    this.loadHome();
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
    for (const s of cfg.sites) {
      names.push(s.name);
      keys.push(s.key);
    }
    this.sites = names;
    this.siteKeys = keys;
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
      this.errMsg = e instanceof Error ? e.message : String(e);
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
      this.errMsg = e instanceof Error ? e.message : String(e);
    } finally {
      this.loading = false;
    }
  }

  // 搜索（结果不可翻页，强制 pageCount=1 关闭触底加载）
  private async doSearch(): Promise<void> {
    const d = this.driver();
    const kw: string = this.searchKey.trim();
    if (d === null || kw === '') { return; }
    this.searching = true;
    this.errMsg = '';
    try {
      const pr: PageResult = await d.searchContent(kw, false);
      if (this.app.driver !== d) { return; }
      this.items = pr.items;
      this.page = 1;
      this.pageCount = 1;
      this.kind = 'search';
      this.errMsg = '';
    } catch (e) {
      this.errMsg = e instanceof Error ? e.message : String(e);
      this.kind = 'search'; // 搜索失败也归位搜索态，重试时按搜索重放
    } finally {
      this.searching = false;
    }
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
    Column() {
      // 顶栏：站点切换 + 搜索入口
      Row({ space: 8 }) {
        Select(this.sites.map((s: string): SelectOption => {
          const opt: SelectOption = { value: s };
          return opt;
        }))
          .selected(this.siteIdx)
          .value(this.sites[this.siteIdx] ?? '站点')
          .onSelect((idx: number) => {
            if (idx === this.siteIdx || this.loading || this.searching) { return; }
            this.siteIdx = idx;
            if (this.app.switchSite(this.siteKeys[idx] ?? '')) {
              this.loadHome();
            }
          })
        Blank()
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
      .padding({ left: 12, right: 12, top: 8 })

      if (this.showSearch) {
        Row({ space: 8 }) {
          TextInput({ placeholder: '搜索影片…', text: this.searchKey })
            .layoutWeight(1).height(40)
            .onChange((v: string) => { this.searchKey = v; })
            .onSubmit(() => { if (this.searching) { return; } this.doSearch(); })
          Button('搜索')
            .height(40)
            .enabled(!this.searching && this.searchKey.trim().length > 0)
            .onClick(() => { this.doSearch(); })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 4, bottom: 4 })
      }

      // 分类横滑 Tabs（搜索模式下隐藏）
      if (!this.showSearch && this.cats.length > 0) {
        Scroll() {
          Row({ space: 10 }) {
            ForEach(this.cats, (c: string, i: number) => {
              Text(c)
                .fontSize(this.catIdx === i ? 16 : 14)
                .fontColor(this.catIdx === i ? '#007DFF' : '#666666')
                .fontWeight(this.catIdx === i ? FontWeight.Bold : FontWeight.Normal)
                .onClick(() => {
                  if (this.loading || this.searching) { return; }
                  this.catIdx = i;
                  this.loadCategory(this.catKeys[i] ?? '', 1, true);
                })
            }, (c: string, i: number) => c + '_' + i)
          }
          .padding({ left: 12, right: 12 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .width('100%')
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
        }.width('100%').padding({ left: 12, right: 12, top: 8 })
      }

      if (this.errMsg !== '') {
        Column({ space: 8 }) {
          Text('加载失败：' + this.errMsg).fontSize(13).fontColor('#E53935')
          Button('重试').onClick(() => { this.retry(); })
          Button('重新配置').onClick(() => { this.app.clearConfig(); Nav.stack.clear(); })
        }
        .width('100%')
        .margin({ top: 60 })
      } else if (this.loading && this.items.length === 0) {
        LoadingProgress().width(44).height(44).margin({ top: 80 })
      } else if (this.items.length === 0) {
        Text('暂无内容').fontSize(14).fontColor('#999999').margin({ top: 80 })
      } else {
        MovieGrid({
          items: this.items,
          hasMore: this.page < this.pageCount,
          loading: this.loading || this.searching,
          onPick: (m: Movie) => { Nav.stack.pushPathByName('Detail', m); },
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
    }
    .hideTitleBar(true)
  }
}
