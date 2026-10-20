// 设置页：订阅维护 + 个性化设置（播放/显示/搜索/隐私/实验性）+ 缓存清理 + 壁纸。
// 个性化设置即改即存（AppSettings.save），返回首页后由各消费点读取生效。
import { AppState } from '../state/AppState';
import { AppSettings, PicSize, WallpaperKind, SPEED_OPTIONS, LONG_PRESS_OPTIONS } from '../state/AppSettings';
import { SearchHistory } from '../state/SearchHistory';
import { SettingRow } from '../components/SettingRow';
import { Nav } from '../nav/Nav';
import { common } from '@kit.AbilityKit';
import fs from '@ohos.file.fs';
import { photoAccessHelper } from '@kit.MediaLibraryKit';

// 海报密度选项（与 PicSize 一一对应）
const PIC_SIZES: PicSize[] = ['small', 'normal', 'large'];
const PIC_LABELS: string[] = ['小（4列）', '标准（3列）', '大（2列）'];
const WALLPAPERS: WallpaperKind[] = ['default', 'dark', 'blue', 'green'];
const WALLPAPER_LABELS: string[] = ['默认（白）', '暗黑', '深蓝渐变', '墨绿渐变'];

@ComponentV2
export struct SettingsPage {
  // 持有实例成员：V2 观察要求经组件成员访问 @Trace（静态链式访问不建立依赖）
  app: AppState = AppState.instance;
  settings: AppSettings = AppSettings.instance;
  @Local inputUrl: string = '';
  @Local busy: boolean = false;
  @Local localErr: string = '';
  @Local localOk: string = '';
  @Local cacheBytes: number = -1;   // -1 = 未统计
  @Local searchHistoryCount: number = 0;
  @Local editingSub: boolean = false;

  aboutToAppear(): void {
    this.inputUrl = this.app.subUrl;
    this.refreshCacheSize();
    this.searchHistoryCount = SearchHistory.instance.getAll().length;
  }

  // @Computed 直接读取 @Trace 属性，确保 V2 依赖建立，壁纸变更立即生效
  @Computed get wallpaperColors(): Array<[ResourceColor, number]> {
    const w = this.settings.wallpaper;
    if (w === 'dark') { return [['#FF141416', 0.0], ['#FF232326', 1.0]]; }
    if (w === 'blue') { return [['#FF0E1E3C', 0.0], ['#FF1B3A5E', 1.0]]; }
    if (w === 'green') { return [['#FF12291F', 0.0], ['#FF1E4030', 1.0]]; }
    return [['#FFFFFFFF', 0.0], ['#FFFFFFFF', 1.0]];
  }

  @Computed get isDarkWallpaper(): boolean {
    return this.settings.wallpaper !== 'default' || this.settings.wallpaperUri !== '';
  }

  @Computed get wallpaperUri(): string {
    return this.settings.wallpaperUri;
  }

  private async pickWallpaper(): Promise<void> {
    try {
      const opt = new photoAccessHelper.PhotoSelectOptions();
      opt.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      opt.maxSelectNumber = 1;
      const pv = new photoAccessHelper.PhotoViewPicker();
      const res = await pv.select(opt);
      if (res.photoUris.length > 0) {
        const srcUri = res.photoUris[0];
        const destPath = (getContext(this) as common.UIAbilityContext).filesDir + '/wallpaper.jpg';
        const srcFile = fs.openSync(srcUri, fs.OpenMode.READ_ONLY);
        const destFile = fs.openSync(destPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        fs.copyFileSync(srcFile.fd, destFile.fd);
        fs.closeSync(srcFile);
        fs.closeSync(destFile);
        this.settings.wallpaperUri = destPath;
        this.settings.save();
      }
    } catch (e) { /* 用户取消或权限不足 */ }
  }

  private clearWallpaper(): void {
    this.settings.wallpaperUri = '';
    this.settings.save();
  }

  // ---------- 缓存 ----------
  private cacheDir(): string {
    return (getContext(this) as common.UIAbilityContext).cacheDir;
  }

  private dirSize(path: string): number {
    let total = 0;
    let names: string[] = [];
    try { names = fs.listFileSync(path); } catch (e) { return 0; }
    for (const n of names) {
      const full = path + '/' + n;
      try {
        const st = fs.statSync(full);
        if (st.isDirectory()) { total += this.dirSize(full); }
        else { total += st.size; }
      } catch (e) { /* 单项失败跳过 */ }
    }
    return total;
  }

  private refreshCacheSize(): void {
    this.cacheBytes = this.dirSize(this.cacheDir());
  }

  private clearCache(): void {
    const dir = this.cacheDir();
    let names: string[] = [];
    try { names = fs.listFileSync(dir); } catch (e) { /* 目录不存在视为已清 */ }
    for (const n of names) {
      try { fs.rmdirSync(dir + '/' + n); } catch (e) {
        try { fs.unlinkSync(dir + '/' + n); } catch (e2) { /* 单项失败跳过 */ }
      }
    }
    this.refreshCacheSize();
  }

  private fmtSize(b: number): string {
    if (b < 0) { return '统计中…'; }
    if (b < 1024) { return b + ' B'; }
    if (b < 1024 * 1024) { return (b / 1024).toFixed(1) + ' KB'; }
    return (b / 1024 / 1024).toFixed(1) + ' MB';
  }

  @Builder
  sectionTitle(t: string) {
    Text(t).fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.isDarkWallpaper ? '#CCCCCC' : '#333333')
      .width('100%').padding({ left: 16 }).margin({ top: 28 })
  }

