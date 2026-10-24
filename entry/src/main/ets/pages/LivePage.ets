// 直播页：消费设置里的 liveUrl——拉取直播源（m3u/txt 双格式）→ 左分组右频道 → 点击播放。
// 未配置 liveUrl 时给出去设置的引导。
import { Nav, PlayerParam } from '../nav/Nav';
import { AppState } from '../state/AppState';
import { AppSettings } from '../state/AppSettings';
import { LiveGroup, LiveChannel, parseLiveSource } from 'common';

@ComponentV2
export struct LivePage {
  settings: AppSettings = AppSettings.instance;
  @Local groups: LiveGroup[] = [];
  @Local groupIdx: number = 0;
  @Local loading: boolean = false;
  @Local errMsg: string = '';

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

  @Computed get curChannels(): LiveChannel[] {
    const g = this.groups[this.groupIdx];
    return g === undefined ? [] : g.channels;
  }

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    const url = this.settings.liveUrl.trim();
    if (url === '') { this.errMsg = '尚未配置直播源'; return; }
    this.loading = true;
    this.errMsg = '';
    try {
      const text = await AppState.instance.makeFetchText()(url);
      const gs = parseLiveSource(text);
      if (gs.length === 0) { this.errMsg = '直播源解析为空（支持 m3u 与 txt 格式）'; return; }
      this.groups = gs;
      this.groupIdx = 0;
    } catch (e) {
      this.errMsg = '直播源加载失败：' + (e instanceof Error ? e.message : String(e));
    } finally {
      this.loading = false;
    }
  }

  build() {
    NavDestination() {
      Column() {
        if (this.loading) {
          LoadingProgress().width(44).height(44).margin({ top: 120 })
        } else if (this.errMsg !== '') {
          Column({ space: 12 }) {
            Text(this.errMsg).fontSize(14).fontColor('#E53935')
            if (this.settings.liveUrl.trim() === '') {
              Button('去设置直播源')
                .onClick(() => { Nav.stack.pushPathByName('Settings', ''); })
            } else {
              Button('重试').onClick(() => { this.load(); })
            }
          }.margin({ top: 100 })
        } else {
          Row() {
            // 左：分组列表
            List() {
              ForEach(this.groups, (g: LiveGroup, i: number) => {
                ListItem() {
                  Column({ space: 3 }) {
                    Text(g.name)
                      .fontSize(14)
                      .fontColor(this.groupIdx === i ? '#F9A825' : (this.isDarkWallpaper ? '#CCCCCC' : '#333333'))
                      .fontWeight(this.groupIdx === i ? FontWeight.Bold : FontWeight.Normal)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(String(g.channels.length) + '台')
                      .fontSize(10).fontColor(this.isDarkWallpaper ? '#888888' : '#999999')
                  }
                  .width('100%')
                  .padding({ left: 12, right: 8, top: 10, bottom: 10 })
                  .onClick(() => { this.groupIdx = i; })
                }
              }, (g: LiveGroup, i: number) => g.name + i)
            }
            .width(112)
            .height('100%')
            .scrollBar(BarState.Off)

            // 右：频道列表
            List() {
              ForEach(this.curChannels, (ch: LiveChannel) => {
                ListItem() {
                  Row({ space: 8 }) {
                    Text('▶').fontSize(12).fontColor('#F9A825')
                    Text(ch.name)
                      .fontSize(14)
                      .fontColor(this.isDarkWallpaper ? '#EEEEEE' : '#222222')
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Blank()
                    Text('LIVE').fontSize(9).fontColor('#E53935')
                  }
                  .width('100%')
                  .padding({ left: 12, right: 12, top: 10, bottom: 10 })
                  .onClick(() => {
                    const param: PlayerParam = { ep: { name: ch.name, url: ch.url }, siteKey: 'live' };
                    Nav.stack.pushPathByName('Player', param);
                  })
                }
              }, (ch: LiveChannel): string => ch.url)
            }
            .layoutWeight(1)
            .height('100%')
            .scrollBar(BarState.Auto)
            .divider({ strokeWidth: 0.5, color: this.isDarkWallpaper ? '#22FFFFFF' : '#11000000' })
          }
          .width('100%')
          .layoutWeight(1)
        }
      }
      .width('100%').height('100%')
      .linearGradient({ angle: 160, colors: this.wallpaperColors })
    }
    .hideTitleBar(false)
    .title('直播')
  }
}
