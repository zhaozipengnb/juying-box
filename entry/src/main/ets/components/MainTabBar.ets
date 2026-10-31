// 底部主导航栏：首页/直播/设置 三页共享（手机/平板）。
// TV 不渲染（build 直接空），三个页面维持顶栏图标布局——布局分叉只在这一处。
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
      Row() {
        this.tabItem('home', $r('app.media.ic_home'), '首页')
        this.tabItem('live', $r('app.media.ic_live'), '直播')
        this.tabItem('settings', $r('app.media.ic_settings'), '设置')
      }
      .width('100%')
      .height(48)
      // 透明：直接透出页面壁纸背景；下沉到系统底部安全区内，图标更贴近屏底
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
      .alignItems(VerticalAlign.Center)
    }
  }

  @Builder
  tabItem(key: string, icon: Resource, label: string) {
    Column({ space: 2 }) {
      Image(icon)
        .width(24).height(24)
        .fillColor(this.active === key ? '#FFFFFF' : '#99FFFFFF')
      Text(label)
        .fontSize(10)
        .fontColor(this.active === key ? '#FFFFFF' : '#99FFFFFF')
        .fontWeight(this.active === key ? FontWeight.Medium : FontWeight.Normal)
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.End)
    .padding({ bottom: 2 })
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
