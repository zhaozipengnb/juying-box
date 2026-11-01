// 历史/收藏页：双 tab。历史条目点按直接续播（带断点），收藏条目进详情。
// 入口：搜索页顶部「观看历史/我的收藏」；无痕模式下播放不写入历史。
import { Nav, PlayerParam } from '../nav/Nav';
import { AppState } from '../state/AppState';
import { AppSettings } from '../state/AppSettings';
import { PlayHistory, PlayRecord } from '../state/PlayHistory';
import { Favorites, FavoriteItem } from '../state/Favorites';
import { Episode, PlayLine, MovieDetail, Movie, SiteConfig } from 'common';

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
  // 单例镜像:本 SDK 下 @ComponentV2 经普通成员读 @ObservedV2 单例不建立响应依赖(坑#3 变体),
  // 直接渲染 this.ph.records 会导致清空/删除后界面纹丝不动——镜像 + 每次可见/操作后同步
  @Local histList: PlayRecord[] = [];
  @Local favList: FavoriteItem[] = [];

  private refreshLists(): void {
    this.histList = this.ph.records.slice();
    this.favList = this.favs.items.slice();
  }

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
              .fontColor('#FFFFFF')
              .fontWeight(this.tab === i ? FontWeight.Bold : FontWeight.Normal)
              .padding({ left: 20, right: 20, top: 10, bottom: 8 })
              .border({ width: { bottom: 2 }, color: this.tab === i ? '#CCCCCC' : Color.Transparent })
              .onClick(() => { this.tab = i; })
          }, (t: string) => t)
          Blank()
          if (this.tab === 0 && this.histList.length > 0) {
            Text('清空')
              .fontSize(13).fontColor('#E53935')
              .padding({ right: 16, top: 4 })
              .onClick(() => {
                this.ph.clear();
                this.refreshLists();
              })
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
          if (this.tab === 0 && this.histList.length === 0) {
            Text('暂无观看记录').fontSize(13).fontColor('#B3FFFFFF')
              .width('100%').textAlign(TextAlign.Center).margin({ top: 80 })
          }
          if (this.tab === 1 && this.favList.length === 0) {
            Text('暂无收藏').fontSize(13).fontColor('#B3FFFFFF')
              .width('100%').textAlign(TextAlign.Center).margin({ top: 80 })
          }
          Grid() {
            if (this.tab === 0) {
              ForEach(this.histList, (r: PlayRecord) => {
                GridItem() {
                  this.recordCard(r.movieName, r.pic, '上次看到' + (r.epName === '' ? '播放' : r.epName),
                    this.siteNameOf(r.siteKey),
                    (): void => { this.resume(r); },
                    (): void => {
                      this.ph.remove(r.siteKey, r.vodId);
                      this.refreshLists();
                    })
                }
              }, (r: PlayRecord) => r.vodId + r.epUrl + String(r.updatedAt))
            } else {
              ForEach(this.favList, (it: FavoriteItem) => {
                GridItem() {
                  this.recordCard(it.name, it.pic, it.remark === '' ? (it.typeName === '' ? '收藏' : it.typeName) : it.remark,
                    this.siteNameOf(it.siteKey),
                    (): void => { this.openFav(it); },
                    (): void => {
                      this.favs.remove(it.siteKey, it.vodId);
                      this.refreshLists();
                    })
                }
              }, (it: FavoriteItem) => it.vodId + String(it.addedAt))
            }
          }
          .columnsTemplate('1fr 1fr 1fr')
          .columnsGap(12).rowsGap(14)
          .width('100%').height('100%')
          .padding({ left: 16, right: 16, top: 8 })
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
    .onShown(() => { this.refreshLists(); })   // 每次可见都同步单例(播放写入历史/收藏后回来也是最新)
    .onReady((ctx: NavDestinationContext) => {
      const arg = ctx.pathInfo.param as string;
      if (arg === 'fav') { this.tab = 1; }
    })
  }

  // 源名解析(徽标用):siteKey → 站点名
  private siteNameOf(siteKey: string): string {
    const cfg = this.app.config;
    if (cfg === null) { return siteKey; }
    const s = cfg.sites.find((x: SiteConfig): boolean => x.key === siteKey);
    return s === undefined ? siteKey : s.name;
  }

  // 模板样式卡:海报 + 左上源徽标 + 绿色续播带 + 片名;长按删除
  @Builder
  recordCard(name: string, pic: string, band: string, siteName: string, onTap: () => void, onDel: () => void) {
    Column({ space: 5 }) {
      Stack({ alignContent: Alignment.Bottom }) {
        Image(pic === '' ? $r('app.media.startIcon') : pic)
          .width('100%').aspectRatio(0.67)
          .objectFit(ImageFit.Cover).borderRadius(8)
          .alt($r('app.media.startIcon'))
        Text(siteName).fontSize(10).fontColor('#FFFFFF').maxLines(1)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .backgroundColor('#99000000').borderRadius(4)
          .position({ x: 6, y: 6 })
        Text(band).fontSize(11).fontColor('#FFFFFF').maxLines(1)
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ left: 6, right: 6, top: 5, bottom: 5 })
          .backgroundColor('#B32E7D32')
          .borderRadius({ bottomLeft: 8, bottomRight: 8 })
      }
      .onClick(() => { onTap(); })
      Row() {
        Text(name).fontSize(13).fontColor('#FFFFFF')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Blank()
        Text('⨯').fontSize(13).fontColor(this.isDarkWallpaper ? '#88999999' : '#CC999999')
          .onClick(() => { onDel(); })
      }
      .width('100%')
    }
    .width('100%')
  }
}
