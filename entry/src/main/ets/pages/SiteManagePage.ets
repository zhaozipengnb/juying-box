// 站点管理二级页：启用/禁用 + 上下排序当前配置里的全部受支持站点。
// 禁用状态存 AppSettings.disabledSites（下拉/聚合搜索/自动跳源/初始选站全部过滤）；
// 排序直接改 config.sites 顺序并经 AppState.reorderSite 持久化（订阅与源包通用）。
import { Nav } from '../nav/Nav';
import { AppState } from '../state/AppState';
import { AppSettings } from '../state/AppSettings';
import { SiteConfig, isSiteSupported, siteEngine } from 'common';

interface SiteRow {
  key: string;
  name: string;
  engine: string;
  disabled: boolean;
}

function engineLabel(s: SiteConfig): string {
  const e = siteEngine(s);
  if (e === 'cms') { return 'CMS'; }
  if (e === 'xml') { return 'XML'; }
  if (e === 'js') { return 'JS'; }
  if (e === 'appys') { return 'AppYs'; }
  if (e === 'proxy') { return '代理'; }
  return '';
}

@ComponentV2
export struct SiteManagePage {
  app: AppState = AppState.instance;
  settings: AppSettings = AppSettings.instance;
  @Local rows: SiteRow[] = [];
  @Local curKey: string = '';

  aboutToAppear(): void {
    this.rebuild();
  }

  private rebuild(): void {
    const cfg = this.app.config;
    if (cfg === null) { this.rows = []; return; }
    const out: SiteRow[] = [];
    for (const s of cfg.sites) {
      if (!isSiteSupported(s)) { continue; }   // 不支持的引擎（Py/JAR）不在管理范围
      out.push({
        key: s.key,
        name: s.name,
        engine: engineLabel(s),
        disabled: this.settings.isSiteDisabled(s.key)
      });
    }
    this.rows = out;
    this.curKey = this.app.currentSite?.key ?? '';
  }

  // 禁用当前使用中的站点时，自动切到第一个可用源
  private onToggle(row: SiteRow): void {
    this.settings.toggleSiteDisabled(row.key);
    if (row.key === this.curKey && this.settings.isSiteDisabled(row.key)) {
      const cfg = this.app.config;
      if (cfg !== null) {
        for (const s of cfg.sites) {
          if (isSiteSupported(s) && this.app.canDrive(s) && siteEngine(s) !== 'proxy'
            && !this.settings.isSiteDisabled(s.key)) {
            this.app.switchSite(s.key);
            break;
          }
        }
      }
    }
    this.rebuild();
  }

  private onMove(index: number, dir: number): void {
    const to = index + dir;
    if (to < 0 || to >= this.rows.length) { return; }
    const cfg = this.app.config;
    if (cfg === null) { return; }
    const key = this.rows[index].key;
    const cfgIdx = cfg.sites.findIndex((s: SiteConfig): boolean => s.key === key);
    if (cfgIdx >= 0) { this.app.reorderSite(cfgIdx, cfgIdx + dir); }
    this.rebuild();
  }

  build() {
    NavDestination() {
      Column() {
        Text('站点管理').fontSize(22).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
        .width('100%').padding({ left: 16, right: 16, top: 14, bottom: 8 })

        Scroll() {
          Column() {
            ForEach(this.rows, (r: SiteRow, i: number) => {
              Row({ space: 10 }) {
                Column({ space: 2 }) {
                  Row({ space: 6 }) {
                    Text(r.name).fontSize(14).fontColor('#FFFFFF')
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    if (r.engine !== '') {
                      Text(r.engine).fontSize(9).fontColor('#B3FFFFFF')
                        .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                        .backgroundColor('#33FFFFFF').borderRadius(4)
                    }
                    if (r.key === this.curKey) {
                      Text('使用中').fontSize(9).fontColor('#4D9EFF')
                        .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                        .backgroundColor('#1A4D9EFF').borderRadius(4)
                    }
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                // 排序
                Column({ space: 4 }) {
                  Text('▲').fontSize(11).fontColor(i > 0 ? '#FFFFFF' : '#44FFFFFF')
                    .onClick(() => { if (i > 0) { this.onMove(i, -1); } })
                  Text('▼').fontSize(11).fontColor(i < this.rows.length - 1 ? '#FFFFFF' : '#44FFFFFF')
                    .onClick(() => { if (i < this.rows.length - 1) { this.onMove(i, 1); } })
                }
                .alignItems(HorizontalAlign.Center)

                // 启用/禁用
                Toggle({ type: ToggleType.Switch, isOn: !r.disabled })
                  .selectedColor('#007DFF')
                  .onChange((_v: boolean) => { this.onToggle(r); })
              }
              .width('100%')
              .padding({ left: 18, right: 16, top: 10, bottom: 10 })
              .backgroundColor(r.disabled ? '#33888888' : '#66888888')
              .borderRadius(9)
              .margin({ top: 4, bottom: 4 })
              .opacity(r.disabled ? 0.55 : 1)
            }, (r: SiteRow) => r.key + r.disabled)
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
    }
    .hideTitleBar(true)
  }

  @Computed get wallpaperColors(): Array<[ResourceColor, number]> {
    const w = this.settings.wallpaper;
    if (w === 'dark') { return [['#FF141416', 0.0], ['#FF232326', 1.0]]; }
    if (w === 'blue') { return [['#FF0E1E3C', 0.0], ['#FF1B3A5E', 1.0]]; }
    if (w === 'green') { return [['#FF12291F', 0.0], ['#FF1E4030', 1.0]]; }
    return [['#FFFFFFFF', 0.0], ['#FFFFFFFF', 1.0]];
  }

}
