// 配置订阅页：粘贴 TVBox 订阅链接，解析成功持久化并切首页，失败原地显示错误
import { AppState } from '../state/AppState';
import { Nav } from '../nav/Nav';

@ComponentV2
export struct ConfigPage {
  // 持有 AppState 实例：V2 观察要求经组件成员访问 @Trace（静态链式访问不建立依赖）
  app: AppState = AppState.instance;
  @Local inputUrl: string = '';
  @Local busy: boolean = false;
  // 错误信息镜像：根内容里 @Trace 条件块刷新失效（SDK bug），await 后手动同步到 @Local 驱动渲染
  @Local localErr: string = '';

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
      if (this.localErr !== '') {
        Text('错误：' + this.localErr)
          .fontSize(13).fontColor('#E53935').width('86%')
      }
    }
    .width('100%').height('100%')
    .alignItems(HorizontalAlign.Center)
  }

  aboutToAppear(): void {
    // 冷启动已恢复配置 → 直接路由进首页（观察失效的绕过：显式命令式路由 + 一次延迟重查兜底）
    if (this.app.phase === 'home') { Nav.stack.replacePath({ name: 'Home' }); return; }
    setTimeout(() => { if (this.app.phase === 'home') { Nav.stack.replacePath({ name: 'Home' }); } }, 1000);
  }

  private async doLoad(): Promise<void> {
    this.busy = true;
    this.app.errMsg = '';
    const ok = await this.app.loadFromUrl(this.inputUrl.trim());
    this.busy = false;
    this.localErr = this.app.errMsg;  // 手动同步（观察失效绕过）
    if (ok) {
      this.app.persistCurrent();
      // 命令式路由进首页（V2 根内容条件刷新失效的绕过，见 Index.ets 说明）
      Nav.stack.replacePath({ name: 'Home' });
    }
  }
}
