// 应用根页面：Navigation 根容器 + phase 驱动首屏 + 路由表
// phase='config' 仅是兜底（内置源装配失败且无订阅时才会出现）；正常首启直接进 Home，
// 订阅在首页 ⚙ 设置里维护（SettingsPage）。
import { AppState } from '../state/AppState';
import { Nav } from '../nav/Nav';
import { ConfigPage } from './ConfigPage';
import { HomePage } from './HomePage';
import { SettingsPage } from './SettingsPage';
import { DetailPage } from './DetailPage';
import { PlayerPage } from './PlayerPage';
import { DownloadPage } from './DownloadPage';
import { SearchPage } from './SearchPage';
import { HistoryPage } from './HistoryPage';

@Entry
@ComponentV2
struct Index {
  app: AppState = AppState.instance;
  build() {
    Navigation(Nav.stack) {

      if (this.app.phase === 'config') { ConfigPage() }
      // 正常首页在 NavDestination 'Home'；此根分支仅在栈被弹空前短暂可见（Home 上 Back 已改为退后台）
      else if (this.app.phase === 'home') { Column() { LoadingProgress().width(44).height(44) }.width('100%').height('100%').justifyContent(FlexAlign.Center) }
      else { Column() { Text('正在加载…') }.width('100%').height('100%').justifyContent(FlexAlign.Center) }
    }
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .hideToolBar(true)
    .navDestination(this.pagesMap)
  }

  aboutToAppear(): void {
    // 冷启动已恢复配置（或无订阅用内置源起步）→ 直接路由进首页（initFromStore 通常先于首帧完成）
    if (this.app.phase === 'home') { Nav.stack.replacePath({ name: 'Home' }); }
  }

  @Builder
  pagesMap(name: string) {
    if (name === 'Home') { HomePage() }
    else if (name === 'Settings') { SettingsPage() }
    else if (name === 'Detail') { DetailPage() }
    else if (name === 'Player') { PlayerPage() }
    else if (name === 'Download') { DownloadPage() }
    else if (name === 'Search') { SearchPage() }
    else if (name === 'History') { HistoryPage() }
  }
}
