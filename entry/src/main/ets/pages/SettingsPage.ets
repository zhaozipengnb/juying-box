// 订阅设置页：从首页 ⚙ 进入，维护订阅地址（加载新订阅 / 更换 / 清除）。
// 首启不再强制填订阅：无订阅时 app 直接用内置源进首页，这里随时补配。
import { AppState } from '../state/AppState';
import { Nav } from '../nav/Nav';

@ComponentV2
export struct SettingsPage {
  // 持有 AppState 实例：V2 观察要求经组件成员访问 @Trace（静态链式访问不建立依赖）
  app: AppState = AppState.instance;
  @Local inputUrl: string = '';
  @Local busy: boolean = false;
  @Local localErr: string = '';
  @Local localOk: string = '';

  aboutToAppear(): void {
    this.inputUrl = this.app.subUrl;
  }

  build() {
    NavDestination() {
      Column({ space: 14 }) {
        Text('订阅设置').fontSize(22).fontWeight(FontWeight.Bold).margin({ top: 24 })
        Text('TVBox 订阅链接（支持 JSON / Base64 / JPEG 伪装格式）')
          .fontSize(13).fontColor('#888888')

        Text(this.app.subUrl === '' ? '当前订阅：未设置（使用内置源）' : '当前订阅：' + this.app.subUrl)
          .fontSize(12).fontColor('#666666')
          .width('86%').maxLines(2)

        TextInput({ placeholder: 'https://…/config.json', text: this.inputUrl })
          .type(InputType.URL).width('86%').height(46)
          .onChange((v: string) => { this.inputUrl = v; })

        Button(this.busy ? '解析中…' : (this.app.subUrl === '' ? '加载订阅' : '更新订阅'))
          .width('86%').height(46)
          .enabled(!this.busy && this.inputUrl.trim().length > 0)
          .onClick(() => { this.doLoad(); })

        if (this.localErr !== '') {
          Text('错误：' + this.localErr).fontSize(13).fontColor('#E53935').width('86%')
        }
        if (this.localOk !== '') {
          Text(this.localOk).fontSize(13).fontColor('#2E7D32').width('86%')
        }

        Button('清除订阅')
          .width('86%').height(44)
          .backgroundColor('#F5F5F5').fontColor('#C62828')
          .enabled(!this.busy)
          .onClick(() => {
            this.app.clearConfig();
            Nav.stack.pop();   // 回首页；HomePage onShown 检测到配置对象更换后自动刷新
          })

        Text('清除后回到内置源；清除不影响已缓存的播放记录。')
          .fontSize(12).fontColor('#999999')
      }
      .width('100%').height('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .hideTitleBar(false)
    .title('设置')
    .onBackPressed(() => { return false; })
  }

  private async doLoad(): Promise<void> {
    this.busy = true;
    this.localErr = '';
    this.localOk = '';
    this.app.errMsg = '';
    const ok = await this.app.loadFromUrl(this.inputUrl.trim());
    this.busy = false;
    if (ok) {
      this.app.persistCurrent();
      this.localOk = '订阅已加载，返回首页即可使用';
      Nav.stack.pop();   // 回首页；HomePage onShown 检测到配置对象更换后自动刷新
    } else {
      this.localErr = this.app.errMsg;  // 失败留在本页展示（phase 未变，无需路由兜底）
    }
  }
}
