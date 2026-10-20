// 影片网格（WaterFlow 多列 + 触底加载更多）：HomePage 分类/首页/搜索共用
// 页码与数据源管理在调用方：触底时通过 onLoadMore 回调，由调用方决定追加方式
// 注意：本 SDK FlowItem 子组件的 width('100%') 会按瀑布流整体宽度解析（压到相邻列上），
// 故列宽经 onAreaChange 实测后显式指定，海报按 2:3 竖版裁切。
// columns 由设置「图片尺寸」映射（small=4 / normal=3 / large=2）；
// siteLabels 与 items 平行（聚合搜索时传入），非空时卡片显示来源站角标。
import { Movie } from 'common';

const COL_GAP = 12;
const H_PAD = 12;   // 容器左右内边距

@ComponentV2
export struct MovieGrid {
  @Param items: Movie[] = [];
  @Param hasMore: boolean = false;   // 是否还有下一页（调用方按 page/pageCount 计算）
  @Param loading: boolean = false;   // 加载中标志：触底时防重复触发
  @Param columns: number = 3;        // 列数（图片尺寸设置映射）
  @Param siteLabels: string[] = [];  // 来源站名（与 items 同序；空 = 不显示角标）
  @Param dark: boolean = false;      // 深色壁纸：标题/备注文字提亮
  // 回调用 @Param（@ComponentV2 中普通属性禁止父组件初始化）
  @Param onPick: (m: Movie, idx: number) => void = (_m: Movie, _i: number) => {};
  @Param onLoadMore: () => void = () => {};
  @Local colW: number = 170;         // 单列宽（vp）：容器实测后校正
  private gridScroller: Scroller = new Scroller();

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
          Column({ space: 8 }) {
            Stack({ alignContent: Alignment.TopEnd }) {
              Image(m.pic === '' ? $r('app.media.startIcon') : m.pic)
                .width(this.colW).aspectRatio(0.67)
                .objectFit(ImageFit.Cover)
                .borderRadius(8)
                .alt($r('app.media.startIcon'))
              if ((this.siteLabels[idx] ?? '') !== '') {
                Text(this.siteLabels[idx])
                  .fontSize(10).fontColor('#FFFFFF')
                  .maxLines(1)
                  .backgroundColor('#99000000')
                  .borderRadius({ topLeft: 0, topRight: 8, bottomLeft: 8, bottomRight: 0 })
                  .padding({ left: 6, right: 6, top: 3, bottom: 3 })
              }
            }
            .width(this.colW)
            Text(m.name)
              .fontSize(14)
              .fontColor(this.dark ? '#E8E8E8' : '#000000')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(m.remark)
              .fontSize(12)
              .fontColor(this.dark ? '#AAAAAA' : '#999999')
              .maxLines(1)
          }
          .width(this.colW)
        }
        .onClick(() => { this.onPick(m, idx); })
      }, (m: Movie) => m.vodId + '_' + m.name)
    }
    .columnsTemplate(this.columnsTemplate())
    .columnsGap(COL_GAP)
    .rowsGap(14)
    .width('100%')
    .layoutWeight(1)
    .padding({ left: H_PAD, right: H_PAD, top: 10 })
    .onAreaChange((_o: Area, n: Area) => {
      // Area.width 含容器 padding：净宽 = 宽 - 2*padding，均分列再扣列间距
      const n2 = this.columns >= 2 ? this.columns : 3;
      this.colW = ((n.width as number) - H_PAD * 2 - COL_GAP * (n2 - 1)) / n2;
    })
    .onReachEnd(() => {
      // 触底：有更多且不在加载中时回调分页（页码推进在调用方）
      if (this.hasMore && !this.loading) { this.onLoadMore(); }
    })
  }
}
