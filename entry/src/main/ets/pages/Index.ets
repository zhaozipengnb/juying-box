// 应用根页面：Navigation 根容器 + phase 驱动首屏 + 路由表
import { AppState } from '../state/AppState';
import { Nav } from '../nav/Nav';
import { ConfigPage } from './ConfigPage';
import { HomePage } from './HomePage';
import { DetailPage } from './DetailPage';
import { PlayerPage } from './PlayerPage';

@Entry
@ComponentV2
struct Index {
  build() {
    Navigation(Nav.stack) {
      if (AppState.instance.phase === 'config') { ConfigPage() }
      else if (AppState.instance.phase === 'home') { HomePage() }
      else { Column() { Text('正在加载…') }.width('100%').height('100%').justifyContent(FlexAlign.Center) }
    }
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .hideToolBar(true)
    .navDestination(this.pagesMap)
  }

  @Builder
  pagesMap(name: string) {
    if (name === 'Detail') { DetailPage() }
    else if (name === 'Player') { PlayerPage() }
  }
}
