// 播放页：全屏播放。Video 直链起播；onError 自动降级 Web 组件内嵌网页播放器
// （TVBox 生态大量 CMS 的播放地址为网页播放页而非视频直链）。错误卡片支持重试/返回。
import { Nav, PlayerParam } from '../nav/Nav';
import { Episode } from 'common';
import { webview } from '@kit.ArkWeb';

@ComponentV2
export struct PlayerPage {
  @Local ep: Episode | null = null;
  @Local errMsg: string = '';
  @Local useWeb: boolean = false;  // Video 失败后降级为网页播放
  private controller: VideoController = new VideoController();
  private webController: webview.WebviewController = new webview.WebviewController();

  build() {
    NavDestination() {
      Stack() {
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
    })
    .onBackPressed(() => { return false; })
  }
}
