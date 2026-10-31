// 应用根页面：Navigation 根容器 + phase 驱动首屏 + 路由表
// phase='config' 仅是兜底（内置源装配失败且无订阅时才会出现）；正常首启直接进 Home，
// 订阅在首页 ⚙ 设置里维护（SettingsPage）。
import { AppState } from '../state/AppState';
import { Nav } from '../nav/Nav';
import { HomePage } from './HomePage';
import { SettingsPage } from './SettingsPage';
import { PlaySettingsPage } from './PlaySettingsPage';
import { PersonSettingsPage } from './PersonSettingsPage';
import { SiteManagePage } from './SiteManagePage';
import { DetailPage } from './DetailPage';
import { PlayerPage } from './PlayerPage';
import { DownloadPage } from './DownloadPage';
import { SearchPage } from './SearchPage';
import { HistoryPage } from './HistoryPage';
import { LivePage } from './LivePage';

@Entry
@ComponentV2
struct Index {
  app: AppState = AppState.instance;
  build() {
    Navigation(Nav.stack) {
      // 首页在 NavDestination 'Home'（无源时首页显示空态引导）；此根分支仅在栈被弹空前短暂可见
      Column() { LoadingProgress().width(44).height(44) }.width('100%').height('100%').justifyContent(FlexAlign.Center)
    }
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .hideToolBar(true)
    .navDestination(this.pagesMap)
  }

  aboutToAppear(): void {
    // 页面切换不做滑动转场：整栈关闭推入/弹出动画，页面秒切（用户反馈滑动易晕）
    Nav.stack.disableAnimation(true);
    // 冷启动恢复完成（或无源空态）→ 路由进首页；延迟重查兜底 initFromStore 晚于首帧的情况
    if (this.app.phase === 'home') { Nav.stack.replacePath({ name: 'Home' }); }
    setTimeout(() => {
      // 仅栈空才补路由：Home 已在栈顶时重复 replacePath 会重建首页组件，
      // loadHome 二次并发在 drpy 桥上互踩（表现为「Unexpected Text in JSON」/「调用超时」）
      if (this.app.phase === 'home' && Nav.stack.size() === 0) { Nav.stack.replacePath({ name: 'Home' }); }
    }, 1000);
  }

  @Builder
  pagesMap(name: string) {
    if (name === 'Home') { HomePage() }
    else if (name === 'Settings') { SettingsPage() }
    else if (name === 'PlaySettings') { PlaySettingsPage() }
    else if (name === 'PersonSettings') { PersonSettingsPage() }
    else if (name === 'SiteManage') { SiteManagePage() }
    else if (name === 'Detail') { DetailPage() }
    else if (name === 'Player') { PlayerPage() }
    else if (name === 'Download') { DownloadPage() }
    else if (name === 'Search') { SearchPage() }
    else if (name === 'History') { HistoryPage() }
    else if (name === 'Live') { LivePage() }
  }
}
