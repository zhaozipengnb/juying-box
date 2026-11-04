// 底部主导航栏：首页/直播/设置 三页共享（手机/平板）。
// 对齐 主流影视App模板：纯图标、无文字，当前项白色胶囊高亮；TV 不渲染（build 空）。
// 直播/设置仍走 Nav 路由栈：回首页清栈到栈底，返回键行为与 tab 直觉一致。
import { Nav } from '../nav/Nav';
import { deviceInfo } from '@kit.BasicServicesKit';

// 是否电视设备（TV 保持顶栏布局，不显示底部栏）
export function isTvDevice(): boolean {
  return deviceInfo.deviceType === 'tv';
}

@ComponentV2
export struct MainTabBar {
  @Param active: string = 'home';   // 当前页：'home' | 'live' | 'settings'

  build() {
    if (!isTvDevice()) {
      Row({ space: 30 }) {
        this.tabItem('home', $r('app.media.ic_home'))
        this.tabItem('live', $r('app.media.ic_live'))
        this.tabItem('settings', $r('app.media.ic_settings'))
      }
      .width('100%')
      .height(56)
      // 透明：直接透出页面壁纸背景；下沉到系统底部安全区内
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
      .alignItems(VerticalAlign.Center)
      .justifyContent(FlexAlign.Center)
    }
  }

  @Builder
  tabItem(key: string, icon: Resource) {
    Column() {
      Image(icon)
        .width(24).height(24)
        .fillColor(this.active === key ? '#007DFF' : '#B3FFFFFF')
    }
    .padding({ left: 18, right: 18, top: 9, bottom: 9 })
    .backgroundColor(this.active === key ? '#FFFFFF' : Color.Transparent)
    .borderRadius(20)
    .onClick(() => {
      if (this.active === key) { return; }
      if (key === 'home') {
        // 清栈回首页（直播/设置可能叠了多层）
        while (Nav.stack.size() > 1) { Nav.stack.pop(); }
      } else if (key === 'live') {
        Nav.stack.pushPathByName('Live', '');
      } else {
        Nav.stack.pushPathByName('Settings', '');
      }
    })
  }
}
