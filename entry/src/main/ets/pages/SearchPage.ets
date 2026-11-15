// 搜索页：顶部输入框 + 下方历史/热搜标签
// 输入关键字回车或点搜索 → 保存历史 → 跳转 DetailPage 跨源搜索
import { Nav } from '../nav/Nav';
import { AppState } from '../state/AppState';
import { AppSettings } from '../state/AppSettings';
import { SearchHistory } from '../state/SearchHistory';
import { Movie } from 'common';

// 热搜兜底词（豆瓣接口失败时显示）
const HOT_FALLBACK: string[] = [
  '庆余年', '繁花', '狂飙', '三体', '流浪地球',
  '满江红', '长安三万里', '封神', '消失的她', '长津湖'
];

@ComponentV2
export struct SearchPage {
  app: AppState = AppState.instance;
  settings: AppSettings = AppSettings.instance;
  @Local searchKey: string = '';
  @Local searchHistory: string[] = [];
  @Local hotWords: string[] = HOT_FALLBACK;

  // 设置镜像:V2 对 @ObservedV2 单例直读不建立响应依赖(实测坑),onChange 显式通知刷镜像
  @Local wallpaperColors: Array<[ResourceColor, number]> = [['#FFFFFFFF', 0.0], ['#FFFFFFFF', 1.0]];
  @Local wallpaperUriM: string = '';
  private settingsCb: (() => void) | null = null;

  private syncSettings(): void {
    this.wallpaperColors = this.settings.wallpaperColors();
    this.wallpaperUriM = this.settings.wallpaperUri;
  }

  get isDarkWallpaper(): boolean {
    return true;   // 默认背景为青橙渐变图，文字统一白色
  }

  get wallpaperUri(): string {
    return this.wallpaperUriM;
  }

  aboutToAppear(): void {
    this.settingsCb = (): void => { this.syncSettings(); };
    this.settings.onChange(this.settingsCb);
    this.syncSettings();
    this.searchHistory = SearchHistory.instance.getAll();
    this.loadHotWords();
  }

  aboutToDisappear(): void {
    if (this.settingsCb !== null) { this.settings.offChange(this.settingsCb); this.settingsCb = null; }
  }

  // 豆瓣实时热门（公开 web 接口，需 Referer）；电影+剧集各取 5，失败保留兜底词
  private async loadHotWords(): Promise<void> {
    const fetchTag = async (tag: string): Promise<string[]> => {
      const url = 'https://movie.douban.com/j/search_subjects?type=' + (tag === '电影' ? 'movie' : 'tv')
        + '&tag=' + encodeURIComponent(tag) + '&page_limit=5';
      const text = await this.app.makeFetchText()(url, { 'Referer': 'https://movie.douban.com/explore' });
      const obj = JSON.parse(text) as Record<string, Object>;
      const subs = (obj['subjects'] ?? []) as Record<string, Object>[];
      const titles: string[] = [];
      for (const it of subs) {
        const t = it['title'];
        if (typeof t === 'string' && t !== '') { titles.push(t); }
      }
      return titles;
    };
    try {
      const movies = await fetchTag('电影');
      const tvs = await fetchTag('剧集');
      const all: string[] = [];
      for (let i = 0; i < Math.max(movies.length, tvs.length); i++) {
        if (i < movies.length) { all.push(movies[i]); }
        if (i < tvs.length) { all.push(tvs[i]); }
      }
      if (all.length >= 4) { this.hotWords = all.slice(0, 10); }
    } catch (e) { /* 接口失败保留兜底词 */ }
  }

  // 搜索：保存历史 → 跳 DetailPage
  private doSearch(kw: string): void {
    const key: string = kw.trim();
    if (key === '') { return; }
    if (!this.settings.incognito) {
      SearchHistory.instance.add(key);
      this.searchHistory = SearchHistory.instance.getAll();
    }
    Nav.stack.pushPathByName('Detail', { vodId: '', name: key, pic: '', remark: '', typeName: '' } as Movie);
  }

