// 居中选项选择弹层：遮罩 + 居中卡片，标题 + 选项列表（当前项高亮打勾）。
// 点选项回调 onPick 并自动 onClose；点遮罩关闭；点卡片本体不关闭。
// 由页面用 @Local 持有 PickerSpec（null = 不显示），赋值即弹出。
export interface PickerSpec {
  title: string;
  options: string[];
  index: number;              // 当前选中项（高亮用，-1 = 无）
  onPick: (idx: number) => void;
}

@ComponentV2
export struct OptionPicker {
  @Param title: string = '';
  @Param options: string[] = [];
  @Param selectedIndex: number = -1;
  @Param onPick: (idx: number) => void = (_i: number) => {};
  @Param onClose: () => void = () => {};

  build() {
    Column() {
      Column() {
        Text(this.title)
          .fontSize(16).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
          .width('100%').textAlign(TextAlign.Center)
          .padding({ top: 18, bottom: 6 })
        ForEach(this.options, (o: string, i: number) => {
          Row() {
            Text(o)
              .fontSize(14)
              .fontColor(i === this.selectedIndex ? '#4D9EFF' : '#E6FFFFFF')
              .fontWeight(i === this.selectedIndex ? FontWeight.Medium : FontWeight.Normal)
            Blank()
            if (i === this.selectedIndex) {
              Text('✓').fontSize(14).fontColor('#4D9EFF')
            }
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 13, bottom: 13 })
          .border(i < this.options.length - 1
            ? { width: { bottom: 0.5 }, color: '#1AFFFFFF' } : { width: 0 })
          .onClick(() => {
            this.onPick(i);
            this.onClose();
          })
        }, (o: string, i: number) => o + i)
      }
      .width('72%')
      .padding({ bottom: 6 })
      .backgroundColor('#D9262629')
      .borderRadius(14)
      // 拦截点击，避免冒泡到遮罩误关
      .onClick(() => {})
    }
    .width('100%').height('100%')
    .backgroundColor('#66000000')
    .justifyContent(FlexAlign.Center)
    .onClick(() => { this.onClose(); })
  }
}
