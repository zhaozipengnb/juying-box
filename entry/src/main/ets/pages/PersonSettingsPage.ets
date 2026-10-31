// 个性设置二级页：FongMi 模板格式——标签在左、当前值在右的单行卡，点行弹 ActionSheet 选择，
// 布尔项点行直接切换；壁纸已定版（默认渐变 + 设置页壁纸卡），此处不再提供背景选择。
// 显示值一律读 @Local 镜像（V2 保证即时重渲染），改动同步回 AppSettings 单例持久化（实测教训，勿改回）。
import { Nav } from '../nav/Nav';
import { AppState } from '../state/AppState';
import { AppSettings, PicSize, WallpaperKind } from '../state/AppSettings';
import { SearchHistory } from '../state/SearchHistory';
import { UrlHistory } from '../state/UrlHistory';
import { PlayHistory } from '../state/PlayHistory';
import { Favorites } from '../state/Favorites';
import { SettingRow } from '../components/SettingRow';
import { OptionPicker, PickerSpec } from '../components/OptionPicker';

const PIC_SIZES: PicSize[] = ['small', 'normal', 'large'];
const PIC_LABELS: string[] = ['小（4列）', '标准（3列）', '大（2列）'];

@ComponentV2
export struct PersonSettingsPage {
  app: AppState = AppState.instance;
  settings: AppSettings = AppSettings.instance;
  @Local wallpaper: WallpaperKind = AppSettings.instance.wallpaper;
  @Local picSize: PicSize = AppSettings.instance.picSize;
  @Local showSite: boolean = AppSettings.instance.showSite;
  @Local aggSearch: boolean = AppSettings.instance.aggSearch;
  @Local siteFilter: boolean = AppSettings.instance.siteFilter;
  @Local autoSkipDead: boolean = AppSettings.instance.autoSkipDead;
  @Local incognito: boolean = AppSettings.instance.incognito;
  @Local searchHistoryCount: number = SearchHistory.instance.getAll().length;
  @Local picker: PickerSpec | null = null;   // 居中选择弹层（null = 不显示）
  favorites: Favorites = Favorites.instance;
  playHistory: PlayHistory = PlayHistory.instance;

  // 写镜像 + 同步单例持久化
  private sync(): void {
    this.settings.wallpaper = this.wallpaper;
    this.settings.picSize = this.picSize;
    this.settings.showSite = this.showSite;
    this.settings.aggSearch = this.aggSearch;
    this.settings.siteFilter = this.siteFilter;
    this.settings.autoSkipDead = this.autoSkipDead;
    this.settings.incognito = this.incognito;
    this.settings.save();
  }

  // 页面自身壁纸随主题镜像即时变化
  @Computed get wallpaperColors(): Array<[ResourceColor, number]> {
    const w = this.wallpaper;
    if (w === 'dark') { return [['#FF141416', 0.0], ['#FF232326', 1.0]]; }
    if (w === 'blue') { return [['#FF0E1E3C', 0.0], ['#FF1B3A5E', 1.0]]; }
    if (w === 'green') { return [['#FF12291F', 0.0], ['#FF1E4030', 1.0]]; }
    return [['#FFFFFFFF', 0.0], ['#FFFFFFFF', 1.0]];
  }

  private pickPicSize(): void {
    this.picker = {
      title: '图片尺寸',
      options: PIC_LABELS,
      index: PIC_SIZES.indexOf(this.picSize),
      onPick: (idx: number): void => {
        this.picSize = PIC_SIZES[idx];
        this.sync();
      }
    };
  }

  // 重置App：居中确认 → 清配置/历史/收藏，设置回默认，镜像同步
  private confirmReset(): void {
    this.getUIContext().showAlertDialog({
      title: '重置App',
      message: '将清除全部配置、历史与个性化设置，恢复首次安装状态。确定继续？',
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '重置', fontColor: '#E53935', action: (): void => { this.doReset(); } }
    });
  }

  private doReset(): void {
    this.app.clearConfig();
    this.settings.resetToDefaults();
    SearchHistory.instance.clear();
    UrlHistory.instance.clear('vod');
    UrlHistory.instance.clear('live');
    UrlHistory.instance.clear('wallpaper');
    this.playHistory.clear();
    this.favorites.clear();
    this.wallpaper = this.settings.wallpaper;
    this.picSize = this.settings.picSize;
    this.showSite = this.settings.showSite;
    this.aggSearch = this.settings.aggSearch;
    this.siteFilter = this.settings.siteFilter;
    this.autoSkipDead = this.settings.autoSkipDead;
    this.incognito = this.settings.incognito;
    this.searchHistoryCount = 0;
  }

  private picLabel(): string {
    return PIC_LABELS[PIC_SIZES.indexOf(this.picSize)] ?? '标准（3列）';
  }

  build() {
    NavDestination() {
      Stack() {
      Column() {
        // 标题：模板样式——左上角仅页面名，返回走系统手势/返回键
        Text('个性设置').fontSize(22).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
        .width('100%').padding({ left: 16, right: 16, top: 14, bottom: 8 })

        Scroll() {
          Column() {
            SettingRow({ label: '图片尺寸', value: this.picLabel(),
              onTap: (): void => { this.pickPicSize(); } })
            SettingRow({ label: '显示站源', value: this.showSite ? '开启' : '关闭',
              onTap: (): void => {
                this.showSite = !this.showSite;
                this.sync();
              } })
            SettingRow({ label: '聚合搜索', value: this.aggSearch ? '开启' : '关闭',
              onTap: (): void => {
                this.aggSearch = !this.aggSearch;
                this.sync();
              } })
            SettingRow({ label: '站源搜索', value: this.siteFilter ? '开启' : '关闭',
              onTap: (): void => {
                this.siteFilter = !this.siteFilter;
                this.sync();
              } })
            SettingRow({ label: '自动跳过失效源', value: this.autoSkipDead ? '开启' : '关闭',
              onTap: (): void => {
                this.autoSkipDead = !this.autoSkipDead;
                this.sync();
              } })
            SettingRow({ label: '无痕模式', value: this.incognito ? '开启' : '关闭',
              onTap: (): void => {
                this.incognito = !this.incognito;
                this.sync();
              } })
            SettingRow({ label: '搜索历史',
              value: this.searchHistoryCount > 0 ? `${this.searchHistoryCount} 条记录` : '暂无记录',
              onTap: (): void => {
                SearchHistory.instance.clear();
                this.searchHistoryCount = 0;
              } })
            SettingRow({ label: '重置App', sub: '清除全部配置、历史与个性化设置，恢复首次安装状态',
              onTap: (): void => { this.confirmReset(); } })
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