  // 清空历史
  private clearHistory(): void {
    SearchHistory.instance.clear();
    this.searchHistory = [];
  }

  build() {
    NavDestination() {
      Column() {
        // 顶栏：返回 + 输入框 + 搜索按钮
        Row({ space: 8 }) {
          Image($r('app.media.ic_back'))
            .width(22).height(22)
            .fillColor('#FFFFFF')
            .onClick(() => { Nav.stack.pop(); })
          TextInput({ placeholder: '输入片名搜索', text: this.searchKey })
            .layoutWeight(1).height(40)
            .fontSize(15)
            .backgroundColor('#4D888888')
            .borderRadius(8)
            .onChange((v: string) => { this.searchKey = v; })
            .onSubmit(() => { this.doSearch(this.searchKey); })
          Button('搜索')
            .height(40)
            .enabled(this.searchKey.trim().length > 0)
            .onClick(() => { this.doSearch(this.searchKey); })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 12, bottom: 12 })

        // 内容区
        Scroll() {
          Column({ space: 16 }) {
            // 快捷入口：观看历史 / 我的收藏
            Row({ space: 12 }) {
              Row({ space: 8 }) {
                Text('🕘').fontSize(18)
                Text('观看历史').fontSize(14).fontColor('#FFFFFF')
              }
              .padding({ left: 16, right: 16, top: 10, bottom: 10 })
              .backgroundColor('#4D888888')
              .borderRadius(10)
              .onClick(() => { Nav.stack.pushPathByName('History', ''); })

              Row({ space: 8 }) {
                Text('❤').fontSize(18).fontColor('#E53935')
                Text('我的收藏').fontSize(14).fontColor('#FFFFFF')
              }
              .padding({ left: 16, right: 16, top: 10, bottom: 10 })
              .backgroundColor('#4D888888')
              .borderRadius(10)
              .onClick(() => { Nav.stack.pushPathByName('History', 'fav'); })
            }
            .width('100%')
            .justifyContent(FlexAlign.Start)
            .padding({ left: 16 })

            // 搜索历史
            if (this.searchHistory.length > 0) {
              this.historySection()
            }
            // 热搜
            this.hotSection()
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 20 })
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
      .width('100%').height('100%')
      .linearGradient({ angle: 160, colors: this.wallpaperColors })
      .backgroundImage(this.settings.bgImage())
      .backgroundImageSize(ImageSize.Cover)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

    }
    .hideTitleBar(true)
  }

  @Builder
  historySection() {
    Column() {
      Row() {
        Text('历史').fontSize(15).fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
        Blank()
        Text('清空').fontSize(13)
          .fontColor('#FFFFFF')
          .onClick(() => { this.clearHistory(); })
      }.width('100%')

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.searchHistory, (tag: string, idx: number) => {
          Text(tag)
            .fontSize(13)
            .fontColor('#FFFFFF')
            .backgroundColor('#4D888888')
            .borderRadius(12)
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .margin({ right: 6, bottom: 6 })
            .onClick(() => { this.doSearch(tag); })
        }, (tag: string, idx: number) => `${tag}-${idx}`)
      }
      .width('100%')
      .margin({ top: 8 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  hotSection() {
    Column() {
      Row() {
        Text('热搜').fontSize(15).fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
      }.width('100%')

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.hotWords, (word: string, idx: number) => {
          Row({ space: 4 }) {
            Text(`${idx + 1}`)
              .fontSize(11)
              .fontColor('#FFFFFF')
              .fontWeight(FontWeight.Bold)
            Text(word)
              .fontSize(13)
              .fontColor('#FFFFFF')
          }
          .backgroundColor('#4D888888')
          .borderRadius(12)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .margin({ right: 6, bottom: 6 })
          .onClick(() => { this.doSearch(word); })
        }, (word: string, idx: number) => `${word}-${idx}`)
      }
      .width('100%')
      .margin({ top: 8 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
