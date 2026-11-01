// 下载管理页：列出所有下载任务，支持暂停/恢复/删除/播放。
import { DownloadManager, DownloadItem, DownloadStatus } from '../state/DownloadManager';
import { AppSettings } from '../state/AppSettings';
import { Nav, PlayerParam } from '../nav/Nav';
import { Episode } from 'common';

@ComponentV2
export struct DownloadPage {
  dl: DownloadManager = DownloadManager.instance;
  settings: AppSettings = AppSettings.instance;
  // 单例镜像:本 SDK 下 @ComponentV2 经普通成员读 @ObservedV2 单例不建立响应依赖(坑#3 变体)
  @Local dlList: DownloadItem[] = [];

  // 任务增删后同步镜像;进度/状态是 @Trace 字段,镜像持同一实例即可实时刷新
  private refreshDl(): void {
    this.dlList = this.dl.items.slice();
  }

  @Computed get isDarkWallpaper(): boolean {
    return true;   // 默认背景为青橙渐变图，文字统一白色
  }

  @Computed get wallpaperColors(): Array<[ResourceColor, number]> {
    const w = this.settings.wallpaper;
    if (w === 'dark') { return [['#FF141416', 0.0], ['#FF232326', 1.0]]; }
    if (w === 'blue') { return [['#FF0E1E3C', 0.0], ['#FF1B3A5E', 1.0]]; }
    if (w === 'green') { return [['#FF12291F', 0.0], ['#FF1E4030', 1.0]]; }
    return [['#FFFFFFFF', 0.0], ['#FFFFFFFF', 1.0]];
  }

  private statusText(s: DownloadStatus): string {
    if (s === 'pending') { return '等待中'; }
    if (s === 'downloading') { return '下载中'; }
    if (s === 'paused') { return '已暂停'; }
    if (s === 'completed') { return '已完成'; }
    return '失败';
  }

  private statusColor(s: DownloadStatus): string {
    if (s === 'completed') { return '#4CAF50'; }
    if (s === 'failed') { return '#E53935'; }
    if (s === 'paused') { return '#FF9800'; }
    return this.isDarkWallpaper ? '#AAAAAA' : '#666666';
  }

  private fmtSize(bytes: number): string {
    if (bytes <= 0) { return '--'; }
    if (bytes < 1024 * 1024) { return `${(bytes / 1024).toFixed(0)} KB`; }
    if (bytes < 1024 * 1024 * 1024) { return `${(bytes / 1024 / 1024).toFixed(1)} MB`; }
    return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} GB`;
  }

  build() {
    NavDestination() {
      Scroll() {
        Column() {
          if (this.dlList.length > 0) {
            Row() {
              Blank()
              Text('清空')
                .fontSize(13).fontColor('#E53935')
                .padding({ right: 4, top: 4, bottom: 4 })
                .onClick(() => {
                  this.dl.removeAll();
                  this.refreshDl();
                })
            }.width('100%').padding({ left: 16, right: 20, top: 4 })
          }
          if (this.dlList.length === 0) {
            // 空态
            Column() {
              Image($r('app.media.ic_empty')).width(48).height(48).fillColor('#FFFFFF').margin({ bottom: 12 })
              Text('暂无下载任务').fontSize(15)
                .fontColor('#FFFFFF')
              Text('在详情页或播放页可下载影片').fontSize(12).margin({ top: 6 })
                .fontColor('#FFFFFF')
            }
            .width('100%').height('100%')
            .justifyContent(FlexAlign.Center)
          } else {
            ForEach(this.dlList, (it: DownloadItem) => {
              Row() {
                // 左侧：标题 + 进度
                Column() {
                  Text(`${it.movieName} · ${it.epName}`)
                    .fontSize(14).fontWeight(FontWeight.Medium)
                    .fontColor('#FFFFFF')
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')

                  Row() {
                    Progress({ value: it.progress, total: 100, type: ProgressType.Linear })
                      .width('70%').height(4)
                      .color(it.status === 'completed' ? '#4CAF50' : '#2196F3')
                      .backgroundColor('#3A3A3C')
                    Text(`${it.progress}%`).fontSize(11)
                      .fontColor('#FFFFFF')
                      .margin({ left: 8 })
                  }
                  .width('100%').margin({ top: 8 })

                  Row() {
                    Text(this.statusText(it.status)).fontSize(11)
                      .fontColor(this.statusColor(it.status))
                    if (it.totalSize > 0) {
                      Text(` · ${this.fmtSize(it.downloadedSize)}/${this.fmtSize(it.totalSize)}`)
                        .fontSize(11)
                        .fontColor('#FFFFFF')
                    }
                  }
                  .width('100%').margin({ top: 4 })
                }
                .layoutWeight(1).alignItems(HorizontalAlign.Start)

                // 右侧：操作按钮
                Row() {
                  if (it.status === 'downloading') {
                    Button('暂停').height(32).fontSize(12)
                      .backgroundColor('#3A3A3C')
                      .fontColor('#FFFFFF')
                      .onClick(() => { this.dl.pause(it.id).then((): void => this.refreshDl()); })
                  } else if (it.status === 'paused' || it.status === 'failed') {
                    Button('继续').height(32).fontSize(12)
                      .backgroundColor('#3A3A3C')
                      .fontColor('#FFFFFF')
                      .onClick(() => { this.dl.resume(it.id).then((): void => this.refreshDl()); })
                  }
                  if (it.status === 'completed') {
                    Button('播放').height(32).fontSize(12).margin({ left: 6 })
                      .backgroundColor('#2196F3').fontColor('#FFFFFF')
                      .onClick(() => {
                        const ep: Episode = { name: it.epName, url: `file://${it.localPath}` };
                        const param: PlayerParam = { ep: ep, siteKey: it.siteKey };
                        Nav.stack.pushPathByName('Player', param);
                      })
                  }
                  Button('删除').height(32).fontSize(12).margin({ left: 6 })
                    .backgroundColor('#3A3A3C')
                    .fontColor('#E53935')
                    .onClick(() => { this.dl.remove(it.id).then((): void => this.refreshDl()); })
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })
              .margin({ bottom: 8 })
              .backgroundColor(this.isDarkWallpaper ? '#22FFFFFF' : '#FFFFFF')
              .borderRadius(12)
            })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ top: 12, bottom: 30 })
      }
      .width('100%').height('100%')
      .scrollBar(BarState.Auto)
      .align(Alignment.Top)   // 内容不足一屏时从顶部开始排,不居中悬空
      .linearGradient({ angle: 160, colors: this.wallpaperColors })
      .backgroundImage(this.settings.bgImage())
      .backgroundImageSize(ImageSize.Cover)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

    }
    .hideTitleBar(false)
    .title('下载管理')
    .onShown(() => { this.refreshDl(); })   // 每次可见都同步单例(新增/删除任务后回来也是最新)
    .onBackPressed(() => { return false; })
  }
}
