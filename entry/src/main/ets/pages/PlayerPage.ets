// 播放页：全屏播放，统一使用 app 内置的 Video 播放器。
// 各源给的地址有两类：媒体直链，以及 MacCMS/解析接口的网页播放页——后者起播前先用
// resolvePlayUrl 解析成直链，避免同一个视频在「app 播放器」和「内嵌网页播放器」之间摇摆。
// 解析不出的地址不静默降级，而是给出错误卡片（重试 / 网页播放 / 返回），由用户决定。
// 全屏：Video 内置全屏按钮只在原方向内拉伸（竖屏下视频仍是一条横带）——
// 本页进入时窗口方向改为跟随传感器，另提供「全屏」按钮强制横屏，退出恢复竖屏。
import { Nav, PlayerParam } from '../nav/Nav';
import { Episode, isDirectMedia, resolvePlayUrl } from 'common';
import { webview } from '@kit.ArkWeb';
import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppState } from '../state/AppState';

@ComponentV2
export struct PlayerPage {
  @Local ep: Episode | null = null;
  @Local playUrl: string = '';     // 解析后的可播放地址（直链）
  @Local resolving: boolean = true;
  @Local errMsg: string = '';
  @Local useWeb: boolean = false;  // 手动兜底：内嵌浏览器播网页播放页
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

  // 起播前解析：直链直接用；网页播放页挖出其中的媒体地址；挖不到则提示（不自动跳网页播放器）
  private async prepare(): Promise<void> {
    const ep = this.ep;
    if (ep === null) { return; }
    this.resolving = true;
    this.errMsg = '';
    let target: string = ep.url;
    try {
      target = await resolvePlayUrl(ep.url, AppState.instance.makeFetchText());
    } catch (e) { /* 解析失败按原地址起播，仍不行则走错误卡片 */ }
    if (isDirectMedia(target)) {
      this.playUrl = target;
    } else {
      this.errMsg = '该源给的是网页播放页，app 播放器无法直接播放';
    }
    this.resolving = false;
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.BottomEnd }) {
        if (this.errMsg !== '') {
          Column({ space: 12 }) {
            Text('播放失败：' + this.errMsg).fontColor('#E53935')
            Row({ space: 12 }) {
              Button('重试').onClick(() => { this.errMsg = ''; this.playUrl = ''; this.prepare(); })
              Button('网页播放').onClick(() => { this.errMsg = ''; this.useWeb = true; })
              Button('返回').onClick(() => { Nav.stack.pop(); })
            }
          }.width('100%')
        } else if (this.useWeb && this.ep !== null) {
          // 网页兜底：仅由用户在错误卡片上显式选择时进入（页面内播放器自行处理视频）
          Web({ src: this.ep.url, controller: this.webController })
            .width('100%').height('100%')
            .javaScriptAccess(true)
            .domStorageAccess(true)
            .mediaPlayGestureAccess(true)
        } else if (this.resolving || this.playUrl === '') {
          LoadingProgress().width(44).height(44)
        } else {
          Video({ src: this.playUrl, controller: this.controller })
            .width('100%').height('100%')
            .autoPlay(true)
            .objectFit(ImageFit.Contain)
            .onError(() => { this.errMsg = '视频地址无法播放'; })
          // 全屏按钮：强制横屏（Video 内置按钮不旋转窗口，竖屏下视频只是一条横带）
          Text('⤢')
            .fontSize(22).fontColor('#FFFFFF')
            .textAlign(TextAlign.Center)
            .width(48).height(48)
            .backgroundColor('#66000000')
            .borderRadius(8)
            .margin({ right: 12, bottom: 12 })
            .onClick(() => { this.setOrientation(window.Orientation.LANDSCAPE); })
        }
      }.width('100%').height('100%').backgroundColor(Color.Black)
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      const p = ctx.pathInfo.param as PlayerParam;
      if (p !== null && p !== undefined) { this.ep = p.ep; }
      else { this.errMsg = '播放参数缺失'; this.resolving = false; }  // 兜底：无参数进错误终态，避免永久 Loading
      this.setImmersive(true);                                          // 铺满安全区 + 黑底（消白边）
      this.setOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED);  // 播放中跟随传感器旋转
      if (this.ep !== null) { this.prepare(); }
    })
    .onWillDisappear(() => {
      this.setImmersive(false);                                  // 还原窗口布局与白底
      this.setOrientation(window.Orientation.PORTRAIT);          // 离开播放页恢复竖屏
    })
    .onBackPressed(() => { return false; })
  }
}
