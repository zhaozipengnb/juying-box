// 设置页：点播 / 直播 / Proxy / 壁纸 / 播放设置 / 个性设置 / 备份恢复 / DoH / 缓存 / 版本 / 关于
// 个性化设置即改即存（AppSettings.save），返回首页后由各消费点读取生效。
import { AppState } from '../state/AppState';
import { AppSettings, PicSize, WallpaperKind, SPEED_OPTIONS, LONG_PRESS_OPTIONS } from '../state/AppSettings';
import { SearchHistory } from '../state/SearchHistory';
import { UrlHistory } from '../state/UrlHistory';
import { SettingRow } from '../components/SettingRow';
import { Nav } from '../nav/Nav';
import { httpFetch } from '../net/HttpClient';
import { common } from '@kit.AbilityKit';
import fs from '@ohos.file.fs';
import { picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { photoAccessHelper } from '@kit.MediaLibraryKit';

// 海报密度选项（与 PicSize 一一对应）
const PIC_SIZES: PicSize[] = ['small', 'normal', 'large'];
const PIC_LABELS: string[] = ['小（4列）', '标准（3列）', '大（2列）'];
const WALLPAPERS: WallpaperKind[] = ['default', 'dark', 'blue', 'green'];
const WALLPAPER_LABELS: string[] = ['默认（白）', '暗黑', '深蓝渐变', '墨绿渐变'];

interface BuiltinBg { name: string; res: Resource; }
const BUILTIN_BGS: BuiltinBg[] = [
  { name: '丁香粉', res: $r('app.media.player_bg_landscape_01_lilac_pink') },
  { name: '薄荷青', res: $r('app.media.player_bg_landscape_02_mint_teal') },
  { name: '莫兰灰', res: $r('app.media.player_bg_landscape_03_morandi_gray') },
  { name: '天际蓝', res: $r('app.media.player_bg_portrait_01_sky_blue') },
  { name: '薰衣草', res: $r('app.media.player_bg_portrait_02_lavender_blue') },
  { name: '蜜桃暮', res: $r('app.media.player_bg_portrait_03_peach_sunset') },
];

@ComponentV2
export struct SettingsPage {
  // 持有实例成员：V2 观察要求经组件成员访问 @Trace（静态链式访问不建立依赖）
  app: AppState = AppState.instance;
  settings: AppSettings = AppSettings.instance;
  @Local inputUrl: string = '';
  @Local inputLiveUrl: string = '';
  @Local inputProxyUrl: string = '';
  @Local inputWallpaperUrl: string = '';
  @Local showUrlDialog: boolean = false;
  @Local showHistory: boolean = false;
  @Local selectedBg: number = -1;
  @Local dialogUrl: string = '';
  @Local dialogTarget: string = '';   // 'vod' | 'live' | 'proxy' | 'wallpaper'
  @Local busy: boolean = false;
  @Local localErr: string = '';
  @Local localOk: string = '';
  @Local cacheBytes: number = -1;   // -1 = 未统计
  @Local searchHistoryCount: number = 0;
  @Local editingSub: boolean = false;

  aboutToAppear(): void {
    this.inputUrl = this.app.subUrl;
    this.inputLiveUrl = this.settings.liveUrl;
    this.inputProxyUrl = this.settings.proxyUrl;
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
        this.showUrlDialog = false;
        this.localErr = '';
        this.localOk = '壁纸已更新为本地图片';
      }
    } catch (e) { /* 用户取消或权限不足 */ }
  }

  private clearWallpaper(): void {
    this.settings.wallpaperUri = '';
    this.settings.save();
  }

  // 刷新壁纸：URL 壁纸重新拉取到沙箱并落盘（覆盖旧缓存，强制重渲染）；本地壁纸重新加载
  private async refreshWallpaper(): Promise<void> {
    const uri = this.settings.wallpaperUri.trim();
    if (uri === '') { this.localErr = '未设置壁纸图片'; return; }
    this.localErr = '';
    this.localOk = '';
    try {
      if (/^https?:\/\//i.test(uri)) {
        const destPath = (getContext(this) as common.UIAbilityContext).filesDir + '/wallpaper.jpg';
        const r = await httpFetch(uri, {});
        if (r.status !== 200) { throw new Error('HTTP ' + r.status); }
        const destFile = fs.openSync(destPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        fs.writeSync(destFile.fd, r.body);
        fs.closeSync(destFile);
        this.settings.wallpaperUri = destPath;
        this.settings.save();
        this.localOk = '壁纸已刷新';
      } else {
        this.settings.save();
        this.localOk = '壁纸已重新加载';
      }
    } catch (e) {
      this.localErr = '刷新失败：' + (e instanceof Error ? e.message : String(e));
    }
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

  // 订阅手动更新：重新拉取当前订阅地址并持久化（保留当前源选择）
  private async refreshSub(): Promise<void> {
    const url = this.app.subUrl;
    if (url === '') { return; }
    this.busy = true;
    this.localErr = '';
    this.localOk = '';
    const ok = await this.app.loadFromUrl(url);
    this.busy = false;
    if (ok) {
      this.app.persistCurrent();
      this.localOk = '订阅已更新';
    } else {
      this.localErr = this.app.errMsg;
    }
  }

  // ---------- 备份 ----------
  // 导出：okvideo_settings 与 okvideo_config 偏好合并写入 filesDir/backups/okvideo_backup.json
  private exportBackup(): void {
    try {
      this.settings.save();   // 先确保最新设置落盘
      const ctx = getContext(this) as common.UIAbilityContext;
      const dir = ctx.filesDir + '/backups';
      if (!fs.accessSync(dir)) { fs.mkdirSync(dir); }
      const path = dir + '/okvideo_backup.json';
      interface BackupPayload { settingsJson: string; exportedAt: string; }
      const payload: BackupPayload = {
        settingsJson: this.settings.toJson(),
        exportedAt: String(Date.now())
      };
      const f = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, JSON.stringify(payload));
      fs.closeSync(f);
      this.localOk = '已导出：' + path;
    } catch (e) {
      this.localErr = '导出失败：' + (e instanceof Error ? e.message : String(e));
    }
  }

  // 导入：系统文件选择器选备份 json → 读回 → AppSettings.restore
  private importBackup(): void {    this.localErr = '';
    this.localOk = '';
    try {
      const opt = new picker.DocumentSelectOptions();
      opt.maxSelectNumber = 1;
      opt.fileSuffixFilters = ['json'];
      const dp = new picker.DocumentViewPicker();
      dp.select(opt).then((uris: string[]) => {
        if (uris.length === 0) { return; }
        const f = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
        const buf = new ArrayBuffer(1024 * 512);
        const n = fs.readSync(f.fd, buf);
        fs.closeSync(f);
        const text = new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buf.slice(0, n)));
        // 导出文件为 {settingsJson, exportedAt} 包装
        let payload: string = text;
        try {
          const wrapped = JSON.parse(text) as Record<string, Object>;
          const inner = wrapped['settingsJson'];
          if (typeof inner === 'string') { payload = inner; }
        } catch (e) { /* 直接就是设置 JSON */ }
        if (this.settings.restore(payload)) {
          this.localOk = '已恢复备份';
        } else {
          this.localErr = '备份文件解析失败';
        }
      }).catch((_e: Object) => { this.localErr = '未选择文件'; });
    } catch (e) {
      this.localErr = '打开文件选择器失败';
    }
  }

  // 点播行文本：本地源包形态 / 订阅 URL / 未设置
  private vodRowText(): string {
    if (this.app.isPackSource) {
      const n = this.app.config?.sites.length ?? 0;
      return `本地源包（${n} 个源）`;
    }
    return this.app.subUrl === '' ? '未设置' : this.app.subUrl;
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
      Stack() {
      Scroll() {
        Column() {
          // ---------- 点播 ----------
          Row() {
            Text('点播').fontSize(16).fontWeight(FontWeight.Bold)
              .fontColor(this.isDarkWallpaper ? '#CCCCCC' : '#333333')
            Text(this.vodRowText())
              .fontSize(13).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontColor(this.isDarkWallpaper ? '#999999' : '#888888')
              .layoutWeight(1).margin({ left: 12 })
            if (!this.app.isPackSource) {
              Text('更新')
                .fontSize(13).fontColor(this.app.subUrl === '' ? (this.isDarkWallpaper ? '#555555' : '#CCCCCC') : '#007AFF')
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .borderRadius(6)
                .backgroundColor(this.isDarkWallpaper ? '#26FFFFFF' : '#F5F5F5')
                .margin({ left: 8 })
                .hitTestBehavior(HitTestMode.Block)
                .onClick(() => { this.refreshSub(); })
              Image($r('app.media.ic_history'))
                .width(20).height(20)
                .fillColor(this.isDarkWallpaper ? '#AAAAAA' : '#888888')
                .margin({ left: 8 })
                .hitTestBehavior(HitTestMode.Block)
                .onClick(() => { this.dialogTarget = 'vod'; this.showHistory = true; })
            }
          }
          .width('100%').padding({ left: 16, right: 16, top: 14, bottom: 14 })
          .onClick(() => {
            this.dialogTarget = 'vod';
            this.dialogUrl = this.app.subUrl;
            this.showUrlDialog = true;
          })
          if (this.localErr !== '') {
            Text('错误：' + this.localErr).fontSize(13).fontColor('#E53935').width('100%').padding({ left: 16, right: 16 })
          }
          if (this.localOk !== '') {
            Text(this.localOk).fontSize(13).fontColor('#2E7D32').width('100%').padding({ left: 16, right: 16 })
          }

          // ---------- 直播 ----------
          Row() {
            Text('直播').fontSize(16).fontWeight(FontWeight.Bold)
              .fontColor(this.isDarkWallpaper ? '#CCCCCC' : '#333333')
            Text(this.inputLiveUrl === '' ? '未设置' : this.inputLiveUrl)
              .fontSize(13).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontColor(this.isDarkWallpaper ? '#999999' : '#888888')
              .layoutWeight(1).margin({ left: 12 })
            Image($r('app.media.ic_history'))
              .width(20).height(20)
              .fillColor(this.isDarkWallpaper ? '#AAAAAA' : '#888888')
              .margin({ left: 8 })
              .hitTestBehavior(HitTestMode.Block)
              .onClick(() => { this.dialogTarget = 'live'; this.showHistory = true; })
          }
          .width('100%').padding({ left: 16, right: 16, top: 14, bottom: 14 })
          .onClick(() => {
            this.dialogTarget = 'live';
            this.dialogUrl = this.inputLiveUrl;
            this.showUrlDialog = true;
          })

          // ---------- Proxy（csp_* JAR 爬虫的远程代理；鸿蒙端无 JVM，JAR 须在外部设备执行）----------
          this.sectionTitle('Proxy')
          SettingRow({
            label: '代理地址',
            sub: this.inputProxyUrl === '' ? '未设置（纯 JAR 源不可用，不影响采集站/drpy 源）'
              : '在电脑/NAS 运行 tools/proxy-server 后填入其地址'
          }) {
            Button('编辑')
              .height(36)
              .backgroundColor(this.isDarkWallpaper ? '#3A3A3C' : '#F5F5F5')
              .fontColor(this.isDarkWallpaper ? '#CCCCCC' : '#333333')
              .onClick(() => {
                this.dialogTarget = 'proxy';
                this.dialogUrl = this.inputProxyUrl;
                this.showUrlDialog = true;
              })
          }

          // ---------- 壁纸 ----------
          this.sectionTitle('壁纸')
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
          Row() {
            Text('壁纸图片').fontSize(15)
              .fontColor(this.isDarkWallpaper ? '#CCCCCC' : '#333333')
            Text(this.wallpaperUri !== '' ? this.wallpaperUri : '未设置')
              .fontSize(13).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontColor(this.isDarkWallpaper ? '#999999' : '#888888')
              .layoutWeight(1).margin({ left: 12 })
            Text('↻')
              .fontSize(22)
              .fontColor(this.isDarkWallpaper ? '#AAAAAA' : '#888888')
              .margin({ left: 8 })
              .hitTestBehavior(HitTestMode.Block)
              .onClick(() => { this.refreshWallpaper(); })
          }
          .width('100%').padding({ left: 16, right: 16, top: 14, bottom: 14 })
          .onClick(() => {
            this.dialogTarget = 'wallpaper';
            this.dialogUrl = this.wallpaperUri;
            this.showUrlDialog = true;
          })

          // 内置背景选择
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(BUILTIN_BGS, (bg: BuiltinBg, idx: number) => {
              Column() {
                Image(bg.res)
                  .width(72).height(48).borderRadius(8)
                  .border(this.selectedBg === idx ? { width: 2, color: '#007AFF' } : { width: 0 })
                Text(bg.name)
                  .fontSize(11).margin({ top: 4 })
                  .fontColor(this.selectedBg === idx ? '#007AFF' : (this.isDarkWallpaper ? '#AAAAAA' : '#666666'))
              }
              .margin({ right: 12, bottom: 12 })
              .onClick(() => {
                this.selectedBg = idx;
                this.settings.wallpaperUri = '';
                this.settings.save();
              })
            })
          }
          .width('100%').padding({ left: 16, right: 16 })

          // ---------- 播放设置 ----------
          this.sectionTitle('播放设置')
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
          SettingRow({ label: 'AI去广告', sub: '过滤 HLS 播放列表里的插播广告分块与「广告/推广」集（对 m3u8 源生效）' }) {
            Toggle({ type: ToggleType.Switch, isOn: this.settings.aiAdFilter })
              .onChange((v: boolean) => { this.settings.aiAdFilter = v; this.settings.save(); })
          }
          SettingRow({ label: '内置下载', sub: '在详情页和播放页显示下载按钮，可离线缓存影片' }) {
            Toggle({ type: ToggleType.Switch, isOn: this.settings.builtinDownload })
              .onChange((v: boolean) => { this.settings.builtinDownload = v; this.settings.save(); })
          }

          // ---------- 个性设置 ----------
          this.sectionTitle('个性设置')
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
          SettingRow({ label: '显示站源', sub: '搜索结果卡片角标展示来源站名' }) {
            Toggle({ type: ToggleType.Switch, isOn: this.settings.showSite })
              .onChange((v: boolean) => { this.settings.showSite = v; this.settings.save(); })
          }
          SettingRow({ label: '聚合搜索', sub: '一次并发搜索全部采集站（CMS/XML）并合并结果' }) {
            Toggle({ type: ToggleType.Switch, isOn: this.settings.aggSearch })
              .onChange((v: boolean) => { this.settings.aggSearch = v; this.settings.save(); })
          }
          SettingRow({ label: '站源搜索', sub: '搜索结果顶部按站点筛选（聚合结果就绪后展示）' }) {
            Toggle({ type: ToggleType.Switch, isOn: this.settings.siteFilter })
              .onChange((v: boolean) => { this.settings.siteFilter = v; this.settings.save(); })
          }
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

          // ---------- 备份恢复 ----------
          this.sectionTitle('备份恢复')
          SettingRow({ label: '配置备份', sub: '导出订阅与个性化设置' }) {
            Button('导出')
              .height(36)
              .backgroundColor(this.isDarkWallpaper ? '#3A3A3C' : '#F5F5F5')
              .fontColor(this.isDarkWallpaper ? '#CCCCCC' : '#333333')
              .onClick(() => { this.exportBackup(); })
          }
          SettingRow({ label: '配置恢复', sub: '从备份文件导入配置' }) {
            Button('导入')
              .height(36)
              .backgroundColor(this.isDarkWallpaper ? '#3A3A3C' : '#F5F5F5')
              .fontColor(this.isDarkWallpaper ? '#CCCCCC' : '#333333')
              .onClick(() => { this.importBackup(); })
          }

          // ---------- DoH ----------
          this.sectionTitle('DoH')
          SettingRow({ label: 'DoH 地址', sub: '未设置（使用系统 DNS）' }) {
            Button('编辑')
              .height(36)
              .backgroundColor(this.isDarkWallpaper ? '#3A3A3C' : '#F5F5F5')
              .fontColor(this.isDarkWallpaper ? '#CCCCCC' : '#333333')
              .onClick(() => {})
          }

          // ---------- 缓存 ----------
          this.sectionTitle('缓存')
          SettingRow({ label: '缓存占用', sub: this.fmtSize(this.cacheBytes) + '（图片等运行缓存）' }) {
            Button('清理')
              .height(36)
              .backgroundColor('#F5F5F5').fontColor('#C62828')
              .onClick(() => { this.clearCache(); })
          }

          // ---------- 版本 ----------
          this.sectionTitle('版本')
          SettingRow({ label: '当前版本', sub: 'v1.0.0' }) {
            Text('检查更新')
              .fontSize(14)
              .fontColor(this.isDarkWallpaper ? '#888888' : '#999999')
              .onClick(() => {})
          }

          // ---------- 关于 ----------
          this.sectionTitle('关于')
          SettingRow({ label: '关于应用', sub: '点播 / 直播聚合播放器' }) {
            Text('>')
              .fontSize(16)
              .fontColor(this.isDarkWallpaper ? '#888888' : '#CCCCCC')
              .onClick(() => {})
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

      // ---------- URL 编辑弹窗 ----------
      if (this.showUrlDialog) {
        Column() {
          // 遮罩
        }
        .width('100%').height('100%')
        .backgroundColor('#80000000')
        .onClick(() => { this.showUrlDialog = false; })

        Column() {
          Text(this.dialogTarget === 'vod' ? '订阅地址' : this.dialogTarget === 'live' ? '直播源' : this.dialogTarget === 'proxy' ? 'Proxy 地址' : '壁纸图片')
            .fontSize(16).fontWeight(FontWeight.Medium).fontColor('#222222')
            .margin({ bottom: 6 })
          if (this.dialogTarget === 'vod') {
            Text('输入订阅链接；或点右侧 📁 导入本地源包（替换当前源）')
              .fontSize(12).fontColor('#999999').margin({ bottom: 10 })
          }
          if (this.dialogTarget === 'wallpaper') {
            Text('输入图片链接；或点右侧 📁 选择本地图片')
              .fontSize(12).fontColor('#999999').margin({ bottom: 10 })
          }
          Stack({ alignContent: Alignment.End }) {
            TextInput({ text: this.dialogUrl, placeholder: 'https://…' })
              .width('100%').height(48)
              .fontSize(14)
              .onChange((v: string) => { this.dialogUrl = v; })
              .onSubmit(() => { this.applyDialogUrl(); })
            if (this.dialogTarget === 'vod' || this.dialogTarget === 'wallpaper') {
              Text('📁')
                .fontSize(20)
                .padding({ left: 10, right: 12, top: 10, bottom: 10 })
                .onClick(() => {
                  if (this.dialogTarget === 'vod') { this.importPackFile(); }
                  else { this.pickWallpaper(); }
                })
            }
          }
          .width('100%')
          Row({ space: 12 }) {
            Button('取消')
              .height(40).layoutWeight(1)
              .backgroundColor('#F5F5F5').fontColor('#333333')
              .onClick(() => { this.showUrlDialog = false; })
            Button('确定')
              .height(40).layoutWeight(1)
              .backgroundColor('#007AFF').fontColor('#FFFFFF')
              .onClick(() => { this.applyDialogUrl(); })
          }
          .width('100%').margin({ top: 16 })
        }
        .width('80%')
        .padding(20)
        .backgroundColor('#FFFFFF')
        .borderRadius(12)
        .justifyContent(FlexAlign.Center)
      }

      // ---------- 历史记录弹窗 ----------
      if (this.showHistory) {
        Column() {
        }
        .width('100%').height('100%')
        .backgroundColor('#80000000')
        .onClick(() => { this.showHistory = false; })

        Column() {
          Text(this.dialogTarget === 'vod' ? '订阅历史' : this.dialogTarget === 'live' ? '直播历史' : '壁纸历史')
            .fontSize(16).fontWeight(FontWeight.Medium).fontColor('#222222')
            .margin({ bottom: 16 })
          if (UrlHistory.instance.get(this.dialogTarget).length === 0) {
            Text('暂无历史记录')
              .fontSize(14).fontColor('#999999')
              .padding(20)
          } else {
            Column() {
              ForEach(UrlHistory.instance.get(this.dialogTarget), (url: string) => {
                Text(url)
                  .fontSize(13).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .fontColor('#444444')
                  .width('100%').padding({ top: 10, bottom: 10 })
                  .onClick(() => {
                    this.showHistory = false;
                    this.dialogTarget = this.dialogTarget;
                    this.dialogUrl = url;
                    this.showUrlDialog = true;
                  })
              })
            }
            .width('100%')
            Button('清除历史')
              .height(36).width('100%').margin({ top: 12 })
              .backgroundColor('#F5F5F5').fontColor('#C62828')
              .onClick(() => {
                UrlHistory.instance.clear(this.dialogTarget);
                this.showHistory = false;
              })
          }
        }
        .width('80%')
        .padding(20)
        .backgroundColor('#FFFFFF')
        .borderRadius(12)
        .justifyContent(FlexAlign.Center)
      }
      }
      .width('100%').height('100%')
      .alignContent(Alignment.Center)
    }
    .hideTitleBar(false)
    .title('设置')
    .onBackPressed(() => { return false; })
  }

  private applyDialogUrl(): void {
    const url = this.dialogUrl.trim();
    if (this.dialogTarget === 'vod') {
      this.inputUrl = url;
      this.showUrlDialog = false;
      if (url.length > 0) {
        try { UrlHistory.instance.add('vod', url); } catch (e) { /* 历史写入失败不阻断加载 */ }
        this.doLoad();
      }
    } else if (this.dialogTarget === 'live') {
      this.inputLiveUrl = url;
      this.settings.liveUrl = url;
      this.settings.save();
      this.showUrlDialog = false;
      if (url.length > 0) {
        try { UrlHistory.instance.add('live', url); } catch (e) { /* ignore */ }
      }
    } else if (this.dialogTarget === 'proxy') {
      this.inputProxyUrl = url;
      this.settings.proxyUrl = url;
      this.settings.save();
      this.showUrlDialog = false;
    } else if (this.dialogTarget === 'wallpaper') {
      this.showUrlDialog = false;
      if (url.length > 0) {
        try { UrlHistory.instance.add('wallpaper', url); } catch (e) { /* ignore */ }
        this.settings.wallpaperUri = url;
        this.settings.save();
      } else {
        this.clearWallpaper();
      }
    }
  }

  // 点播弹窗 📁：选择聚合源 JSON 文件 → 解析装载 → 替换当前源（subUrl 清空为本地源包形态）
  private importPackFile(): void {
    this.localErr = '';
    this.localOk = '';
    try {
      const opt = new picker.DocumentSelectOptions();
      opt.maxSelectNumber = 1;
      opt.fileSuffixFilters = ['json'];
      const dp = new picker.DocumentViewPicker();
      dp.select(opt).then((uris: string[]) => {
        if (uris.length === 0) { return; }
        try {
          const f = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
          const stat = fs.statSync(f.fd);
          const buf = new ArrayBuffer(Math.max(stat.size, 1));
          const n = fs.readSync(f.fd, buf);
          fs.closeSync(f);
          const text = new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buf.slice(0, n)));
          if (this.app.loadFromPackText(text)) {
            this.showUrlDialog = false;
            this.localOk = `已导入本地源包（${this.app.config?.sites.length ?? 0} 个源），已替换当前源`;
            Nav.stack.pop();   // 回首页；HomePage onShown 检测到配置更换后自动刷新
          } else {
            this.localErr = '源包导入失败：' + this.app.errMsg;
          }
        } catch (e) {
          this.localErr = '源包导入失败：' + (e instanceof Error ? e.message : String(e));
        }
      }).catch((_e: Object) => { /* 未选择文件 */ });
    } catch (e) {
      this.localErr = '打开文件选择器失败';
    }
  }

  private async doLoad(): Promise<void> {
    this.busy = true;
    this.localErr = '';
    this.localOk = '';
    this.app.errMsg = '';
    try {
      const ok = await this.app.loadFromUrl(this.inputUrl.trim());
      this.busy = false;
      if (ok) {
        this.app.persistCurrent();
        this.localOk = '订阅已加载，返回首页即可使用';
        Nav.stack.pop();   // 回首页；HomePage onShown 检测到配置对象更换后自动刷新
      } else {
        this.localErr = this.app.errMsg;  // 失败留在本页展示（phase 未变，无需路由兜底）
      }
    } catch (e) {
      this.busy = false;
      this.localErr = e instanceof Error ? e.message : String(e);
    }
  }
}
