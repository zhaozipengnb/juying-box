// 设置行子组件：左侧标签/说明 + 右侧控件（@BuilderParam 尾随闭包）
@Builder
function emptyBuilder() {}

@ComponentV2
export struct SettingRow {
  @Param label: string = '';
  @Param sub: string = '';
  @BuilderParam content: () => void = emptyBuilder;

  build() {
    Row() {
      Column() {
        Text(this.label).fontSize(15).fontColor('#FFFFFF')
        if (this.sub !== '') {
          Text(this.sub).fontSize(11).fontColor('#FFFFFF').margin({ top: 4 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      this.content()
    }
    .width('100%')
    .padding({ left: 28, right: 20, top: 14, bottom: 14 })
  }
}
