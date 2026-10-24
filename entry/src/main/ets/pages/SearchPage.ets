// 搜索页：顶部输入框 + 下方历史/热搜标签
// 输入关键字回车或点搜索 → 保存历史 → 跳转 DetailPage 跨源搜索
import { Nav } from '../nav/Nav';
import { AppState } from '../state/AppState';
import { AppSettings } from '../state/AppSettings';
import { SearchHistory } from '../state/SearchHistory';
import { Movie } from 'common';

// 热搜默认词（无后端接口，静态内置）
const HOT_WORDS: string[] = [
  '庆余年', '繁花', '狂飙', '三体', '流浪地球',
  '满江红', '长安三万里', '封神', '消失的她', '长津湖'
];

@ComponentV2
export struct SearchPage {
  app: AppState = AppState.instance;
  settings: AppSettings = AppSettings.instance;
  @Local searchKey: string = '';
  @Local searchHistory: string[] = [];

  @Computed get isDarkWallpaper(): boolean {
    return this.settings.wallpaper !== 'default' || this.settings.wallpaperUri !== '';
  }

  @Computed get wallpaperUri(): string {
    return this.settings.wallpaperUri;
  }

  @Computed get wallpaperColors(): Array<[ResourceColor, number]> {
    const w = this.settings.wallpaper;
    if (w === 'dark') { return [['#FF141416', 0.0], ['#FF232326', 1.0]]; }
    if (w === 'blue') { return [['#FF0E1E3C', 0.0], ['#FF1B3A5E', 1.0]]; }
    if (w === 'green') { return [['#FF12291F', 0.0], ['#FF1E4030', 1.0]]; }
    return [['#FFFFFFFF', 0.0], ['#FFFFFFFF', 1.0]];
  }

  aboutToAppear(): void {
    this.searchHistory = SearchHistory.instance.getAll();
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
            .fillColor(this.isDarkWallpaper ? '#CCCCCC' : '#555555')
            .onClick(() => { Nav.stack.pop(); })
          TextInput({ placeholder: '输入片名搜索', text: this.searchKey })
            .layoutWeight(1).height(40)
            .fontSize(15)
            .backgroundColor(this.isDarkWallpaper ? '#33FFFFFF' : '#F5F5F5')
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
                Text('观看历史').fontSize(14).fontColor(this.isDarkWallpaper ? '#EEEEEE' : '#333333')
              }
              .padding({ left: 16, right: 16, top: 10, bottom: 10 })
              .backgroundColor(this.isDarkWallpaper ? '#26FFFFFF' : '#F5F5F5')
              .borderRadius(10)
              .onClick(() => { Nav.stack.pushPathByName('History', ''); })

              Row({ space: 8 }) {
                Text('❤').fontSize(18).fontColor('#E53935')
                Text('我的收藏').fontSize(14).fontColor(this.isDarkWallpaper ? '#EEEEEE' : '#333333')
              }
              .padding({ left: 16, right: 16, top: 10, bottom: 10 })
              .backgroundColor(this.isDarkWallpaper ? '#26FFFFFF' : '#F5F5F5')
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
      .backgroundImage(this.wallpaperUri)
      .backgroundImageSize(ImageSize.Cover)
    }
    .hideTitleBar(true)
  }

  @Builder
  historySection() {
    Column() {
      Row() {
        Text('历史').fontSize(15).fontWeight(FontWeight.Bold)
          .fontColor(this.isDarkWallpaper ? '#EEEEEE' : '#333333')
        Blank()
        Text('清空').fontSize(13)
          .fontColor(this.isDarkWallpaper ? '#888888' : '#999999')
          .onClick(() => { this.clearHistory(); })
      }.width('100%')

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.searchHistory, (tag: string, idx: number) => {
          Text(tag)
            .fontSize(13)
            .fontColor(this.isDarkWallpaper ? '#AAAAAA' : '#555555')
            .backgroundColor(this.isDarkWallpaper ? '#33FFFFFF' : '#F5F5F5')
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
          .fontColor(this.isDarkWallpaper ? '#EEEEEE' : '#333333')
      }.width('100%')

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(HOT_WORDS, (word: string, idx: number) => {
          Row({ space: 4 }) {
            Text(`${idx + 1}`)
              .fontSize(11)
              .fontColor(idx < 3 ? '#F9A825' : (this.isDarkWallpaper ? '#888888' : '#AAAAAA'))
              .fontWeight(FontWeight.Bold)
            Text(word)
              .fontSize(13)
              .fontColor(this.isDarkWallpaper ? '#CCCCCC' : '#333333')
          }
          .backgroundColor(this.isDarkWallpaper ? '#26FFFFFF' : '#F5F5F5')
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
