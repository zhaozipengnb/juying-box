// 历史/收藏页：双 tab。历史条目点按直接续播（带断点），收藏条目进详情。
// 入口：搜索页顶部「观看历史/我的收藏」；无痕模式下播放不写入历史。
import { Nav, PlayerParam } from '../nav/Nav';
import { AppState } from '../state/AppState';
import { AppSettings } from '../state/AppSettings';
import { PlayHistory, PlayRecord } from '../state/PlayHistory';
import { Favorites, FavoriteItem } from '../state/Favorites';
import { Episode, PlayLine, MovieDetail, Movie } from 'common';

const TABS: string[] = ['历史', '收藏'];

@ComponentV2
export struct HistoryPage {
  app: AppState = AppState.instance;
  settings: AppSettings = AppSettings.instance;
  ph: PlayHistory = PlayHistory.instance;
  favs: Favorites = Favorites.instance;
  @Local tab: number = 0;
  @Local loading: boolean = false;   // 续播拉详情中
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

  // 历史续播：切到来源站 → 拉详情 → 跳播放页（线路/集索引沿用记录）
  private async resume(r: PlayRecord): Promise<void> {
    if (this.app.currentSite?.key !== r.siteKey) {
      if (!this.app.switchSite(r.siteKey)) { this.errMsg = '来源站不可用：' + r.siteKey; return; }
    }
    const d = this.app.driver;
    if (d === null) { this.errMsg = '引擎未就绪'; return; }
    this.loading = true;
    this.errMsg = '';
    try {
      const detail: MovieDetail = await d.detailContent([r.vodId]);
      const lines: PlayLine[] = detail.lines;
      if (lines.length === 0) { this.errMsg = '该片已无可用线路'; return; }
      const li = Math.min(r.lineIdx, lines.length - 1);
      const eps = lines[li].episodes;
      if (eps.length === 0) { this.errMsg = '该剧集已不可用'; return; }
      // 集地址对得上用记录索引；对不上按 epName 找；再退回记录集索引
      let ei = eps.findIndex((e: Episode): boolean => e.url === r.epUrl);
      if (ei < 0) { ei = eps.findIndex((e: Episode): boolean => e.name === r.epName); }
      if (ei < 0) { ei = Math.min(Math.max(r.epIdx, 0), eps.length - 1); }
      const param: PlayerParam = {
        ep: eps[ei], siteKey: r.siteKey, siteName: this.app.currentSite?.name ?? '',
        movieName: r.movieName, detail: detail, lines: lines, lineIdx: li, epIdx: ei
      };
      Nav.stack.pushPathByName('Player', param);
    } catch (e) {
      this.errMsg = e instanceof Error ? e.message : String(e);
    } finally {
      this.loading = false;
    }
  }

  // 收藏进详情（沿用聚合搜索详情页的片名搜索路径）
  private openFav(it: FavoriteItem): void {
    const m: Movie = { vodId: it.vodId, name: it.name, pic: it.pic, remark: it.remark, typeName: it.typeName };
    Nav.stack.pushPathByName('Detail', m);
  }

  build() {
    NavDestination() {
      Column() {
        // tab 栏
        Row() {
          ForEach(TABS, (t: string, i: number) => {
            Text(t)
              .fontSize(16)
              .fontColor(this.tab === i ? '#F9A825' : '#FFFFFF')
              .fontWeight(this.tab === i ? FontWeight.Bold : FontWeight.Normal)
              .padding({ left: 20, right: 20, top: 10, bottom: 8 })
              .border({ width: { bottom: 2 }, color: this.tab === i ? '#CCCCCC' : Color.Transparent })
              .onClick(() => { this.tab = i; })
          }, (t: string) => t)
          Blank()
          if (this.tab === 0 && this.ph.records.length > 0) {
            Text('清空')
              .fontSize(13).fontColor('#E53935')
              .padding({ right: 16, top: 4 })
              .onClick(() => { this.ph.clear(); })
          }
        }.width('100%')

        if (this.loading) {
          LoadingProgress().width(40).height(40).margin({ top: 80 })
        } else if (this.errMsg !== '') {
          Column({ space: 8 }) {
            Text(this.errMsg).fontSize(13).fontColor('#E53935').margin({ top: 60 })
            Button('返回').fontSize(13).onClick(() => { Nav.stack.pop(); })
          }
        } else {
          List({ space: 0 }) {
            if (this.tab === 0) {
              ForEach(this.ph.records, (r: PlayRecord) => {
                ListItem() {
                  this.recordRow(r.movieName, r.pic, r.epName, '继续观看',
                    (): void => { this.resume(r); },
                    (): void => { this.ph.remove(r.siteKey, r.vodId); })
                }
              }, (r: PlayRecord) => r.vodId + r.epUrl + String(r.updatedAt))
            } else {
              ForEach(this.favs.items, (it: FavoriteItem) => {
                ListItem() {
                  this.recordRow(it.name, it.pic, it.remark === '' ? it.typeName : it.remark, '查看详情',
                    (): void => { this.openFav(it); },
                    (): void => { this.favs.remove(it.siteKey, it.vodId); })
                }
              }, (it: FavoriteItem) => it.vodId + String(it.addedAt))
            }
          }
          .width('100%')
          .layoutWeight(1)
          .divider({ strokeWidth: 0.5, color: this.isDarkWallpaper ? '#22FFFFFF' : '#11000000', startMargin: 100 })
        }
      }
      .width('100%').height('100%')
      .linearGradient({ angle: 160, colors: this.wallpaperColors })
      .backgroundImage(this.settings.bgImage())
      .backgroundImageSize(ImageSize.Cover)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .hideTitleBar(false)
    .title(this.tab === 0 ? '观看历史' : '我的收藏')
    .onReady((ctx: NavDestinationContext) => {
      const arg = ctx.pathInfo.param as string;
      if (arg === 'fav') { this.tab = 1; }
    })
  }

  @Builder
  recordRow(name: string, pic: string, sub: string, action: string, onTap: () => void, onDel: () => void) {
    Row({ space: 12 }) {
      Image(pic === '' ? $r('app.media.startIcon') : pic)
        .width(72).height(100).objectFit(ImageFit.Cover).borderRadius(8).alt($r('app.media.startIcon'))
      Column({ space: 6 }) {
        Text(name)
          .fontSize(15).fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(sub)
          .fontSize(12).fontColor('#FFFFFF')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(action)
          .fontSize(12).fontColor('#F9A825')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Column({ space: 4 }) {
        Text('>')
          .fontSize(16).fontColor('#FFFFFF')
        Text('⨯')
          .fontSize(15).fontColor(this.isDarkWallpaper ? '#88999999' : '#CC999999')
          .padding({ top: 6 })
          .onClick(() => { onDel(); })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .backgroundColor(Color.Transparent)
    .onClick(() => { onTap(); })
  }
}
