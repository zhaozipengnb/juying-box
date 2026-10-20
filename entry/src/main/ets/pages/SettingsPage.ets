// 设置页：订阅维护 + 个性化设置（播放/显示/搜索/隐私/实验性）+ 缓存清理 + 壁纸。
// 个性化设置即改即存（AppSettings.save），返回首页后由各消费点读取生效。
import { AppState } from '../state/AppState';
import { AppSettings, PicSize, WallpaperKind, SPEED_OPTIONS, LONG_PRESS_OPTIONS } from '../state/AppSettings';
import { Nav } from '../nav/Nav';
import { common } from '@kit.AbilityKit';
import fs from '@ohos.file.fs';

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

  aboutToAppear(): void {
    this.inputUrl = this.app.subUrl;
    this.refreshCacheSize();
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

  // ---------- 通用行组件参数 ----------
  @Builder
  sectionTitle(t: string) {
    Text(t).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#333333')
      .width('86%').margin({ top: 10 })
  }

  @Builder
  settingRow(label: string, sub: string, content: () => void) {
    Column() {
      Row() {
        Column() {
          Text(label).fontSize(15).fontColor('#222222')
          if (sub !== '') {
            Text(sub).fontSize(11).fontColor('#999999').margin({ top: 2 })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        content()
      }
      .width('100%')
    }
    .width('86%')
    .padding({ top: 10, bottom: 10 })
  }

  build() {
    NavDestination() {
      Scroll() {
        Column() {
          Text('订阅设置').fontSize(17).fontWeight(FontWeight.Bold).margin({ top: 16 })
          Text(this.app.subUrl === '' ? '当前订阅：未设置（使用内置源）' : '当前订阅：' + this.app.subUrl)
            .fontSize(12).fontColor('#666666')
            .width('86%').maxLines(2)
            .margin({ top: 6 })

          TextInput({ placeholder: 'https://…/config.json（支持 JSON / Base64 / JPEG 伪装格式）', text: this.inputUrl })
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
              Nav.stack.pop();   // 回首页；HomePage onShown 检测到配置对象更换后自动刷新
            })

          if (this.localErr !== '') {
            Text('错误：' + this.localErr).fontSize(13).fontColor('#E53935').width('86%')
          }
          if (this.localOk !== '') {
            Text(this.localOk).fontSize(13).fontColor('#2E7D32').width('86%')
          }

          Divider().margin({ top: 14 })

          // ---------- 播放 ----------
          this.sectionTitle('播放')
          this.settingRow('播放倍速', '进入播放页时的默认倍速', () => {
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
          })
          this.settingRow('长按倍速', '播放中长按屏幕临时加速，松开恢复', () => {
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
          })
          this.settingRow('AI去广告', '预留：将作用于播放地址解析阶段，本版本暂未生效', () => {
            Toggle({ type: ToggleType.Switch, isOn: this.settings.aiAdFilter })
              .onChange((v: boolean) => { this.settings.aiAdFilter = v; this.settings.save(); })
          })
          this.settingRow('内置下载', '预留：影片离线缓存，本版本暂未生效', () => {
            Toggle({ type: ToggleType.Switch, isOn: this.settings.builtinDownload })
              .onChange((v: boolean) => { this.settings.builtinDownload = v; this.settings.save(); })
          })

          Divider().margin({ top: 8 })

          // ---------- 显示 ----------
          this.sectionTitle('显示')
          this.settingRow('图片尺寸', '首页海报密度（列数）', () => {
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
          })
          this.settingRow('壁纸', '首页背景', () => {
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
          })
          this.settingRow('显示站源', '搜索结果卡片角标展示来源站名', () => {
            Toggle({ type: ToggleType.Switch, isOn: this.settings.showSite })
              .onChange((v: boolean) => { this.settings.showSite = v; this.settings.save(); })
          })

          Divider().margin({ top: 8 })

          // ---------- 搜索 ----------
          this.sectionTitle('搜索')
          this.settingRow('聚合搜索', '一次并发搜索全部采集站（CMS/XML）并合并结果', () => {
            Toggle({ type: ToggleType.Switch, isOn: this.settings.aggSearch })
              .onChange((v: boolean) => { this.settings.aggSearch = v; this.settings.save(); })
          })
          this.settingRow('站源搜索', '搜索结果顶部按站点筛选（聚合结果就绪后展示）', () => {
            Toggle({ type: ToggleType.Switch, isOn: this.settings.siteFilter })
              .onChange((v: boolean) => { this.settings.siteFilter = v; this.settings.save(); })
          })

          Divider().margin({ top: 8 })

          // ---------- 隐私 ----------
          this.sectionTitle('隐私')
          this.settingRow('无痕模式', '不保留搜索词（播放/浏览历史功能上线后一并生效）', () => {
            Toggle({ type: ToggleType.Switch, isOn: this.settings.incognito })
              .onChange((v: boolean) => { this.settings.incognito = v; this.settings.save(); })
          })

          Divider().margin({ top: 8 })

          // ---------- 缓存 ----------
          this.sectionTitle('缓存')
          this.settingRow('缓存占用', this.fmtSize(this.cacheBytes) + '（图片等运行缓存）', () => {
            Button('清理')
              .height(36)
              .backgroundColor('#F5F5F5').fontColor('#C62828')
              .onClick(() => { this.clearCache(); })
          })

          Text('清除订阅不影响个性化设置；个性化设置与订阅分开存储。')
            .fontSize(12).fontColor('#999999')
            .width('86%').margin({ top: 16, bottom: 30 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
      }
      .width('100%').height('100%')
      .scrollBar(BarState.Auto)
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
