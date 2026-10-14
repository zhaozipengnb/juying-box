// 影片网格（WaterFlow 两列 + 触底加载更多）：HomePage 分类/首页共用，Task 6 搜索结果页复用
// 页码与数据源管理在调用方：触底时通过 onLoadMore 回调，由调用方决定追加方式
import { Movie } from 'common';

@ComponentV2
export struct MovieGrid {
  @Param items: Movie[] = [];
  @Param hasMore: boolean = false;   // 是否还有下一页（调用方按 page/pageCount 计算）
  @Param loading: boolean = false;   // 加载中标志：触底时防重复触发
  // 回调用 @Param（@ComponentV2 中普通属性禁止父组件初始化）
  @Param onPick: (m: Movie) => void = (_m: Movie) => {};
  @Param onLoadMore: () => void = () => {};
  private gridScroller: Scroller = new Scroller();

  build() {
    WaterFlow({ scroller: this.gridScroller }) {
      ForEach(this.items, (m: Movie) => {
        FlowItem() {
          Column({ space: 6 }) {
            Image(m.pic === '' ? $r('app.media.startIcon') : m.pic)
              .width('100%').height(180)
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
          .width('100%')
        }
        .onClick(() => { this.onPick(m); })
      }, (m: Movie) => m.vodId + '_' + m.name)
    }
    .columnsTemplate('1fr 1fr')
    .columnsGap(10)
    .rowsGap(12)
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 12, right: 12, top: 8 })
    .onReachEnd(() => {
      // 触底：有更多且不在加载中时回调分页（页码推进在调用方）
      if (this.hasMore && !this.loading) { this.onLoadMore(); }
    })
  }
}
