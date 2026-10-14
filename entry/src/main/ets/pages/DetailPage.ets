// 详情页 —— 海报信息 + 线路切换 + 剧集网格，点剧集进入播放页（Task 7 完整版）
import { Nav, PlayerParam } from '../nav/Nav';
import { AppState } from '../state/AppState';
import { MovieDetail, Movie, Episode, PlayLine } from 'common';

@ComponentV2
export struct DetailPage {
  @Local detail: MovieDetail | null = null;
  @Local lineIdx: number = 0;
  @Local loading: boolean = false;
  @Local errMsg: string = '';
  private movie: Movie | null = null;

  aboutToAppear(): void {
    // Navigation 参数在 NavDestination onReady 里取，此处兜底：push 顺序保证先于首帧
  }

  build() {
    NavDestination() {
      Column() {
        if (this.loading) { LoadingProgress().width(44).height(44).margin({ top: 120 }) }
        else if (this.errMsg !== '') {
          Column({ space: 8 }) {
            Text('加载失败：' + this.errMsg).fontColor('#E53935')
            Button('重试').onClick(() => { this.load(); })
          }.margin({ top: 120 })
        }
        else if (this.detail !== null) { this.detailBody() }
      }.width('100%').height('100%')
    }
    .title(this.detail?.movie.name ?? '详情')
    .onReady((ctx: NavDestinationContext) => {
      const m = ctx.pathInfo.param as Movie;
      if (m !== null && m !== undefined) { this.movie = m; this.load(); }
    })
  }

  @Builder
  detailBody() {
    Column() {
      Row({ space: 12 }) {
        Image(this.detail!.movie.pic === '' ? $r('app.media.startIcon') : this.detail!.movie.pic)
          .width(110).height(150).objectFit(ImageFit.Cover).borderRadius(8).alt($r('app.media.startIcon'))
        Column({ space: 4 }) {
          Text(this.detail!.movie.name).fontSize(18).fontWeight(FontWeight.Bold)
          Text('年份：' + (this.detail!.year === '' ? '未知' : this.detail!.year)).fontSize(13).fontColor('#666666')
          Text('演员：' + (this.detail!.actor === '' ? '未知' : this.detail!.actor))
            .fontSize(13).fontColor('#666666').maxLines(2)
          Text('导演：' + (this.detail!.director === '' ? '未知' : this.detail!.director)).fontSize(13).fontColor('#666666')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.width('100%').padding(12)

      Text(this.detail!.desc === '' ? '暂无简介' : this.detail!.desc)
        .fontSize(13).fontColor('#444444').maxLines(6)
        .padding({ left: 12, right: 12 })

      if (this.detail!.lines.length > 0) {
        Scroll() {
          Row({ space: 10 }) {
            ForEach(this.detail!.lines, (l: PlayLine, i: number) => {
              Text(l.from)
                .fontColor(this.lineIdx === i ? '#007DFF' : '#666666')
                .fontWeight(this.lineIdx === i ? FontWeight.Bold : FontWeight.Normal)
                .onClick(() => { this.lineIdx = i; })
            }, (l: PlayLine, i: number) => l.from + i)
          }.padding({ left: 12, top: 12 })
        }.scrollable(ScrollDirection.Horizontal).width('100%')

        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
          ForEach(this.detail!.lines[this.lineIdx].episodes, (ep: Episode, i: number) => {
            Button(ep.name)
              .fontSize(13).height(36).margin({ left: 8, top: 8 })
              .backgroundColor('#F2F3F5').fontColor('#333333')
              .onClick(() => {
                const param: PlayerParam = { ep: ep, siteKey: AppState.instance.currentSite?.key ?? '' };
                Nav.stack.pushPathByName('Player', param);
              })
          }, (ep: Episode, i: number) => ep.url + i)
        }.width('100%').padding({ left: 4, right: 12 })
      } else {
        Text('无可用播放线路').fontSize(14).fontColor('#999999').margin({ top: 40 })
      }
    }.width('100%').height('100%').alignItems(HorizontalAlign.Start)
  }

  private async load(): Promise<void> {
    const d = AppState.instance.driver;
    const m = this.movie;
    if (d === null || m === null) { return; }
    this.loading = true; this.errMsg = ''; this.lineIdx = 0;
    try {
      this.detail = await d.detailContent([m.vodId]);
    } catch (e) { this.errMsg = e instanceof Error ? e.message : String(e); }
    this.loading = false;
  }
}
