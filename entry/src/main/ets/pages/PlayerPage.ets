// 播放页：全屏播放。Video 直链起播；onError 自动降级 Web 组件内嵌网页播放器
// （TVBox 生态大量 CMS 的播放地址为网页播放页而非视频直链）。错误卡片支持重试/返回。
// 全屏：Video 内置全屏按钮只在原方向内拉伸（竖屏下视频仍是一条横带）——
// 本页进入时窗口方向改为跟随传感器，另提供「全屏」按钮强制横屏，退出恢复竖屏。
import { Nav, PlayerParam } from '../nav/Nav';
import { Episode } from 'common';
import { webview } from '@kit.ArkWeb';
import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';

@ComponentV2
export struct PlayerPage {
  @Local ep: Episode | null = null;
  @Local errMsg: string = '';
  @Local useWeb: boolean = false;  // Video 失败后降级为网页播放
  private controller: VideoController = new VideoController();
  private webController: webview.WebviewController = new webview.WebviewController();

  // 切窗口方向：全屏=强制横屏，退出=恢复竖屏（模拟器无重力传感器也能用按钮）
  private async setOrientation(o: window.Orientation): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const win = await window.getLastWindow(ctx);
      await win.setPreferredOrientation(o);
    } catch (e) { /* 方向切换失败不阻塞播放 */ }
  }

  // 沉浸式全屏：布局扩展进安全区（状态栏/导航条），窗口背景置黑。
  // 不开 layoutFullScreen 时页面只画到安全区内，安全区外露出窗口默认白底——即播放器白边的来源。
  private async setImmersive(on: boolean): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const win = await window.getLastWindow(ctx);
      await win.setWindowLayoutFullScreen(on);
      await win.setWindowBackgroundColor(on ? '#FF000000' : '#FFFFFFFF');
    } catch (e) { /* 沉浸式失败不阻塞播放（仅留白，功能可用） */ }
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.BottomEnd }) {
        if (this.errMsg !== '') {
          Column({ space: 12 }) {
            Text('播放失败：' + this.errMsg).fontColor('#E53935')
            Row({ space: 12 }) {
              Button('重试').onClick(() => { this.errMsg = ''; this.useWeb = false; this.controller.start(); })
              Button('网页播放').onClick(() => { this.errMsg = ''; this.useWeb = true; })
              Button('返回').onClick(() => { Nav.stack.pop(); })
            }
          }.width('100%')
        } else if (this.ep !== null && this.useWeb) {
          // 网页播放降级：内嵌浏览器加载播放页（页面内的网页播放器自行处理视频）
          Web({ src: this.ep.url, controller: this.webController })
            .width('100%').height('100%')
            .javaScriptAccess(true)
            .domStorageAccess(true)
            .mediaPlayGestureAccess(true)
        } else if (this.ep !== null) {
          Video({ src: this.ep.url, controller: this.controller })
            .width('100%').height('100%')
            .autoPlay(true)
            .objectFit(ImageFit.Contain)
            .onError(() => {
              // 直链失败 → 自动降级网页播放（CMS 站播放地址多为网页播放器页面）
              this.useWeb = true;
            })
          // 全屏按钮：强制横屏（Video 内置按钮不旋转窗口，竖屏下视频只是一条横带）
          Text('⤢')
            .fontSize(22).fontColor('#FFFFFF')
            .textAlign(TextAlign.Center)
            .width(48).height(48)
            .backgroundColor('#66000000')
            .borderRadius(8)
            .margin({ right: 12, bottom: 12 })
            .onClick(() => { this.setOrientation(window.Orientation.LANDSCAPE); })
        } else {
          LoadingProgress().width(44).height(44)
        }
      }.width('100%').height('100%').backgroundColor(Color.Black)
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      const p = ctx.pathInfo.param as PlayerParam;
      if (p !== null && p !== undefined) { this.ep = p.ep; }
      else { this.errMsg = '播放参数缺失'; }  // 兜底：无参数直接进错误终态，避免永久 Loading
      this.setImmersive(true);                                          // 铺满安全区 + 黑底（消白边）
      this.setOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED);  // 播放中跟随传感器旋转
    })
    .onWillDisappear(() => {
      this.setImmersive(false);                                  // 还原窗口布局与白底
      this.setOrientation(window.Orientation.PORTRAIT);          // 离开播放页恢复竖屏
    })
    .onBackPressed(() => { return false; })
  }
}
