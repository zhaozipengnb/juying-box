// 播放页：全屏 Video 起播，错误卡片支持重试/返回（隐藏标题栏，返回交由系统默认出栈）
import { Nav, PlayerParam } from '../nav/Nav';
import { Episode } from 'common';

@ComponentV2
export struct PlayerPage {
  @Local ep: Episode | null = null;
  @Local errMsg: string = '';
  private controller: VideoController = new VideoController();

  build() {
    NavDestination() {
      Stack() {
        if (this.errMsg !== '') {
          Column({ space: 12 }) {
            Text('播放失败：' + this.errMsg).fontColor('#E53935')
            Row({ space: 12 }) {
              Button('重试').onClick(() => { this.errMsg = ''; this.controller.start(); })
              Button('返回').onClick(() => { Nav.stack.pop(); })
            }
          }.width('100%')
        } else if (this.ep !== null) {
          Video({ src: this.ep.url, controller: this.controller })
            .width('100%').height('100%')
            .autoPlay(true)
            .objectFit(ImageFit.Contain)
            .onError(() => { this.errMsg = '视频加载或解码失败'; })
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
