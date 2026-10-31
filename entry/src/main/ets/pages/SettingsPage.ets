// 设置页（FongMi 格式）：三张 URL 卡（点播/直播/壁纸）+ 播放设置/个性设置入口行
// + Proxy/DoH/缓存/版本/关于 值行；播放与个性配置收拢在二级页（PlaySettings/PersonSettings）。
// 个性化设置即改即存（AppSettings.save），返回首页后由各消费点读取生效。
import { AppState } from '../state/AppState';
import { pickImportPack } from '../state/PackImport';
import { AppSettings } from '../state/AppSettings';
import { UrlHistory } from '../state/UrlHistory';
import { SettingRow } from '../components/SettingRow';
import { MainTabBar } from '../components/MainTabBar';
import { Nav } from '../nav/Nav';
import { httpFetch } from '../net/HttpClient';
import { common } from '@kit.AbilityKit';
import fs from '@ohos.file.fs';
import { pasteboard } from '@kit.BasicServicesKit';
import { picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';

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
  @Local dialogUrl: string = '';
  @Local dialogTarget: string = '';   // 'vod' | 'live' | 'proxy' | 'wallpaper'
  @Local busy: boolean = false;
  @Local localErr: string = '';
  @Local localOk: string = '';
  @Local cacheBytes: number = -1;   // -1 = 未统计
  @Local editingSub: boolean = false;

  aboutToAppear(): void {
    this.inputUrl = this.app.subUrl;
    this.inputLiveUrl = this.settings.liveUrl;
    this.inputProxyUrl = this.settings.proxyUrl;
    this.refreshCacheSize();
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
    return true;   // 默认背景为青橙渐变图，文字统一白色
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
        // 时间戳文件名：路径变化才能触发重渲染并绕过图片路径缓存
        const destPath = (getContext(this) as common.UIAbilityContext).filesDir + '/wallpaper_' + Date.now() + '.jpg';
        const srcFile = fs.openSync(srcUri, fs.OpenMode.READ_ONLY);
        const destFile = fs.openSync(destPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        fs.copyFileSync(srcFile.fd, destFile.fd);
        fs.closeSync(srcFile);
        fs.closeSync(destFile);
        this.replaceWallpaperFile(destPath);
        this.showUrlDialog = false;
        this.localErr = '';
        this.localOk = '壁纸已更新为本地图片';
      }
    } catch (e) { /* 用户取消或权限不足 */ }
  }

  // 更新壁纸路径并清理旧沙箱文件（仅删本应用 filesDir 下的旧拷贝，不动用户相册/链接）
  private replaceWallpaperFile(destPath: string): void {
    const old = this.settings.wallpaperUri;
    this.settings.wallpaperUri = destPath;
    this.settings.save();
    const ctx = getContext(this) as common.UIAbilityContext;
    if (old !== '' && old !== destPath && old.startsWith(ctx.filesDir)) {
      try { fs.unlinkSync(old); } catch (e) { /* 旧文件已不存在则忽略 */ }
    }
  }

  private clearWallpaper(): void {
    this.settings.wallpaperUri = '';
    this.settings.save();
  }

  // 刷新壁纸：URL 壁纸重新拉取到沙箱并落盘（覆盖旧缓存，强制重渲染）；本地壁纸重新加载
  private async refreshWallpaper(): Promise<void> {
    const uri = this.settings.wallpaperUri.trim();
    hilog.info(0x0000, 'OKV', 'wallpaper refresh uri=%{public}s', uri);
    if (uri === '') { this.localErr = '未设置壁纸图片'; return; }
    this.localErr = '';
    this.localOk = '';
    try {
      if (/^https?:\/\//i.test(uri)) {
        // 时间戳文件名：覆盖同名文件不会触发重渲染（路径不变 + 图片按路径缓存），
        // 每次落新文件并删除旧沙箱文件，强制换图
        const destPath = (getContext(this) as common.UIAbilityContext).filesDir + '/wallpaper_' + Date.now() + '.jpg';
        const r = await httpFetch(uri, {});
        if (r.status !== 200) { throw new Error('HTTP ' + r.status); }
        const destFile = fs.openSync(destPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        fs.writeSync(destFile.fd, r.body);
        fs.closeSync(destFile);
        this.replaceWallpaperFile(destPath);
        this.localOk = '壁纸已刷新（' + destPath.substring(destPath.lastIndexOf('/') + 1) + '）';
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

  // 分享：备份 JSON 复制到剪贴板（微信/网盘等任意途径传到其他设备粘贴导入）
  private shareBackup(): void {
    try {
      this.settings.save();
      interface BackupPayload { settingsJson: string; exportedAt: string; }
      const payload: BackupPayload = {
        settingsJson: this.settings.toJson(),
        exportedAt: String(Date.now())
      };
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, JSON.stringify(payload));
      pasteboard.getSystemPasteboard().setData(data);
      this.localOk = '配置已复制到剪贴板';
    } catch (e) {
      this.localErr = '分享失败：' + (e instanceof Error ? e.message : String(e));
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

  build() {
    NavDestination() {
      Column() {
      Stack() {
      Scroll() {
        Column() {
          // 页面标题（系统标题栏已去，自绘与首页同风格）
          Text('设置')
            .fontSize(20).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
            .width('100%').padding({ left: 16, right: 16, top: 14, bottom: 4 })
          // ---------- 点播 ----------
          Row() {
            Text('点播').fontSize(16).fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
            Text(this.vodRowText())
              .fontSize(13).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontColor('#FFFFFF')
              .layoutWeight(1).margin({ left: 12 })
            if (!this.app.isPackSource) {
              Text('更新')
                .fontSize(13).fontColor(this.app.subUrl === '' ? '#FFFFFF' : '#007AFF')
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .borderRadius(6)
                .backgroundColor(this.isDarkWallpaper ? '#26FFFFFF' : '#F5F5F5')
                .margin({ left: 8 })
                .hitTestBehavior(HitTestMode.Block)
                .onClick(() => { this.refreshSub(); })
              Image($r('app.media.ic_history'))
                .width(20).height(20)
                .fillColor('#FFFFFF')
                .margin({ left: 8 })
                .hitTestBehavior(HitTestMode.Block)
                .onClick(() => { this.dialogTarget = 'vod'; this.showHistory = true; })
            }
          }
          .width('100%').padding({ left: 16, right: 14, top: 8, bottom: 8 })
          .backgroundColor('#66888888')
          .borderRadius(9)
          .margin({ top: 4, bottom: 4 })
          .onClick(() => {
            this.dialogTarget = 'vod';
            this.dialogUrl = this.app.subUrl;
            this.showUrlDialog = true;
          })
          if (this.localErr !== '') {
            Text('错误：' + this.localErr).fontSize(13).fontColor('#FFFFFF').width('100%').padding({ left: 16, right: 16 })
          }
          if (this.localOk !== '') {
            Text(this.localOk).fontSize(13).fontColor('#FFFFFF').width('100%').padding({ left: 16, right: 16 })
          }

          // ---------- 直播 ----------
          Row() {
            Text('直播').fontSize(16).fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
            Text(this.inputLiveUrl === '' ? '未设置' : this.inputLiveUrl)
              .fontSize(13).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontColor('#FFFFFF')
              .layoutWeight(1).margin({ left: 12 })
            Image($r('app.media.ic_history'))
              .width(20).height(20)
              .fillColor('#FFFFFF')
              .margin({ left: 8 })
              .hitTestBehavior(HitTestMode.Block)
              .onClick(() => { this.dialogTarget = 'live'; this.showHistory = true; })
          }
          .width('100%').padding({ left: 16, right: 14, top: 8, bottom: 8 })
          .backgroundColor('#66888888')
          .borderRadius(9)
          .margin({ top: 4, bottom: 4 })
          .onClick(() => {
            this.dialogTarget = 'live';
            this.dialogUrl = this.inputLiveUrl;
            this.showUrlDialog = true;
          })

          // ---------- 壁纸图片 ----------
          Row() {
            Text('壁纸').fontSize(16).fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
            Text(this.wallpaperUri !== '' ? this.wallpaperUri : '未设置')
              .fontSize(13).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontColor('#FFFFFF')
              .layoutWeight(1).margin({ left: 12 })
            Image($r('app.media.ic_refresh'))
              .width(20).height(20)
              .fillColor('#FFFFFF')
              .margin({ left: 8 })
              .hitTestBehavior(HitTestMode.Block)
              .onClick(() => { this.refreshWallpaper(); })
          }
          .width('100%').padding({ left: 16, right: 14, top: 8, bottom: 8 })
          .backgroundColor('#66888888')
          .borderRadius(9)
          .margin({ top: 4, bottom: 4 })
          .onClick(() => {
            this.dialogTarget = 'wallpaper';
            this.dialogUrl = this.wallpaperUri;
            this.showUrlDialog = true;
          })

          // ---------- 入口行：二级页 ----------
          SettingRow({ label: '站点管理', sub: '启用/禁用与排序当前配置中的站点', arrow: true,
            onTap: (): void => { Nav.stack.pushPathByName('SiteManage', ''); } })
          SettingRow({ label: '播放设置', sub: '倍速 / 长按 / 去广告 / 下载', arrow: true,
            onTap: (): void => { Nav.stack.pushPathByName('PlaySettings', ''); } })
          SettingRow({ label: '个性设置', sub: '壁纸主题 / 海报密度 / 搜索偏好', arrow: true,
            onTap: (): void => { Nav.stack.pushPathByName('PersonSettings', ''); } })

          // ---------- Proxy（csp_* JAR 爬虫的远程代理；鸿蒙端无 JVM，JAR 须在外部设备执行）----------
          SettingRow({
            label: '代理地址',
            sub: this.inputProxyUrl === '' ? '未设置（纯 JAR 源不可用，不影响采集站/drpy 源）'
              : '在电脑/NAS 运行 tools/proxy-server 后填入其地址'
          }) {
            Button('编辑')
              .height(36)
              .backgroundColor('#3A3A3C')
              .fontColor('#FFFFFF')
              .onClick(() => {
                this.dialogTarget = 'proxy';
                this.dialogUrl = this.inputProxyUrl;
                this.showUrlDialog = true;
              })
          }

          // ---------- 备份恢复 ----------
          SettingRow({ label: '配置备份', sub: '导出订阅与个性化设置，可分享给其他设备' }) {
            Button('导出')
              .height(36)
              .backgroundColor('#3A3A3C')
              .fontColor('#FFFFFF')
              .onClick(() => { this.exportBackup(); })
            Button('分享')
              .height(36)
              .backgroundColor('#3A3A3C')
              .fontColor('#FFFFFF')
              .margin({ left: 8 })
              .onClick(() => { this.shareBackup(); })
          }
          SettingRow({ label: '配置恢复', sub: '从备份文件导入配置' }) {
            Button('导入')
              .height(36)
              .backgroundColor('#3A3A3C')
              .fontColor('#FFFFFF')
              .onClick(() => { this.importBackup(); })
          }

          // ---------- 缓存 ----------
          SettingRow({ label: '缓存占用', sub: this.fmtSize(this.cacheBytes) + '（图片等运行缓存）' }) {
            Button('清理')
              .height(36)
              .backgroundColor('#F5F5F5').fontColor('#C62828')
              .onClick(() => { this.clearCache(); })
          }

          // ---------- 版本 ----------
          SettingRow({ label: '当前版本', sub: 'v1.0.0' })

          // ---------- 关于 ----------
          SettingRow({ label: '关于应用', sub: '点播 / 直播聚合播放器' }) {
          }

          Text('清除订阅不影响个性化设置；个性化设置与订阅分开存储。')
            .fontSize(12).fontColor('#FFFFFF')
            .width('100%').padding({ left: 16, right: 16 }).margin({ top: 16, bottom: 30 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ left: 16, right: 16, bottom: 76 })
      }
      .width('100%').height('100%')
      .scrollBar(BarState.Auto)


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
            TextInput({ text: this.dialogUrl!!, placeholder: 'https://…' })
              .width('100%').height(48)
              .fontSize(14)
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
      .width('100%')
      .layoutWeight(1)
      .alignContent(Alignment.Center)

      // 底部导航栏（TV 不渲染）
      MainTabBar({ active: 'settings' })
      }
      .width('100%').height('100%')
      .linearGradient({ angle: 160, colors: this.wallpaperColors })
      .backgroundImage(this.settings.bgImage())
      .backgroundImageSize(ImageSize.Cover)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .hideTitleBar(true)
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
      hilog.info(0x0000, 'OKV', 'wallpaper apply target=%{public}s url=%{public}s', this.dialogTarget, url);
      this.showUrlDialog = false;
      if (url.length > 0) {
        try { UrlHistory.instance.add('wallpaper', url); } catch (e) { /* ignore */ }
        this.settings.wallpaperUri = url;
        this.settings.save();
        hilog.info(0x0000, 'OKV', 'wallpaper saved uri=%{public}s', this.settings.wallpaperUri);
      } else {
        hilog.info(0x0000, 'OKV', 'wallpaper CLEARED (empty url)');
        this.clearWallpaper();
      }
    }
  }

  // 点播弹窗 📁：选择聚合源 JSON 文件 → 解析装载 → 替换当前源（subUrl 清空为本地源包形态）
  private async importPackFile(): Promise<void> {
    this.localErr = '';
    this.localOk = '';
    try {
      const total = await pickImportPack(this.app);
      if (total < 0) { return; }   // 未选择文件
      this.localOk = `已导入本地源包（${total} 个源），已替换当前源`;
      Nav.stack.pop();   // 回首页；HomePage onShown 检测到配置更换后自动刷新
    } catch (e) {
      this.localErr = '源包导入失败：' + (e instanceof Error ? e.message : String(e));
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
