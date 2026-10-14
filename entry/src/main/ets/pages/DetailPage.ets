// 详情页 —— Task 3 骨架，Task 7 替换为完整版
import { Nav } from '../nav/Nav';

@ComponentV2
export struct DetailPage {
  build() {
    NavDestination() { Column() { Text('详情（骨架）') }.width('100%').height('100%').justifyContent(FlexAlign.Center) }
      .onReady((ctx: NavDestinationContext) => {})
  }
}