  build() {
    NavDestination() {
      Scroll() {
        Column() {
          this.sectionTitle('订阅')
          SettingRow({ label: '订阅地址', sub: this.app.subUrl === '' ? '未设置（使用内置源）' : this.app.subUrl }) {
            Button(this.editingSub ? '取消' : '编辑')
              .height(36)
              .backgroundColor(this.isDarkWallpaper ? '#3A3A3C' : '#F5F5F5')
              .fontColor(this.isDarkWallpaper ? '#CCCCCC' : '#333333')
              .onClick(() => {
                this.editingSub = !this.editingSub;
                if (this.editingSub) { this.inputUrl = this.app.subUrl; }
                this.localErr = '';
                this.localOk = '';
              })
          }

          if (this.editingSub) {
            TextInput({ placeholder: 'https://…/config.json（支持 JSON / Base64 / JPEG 伪装格式）' })
              .type(InputType.URL).width('86%').height(46)
              .onChange((v: string) => { this.inputUrl = v; })

            Button(this.busy ? '解析中…' : (this.app.subUrl === '' ? '加载订阅' : '更新订阅'))
              .width('86%').height(44)
              .enabled(!this.busy && this.inputUrl.trim().length > 0)
              .onClick(() => { this.doLoad(); })

            Button('清除订阅')
              .width('86%').height(40)
              .backgroundColor('#F5F5F5').fontColor('#C62828')
              .enabled(!this.busy)
              .onClick(() => {
                this.app.clearConfig();
                this.editingSub = false;
                Nav.stack.pop();
              })

            if (this.localErr !== '') {
              Text('错误：' + this.localErr).fontSize(13).fontColor('#E53935').width('100%').padding({ left: 16, right: 16 })
            }
            if (this.localOk !== '') {
              Text(this.localOk).fontSize(13).fontColor('#2E7D32').width('100%').padding({ left: 16, right: 16 })
            }
          }

          // ---------- 播放 ----------
          this.sectionTitle('播放')
          SettingRow({ label: '播放倍速', sub: '进入播放页时的默认倍速' }) {
            Select(SPEED_OPTIONS.map((s: number): SelectOption => {
              const opt: SelectOption = { value: s + 'x' };
              return opt;
            }))
              .selected(SPEED_OPTIONS.indexOf(this.settings.playSpeed))
              .value(this.settings.playSpeed + 'x')
              .width(110)
              .onSelect((idx: number) => {
                this.settings.playSpeed = SPEED_OPTIONS[idx];
                this.settings.save();
              })
          }
          SettingRow({ label: '长按倍速', sub: '播放中长按屏幕临时加速，松开恢复' }) {
            Select(LONG_PRESS_OPTIONS.map((s: number): SelectOption => {
              const opt: SelectOption = { value: s === 0 ? '关闭' : s + 'x' };
              return opt;
            }))
              .selected(LONG_PRESS_OPTIONS.indexOf(this.settings.longPressSpeed))
              .value(this.settings.longPressSpeed === 0 ? '关闭' : this.settings.longPressSpeed + 'x')
              .width(110)
              .onSelect((idx: number) => {
                this.settings.longPressSpeed = LONG_PRESS_OPTIONS[idx];
                this.settings.save();
              })
          }
          SettingRow({ label: 'AI去广告', sub: '预留：将作用于播放地址解析阶段，本版本暂未生效' }) {
            Toggle({ type: ToggleType.Switch, isOn: this.settings.aiAdFilter })
              .onChange((v: boolean) => { this.settings.aiAdFilter = v; this.settings.save(); })
          }
          SettingRow({ label: '内置下载', sub: '在详情页和播放页显示下载按钮，可离线缓存影片' }) {
            Toggle({ type: ToggleType.Switch, isOn: this.settings.builtinDownload })
              .onChange((v: boolean) => { this.settings.builtinDownload = v; this.settings.save(); })
          }

          // ---------- 显示 ----------
          this.sectionTitle('显示')
          SettingRow({ label: '图片尺寸', sub: '首页海报密度（列数）' }) {
            Select(PIC_LABELS.map((s: string): SelectOption => {
              const opt: SelectOption = { value: s };
              return opt;
            }))
              .selected(PIC_SIZES.indexOf(this.settings.picSize))
              .value(PIC_LABELS[PIC_SIZES.indexOf(this.settings.picSize)] ?? '标准（3列）')
              .width(140)
              .onSelect((idx: number) => {
                this.settings.picSize = PIC_SIZES[idx];
                this.settings.save();
              })
          }
          SettingRow({ label: '颜色主题', sub: '全局背景渐变色' }) {
            Select(WALLPAPER_LABELS.map((s: string): SelectOption => {
              const opt: SelectOption = { value: s };
              return opt;
            }))
              .selected(WALLPAPERS.indexOf(this.settings.wallpaper))
              .value(WALLPAPER_LABELS[WALLPAPERS.indexOf(this.settings.wallpaper)] ?? '默认（白）')
              .width(140)
              .onSelect((idx: number) => {
                this.settings.wallpaper = WALLPAPERS[idx];
                this.settings.save();
              })
          }
          SettingRow({ label: '壁纸图片', sub: this.wallpaperUri !== '' ? '已设置自定义背景图片' : '选择本地图片作为全局背景' }) {
            Row() {
              Button(this.wallpaperUri !== '' ? '更换' : '选择')
                .height(36)
                .backgroundColor(this.isDarkWallpaper ? '#3A3A3C' : '#F5F5F5')
                .fontColor(this.isDarkWallpaper ? '#CCCCCC' : '#333333')
                .onClick(() => { this.pickWallpaper(); })
              if (this.wallpaperUri !== '') {
                Button('清除')
                  .height(36).margin({ left: 8 })
                  .backgroundColor(this.isDarkWallpaper ? '#3A3A3C' : '#F5F5F5')
                  .fontColor('#C62828')
                  .onClick(() => { this.clearWallpaper(); })
              }
            }
          }
          SettingRow({ label: '显示站源', sub: '搜索结果卡片角标展示来源站名' }) {
            Toggle({ type: ToggleType.Switch, isOn: this.settings.showSite })
              .onChange((v: boolean) => { this.settings.showSite = v; this.settings.save(); })
          }

          // ---------- 搜索 ----------
          this.sectionTitle('搜索')
          SettingRow({ label: '聚合搜索', sub: '一次并发搜索全部采集站（CMS/XML）并合并结果' }) {
            Toggle({ type: ToggleType.Switch, isOn: this.settings.aggSearch })
              .onChange((v: boolean) => { this.settings.aggSearch = v; this.settings.save(); })
          }
          SettingRow({ label: '站源搜索', sub: '搜索结果顶部按站点筛选（聚合结果就绪后展示）' }) {
            Toggle({ type: ToggleType.Switch, isOn: this.settings.siteFilter })
              .onChange((v: boolean) => { this.settings.siteFilter = v; this.settings.save(); })
          }

          // ---------- 隐私 ----------
          this.sectionTitle('隐私')
          SettingRow({ label: '无痕模式', sub: '不保留搜索记录，搜索栏不展示历史标签' }) {
            Toggle({ type: ToggleType.Switch, isOn: this.settings.incognito })
              .onChange((v: boolean) => { this.settings.incognito = v; this.settings.save(); })
          }
          SettingRow({ label: '搜索历史', sub: this.searchHistoryCount > 0 ? `${this.searchHistoryCount} 条记录` : '暂无记录' }) {
            Button('清除')
              .height(36)
              .backgroundColor(this.isDarkWallpaper ? '#3A3A3C' : '#F5F5F5')
              .fontColor('#C62828')
              .enabled(this.searchHistoryCount > 0)
              .onClick(() => {
                SearchHistory.instance.clear();
                this.searchHistoryCount = 0;
              })
          }

          // ---------- 缓存 ----------
          this.sectionTitle('缓存')
          SettingRow({ label: '缓存占用', sub: this.fmtSize(this.cacheBytes) + '（图片等运行缓存）' }) {
            Button('清理')
              .height(36)
              .backgroundColor('#F5F5F5').fontColor('#C62828')
              .onClick(() => { this.clearCache(); })
          }

          Text('清除订阅不影响个性化设置；个性化设置与订阅分开存储。')
            .fontSize(12).fontColor(this.isDarkWallpaper ? '#888888' : '#999999')
            .width('100%').padding({ left: 16, right: 16 }).margin({ top: 16, bottom: 30 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
      }
      .width('100%').height('100%')
      .scrollBar(BarState.Auto)
      .linearGradient({ angle: 160, colors: this.wallpaperColors })
      .backgroundImage(this.wallpaperUri)
      .backgroundImageSize(ImageSize.Cover)
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
