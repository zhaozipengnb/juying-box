// 播放设置二级页：FongMi 模板格式——标签在左、当前值在右的单行卡，点行弹 ActionSheet 选择，
// 布尔项点行直接切换（右侧显示 开启/关闭）。
// 注意：显示值一律读 @Local 镜像（V2 保证即时重渲染）；改动同步回 AppSettings 单例持久化。
// 直接读单例 @Trace 的 @Param 表达式与 @Builder 值传参在本工程均不触发刷新（实测），勿改回。
import { Nav } from '../nav/Nav';
import { AppSettings, VideoFit, SPEED_OPTIONS, LONG_PRESS_OPTIONS } from '../state/AppSettings';
import { SettingRow } from '../components/SettingRow';
import { OptionPicker, PickerSpec } from '../components/OptionPicker';

@ComponentV2
export struct PlaySettingsPage {
  settings: AppSettings = AppSettings.instance;
  @Local playSpeed: number = AppSettings.instance.playSpeed;
  @Local longPressSpeed: number = AppSettings.instance.longPressSpeed;
  @Local videoFit: VideoFit = AppSettings.instance.videoFit;
  @Local danmakuOn: boolean = AppSettings.instance.danmakuOn;
  @Local lineAutoPlay: boolean = AppSettings.instance.lineAutoPlay;
  @Local aiAdFilter: boolean = AppSettings.instance.aiAdFilter;
  @Local builtinDownload: boolean = AppSettings.instance.builtinDownload;
  @Local picker: PickerSpec | null = null;   // 居中选择弹层（null = 不显示）

  // 写镜像 + 同步单例持久化（页面显示读镜像，播放页读单例，二者经 sync 保持一致）
  private sync(): void {
    this.settings.playSpeed = this.playSpeed;
    this.settings.longPressSpeed = this.longPressSpeed;
    this.settings.videoFit = this.videoFit;
    this.settings.danmakuOn = this.danmakuOn;
    this.settings.lineAutoPlay = this.lineAutoPlay;
    this.settings.aiAdFilter = this.aiAdFilter;
    this.settings.builtinDownload = this.builtinDownload;
    this.settings.save();
  }

  @Computed get wallpaperColors(): Array<[ResourceColor, number]> {
    const w = this.settings.wallpaper;
    if (w === 'dark') { return [['#FF141416', 0.0], ['#FF232326', 1.0]]; }
    if (w === 'blue') { return [['#FF0E1E3C', 0.0], ['#FF1B3A5E', 1.0]]; }
    if (w === 'green') { return [['#FF12291F', 0.0], ['#FF1E4030', 1.0]]; }
    return [['#FFFFFFFF', 0.0], ['#FFFFFFFF', 1.0]];
  }

  private pickSpeed(): void {
    this.picker = {
      title: '播放倍速',
      options: SPEED_OPTIONS.map((s: number): string => s + 'x'),
      index: SPEED_OPTIONS.indexOf(this.playSpeed),
      onPick: (idx: number): void => {
        this.playSpeed = SPEED_OPTIONS[idx];
        this.sync();
      }
    };
  }

  private pickLongPress(): void {
    this.picker = {
      title: '长按倍速',
      options: LONG_PRESS_OPTIONS.map((s: number): string => s === 0 ? '关闭' : s + 'x'),
      index: LONG_PRESS_OPTIONS.indexOf(this.longPressSpeed),
      onPick: (idx: number): void => {
        this.longPressSpeed = LONG_PRESS_OPTIONS[idx];
        this.sync();
      }
    };
  }

  build() {
    NavDestination() {
      Stack() {
      Column() {
        // 标题：模板样式——左上角仅页面名，返回走系统手势/返回键
        Text('播放设置').fontSize(22).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
        .width('100%').padding({ left: 16, right: 16, top: 14, bottom: 8 })

        Scroll() {
          Column() {
            SettingRow({ label: '播放倍速', value: this.playSpeed + 'x',
              onTap: (): void => { this.pickSpeed(); } })
            SettingRow({ label: '长按倍速',
              value: this.longPressSpeed === 0 ? '关闭' : this.longPressSpeed + 'x',
              onTap: (): void => { this.pickLongPress(); } })
            SettingRow({ label: '线路播放', value: this.lineAutoPlay ? '自动' : '手动',
              onTap: (): void => {
                this.lineAutoPlay = !this.lineAutoPlay;
                this.sync();
              } })
            SettingRow({ label: 'AI去广告', value: this.aiAdFilter ? '开启' : '关闭',
              onTap: (): void => {
                this.aiAdFilter = !this.aiAdFilter;
                this.sync();
              } })
            SettingRow({ label: '内置下载', value: this.builtinDownload ? '开启' : '关闭',
              onTap: (): void => {
                this.builtinDownload = !this.builtinDownload;
                this.sync();
              } })
          }
          .width('100%').padding({ left: 16, right: 16, top: 6, bottom: 20 })
        }
        .width('100%').layoutWeight(1)
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
      }
      .width('100%').height('100%')
      .linearGradient({ angle: 160, colors: this.wallpaperColors })
      .backgroundImage(this.settings.bgImage())
      .backgroundImageSize(ImageSize.Cover)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      if (this.picker !== null) {
        OptionPicker({
          title: this.picker.title,
          options: this.picker.options,
          selectedIndex: this.picker.index,
          onPick: (idx: number): void => {
            const pk: PickerSpec | null = this.picker;
            if (pk !== null) { pk.onPick(idx); }
            this.picker = null;
          },
          onClose: (): void => { this.picker = null; }
        })
      }
      }
      .width('100%').height('100%')
    }
    .hideTitleBar(true)
  }
}
