// 配置订阅页 —— Task 3 骨架，Task 4 替换为完整版
import { AppState } from '../state/AppState';

@ComponentV2
export struct ConfigPage {
  build() {
    Column() {
      Text('配置订阅（骨架）').fontSize(20)
      if (AppState.instance.phase === 'initing') { Text('加载中…') }
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
  }
}
