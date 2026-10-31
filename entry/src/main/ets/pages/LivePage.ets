// 直播页：消费设置里的 liveUrl——拉取直播源（m3u/txt 双格式）→ 左分组右频道 → 点击播放。
// 未配置 liveUrl 时给出去设置的引导。
import { Nav, PlayerParam } from '../nav/Nav';
import { AppState } from '../state/AppState';
import { AppSettings } from '../state/AppSettings';
import { MainTabBar } from '../components/MainTabBar';
import { LiveGroup, LiveChannel, PlayLine, parseLiveSource } from 'common';
import { LiveFavs } from '../state/LiveFavs';

@ComponentV2
export struct LivePage {
  settings: AppSettings = AppSettings.instance;
  favs: LiveFavs = LiveFavs.instance;
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
    return true;   // 默认背景为青橙渐变图，文字统一白色
  }

  // 展示分组：有收藏频道时「收藏」组置顶（按 url 去重，跨分组聚合）
  @Computed get displayGroups(): LiveGroup[] {
    const out: LiveGroup[] = [];
    if (this.favs.urls.length > 0) {
      const favChannels: LiveChannel[] = [];
      const seen = new Set<string>();
      for (const g of this.groups) {
        for (const ch of g.channels) {
          if (this.favs.has(ch.url) && !seen.has(ch.url)) { seen.add(ch.url); favChannels.push(ch); }
        }
      }
      if (favChannels.length > 0) { out.push({ name: '★ 收藏', channels: favChannels }); }
    }
    return out.concat(this.groups);
  }

  @Computed get curChannels(): LiveChannel[] {
    const g = this.displayGroups[this.groupIdx];
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
        // 主内容区（flex 占满，底部导航栏之外的全部空间）
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
              ForEach(this.displayGroups, (g: LiveGroup, i: number) => {
                ListItem() {
                  Column({ space: 3 }) {
                    Text(g.name)
                      .fontSize(14)
                      .fontColor('#FFFFFF')
                      .fontWeight(this.groupIdx === i ? FontWeight.Bold : FontWeight.Normal)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(String(g.channels.length) + '台')
                      .fontSize(10).fontColor('#FFFFFF')
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
                    Image($r('app.media.ic_play')).width(12).height(12).fillColor('#FFFFFF')
                    Text(ch.name)
                      .fontSize(14)
                      .fontColor('#FFFFFF')
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                    Image($r('app.media.ic_heart'))
                      .width(16).height(16)
                      .fillColor(this.favs.has(ch.url) ? '#E53935' : '#80FFFFFF')
                      .hitTestBehavior(HitTestMode.Block)
                      .onClick(() => {
                        // 收藏切换会增删「收藏」组，按组名回定位避免索引漂移
                        const name = this.displayGroups[this.groupIdx]?.name ?? '';
                        this.favs.toggle(ch.url);
                        const gi = this.displayGroups.findIndex((g: LiveGroup): boolean => g.name === name);
                        this.groupIdx = gi >= 0 ? gi : 0;
                      })
                    Text('LIVE').fontSize(9).fontColor('#E53935').margin({ left: 6 })
                  }
                  .width('100%')
                  .padding({ left: 12, right: 12, top: 10, bottom: 10 })
                  .onClick(() => {
                    // 携带整组频道作为播放线路：播放页上/下一颗即换台
                    const eps = this.curChannels;
                    const lines: PlayLine[] = [{ from: '直播', episodes: eps }];
                    const idx = eps.findIndex((c: LiveChannel): boolean => c.url === ch.url);
                    const param: PlayerParam = {
                      ep: { name: ch.name, url: ch.url }, siteKey: 'live',
                      movieName: ch.name, lines: lines, lineIdx: 0, epIdx: idx >= 0 ? idx : 0
                    };
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
        .width('100%')
        .layoutWeight(1)

        // 底部导航栏（TV 不渲染）
        MainTabBar({ active: 'live' })
      }
      .width('100%').height('100%')
      .linearGradient({ angle: 160, colors: this.wallpaperColors })
      .backgroundImage(this.settings.bgImage())
      .backgroundImageSize(ImageSize.Cover)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .hideTitleBar(true)
  }
}
