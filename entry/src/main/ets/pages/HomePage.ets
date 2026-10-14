// 首页 —— Task 3 骨架，Task 5 替换为完整版
import { AppState } from '../state/AppState';

@ComponentV2
export struct HomePage {
  build() {
    Column() { Text('首页（骨架）').fontSize(20) }
      .width('100%').height('100%').justifyContent(FlexAlign.Center)
  }
}
