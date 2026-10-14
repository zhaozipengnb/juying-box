// 配置订阅页：粘贴 TVBox 订阅链接，解析成功持久化并切首页，失败原地显示错误
import { AppState } from '../state/AppState';

@ComponentV2
export struct ConfigPage {
  @Local inputUrl: string = '';
  @Local busy: boolean = false;

  build() {
    Column({ space: 16 }) {
      Text('OK 影视').fontSize(28).fontWeight(FontWeight.Bold).margin({ top: 120 })
      Text('粘贴 TVBox 订阅链接（支持 JSON/Base64/JPEG 伪装格式）')
        .fontSize(13).fontColor('#888888')
      TextInput({ placeholder: 'https://…/config.json', text: this.inputUrl })
        .type(InputType.URL).width('86%').height(46)
        .onChange((v: string) => { this.inputUrl = v; })
      Button(this.busy ? '解析中…' : '加载订阅')
        .width('86%').height(46)
        .enabled(!this.busy && this.inputUrl.trim().length > 0)
        .onClick(() => { this.doLoad(); })
      if (AppState.instance.errMsg !== '') {
        Text('错误：' + AppState.instance.errMsg)
          .fontSize(13).fontColor('#E53935').width('86%')
      }
    }
    .width('100%').height('100%')
    .alignItems(HorizontalAlign.Center)
  }

  private async doLoad(): Promise<void> {
    this.busy = true;
    AppState.instance.errMsg = '';
    const ok = await AppState.instance.loadFromUrl(this.inputUrl.trim());
    this.busy = false;
    if (ok) {
      // 持久化（fire-and-forget）：从 EntryAbility 装配的 store 读取
      AppState.instance.persistCurrent();
      // phase 已由 loadFromUrl 置 'home'，Navigation 根内容随 phase 自动切换，无需路由操作
    }
  }
}
