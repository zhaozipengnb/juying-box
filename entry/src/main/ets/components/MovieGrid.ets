// 影片网格（WaterFlow 两列 + 触底加载更多）：HomePage 分类/首页共用，Task 6 搜索结果页复用
// 页码与数据源管理在调用方：触底时通过 onLoadMore 回调，由调用方决定追加方式
// 注意：本 SDK FlowItem 子组件的 width('100%') 会按瀑布流整体宽度解析（压到相邻列上），
// 故列宽经 onAreaChange 实测后显式指定，海报按 2:3 竖版裁切。
import { Movie } from 'common';

const COL_GAP = 10;
const H_PAD = 12;   // 容器左右内边距

@ComponentV2
export struct MovieGrid {
  @Param items: Movie[] = [];
  @Param hasMore: boolean = false;   // 是否还有下一页（调用方按 page/pageCount 计算）
  @Param loading: boolean = false;   // 加载中标志：触底时防重复触发
  // 回调用 @Param（@ComponentV2 中普通属性禁止父组件初始化）
  @Param onPick: (m: Movie) => void = (_m: Movie) => {};
  @Param onLoadMore: () => void = () => {};
  @Local colW: number = 170;         // 单列宽（vp）：容器实测后校正
  private gridScroller: Scroller = new Scroller();

  build() {
    WaterFlow({ scroller: this.gridScroller }) {
      ForEach(this.items, (m: Movie) => {
        FlowItem() {
          Column({ space: 6 }) {
            Image(m.pic === '' ? $r('app.media.startIcon') : m.pic)
              .width(this.colW).aspectRatio(0.67)
              .objectFit(ImageFit.Cover)
              .borderRadius(8)
              .alt($r('app.media.startIcon'))
            Text(m.name)
              .fontSize(14)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(m.remark)
              .fontSize(12)
              .fontColor('#999999')
              .maxLines(1)
          }
          .width(this.colW)
        }
        .onClick(() => { this.onPick(m); })
      }, (m: Movie) => m.vodId + '_' + m.name)
    }
    .columnsTemplate('1fr 1fr')
    .columnsGap(COL_GAP)
    .rowsGap(12)
    .width('100%')
    .layoutWeight(1)
    .padding({ left: H_PAD, right: H_PAD, top: 8 })
    .onAreaChange((_o: Area, n: Area) => {
      // Area.width 含容器 padding：净宽 = 宽 - 2*padding，均分两列再扣列间距
      this.colW = (n.width - H_PAD * 2 - COL_GAP) / 2;
    })
    .onReachEnd(() => {
      // 触底：有更多且不在加载中时回调分页（页码推进在调用方）
      if (this.hasMore && !this.loading) { this.onLoadMore(); }
    })
  }
}
