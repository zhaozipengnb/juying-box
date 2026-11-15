// 影片网格（WaterFlow 多列 + 触底加载更多）：HomePage 分类/首页/搜索共用
// 布局对齐 主流影视App风格：海报大图 2:3 圆角，标题/备注白色叠印在海报底部渐变上，
// 左下角类型徽标；列数由设置「图片尺寸」映射（small=4 / normal=3 / large=2）。
// 注意：本 SDK FlowItem 子组件的 width('100%') 会按瀑布流整体宽度解析（压到相邻列上），
// 故列宽经 onAreaChange 实测后显式指定。siteLabels 与 items 平行（聚合搜索角标）。
import { Movie } from 'common';

const COL_GAP = 16;
const H_PAD = 16;   // 容器左右内边距

@ComponentV2
export struct MovieGrid {
  @Param items: Movie[] = [];
  @Param hasMore: boolean = false;   // 是否还有下一页（调用方按 page/pageCount 计算）
  @Param loading: boolean = false;   // 加载中标志：触底时防重复触发
  @Param columns: number = 3;        // 列数（图片尺寸设置映射）
  @Param siteLabels: string[] = [];  // 来源站名（与 items 同序；空 = 不显示角标）
  // 回调用 @Param（@ComponentV2 中普通属性禁止父组件初始化）
  @Param onPick: (m: Movie, idx: number) => void = (_m: Movie, _i: number) => {};
  @Param onLoadMore: () => void = () => {};
  @Local colW: number = 170;         // 单列宽（vp）：容器实测后校正
  private areaW: number = 0;         // WaterFlow 实测净宽（onAreaChange 记录，列数变化时据此重算）
  private gridScroller: Scroller = new Scroller();

  // 列数变化（图片尺寸设置）时容器总宽不变，onAreaChange 不会再触发——
  // 不重算 colW 则 FlowItem 仍按旧列宽渲染、盖到相邻列上（"设置变了布局不动"的根因）
  @Monitor('columns')
  onColumnsChange(): void {
    this.recalcColW();
  }

  private recalcColW(): void {
    const n = this.columns >= 2 ? this.columns : 3;
    if (this.areaW <= 0) { return; }
    this.colW = (this.areaW - H_PAD * 2 - COL_GAP * (n - 1)) / n;
  }

  private columnsTemplate(): string {
    const n = this.columns >= 2 ? this.columns : 3;
    const parts: string[] = [];
    for (let i = 0; i < n; i++) { parts.push('1fr'); }
    return parts.join(' ');
  }

  build() {
    WaterFlow({ scroller: this.gridScroller }) {
      ForEach(this.items, (m: Movie, idx: number) => {
        FlowItem() {
          Stack({ alignContent: Alignment.BottomStart }) {
            Image(m.pic === '' ? $r('app.media.startIcon') : m.pic)
              .width(this.colW).aspectRatio(0.67)
              .objectFit(ImageFit.Cover)
              .borderRadius(12)
              .alt($r('app.media.startIcon'))
            // 底部渐变叠层：类型徽标 + 标题 + 备注（白色叠印在海报上）
            Column() {
              if ((m.score ?? '') !== '' || (m.typeName !== '') || (this.siteLabels[idx] ?? '') !== '') {
                Row({ space: 4 }) {
                  if ((m.score ?? '') !== '') {
                    Text(m.score)
                      .fontSize(10).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
                      .maxLines(1)
                      .backgroundColor('#2E7D32')
                      .borderRadius(5)
                      .padding({ left: 5, right: 5, top: 2, bottom: 2 })
                  }
                  if (m.typeName !== '') {
                    Text(m.typeName)
                      .fontSize(10).fontColor('#FFFFFF')
                      .maxLines(1)
                      .backgroundColor('#99333B44')
                      .borderRadius(5)
                      .padding({ left: 5, right: 5, top: 2, bottom: 2 })
                  }
                  if ((this.siteLabels[idx] ?? '') !== '') {
                    Text(this.siteLabels[idx])
                      .fontSize(10).fontColor('#FFFFFF')
                      .maxLines(1)
                      .backgroundColor('#99000000')
                      .borderRadius(5)
                      .padding({ left: 5, right: 5, top: 2, bottom: 2 })
                  }
                }
              }
              Text(m.name)
                .fontSize(16).fontWeight(FontWeight.Bold)
                .fontColor('#FFFFFF')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ top: 3 })
              if (m.remark !== '') {
                Text(m.remark)
                  .fontSize(12).fontColor('#D8FFFFFF')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ top: 2 })
              }
            }
            .alignItems(HorizontalAlign.Start)
            .width(this.colW)
            .padding({ left: 8, right: 8, bottom: 8, top: 24 })
            .linearGradient({ angle: 180, colors: [['#00111111', 0.0], ['#C2000000', 1.0]] })
          }
          .width(this.colW)
        }
        .onClick(() => { this.onPick(m, idx); })
      }, (m: Movie) => m.vodId + '_' + m.name)
    }
    .columnsTemplate(this.columnsTemplate())
    .columnsGap(COL_GAP)
    .rowsGap(16)
    .width('100%')
    .layoutWeight(1)
    .padding({ left: H_PAD, right: H_PAD, top: 10 })
    .onAreaChange((_o: Area, n: Area) => {
      // Area.width 含容器 padding：净宽 = 宽 - 2*padding，记录后统一走 recalcColW
      this.areaW = n.width as number;
      this.recalcColW();
    })
    .onReachEnd(() => {
      // 触底：有更多且不在加载中时回调分页（页码推进在调用方）
      if (this.hasMore && !this.loading) { this.onLoadMore(); }
    })
  }
}
