// 设置行子组件：左侧标签/说明 + 右侧控件（@BuilderParam 尾随闭包）
// 视觉对齐 主流影视App设置页：圆角半透明胶囊卡，壁纸透出。
// onTap：整行点击（入口行用，子控件自身点击仍优先生效）；arrow：右侧渲染 › 箭头
@Builder
function emptyBuilder() {}

@ComponentV2
export struct SettingRow {
  @Param label: string = '';
  @Param sub: string = '';
  @Param value: string = '';   // 右侧当前值文本（非空渲染）；由父页构建时求值，状态变化即刷新
  @Param arrow: boolean = false;
  @Param onTap: () => void = () => {};
  @BuilderParam content: () => void = emptyBuilder;

  build() {
    Row() {
      Column() {
        Text(this.label).fontSize(14).fontColor('#FFFFFF')
        if (this.sub !== '') {
          Text(this.sub).fontSize(10).fontColor('#B3FFFFFF').margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      this.content()
      if (this.value !== '') {
        Text(this.value).fontSize(13).fontColor('#E6FFFFFF')
      }
      if (this.arrow) {
        Text('›').fontSize(20).fontColor('#FFFFFF').margin({ left: 6 })
      }
    }
    .width('100%')
    .padding({ left: 18, right: 16, top: 10, bottom: 10 })
    .backgroundColor('#66888888')
    .borderRadius(9)
    .margin({ top: 4, bottom: 4 })
    .onClick(() => { this.onTap(); })
  }
}
